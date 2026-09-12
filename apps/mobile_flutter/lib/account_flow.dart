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

  /// 设备批准:把 `plaintext`(本机账号私钥)用对方设备的临时公钥封起来,只有
  /// 那台设备自己的临时私钥能拆开(`sync_open_sealed`,在那台设备上跑,不在这里)。
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext);
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

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) => rust.syncSealTo(public: public, plaintext: plaintext);
}

/// [AccountFlow.prepareKeys] 的返回值——纯内存,不落任何盘。交给
/// [AccountFlow.commitKeys] 才会真正上传 + 存进本机 secure storage。
typedef PreparedKeys = ({
  Uint8List publicKey,
  Uint8List privateKey,
  Uint8List wrappedPw,
  Uint8List wrappedRc,
  Uint8List salt,
  String recoveryCode,
});

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

  /// 本屏重建/冷启动时用:如果本机已经有登录 token(`loginOtp`/`loginApple`
  /// 早先存过),照 [_afterLogin] 同一套逻辑重新判一次该走哪个阶段——不重新发
  /// OTP、不重新走登录。从没登录过(或 `AccountSession.clear()` 过)时
  /// `session.accountId` 为 null,返回 null,UI 留在最初的登录入口。
  Future<LoginOutcome?> resumeIfLoggedIn() async {
    if (session.accountId == null || session.access == null) return null;
    return _afterLogin();
  }

  /// 首次注册,第一步:生成密钥对、口令包一份、恢复码包一份——**纯内存操作,
  /// 不上传、不写本机存储**。恢复码只在返回值里出现这一次。
  ///
  /// 与 [commitKeys] 分成两步,是因为中间要插一道「用户必须先抄下恢复码」的
  /// UI 关卡(见 `account_screen.dart` 的 showRecovery 阶段)——如果这一步就把
  /// 密钥传上服务器、存进本机,那道关卡就只是摆设:App 在恢复码画面被强杀,
  /// 账号已经是「有效可用」的了,但恢复码再也拿不出来第二次。拆成两步之后,
  /// 强杀导致的最坏情况只是「服务端和本机都还没有这个账号的密钥」——用户下次
  /// 打开重新走一遍注册即可(会生成一把全新的密钥对,这一把从未落过盘、从未
  /// 上传过,不构成任何残留状态,谈不上"丢失")。
  Future<PreparedKeys> prepareKeys(String password) async {
    final (pub, sec) = await crypto.accountKeysNew();
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final pw = await crypto.wrapPrivate(sec, password, salt, kdf.mKib, kdf.t, kdf.p);
    final code = await crypto.recoveryCodeNew();
    final rc = await crypto.wrapPrivateRc(sec, code);
    return (publicKey: pub, privateKey: sec, wrappedPw: pw, wrappedRc: rc, salt: salt, recoveryCode: code);
  }

  /// 第二步,只应该在用户点了「我已抄下恢复码」之后调用:把 [prepareKeys] 备好
  /// 的密文上传服务器、私钥存进本机 secure storage。这一步失败(比如服务器
  /// 500)不清 `keys`——UI 应该原样保留恢复码画面,允许用户直接重试这一步,
  /// 不必重新生成一把新密钥对。
  Future<void> commitKeys(PreparedKeys keys) async {
    await api.putJson('/v1/account/keys', {
      'public_key': base64Encode(keys.publicKey),
      'wrapped_priv_pw': base64Encode(keys.wrappedPw),
      'wrapped_priv_rc': base64Encode(keys.wrappedRc),
      'kdf_salt': base64Encode(keys.salt),
      'kdf_params': {'m_kib': kdf.mKib, 't': kdf.t, 'p': kdf.p},
    });
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: keys.publicKey,
      privateKey: keys.privateKey,
    );
    lastOutcome = LoginOutcome.ready;
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
