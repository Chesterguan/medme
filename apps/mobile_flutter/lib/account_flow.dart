import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:mobile_flutter/vault_boot.dart';
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

  /// [sealTo] 的反向操作:用自己的私钥拆开别人用自己公钥封的密文。
  /// [AccountFlow.restoreProfileKeys] 拿它把 `wrapped_profile_key`(账号公钥封的
  /// 档案密钥)解出来——退出登录/换设备之后"重新登录自动恢复"的真正实现
  /// (Task 15 review C1:这条路径之前完全没有 Dart 调用点,是一句假文案)。
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob);
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

  @override
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob) => rust.syncOpenSealed(secret: secret, blob: blob);
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
  AccountFlow(
    this.api,
    this.session, {
    this.crypto = const RustCrypto(),
    this.reopenCurrentProfileVault = openCurrentProfileVault,
  });

  final ApiClient api;
  final AccountSession session;
  final SyncCrypto crypto;

  /// [restoreProfileKeys] 补完密钥后,如果补的正好是**当前打开的成员**、且它
  /// 补之前是锁着的,就用这个重开一次——测试注入点,默认真实的
  /// `vault_boot.openCurrentProfileVault`(`flutter test` 不能跑到它内部的
  /// FFI 开箱,测试传一个假的进来)。
  final Future<void> Function() reopenCurrentProfileVault;

  /// Argon2id 参数。Task 14 会在真机上实测 `syncKdfBenchMs` 之后回来改这一处——
  /// 全部口令包/解包只从这一个常量取,改一次全生效。
  static const kdf = (mKib: 65536, t: 3, p: 1);

  Map<String, dynamic>? _serverKeys;

  /// [loginApple] 是 `Future<void>`(见接口),结果放这里给 UI 读。
  LoginOutcome? lastOutcome;

  Future<void> sendOtp(String phone) => api.postJson('/v1/auth/otp', {'phone': phone});

  /// `account_login` 只覆盖「认证 + session.save」这一小段——**`_afterLogin()`
  /// 必须留在这个 try 外面**。它调的 `GET /v1/account/keys` 只吞 404
  /// (见 `_afterLogin`),非 404 会 rethrow;如果把它包进同一个 try,登录本身
  /// 明明成功了,却会因为账号密钥服务 500 被这里的 catch 接住,再报一条
  /// `ok:false`——一次点击变成两条互相矛盾的 `account_login`。
  Future<LoginOutcome> loginOtp(String phone, String code) async {
    try {
      final r = await api.postJson('/v1/auth/login', {
        'phone': phone,
        'code': code,
        'device_id': await deviceId(),
        'device_name': Platform.operatingSystem,
      });
      await session.save(
        accountId: r['account_id'] as String,
        access: r['access'] as String,
        refresh: r['refresh'] as String,
        loginMethod: 'otp',
      );
    } catch (_) {
      Analytics.track(AnalyticsEvent.accountLogin, {'method': 'otp', 'ok': false});
      rethrow;
    }
    Analytics.track(AnalyticsEvent.accountLogin, {'method': 'otp', 'ok': true});
    return _afterLogin();
  }

  /// 同 [loginOtp] 的道理:`account_login` 只钉住 Apple 认证 + `session.save`,
  /// `_afterLogin()` 的失败留给调用方自己处理,不污染登录事件。
  Future<void> loginApple() async {
    try {
      final cred = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
      );
      final r = await api.postJson('/v1/auth/apple', {
        'identity_token': cred.identityToken,
        'device_id': await deviceId(),
        'device_name': Platform.operatingSystem,
      });
      await session.save(
        accountId: r['account_id'] as String,
        access: r['access'] as String,
        refresh: r['refresh'] as String,
        loginMethod: 'apple',
      );
    } catch (_) {
      Analytics.track(AnalyticsEvent.accountLogin, {'method': 'apple', 'ok': false});
      rethrow;
    }
    Analytics.track(AnalyticsEvent.accountLogin, {'method': 'apple', 'ok': true});
    await _afterLogin();
  }

  Future<LoginOutcome> _afterLogin() async {
    try {
      final k = await api.getJson('/v1/account/keys') as Map<String, dynamic>;
      _serverKeys = k;
      if (session.privateKey == null) {
        lastOutcome = LoginOutcome.needsUnlock;
      } else {
        // 本机已经有私钥(这台设备之前解锁过)——直接进「已就绪」之前,顺手把
        // 服务端记着、本机还没补上的档案密钥补一遍,见 [restoreProfileKeys]。
        await restoreProfileKeys();
        lastOutcome = LoginOutcome.ready;
      }
    } on ApiFailed catch (e) {
      if (e.status != 404) rethrow;
      lastOutcome = LoginOutcome.needsKeySetup;
    }
    return lastOutcome!;
  }

  /// 换设备/重新登录后,把服务端记着的、本机还没有的档案密钥补回来——
  /// 「退出登录/换设备之后重新登录会自动恢复」这句话的真正实现(Task 15
  /// review C1:之前 `syncOpenSealed` 压根没有 Dart 调用点,这句话是假的,
  /// `AccountSession.clear()` 清掉 `pk_<cloudId>` 之后没有任何路径能补回来,
  /// 云成员会永久锁死)。
  ///
  /// `GET /v1/profiles` 拿到这个账号能访问的全部云档案(含用账号公钥封的
  /// `wrapped_profile_key`),用账号私钥拆开:
  ///
  /// * 本地**已经有**这个成员(有同一个 cloudId)、只是缺密钥 → 把密钥补回去;
  /// * 本地**没有**这个成员 → **新建一个**(最终评审 I3,spec 的「换机」那条路):
  ///   名字是占位的「云端档案 `<cloudId 前 6 位>`」,`markCloud` 记下
  ///   role/expiresAt,密钥存进 secure storage。换了台新手机、或者清了 App 数据
  ///   之后,用户重新登录 + 解锁就能看见自己的档案都在——在这之前这条路完全不
  ///   存在:服务端明明有这些档案、密钥也解得开,本机却因为「没有对应的本地
  ///   成员」全部跳过,于是新手机上一片空白,只有一条邀请链接能救(而 owner
  ///   根本给自己发不出邀请)。
  ///
  ///   占位名要用户自己改(成员改名在设置页,只动标签不动数据)——我们这一侧
  ///   拿不到真名:名字在病历里,而病历此刻还没同步下来。**第一次同步在用户切到
  ///   这个成员时发生**:切换走 `vault_boot.switchProfileAndReopen`,它会
  ///   `bumpVaultRevision()`,后台触发器随即给这个成员跑一次推拉
  ///   (见 `sync_engine.dart` 的 `triggerBackgroundSync`)。这里不自己发起同步:
  ///   `SyncEngine` 要求「要同步的档案 == 当前打开的那个 keyed 箱子」,而刚新建的
  ///   成员并不是当前成员,硬要同步就得把用户的当前成员切走。
  ///
  /// 单条数据解不开/格式不对只跳过那一条(见循环里的 try/catch),不让一条坏
  /// 数据拖累其它成员的恢复;整个 `/v1/profiles` 请求失败也不抛——这一步是
  /// "顺手补",不该挡住登录/解锁本身成功这件事。
  ///
  /// 如果**当前打开的成员**在补之前是锁着的(有 cloudId、没密钥),补上之后用
  /// [reopenCurrentProfileVault] 重开一次,免得用户还要再手动做一步才能看到
  /// 自己的档案。
  ///
  /// **不调 `ProfileManager.instance.ensureLoaded()`**——这里是唯一一次刻意
  /// 不调的地方,理由是真的会踩坑:能走到这个方法,说明 App 已经完整启动过
  /// `VaultBootstrap`(它的 `openCurrentProfileVault()` 第一行就是
  /// `ensureLoaded()`),`ProfileManager` 早就加载好了,这里再调一次只是
  /// 白问一次「加载了没」。而它一旦真的在没加载过的时候被调用(这个方法由一次
  /// 按钮点击的调用链间接触发),会去碰真实文件 I/O——这类调用只有包在
  /// `tester.runAsync()` 里才能在 `flutter test` 的 widget 测试里跑完,一次
  /// 平常的 `await tester.tap(...)` 会直接卡死等不到它(踩过的坑,不是猜的)。
  Future<void> restoreProfileKeys() async {
    final priv = session.privateKey;
    if (priv == null) return;
    final currentCloudId = ProfileManager.instance.current.cloudId;
    final currentWasLocked = currentCloudId != null && await session.profileKey(currentCloudId) == null;

    List<dynamic> serverProfiles;
    try {
      serverProfiles = await api.getJson('/v1/profiles') as List<dynamic>;
    } catch (_) {
      return;
    }

    // `ProfileManager.create()` 会把 current 切到新建的那个成员——而这里只是
    // "顺手补齐",绝不该改变用户此刻正在看哪个成员。新建完统一切回来。
    final currentIdBefore = ProfileManager.instance.currentId.value;
    var restoredCurrent = false;
    for (final raw in serverProfiles) {
      try {
        final entry = raw as Map<String, dynamic>;
        final cloudId = entry['profile_id'] as String;
        final wrapped = entry['wrapped_profile_key'] as String?;
        if (wrapped == null) continue;
        final hasLocalProfile = ProfileManager.instance.profiles.any((p) => p.cloudId == cloudId);
        if (hasLocalProfile && await session.profileKey(cloudId) != null) continue; // 这一个已经齐了
        // **先解密再建成员**:解不开(这条数据坏了 / 不是用这把私钥封的)就整条
        // 跳过,不留下一个永远打不开的空壳成员。
        final key = await crypto.openSealed(priv, base64Decode(wrapped));
        await session.putProfileKey(cloudId, key);
        if (!hasLocalProfile) {
          final localId = await ProfileManager.instance.create(
            '云端档案 ${cloudId.length <= 6 ? cloudId : cloudId.substring(0, 6)}',
            userManaged: false,
          );
          if (localId == null) continue;
          await ProfileManager.instance.markCloud(
            localId,
            cloudId,
            entry['role'] as String? ?? 'viewer',
            DateTime.tryParse(entry['expires_at'] as String? ?? ''),
          );
        }
        if (cloudId == currentCloudId) restoredCurrent = true;
      } catch (_) {
        continue;
      }
    }
    if (ProfileManager.instance.currentId.value != currentIdBefore) {
      await ProfileManager.instance.switchTo(currentIdBefore);
    }

    if (currentWasLocked && restoredCurrent) {
      try {
        await reopenCurrentProfileVault();
      } catch (_) {
        // 重开失败不影响"密钥已经补上了"这件事本身——下次任何触发开箱的路径
        // (比如用户自己切一下成员、或 `VaultBootstrap` 的重试)都会用上它。
      }
    }
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
    // 全新账号,服务端此刻不会有任何档案(自己刚生成密钥对),调用一次也
    // 无害(空列表,循环直接跳过)——统一走这条路径,不必单独判断"是不是新
    // 账号"。
    await restoreProfileKeys();
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
    await restoreProfileKeys();
    lastOutcome = LoginOutcome.ready;
  }

  /// 退出登录:清掉本机全部账号态(token、私钥、各档案密钥)。**不是**注销账号——
  /// 服务端账号与云端数据原样保留;已开通云同步的成员在这台设备上会因为没有档案
  /// 密钥而变成 [ProfileLocked](`vault_boot.dart`),重新登录后自动恢复。调用方
  /// (`AccountScreen`)在确认弹窗里把这句话说清楚,不是这里的事。
  Future<void> logout() => session.clear();

  /// 自助注销(手机账号):`otp_code` 必须是**刚发的**验证码(见
  /// `services/api/app.py` 的 `DELETE /v1/account`——重新证明是本人,偷来的
  /// access token 单独用不了这条路)。成功后服务端账号、其名下云档案、授权全部
  /// 已被删除,这里跟着清掉本机账号态(同 [logout])——不可逆,调用方必须已经
  /// 走过确认弹窗。
  Future<void> deleteAccountWithOtp(String phone, String otpCode) async {
    await api.delete('/v1/account', body: {'phone': phone, 'otp_code': otpCode});
    await session.clear();
  }

  /// 自助注销(Apple 账号):需要一个**刚拿到的** identity token,和 [loginApple]
  /// 同一条系统弹窗,不能复用登录时那一次(那次早就用过、可能已过期)。
  Future<void> deleteAccountWithApple() async {
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email],
    );
    await api.delete('/v1/account', body: {'identity_token': cred.identityToken});
    await session.clear();
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
    await restoreProfileKeys();
    lastOutcome = LoginOutcome.ready;
  }
}
