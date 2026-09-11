import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// 本机在服务端的登记名——首次用时生成、存进 shared_preferences,后续复用。
/// 不落 secure storage:它不是密钥,只是设备批准/审计用的一个标识符,泄露无害。
Future<String> deviceId() async {
  final p = await SharedPreferences.getInstance();
  var id = p.getString('device_id');
  if (id == null) {
    final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
    id = base64UrlEncode(bytes).replaceAll('=', '');
    await p.setString('device_id', id);
  }
  return id;
}

/// 登录之后、密钥就绪之前,UI 该走哪条路。
enum LoginOutcome {
  /// 服务端还没有这个账号的密钥(`GET /v1/account/keys` 404)—— 首次注册,
  /// 需要设口令、生成密钥对。
  needsKeySetup,

  /// 服务端有密钥,但本机没有解出来的私钥(新设备/清过 App)—— 需要口令或
  /// 恢复码解锁。
  needsUnlock,

  /// 本机已经有私钥,可以直接用。
  ready,
}

/// 口令/恢复码解不开私钥。**绝不吞掉、绝不清 session**——调用方只应据此展示
/// 错误并允许重试,账号登录态本身不受影响。
class UnlockFailed implements Exception {
  const UnlockFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 对 `sync_*` FRB 调用的薄包装,纯粹是为了让 [AccountFlow] 在测试里可以注入假实现
/// (widget test 不应该碰真实 Rust bridge)。方法与参数一一对应 FRB 侧签名。
abstract class SyncCrypto {
  Future<(Uint8List, Uint8List)> accountKeysNew();
  Future<Uint8List> wrapPrivate(Uint8List secret, String password, Uint8List salt, int mKib, int t, int p);
  Future<Uint8List> unwrapPrivatePw(Uint8List blob, String password, Uint8List salt, int mKib, int t, int p);
  Future<String> recoveryCodeNew();
  Future<Uint8List> wrapPrivateRc(Uint8List secret, String code);
  Future<Uint8List> unwrapPrivateRc(Uint8List blob, String code);
}

class RustCrypto implements SyncCrypto {
  const RustCrypto();

  @override
  Future<(Uint8List, Uint8List)> accountKeysNew() => rust.syncAccountKeysNew();

  @override
  Future<Uint8List> wrapPrivate(Uint8List secret, String password, Uint8List salt, int mKib, int t, int p) =>
      rust.syncWrapPrivate(secret: secret, password: password, salt: salt, mKib: mKib, t: t, p: p);

  @override
  Future<Uint8List> unwrapPrivatePw(Uint8List blob, String password, Uint8List salt, int mKib, int t, int p) =>
      rust.syncUnwrapPrivatePw(blob: blob, password: password, salt: salt, mKib: mKib, t: t, p: p);

  @override
  Future<String> recoveryCodeNew() => rust.syncRecoveryCodeNew();

  @override
  Future<Uint8List> wrapPrivateRc(Uint8List secret, String code) => rust.syncWrapPrivateRc(secret: secret, code: code);

  @override
  Future<Uint8List> unwrapPrivateRc(Uint8List blob, String code) => rust.syncUnwrapPrivateRc(blob: blob, code: code);
}

/// 注册 / 登录 / 解锁 / 设备批准的编排——不含任何 UI。[AccountScreen] 只负责
/// 按返回值/异常切状态、画界面。
class AccountFlow {
  AccountFlow(this.api, this.session, {this.crypto = const RustCrypto()});

  final ApiClient api;
  final AccountSession session;
  final SyncCrypto crypto;

  /// Argon2id 参数。Task 14 会在真机上实测 `syncKdfBenchMs` 之后回来改这一处——
  /// 全部口令包/解包只从这一个常量取,改一次全生效。
  static const kdf = (mKib: 65536, t: 3, p: 1);

  Map<String, dynamic>? _serverKeys;

  /// [loginApple] 是 `Future<void>`(见接口),结果放这里给 UI 读。
  LoginOutcome? lastOutcome;

  Future<void> sendOtp(String phone) => api.postJson('/v1/auth/otp', {'phone': phone});

  Future<LoginOutcome> loginOtp(String phone, String code) async {
    final r = await api.postJson('/v1/auth/login', {
      'phone': phone,
      'code': code,
      'device_id': await deviceId(),
      'device_name': Platform.operatingSystem,
    });
    await session.save(accountId: r['account_id'] as String, access: r['access'] as String, refresh: r['refresh'] as String);
    return _afterLogin();
  }

  Future<void> loginApple() async {
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email],
    );
    final r = await api.postJson('/v1/auth/apple', {
      'identity_token': cred.identityToken,
      'device_id': await deviceId(),
      'device_name': Platform.operatingSystem,
    });
    await session.save(accountId: r['account_id'] as String, access: r['access'] as String, refresh: r['refresh'] as String);
    await _afterLogin();
  }

  Future<LoginOutcome> _afterLogin() async {
    try {
      final k = await api.getJson('/v1/account/keys') as Map<String, dynamic>;
      _serverKeys = k;
      lastOutcome = session.privateKey == null ? LoginOutcome.needsUnlock : LoginOutcome.ready;
    } on ApiFailed catch (e) {
      if (e.status != 404) rethrow;
      lastOutcome = LoginOutcome.needsKeySetup;
    }
    return lastOutcome!;
  }

  /// 首次:生成密钥对、口令包一份、恢复码包一份,上传;返回恢复码给 UI 展示——
  /// **只有这一次**能看到明文恢复码,之后服务端只存包好的密文,任何人(包括我们)
  /// 都读不出来。UI 必须强制用户确认已经抄下,见 `account_screen.dart`。
  Future<String> registerKeys(String password) async {
    final (pub, sec) = await crypto.accountKeysNew();
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final pw = await crypto.wrapPrivate(sec, password, salt, kdf.mKib, kdf.t, kdf.p);
    final code = await crypto.recoveryCodeNew();
    final rc = await crypto.wrapPrivateRc(sec, code);
    await api.putJson('/v1/account/keys', {
      'public_key': base64Encode(pub),
      'wrapped_priv_pw': base64Encode(pw),
      'wrapped_priv_rc': base64Encode(rc),
      'kdf_salt': base64Encode(salt),
      'kdf_params': {'m_kib': kdf.mKib, 't': kdf.t, 'p': kdf.p},
    });
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: pub,
      privateKey: sec,
    );
    lastOutcome = LoginOutcome.ready;
    return code;
  }

  Future<void> unlockWithPassword(String password) async {
    final k = _serverKeys!;
    final p = k['kdf_params'] as Map;
    final Uint8List sec;
    try {
      sec = await crypto.unwrapPrivatePw(
        base64Decode(k['wrapped_priv_pw'] as String),
        password,
        base64Decode(k['kdf_salt'] as String),
        p['m_kib'] as int,
        p['t'] as int,
        p['p'] as int,
      );
    } catch (_) {
      throw const UnlockFailed('口令不对');
    }
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: base64Decode(k['public_key'] as String),
      privateKey: sec,
    );
    lastOutcome = LoginOutcome.ready;
  }

  Future<void> unlockWithRecovery(String code) async {
    final k = _serverKeys!;
    final Uint8List sec;
    try {
      sec = await crypto.unwrapPrivateRc(base64Decode(k['wrapped_priv_rc'] as String), code);
    } catch (_) {
      throw const UnlockFailed('恢复码不对');
    }
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: base64Decode(k['public_key'] as String),
      privateKey: sec,
    );
    lastOutcome = LoginOutcome.ready;
  }
}
