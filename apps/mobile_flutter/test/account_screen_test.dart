import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 API——每个方法都记进 [calls],方便断言"到底调没调、调了几次"；每个失败
/// 分支都是构造时的一个 flag,默认全部成功。所有异步方法都真的 `Future.delayed`
/// 一下(而不是立刻 resolve)——纯微任务链在 `pump()` 单帧内就会跑完,测不出
/// "加载中" 这一态,必须有一个真 Timer 撑住那一帧。
class FakeApi extends ApiClient {
  FakeApi({
    this.failOtp = false,
    this.otpError,
    this.failLogin = false,
    this.hasKeys = false,
    this.failPut = false,
    this.devices = const [],
    this.profiles = const [],
    this.failDevices = false,
    this.failProfiles = false,
    this.failApprove = false,
    this.failRevoke = false,
    this.failKeys500 = false,
    this.lookupResult,
    this.lookupError,
    this.failDeleteAccount = false,
    this.failDeleteAccountError,
    this.failCreateProfile = false,
    this.myGrants = const {},
    this.failMyGrants = false,
    this.myGrantsDelay,
    this.approvalSealed,
    this.approvalPending = 0,
    this.approvalDelay,
    Uint8List? serverPublicKey,
    this.delay = const Duration(milliseconds: 30),
  })  : serverPublicKey = serverPublicKey ?? Uint8List(32),
        super(base: 'http://x');

  /// `GET /v1/account/keys` 里那把账号公钥。默认 32 个 0,与 [FakeCrypto] 的
  /// "公钥 == 私钥"模型配得上;C1 的攻击用例传一把**不一样**的进来。
  final Uint8List serverPublicKey;

  /// `GET /v1/devices/approval` 的假响应:头 [approvalPending] 次回 null(旧手机
  /// 还没扫),之后回这串密文。null = 永远没人批准(测超时那条)。
  final String? approvalSealed;
  final int approvalPending;

  /// 被问了几次"批准了吗"——钉住"每 3 秒一次"这件事。
  int approvalPolls = 0;

  /// 让"批准了吗"这一问变慢(M10:慢过 3 秒时轮询不许重叠)。
  final Duration? approvalDelay;

  /// `POST /v1/devices/request` / `POST /v1/devices/approve` 的 body 与 header
  /// (X-Device-Id 是服务端分辨"谁在批准"的唯一依据,见 `app.device_approve`)。
  final deviceRequestBodies = <Map<String, dynamic>>[];
  final deviceApproveBodies = <Map<String, dynamic>>[];
  final sentHeaders = <String, Map<String, String>?>{};

  final bool failOtp;

  /// 发验证码这一步抛出的异常(默认 null = 不抛)。[failOtp] 只能抛 429,而
  /// B1 要验的是**网络层**那个异常(`ApiNetworkError`)在屏上长什么样。
  final Object? otpError;
  final bool failLogin;
  final bool hasKeys;
  final bool failPut;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> profiles;
  final bool failDevices;
  final bool failProfiles;
  final bool failApprove;
  final bool failRevoke;
  /// `GET /v1/profiles/{pid}/grants`(「我授权给谁」)的假响应,按 `profile_id`
  /// 分开;`failMyGrants` 让它统一报错——测「我授权给谁」三态。
  final Map<String, List<Map<String, dynamic>>> myGrants;
  final bool failMyGrants;
  /// 只加在 `/v1/profiles/{pid}/grants` 这一个调用上的额外延迟(默认不加)——
  /// 独立于 [delay],这样能在不拖慢解锁本身(`GET /v1/profiles` 走的是
  /// [delay])的前提下,单独撑住「我授权给谁」这一步的加载中状态够久,测出
  /// 那一帧的进度圈。
  final Duration? myGrantsDelay;
  /// `GET /v1/account/keys` 报 500(不是 404)——`_afterLogin` 只吞 404,
  /// 非 404 一律 rethrow;用来测 `resumeIfLoggedIn` 冷启动那条路径接不接得住。
  final bool failKeys500;
  /// `POST /v1/accounts/lookup` 的假响应/假失败——测「按手机号添加家属」。
  final Map<String, dynamic>? lookupResult;
  final ApiFailed? lookupError;
  /// 注销账号(`POST /v1/account/delete`,见最终评审 I5)的假失败,默认成功——
  /// 测「注销账号」三态。
  final bool failDeleteAccount;
  final ApiFailed? failDeleteAccountError;
  /// `POST /v1/profiles`(开通云同步的注册那一步)的假失败——测「开通云同步」
  /// 失败态,不必也不能真的走到重开箱那一步(`flutter test` 没有原生库)。
  final bool failCreateProfile;
  final Duration delay;
  final calls = <String>[];
  /// 每次 `delete()` 收到的 body,按调用顺序——测「注销账号」发对了 phone/otp_code。
  final deleteBodies = <Object?>[];
  /// `POST /v1/profiles/{pid}/invites` 的 body——B5 测「转为主人」发的是 owner、
  /// 而且不带 days。
  final inviteBodies = <Map<String, dynamic>>[];
  /// 让建邀请这一步 500,测 B5 的失败态。
  bool failInvite = false;

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    sentHeaders[path] = headers;
    if (path == '/v1/devices/request') deviceRequestBodies.add(body as Map<String, dynamic>);
    if (path == '/v1/devices/approve') deviceApproveBodies.add(body as Map<String, dynamic>);
    await Future<void>.delayed(delay);
    if (path == '/v1/auth/otp') {
      if (otpError != null) throw otpError!;
      if (failOtp) throw const ApiFailed(429, 'rate_limited');
      return {'ok': true};
    }
    if (path == '/v1/auth/login') {
      if (failLogin) throw const ApiFailed(401, 'bad code');
      return {'account_id': 'acc_1', 'access': 'a', 'refresh': 'r'};
    }
    if (path == '/v1/devices/approve') {
      if (failApprove) throw const ApiFailed(500, 'approve failed');
      return {'ok': true};
    }
    if (path == '/v1/profiles') {
      if (failCreateProfile) throw const ApiFailed(500, 'create profile failed');
      return {'profile_id': 'prf_new'};
    }
    if (path.startsWith('/v1/profiles/') && path.endsWith('/invites')) {
      if (failInvite) throw const ApiFailed(500, 'invite failed');
      inviteBodies.add(body as Map<String, dynamic>);
      return {'invite_id': 'inv_transfer_1'};
    }
    if (path == '/v1/accounts/lookup') {
      if (lookupError != null) throw lookupError!;
      return lookupResult!;
    }
    return {'ok': true};
  }

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    await Future<void>.delayed(delay);
    if (path == '/v1/account/keys') {
      if (failKeys500) throw const ApiFailed(500, 'keys server error');
      if (!hasKeys) throw const ApiFailed(404, 'no keys');
      return {
        // 真实的账号公钥是 32 字节的 X25519 公钥 —— 这里必须照这个形状,否则 C1 那道
        // "私钥和公钥是一对吗"的探针在测试里无从下手。[serverPublicKey] 让用例能把它
        // 换成一把**不匹配**的公钥(模拟恶意服务器)。
        'public_key': base64Encode(serverPublicKey),
        'wrapped_priv_pw': 'AA==',
        'wrapped_priv_rc': 'AA==',
        'kdf_salt': 'AA==',
        'kdf_params': {'m_kib': 8, 't': 1, 'p': 1},
      };
    }
    if (path == '/v1/devices') {
      if (failDevices) throw const ApiFailed(500, 'devices failed');
      return devices;
    }
    if (path == '/v1/devices/approval') {
      approvalPolls++;
      sentHeaders[path] = headers;
      if (approvalDelay != null) await Future<void>.delayed(approvalDelay!);
      return {'approved_priv': approvalPolls > approvalPending ? approvalSealed : null};
    }
    if (path == '/v1/profiles') {
      if (failProfiles) throw const ApiFailed(500, 'profiles failed');
      return profiles;
    }
    if (path.startsWith('/v1/profiles/') && path.endsWith('/grants')) {
      if (myGrantsDelay != null) await Future<void>.delayed(myGrantsDelay!);
      if (failMyGrants) throw const ApiFailed(500, 'my grants failed');
      final pid = path.split('/')[3];
      return myGrants[pid] ?? const [];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> putJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('PUT $path');
    await Future<void>.delayed(delay);
    if (path == '/v1/account/keys' && failPut) throw const ApiFailed(500, 'put failed');
    return {'ok': true};
  }

  @override
  Future<void> delete(String path, {Object? body, Map<String, String>? headers}) async {
    calls.add('DELETE $path');
    deleteBodies.add(body);
    await Future<void>.delayed(delay);
    if (path == '/v1/account') {
      if (failDeleteAccount) throw failDeleteAccountError ?? const ApiFailed(401, 'reauth required');
      return;
    }
    if (failRevoke) throw const ApiFailed(500, 'revoke failed');
  }

  /// 注销账号现在走 `POST /v1/account/delete`(I5:带 body 的 DELETE 会被网关
  /// 丢掉 body)。请求体记进同一个 [deleteBodies],断言不必改两处。
  @override
  Future<void> postNoContent(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    deleteBodies.add(body);
    await Future<void>.delayed(delay);
    if (path == AccountFlow.deletePath && failDeleteAccount) {
      throw failDeleteAccountError ?? const ApiFailed(401, 'reauth required');
    }
  }
}

/// `GET /v1/profiles` 永远不返回 —— 专测 `restoreProfileKeys` 那一次请求的超时预算
/// (复审新问题 4)。其余路径照旧。
class _HangingProfilesApi extends FakeApi {
  _HangingProfilesApi() : super(hasKeys: true, delay: const Duration(milliseconds: 5));
  final _hang = Completer<dynamic>();

  /// 用例收尾时调 —— 别留一个永远挂着的 Future。
  void release() {
    if (!_hang.isCompleted) _hang.complete(const <dynamic>[]);
  }

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) {
    if (path == '/v1/profiles') {
      calls.add('GET $path');
      return _hang.future;
    }
    return super.getJson(path, query: query, headers: headers);
  }
}

/// `POST /v1/devices/request` 报 500 —— 测"生成二维码失败"那一态。
class _FailingRequestApi extends FakeApi {
  _FailingRequestApi() : super(hasKeys: true, delay: const Duration(milliseconds: 5));

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    if (path == '/v1/devices/request') {
      calls.add('POST $path');
      await Future<void>.delayed(delay);
      throw const ApiFailed(500, 'request failed');
    }
    return super.postJson(path, body, headers: headers);
  }
}

/// 第一次发验证码成功、之后按 [failNext] 决定失不失败 —— 专测"重发"那条路
/// (评审 Minor 21:原来那条用例在一块全新的屏上点最初那个按钮,从没走过重发)。
class _FlakyOtpApi extends FakeApi {
  _FlakyOtpApi() : super(delay: const Duration(milliseconds: 5));
  bool failNext = false;

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    if (path == '/v1/auth/otp' && failNext) {
      calls.add('POST $path');
      await Future<void>.delayed(delay);
      throw const ApiFailed(429, 'rate_limited');
    }
    return super.postJson(path, body, headers: headers);
  }
}

/// 假加密——同样真的 delay 一下(Argon2id 本来就该花时间),口令/恢复码只有
/// 配置的那一个值判"对"，方便同时测成功和失败分支。
class FakeCrypto implements SyncCrypto {
  FakeCrypto({
    this.rightPassword = 'right',
    this.rightRecoveryCode = 'GOODCODE',
    this.failAccountKeysNew = false,
    this.openSealedFails,
    this.delay = const Duration(milliseconds: 20),
  });

  /// 见 [openSealed]——返回 true 的那些 blob 解不开。
  final bool Function(Uint8List blob)? openSealedFails;

  final String rightPassword;
  final String rightRecoveryCode;
  final bool failAccountKeysNew;
  final Duration delay;

  Future<void> _wait() => Future<void>.delayed(delay);

  @override
  Future<(Uint8List, Uint8List)> accountKeysNew() async {
    await _wait();
    if (failAccountKeysNew) throw Exception('kdf boom');
    return (Uint8List(32), Uint8List(32));
  }

  @override
  Future<Uint8List> wrapPrivate(Uint8List s, String pw, Uint8List salt, int m, int t, int p) async {
    await _wait();
    return Uint8List(40);
  }

  @override
  Future<Uint8List> unwrapPrivatePw(Uint8List b, String pw, Uint8List salt, int m, int t, int p) async {
    await _wait();
    if (pw != rightPassword) throw Exception('crypto');
    return Uint8List(32);
  }

  @override
  Future<String> recoveryCodeNew() async {
    await _wait();
    return 'ABCD-EFGH-JKMN-PQRS-TVWX';
  }

  @override
  Future<Uint8List> wrapPrivateRc(Uint8List s, String code) async {
    await _wait();
    return Uint8List(40);
  }

  @override
  Future<Uint8List> unwrapPrivateRc(Uint8List b, String code) async {
    await _wait();
    if (code != rightRecoveryCode) throw Exception('crypto');
    return Uint8List(32);
  }

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async {
    await _wait();
    return Uint8List.fromList([...public, ...plaintext]);
  }

  /// [sealTo] 的反面。**这个假实现把"公钥 == 私钥"当作配对**:真实现是 X25519,
  /// 测试不需要真密码学,只需要"配不上就打不开"这件事是可观测的 —— C1 那道密钥对
  /// 匹配探针(新设备收到的私钥必须和服务端给的公钥是一对)只有在这个模型下才测得出来。
  ///
  /// 不是"封给我的"那些 blob 仍然**恒等透传**:既有那批用例(服务端返回的
  /// `wrapped_profile_key` 原样存进 `pk_<cloudId>`)依赖这个行为。
  /// [openSealedFails] 为某些 blob 返回 true 时改为抛异常,测"解不开就整条跳过"。
  @override
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob) async {
    await _wait();
    if (openSealedFails?.call(blob) ?? false) throw Exception('open sealed boom');
    if (blob.length >= secret.length && listEquals(blob.sublist(0, secret.length), secret)) {
      return Uint8List.fromList(blob.sublist(secret.length));
    }
    return blob;
  }
}

/// 假 `GrantsRust`——只有 `sealTo` 会被「按手机号添加家属」用到,拼接公钥与
/// 明文即可(同 `sync_engine_test.dart`/`grants_test.dart` 的 `FakeRust`/
/// `FakeGrantsRust` 套路,不追求真实的密码学正确性,只钉住"传对了什么")。
class FakeGrantsRust implements GrantsRust {
  final sealedWith = <Uint8List>[];

  @override
  Future<Uint8List> wrapWithToken(Uint8List plaintext, String token) async => plaintext;

  @override
  Future<Uint8List> unwrapWithToken(Uint8List blob, String token) async => blob;

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async {
    sealedWith.add(public);
    return Uint8List.fromList([...public, ...plaintext]);
  }
}

/// 假 `RustSyncApi`——只覆盖「开通云同步」/「立即同步」用得到的方法。
/// `sync_engine_test.dart` 的 `FakeRust` 已经把 `SyncEngine` 本身的推拉逻辑钉住了,
/// 这里只需要能让 `AccountScreen` 这一层的三态可控,不追求覆盖度。
///
/// **不测 `enableCloud` 成功态**——它内部会重开箱(`vault_boot.openCurrentProfileVault`),
/// 那条路径调真实 FRB,`flutter test` 没有原生库(同 `sync_engine_test.dart` 顶部
/// 那条限制)。所以「开通云同步」的测试只到 `registerCloudProfile` 这一步失败为止,
/// 成功态改为直接摆一个已有 `cloudId` 的档案,断言 UI 显示"已开通"分支。
class _FakeSyncRust implements RustSyncApi {
  _FakeSyncRust({this.keyed = true, this.icloudOn = false, String? vaultRoot})
      : vaultRoot = vaultRoot ?? '/x/profiles/p-1/vault';
  final bool keyed;

  /// 这台设备开着 iCloud 同步——C3(「开通云同步」必须拒绝并把原因摆出来)用。
  final bool icloudOn;
  final String vaultRoot;

  @override
  Future<Uint8List> profileKeyNew() async => Uint8List(32);

  @override
  Future<bool> icloudEnabled() async => icloudOn;

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async =>
      Uint8List.fromList([...public, ...plaintext]);

  @override
  Future<bool> currentVaultIsKeyed() async => keyed;

  @override
  Future<String> currentVaultRoot() async => vaultRoot;

  @override
  Future<List<(String, int)>> localSeqMap() async => const [];

  @override
  Future<List<SyncEventDto>> exportEvents(Uint8List profileKey, List<(String, int)> after) async => const [];

  @override
  Future<SyncImportOutcomeDto> importEvents(Uint8List profileKey, List<SyncEventDto> events) async =>
      SyncImportOutcomeDto(applied: events.length, skippedExisting: 0, outOfOrder: 0, untrusted: 0, undecodable: 0);

  @override
  Future<List<(String, String)>> missingObjects(Uint8List profileKey) async => const [];

  @override
  Future<List<(String, String)>> allObjectIds(Uint8List profileKey) async => const [];

  @override
  Future<(String, Uint8List)> encryptObject(Uint8List profileKey, String hash) async => (hash, Uint8List(1));

  @override
  Future<String> storeObject(Uint8List profileKey, String objectId, Uint8List ciphertext) async => objectId;
}

/// 「开通到一半」那条用例用的假 Rust 桥:`keyedNow` 一开始是 false(箱子还没
/// keyed 打开 → 同步撞 `VaultMismatch`),假的 `reopenVault` 把它置 true,于是
/// 重试之后同步能跑通。单独一个类而不是往 [_FakeSyncRust] 加 setter,是因为只有
/// 这一条用例需要"中途会变"的行为。
class _ReopenableFakeSyncRust extends _FakeSyncRust {
  _ReopenableFakeSyncRust({required String super.vaultRoot});
  bool keyedNow = false;

  @override
  Future<bool> currentVaultIsKeyed() async => keyedNow;
}

/// 假 API——只覆盖「立即同步」用得到的两个方法(拉事件 + 拉对象清单),专测
/// `_syncNow` 的三态。加一个真延迟(同文件顶部 `FakeApi` 的道理):纯微任务链
/// 在 `pump()` 单帧内就会跑完,测不出"加载中"这一态。
class _SyncApi extends ApiClient {
  _SyncApi({this.failPull = false, this.delay = const Duration(milliseconds: 20)}) : super(base: 'http://x');
  final bool failPull;
  final Duration delay;

  /// 成功跑到"拉事件"这一步的次数——测「重试之后同步真的跑起来了」。
  var pulls = 0;

  @override
  Future<(dynamic, Map<String, String>)> getJsonWithHeaders(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    await Future<void>.delayed(delay);
    if (failPull) throw const ApiFailed(500, 'pull failed');
    pulls++;
    return (const [], {'x-seq-map': '{}'});
  }

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async => const [];

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async => {'ok': true};
}

Widget _app(
  FakeApi api, {
  SyncCrypto? crypto,
  Grants? grants,
  SyncEngine? syncEngine,
  bool? debugModeOverride,
  KdfBenchFn? kdfBenchFn,
  Future<String?> Function(BuildContext)? scanQr,
}) => MaterialApp(
      home: AccountScreen(
        flow: AccountFlow(api, AccountSession.instance, crypto: crypto ?? FakeCrypto()),
        grants: grants,
        syncEngine: syncEngine,
        debugModeOverride: debugModeOverride,
        kdfBenchFn: kdfBenchFn,
        scanQr: scanQr,
      ),
    );

/// 手机号 → 发验证码 → 输入验证码 → 登录,落在哪个阶段由 `api.hasKeys` 决定。
Future<void> _loginUpTo(WidgetTester t) async {
  await t.enterText(find.byKey(const Key('phone')), '13800000001');
  await t.tap(find.text('发送验证码'));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('code')), '000000');
  await t.tap(find.text('登录'));
  await t.pumpAndSettle();
}

/// 登录 + 口令解锁,一路落到「已就绪」——要求 `api.hasKeys == true`。
Future<void> _toReady(
  WidgetTester t,
  FakeApi api, {
  SyncCrypto? crypto,
  Grants? grants,
  SyncEngine? syncEngine,
  bool? debugModeOverride,
  KdfBenchFn? kdfBenchFn,
  Future<String?> Function(BuildContext)? scanQr,
}) async {
  await t.pumpWidget(_app(
    api,
    crypto: crypto,
    grants: grants,
    syncEngine: syncEngine,
    debugModeOverride: debugModeOverride,
    kdfBenchFn: kdfBenchFn,
    scanQr: scanQr,
  ));
  await _loginUpTo(t);
  await t.enterText(find.byKey(const Key('password')), 'right');
  await t.pump();
  await t.tap(find.text('解锁'));
  await t.pumpAndSettle();
}

/// 「我授权给谁」排在「已就绪」页最后一节——`ListView(children: ...)` 底层还是
/// `SliverChildListDelegate`,只有落在视口 + 缓存区内的子节点才会被挂载,普通
/// `ensureVisible` 对还没挂载的 widget 无能为力(同 `visit_summary_sheet_test.dart`
/// 的 `scrollToMedsToggle` 一模一样的坑):先 `scrollUntilVisible` 挂载它,再
/// `ensureVisible` 把它拉回可点击的范围。
Future<void> _scrollToMyGrants(WidgetTester t) => _scrollToText(t, '我授权给谁');

/// 把一段文字滚进视口。C7 把「云同步」提到第一位之后,「设备」「账号管理」落到了
/// 最底下 —— 原来那些裸 `ensureVisible` 够不到它们(`SliverList` 懒实现,没挂载的
/// widget `ensureVisible` 无能为力),必须先 `scrollUntilVisible` 把它挂载出来。
Future<void> _scrollToText(WidgetTester t, String text) async {
  final finder = find.text(text);
  await t.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await t.ensureVisible(finder);
  await t.pumpAndSettle();
}

/// 旧设备封回来的那份批准,**真实形状**:`[...新设备的临时公钥, ...账号私钥]`
/// (见 [FakeCrypto.sealTo]/[FakeCrypto.openSealed] 的"公钥 == 私钥"模型)。
/// 两段都是 32 个 0,于是拆出来的账号私钥正好与 `FakeApi.serverPublicKey` 配得上。
final _sealedApproval = base64Encode(Uint8List(64));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // fix round 1 (Task 15 review) C1: `AccountFlow.restoreProfileKeys()` 现在
  // 在每次登录/解锁成功之后都跑,它调 `ProfileManager.instance.ensureLoaded()`
  // ——这条路径会碰 `path_provider`。之前只有少数几个测试组自己给这个 channel
  // 挂了 mock(且各起各的临时目录),其余测试组从没需要过;现在**任何**一次
  // 登录/解锁都会顺带触发它,所以这里把 mock 提到文件级 `setUp`,保证跑到哪个
  // 测试都有地方落盘,不依赖具体是哪个 channel 调用没接住。
  late Directory globalSupport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
    // `sync_engine.pendingFirstSync` 与 `Grants` 的两个邀请缓存都是模块级/静态的,
    // 用例之间会串 —— 不清的话「生成失败」那条用例会拿到上一条用例缓存的链接。
    resetPendingFirstSyncForTest();
    // `restoreProfileKeys` 的重入守卫是静态的(遗留 4) —— 上一个用例留下的
    // in-flight future(比如那条 `GET /v1/profiles` 永不返回的)不该串到下一个。
    AccountFlow.resetRestoreGuardForTest();
    Grants.clearInviteCache();
    globalSupport = await Directory.systemTemp.createTemp('medme-account-screen-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => globalSupport.path,
    );
  });

  tearDown(() async => globalSupport.delete(recursive: true));

  group('注册:prepareKeys/commitKeys 两步(恢复码强制确认)', () {
    testWidgets('登录 → 设口令 → 生成密钥展示恢复码(此时未提交)→ 确认后才真正提交', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget); // 加载中
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('code')), '000000');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();
      expect(find.text('设置口令'), findsOneWidget); // needsKeySetup

      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget); // 恢复码
      expect(find.text('我已抄下恢复码'), findsOneWidget);
      // 生成密钥这一步只在内存里备好,还没上传、没落盘。
      expect(api.calls, isNot(contains('PUT /v1/account/keys')));
      expect(AccountSession.instance.privateKey, isNull);

      await t.tap(find.text('我已抄下恢复码'));
      await t.pumpAndSettle();
      expect(api.calls, contains('PUT /v1/account/keys'));
      expect(AccountSession.instance.privateKey, isNotNull);
      expect(find.text('已登录'), findsOneWidget);
    });

    testWidgets('恢复码画面强杀重开(未点确认):新开一屏落在设置口令,不是已就绪', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget);
      // 没点「我已抄下恢复码」——从没提交过。
      expect(api.calls, isNot(contains('PUT /v1/account/keys')));

      // 模拟强杀重开:先换成一个完全不同类型的根 widget,强制 Flutter 把上一棵
      // element 树整个 dispose 掉(而不是当成"同一个 MaterialApp 更新"复用
      // State——那样 initState 不会重跑,测不出"重开"这件事)。然后再 pump 一个
      // 全新的 AccountScreen(全新 AccountFlow/FakeApi);AccountSession 单例
      // (mock 存储)还在——之前那次登录的 token 已经落盘。
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpWidget(_app(FakeApi()));
      await t.pumpAndSettle();
      expect(find.text('设置口令'), findsOneWidget);
      expect(find.text('已登录'), findsNothing);
      expect(AccountSession.instance.privateKey, isNull);
    });

    testWidgets('生成密钥:加载中显示进度圈', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('生成密钥失败(KDF/加密层报错):错误可见,停留设置口令,未调用 PUT', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api, crypto: FakeCrypto(failAccountKeysNew: true)));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
      expect(find.textContaining('kdf boom'), findsOneWidget);
      expect(find.text('设置口令'), findsOneWidget); // 还在这一步
      expect(api.calls, isNot(contains('PUT /v1/account/keys')));
      expect(AccountSession.instance.privateKey, isNull);
    });

    testWidgets('提交密钥(commitKeys):加载中显示进度圈', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
      await t.tap(find.text('我已抄下恢复码'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('提交密钥失败(服务器 500):停留在恢复码画面、恢复码仍可见,未落盘', (t) async {
      final api = FakeApi(failPut: true);
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget);

      await t.tap(find.text('我已抄下恢复码'));
      await t.pumpAndSettle();
      expect(find.text('服务器开小差了,稍后再试'), findsOneWidget); // B2:不念状态码
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget); // 恢复码原样还在
      expect(find.text('我已抄下恢复码'), findsOneWidget); // 可以直接重试
      expect(AccountSession.instance.privateKey, isNull);
    });
  });

  // ---- 验证码屏:原来既没有倒计时也没有重发按钮 ----
  group('验证码屏:60 秒倒计时 + 重新发送', () {
    testWidgets('刚发完:倒计时 60 秒,「重新发送」此刻不可点', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      // 不用 pumpAndSettle:它会把 60 秒虚拟时间一次走完,倒计时就看不到了。
      await t.pump(const Duration(milliseconds: 60));

      expect(find.text('输入验证码'), findsOneWidget);
      expect(find.text('60 秒后可重新发送'), findsOneWidget);
      expect(t.widget<TextButton>(find.byKey(const Key('otp_resend'))).onPressed, isNull);

      await t.pump(const Duration(seconds: 1));
      expect(find.text('59 秒后可重新发送'), findsOneWidget);
    });

    testWidgets('60 秒后:变成「重新发送」且可点;点了重新发一次 OTP、清掉旧码', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      // `pumpAndSettle` 只画到"没有新帧要排队"为止,不会替你把 60 秒走完 ——
      // 倒计时要自己推(一次 pump 推 60 秒,周期 timer 在这一跳里全部触发)。
      await t.pump(const Duration(seconds: 60));

      expect(find.text('重新发送'), findsOneWidget);
      expect(t.widget<TextButton>(find.byKey(const Key('otp_resend'))).onPressed, isNotNull);

      await t.enterText(find.byKey(const Key('code')), '111111');
      await t.pump();
      api.calls.clear();
      await t.tap(find.byKey(const Key('otp_resend')));
      await t.pump(const Duration(milliseconds: 60));

      expect(api.calls, contains('POST /v1/auth/otp'));
      expect(find.text('111111'), findsNothing, reason: '旧码要清掉,否则用户会拿旧码去点登录');
      expect(find.text('验证码已重新发送'), findsOneWidget);
      expect(find.text('输入验证码'), findsOneWidget, reason: '仍在这一屏,不退回手机号那一步');
    });

    testWidgets('首次发送失败(429):错误可见,不进下一屏', (t) async {
      final api = FakeApi(failOtp: true);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();

      expect(find.text('操作太频繁,过一会儿再试'), findsOneWidget);
      expect(find.text('输入验证码'), findsNothing, reason: '没发出去就不该进下一屏');
    });

    // 评审 Minor 21:上面那条用例原来叫「重发失败」,但它在一块全新的屏上点**最初**
    // 那个「发送验证码」—— 从没走过重发路径。于是下面这件事对测试套件是隐形的:
    // 重发失败时倒计时不跑,按钮保持可点,用户可以继续猛戳一个已经在限流他的服务端。
    testWidgets('重发失败(429):也要进冷却 —— 不许继续猛戳一个正在限流你的服务端', (t) async {
      final api = _FlakyOtpApi();
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 60)); // 第一轮冷却走完

      expect(find.text('重新发送'), findsOneWidget);
      api.failNext = true;
      await t.tap(find.byKey(const Key('otp_resend')));
      await t.pumpAndSettle();

      expect(find.text('操作太频繁,过一会儿再试'), findsOneWidget);
      expect(find.text('输入验证码'), findsOneWidget, reason: '仍在这一屏');
      expect(find.text('60 秒后可重新发送'), findsOneWidget, reason: '失败也要进冷却');
      expect(t.widget<TextButton>(find.byKey(const Key('otp_resend'))).onPressed, isNull);
    });

    testWidgets('验证码打错/过期:说「重新发送」,不说「重新登录」', (t) async {
      final api = FakeApi(failLogin: true);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('code')), '111111');
      await t.pump();
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();

      expect(find.text('验证码不对或已过期,请重新发送'), findsOneWidget);
      expect(find.textContaining('重新登录'), findsNothing);
      expect(find.byKey(const Key('otp_resend')), findsOneWidget, reason: '出路就在下面这颗按钮上');
    });
  });

  // ---- A4:口令只输一次、看不见、无长度下限 ----
  group('A4:口令屏的眼睛 + 最短 6 位', () {
    /// 当前那个口令输入框是不是遮着的。
    bool obscured(WidgetTester t) => t.widget<TextField>(find.byKey(const Key('password'))).obscureText;

    testWidgets('注册:默认遮着,点眼睛露出来,再点又遮回去', (t) async {
      await t.pumpWidget(_app(FakeApi()));
      await _loginUpTo(t);
      expect(find.text('设置口令'), findsOneWidget);
      expect(obscured(t), isTrue);

      await t.tap(find.byKey(const Key('password_eye')));
      await t.pump();
      expect(obscured(t), isFalse, reason: '打错一个字要到换机那天才暴露——必须能看见自己打的是什么');

      await t.tap(find.byKey(const Key('password_eye')));
      await t.pump();
      expect(obscured(t), isTrue);
    });

    testWidgets('注册:不足 6 位时「生成密钥」不可点并说还差几位;够了才能点', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);

      FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, '生成密钥'));
      expect(button().onPressed, isNull, reason: '空口令就不能往下走');

      await t.enterText(find.byKey(const Key('password')), 'ab12');
      await t.pump();
      expect(find.text('还差 2 位'), findsOneWidget);
      expect(button().onPressed, isNull);

      // 点一下也不该发生任何事(按钮是真的禁用,不是只画成灰的)。
      await t.tap(find.widgetWithText(FilledButton, '生成密钥'));
      await t.pumpAndSettle();
      expect(find.text('设置口令'), findsOneWidget);
      expect(api.calls, isNot(contains('PUT /v1/account/keys')));

      await t.enterText(find.byKey(const Key('password')), 'ab1234');
      await t.pump();
      expect(find.textContaining('还差'), findsNothing);
      expect(button().onPressed, isNotNull);
    });

    testWidgets('解锁:口令框也有眼睛(恢复码框本来就是明文,没有)', (t) async {
      await t.pumpWidget(_app(FakeApi(hasKeys: true)));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);
      expect(obscured(t), isTrue);
      await t.tap(find.byKey(const Key('password_eye')));
      await t.pump();
      expect(obscured(t), isFalse);

      await t.tap(find.text('口令忘了?改用恢复码解锁'));
      await t.pump();
      expect(find.byKey(const Key('password_eye')), findsNothing);
    });

    testWidgets('解锁屏没有长度下限——旧账号的口令可能就是短的,不许把人关在门外', (t) async {
      await t.pumpWidget(_app(FakeApi(hasKeys: true), crypto: FakeCrypto(rightPassword: 'abc')));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'abc');
      await t.pump();
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, '解锁')).onPressed, isNotNull);
      await t.tap(find.text('解锁'));
      await t.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
    });
  });

  // ---- Argon2 等待:转圈时原来一句话都没有 ----
  group('转圈时说一句「正在生成密钥」', () {
    testWidgets('注册点「生成密钥」:进度圈旁边有那句话', (t) async {
      await t.pumpWidget(_app(FakeApi()));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在生成密钥,老一点的手机可能要等几秒,请不要退出'), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('解锁点「解锁」:同一句话', (t) async {
      await t.pumpWidget(_app(FakeApi(hasKeys: true)));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pump();
      expect(find.text('正在生成密钥,老一点的手机可能要等几秒,请不要退出'), findsOneWidget);
      await t.pumpAndSettle();
    });
  });

  // ---- 评审 Important 10:Argon2 转圈时退出会 setState after dispose ----
  group('Important 10:转圈时离开这一屏不崩', () {
    testWidgets('「生成密钥」转圈中把屏拆掉:不留未处理的异步错误', (t) async {
      // 这正是 `_kdfWaitHint`(「请不要等…请不要退出」)所描述的那几秒等待 ——
      // 而 `PopScope` 只在恢复码那一阶段挡返回,所以这几秒里真的走得掉。
      final api = FakeApi(delay: const Duration(milliseconds: 5));
      await t.pumpWidget(_app(api, crypto: FakeCrypto(delay: const Duration(milliseconds: 300))));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pump(); // 转圈起来了,Argon2 还在跑

      await t.pumpWidget(const SizedBox.shrink()); // 整棵树 dispose
      // 把假 Argon2 那串 delayed timer 排空 —— 它们 resolve 的那一刻正是原来
      // `setState after dispose` 抛出来的时刻。`pumpAndSettle` 自己不推进它们
      // (没有帧在排队),所以要显式给时间;`prepareKeys` 里是**四次**串行的
      // 300ms(生成密钥对 / 口令包 / 恢复码 / 恢复码包),一次给足。
      await t.pump(const Duration(seconds: 3));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull, reason: 'setState() called after dispose() 会从这里冒出来');
    });

    testWidgets('「解锁」失败那一刻屏已经拆掉:catch 里的 setState 也不许抛', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await t.pumpWidget(_app(api, crypto: FakeCrypto(delay: const Duration(milliseconds: 300))));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'wrong');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pump();

      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
    });
  });

  // ---- 评审 Important 11:恢复码离开设备之前要先说一句 ----
  group('Important 11:「分享给自己」先确认', () {
    Future<void> toRecoveryScreen(WidgetTester t) async {
      await t.pumpWidget(_app(FakeApi()));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
    }

    testWidgets('点「分享给自己」先弹确认,说清它会经第三方 App 传出去', (t) async {
      await toRecoveryScreen(t);
      await t.tap(find.byKey(const Key('recovery_share')));
      await t.pumpAndSettle();

      expect(find.text('要把恢复码发出去?'), findsOneWidget);
      expect(find.textContaining('会经你选的那个 App 离开这台手机'), findsOneWidget);
      expect(find.textContaining('只发给自己'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('取消:不打开分享面板,恢复码画面原样留着', (t) async {
      await toRecoveryScreen(t);
      await t.tap(find.byKey(const Key('recovery_share')));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget);
      expect(find.text('我已抄下恢复码'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('确认之后分享面板打不开:中文提示,不是未处理异常', (t) async {
      // 真的让它失败一次:mock 掉 share_plus 自己那条 channel,让它抛
      // `PlatformException` —— 正是 iPad 拿不到锚点、或系统里没有可分享目标时的形状。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async => throw PlatformException(code: 'no_target', message: '没有可分享的目标'),
      );
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/share'), null));

      await toRecoveryScreen(t);
      await t.tap(find.byKey(const Key('recovery_share')));
      await t.pumpAndSettle();
      await t.tap(find.text('发给自己'));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull, reason: 'onPressed 里的 async 必须自己接住');
      expect(find.textContaining('分享没打开'), findsOneWidget);
      expect(find.textContaining('可以改用上面的「复制」'), findsOneWidget);
      // 恢复码画面原样留着,用户还能走「复制」那条。
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget);
    });
  });

  // ---- A6:两样都丢了的人原来卡死在解锁屏 ----
  group('A6:口令和恢复码都丢了', () {
    testWidgets('解锁屏底部有这个入口;弹窗照实说明"找不回"', (t) async {
      await t.pumpWidget(_app(FakeApi(hasKeys: true)));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);

      await t.tap(find.byKey(const Key('lost_everything')));
      await t.pumpAndSettle();
      expect(find.textContaining('我们不托管你的密钥'), findsOneWidget);
      expect(find.textContaining('没有任何办法帮你找回'), findsOneWidget);
      expect(find.text('退出登录,重新开始'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('确认「退出登录,重新开始」:真退出,回到登录入口', (t) async {
      await t.pumpWidget(_app(FakeApi(hasKeys: true)));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pumpAndSettle();
      // 先真的解锁一次,让 session 里有东西可清,再退回解锁屏重来这条路。
      expect(AccountSession.instance.privateKey, isNotNull);
      await t.pumpWidget(const SizedBox.shrink());
      await AccountSession.instance.save(accountId: 'acc_1', access: 'a', refresh: 'r');
      AccountSession.instance.privateKey = null; // 换了台设备的样子:有 token、没私钥
      await t.pumpWidget(_app(FakeApi(hasKeys: true)));
      await t.pumpAndSettle();
      expect(find.text('输入口令解锁'), findsOneWidget);

      await t.tap(find.byKey(const Key('lost_everything')));
      await t.pumpAndSettle();
      await t.tap(find.text('退出登录,重新开始'));
      await t.pumpAndSettle();

      expect(find.text('登录 MedMe 账号'), findsOneWidget);
      expect(AccountSession.instance.accountId, isNull);
      expect(AccountSession.instance.loggedIn.value, isFalse);
    });

    testWidgets('取消:一切原样,仍停在解锁屏、没有退出登录', (t) async {
      await t.pumpWidget(_app(FakeApi(hasKeys: true)));
      await _loginUpTo(t);
      await t.tap(find.byKey(const Key('lost_everything')));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(find.text('输入口令解锁'), findsOneWidget);
      expect(AccountSession.instance.accountId, isNotNull);
    });
  });

  group('登录/OTP 三态', () {
    testWidgets('发送验证码失败:显示错误,仍停在这一步,可重试', (t) async {
      final api = FakeApi(failOtp: true);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      expect(find.text('操作太频繁,过一会儿再试'), findsOneWidget); // B2:429 的人话
      expect(find.text('发送验证码'), findsOneWidget); // 可重试
      expect(find.byKey(const Key('code')), findsNothing); // 没有进入下一步
    });

    testWidgets('登录失败显示错误且可重试', (t) async {
      final api = FakeApi(failLogin: true);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('code')), '111111');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();
      expect(find.text('验证码不对或已过期,请重新发送'), findsOneWidget); // B2:不说「重新登录」
      expect(find.text('登录'), findsOneWidget); // 可重试
    });
  });

  group('解锁三态(已有密钥、本机无私钥)', () {
    testWidgets('口令解锁:加载中显示进度圈', (t) async {
      final api = FakeApi(hasKeys: true);
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('口令解锁成功:进入已就绪,私钥写入 session', (t) async {
      final api = FakeApi(hasKeys: true);
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      expect(AccountSession.instance.privateKey, isNotNull);
    });

    testWidgets('口令解锁失败:报错,不清 session', (t) async {
      final api = FakeApi(hasKeys: true);
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);
      await t.enterText(find.byKey(const Key('password')), 'wrong');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pumpAndSettle();
      expect(find.textContaining('口令不对'), findsOneWidget);
      expect(AccountSession.instance.accountId, isNotNull);
      expect(AccountSession.instance.access, isNotNull);
      expect(AccountSession.instance.privateKey, isNull);
    });

    testWidgets('恢复码解锁成功:进入已就绪,私钥写入 session', (t) async {
      final api = FakeApi(hasKeys: true);
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.tap(find.text('口令忘了?改用恢复码解锁'));
      await t.pump();
      await t.enterText(find.byKey(const Key('recovery_code')), 'GOODCODE');
      await t.tap(find.text('用恢复码解锁'));
      await t.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      expect(AccountSession.instance.privateKey, isNotNull);
    });

    testWidgets('恢复码解锁失败:报错,session 完好(token 还在、私钥仍未写入)', (t) async {
      final api = FakeApi(hasKeys: true);
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.tap(find.text('口令忘了?改用恢复码解锁'));
      await t.pump();
      await t.enterText(find.byKey(const Key('recovery_code')), 'WRONGCODE');
      await t.tap(find.text('用恢复码解锁'));
      await t.pumpAndSettle();
      expect(find.textContaining('恢复码不对'), findsOneWidget);
      expect(AccountSession.instance.accountId, isNotNull);
      expect(AccountSession.instance.access, isNotNull);
      expect(AccountSession.instance.privateKey, isNull);
    });
  });

  group('已就绪:设备列表(C2:列表里没有「批准」按钮)', () {
    // 复审 C2(CRITICAL):那颗按钮把账号私钥封给**服务端返回的** `eph_public` ——
    // 和 C1 是同一个替换攻击的另一半:恶意服务器在 `GET /v1/devices` 里塞一行
    // 假的"待批准设备",公钥是它自己的,旧设备一点「批准」就把账号私钥交出去了。
    // 而扫码那条路上那把公钥来自**用户眼睛看到的那张码**(而且还要和服务器记录
    // 逐字节一致,见 I3)。所以批准只留扫码这一条路。
    testWidgets('加载中 → 成功展示;待批准的设备只有状态文字,没有可点的「批准」', (t) async {
      final api = FakeApi(hasKeys: true, devices: [
        {'device_id': 'dev2', 'name': 'iPhone 15', 'eph_public': 'AA==', 'approved': false},
      ]);
      await _toReady(t, api);
      await _scrollToText(t, '设备');
      expect(find.text('iPhone 15'), findsOneWidget);
      expect(find.text('新设备,等你批准'), findsOneWidget, reason: '状态照实显示,只是不给这条操作入口');
      expect(
        find.widgetWithText(TextButton, '批准'),
        findsNothing,
        reason: '批准私钥不能封给服务端报上来的公钥 —— 唯一的批准路径是扫那张码',
      );
      await _scrollToText(t, '扫码批准新设备');
      expect(find.byKey(const Key('scan_approve_device')), findsOneWidget);
    });

    testWidgets('加载失败:显示错误,不崩', (t) async {
      final api = FakeApi(hasKeys: true, failDevices: true);
      await _toReady(t, api);
      await _scrollToText(t, '设备');
      expect(find.textContaining('设备列表加载失败:服务器开小差了'), findsOneWidget);
    });

    testWidgets('屏上怎么点都不会发出 devices/approve(除了扫码那条)', (t) async {
      final api = FakeApi(hasKeys: true, devices: [
        {'device_id': 'dev2', 'name': 'iPhone 15', 'eph_public': 'AA==', 'approved': false},
      ]);
      await _toReady(t, api);
      await _scrollToText(t, '新设备,等你批准');
      await t.tap(find.text('新设备,等你批准'));
      await t.pumpAndSettle();
      expect(api.calls, isNot(contains('POST /v1/devices/approve')));
    });
  });

  // ---- C1/C2/C3/C6/C7:内部 id 不给用户看,区块顺序按"用户来干什么"排 ----
  group('C:账号屏不再把内部 id 和英文角色摆给用户', () {
    test('maskPhone:只留头三位和后四位;不像手机号的一律 ****', () {
      expect(maskPhone('13800138000'), '138****8000');
      expect(maskPhone('138 0013 8000'), '138****8000');
      expect(maskPhone('+8613800138000'), '861****8000');
      expect(maskPhone('123'), '****');
      expect(maskPhone(''), '****');
    });

    test('roleLabel:服务端的词不出现在界面上', () {
      expect(roleLabel('viewer'), '只能看');
      expect(roleLabel('editor'), '能一起录');
      expect(roleLabel('owner'), '主人');
      expect(roleLabel(null), '未知');
    });

    test('expiryLabel:ISO 串 → 「至 M月D日」;没有到期日是「长期有效」', () {
      expect(expiryLabel('2026-09-20T10:00:00'), '至 9月20日');
      expect(expiryLabel(null), '长期有效');
      // 评审 Minor 16:解析不了**不是**「长期有效」—— 一个格式坏掉的 expires_at
      // 会让一份有期限的授权读起来像永久的,而这是一个权限标签。
      expect(expiryLabel('不是时间'), '到期时间不明');
      expect(expiryLabel('2026-09-20T10:00:00'), isNot(contains('T')));
    });

    test('createdLabel:「M月D日添加」;认不出来就不说(不编一个日期)', () {
      // 不带 Z = 按本地时间解析,于是断言不跟着跑测试的机器所在时区变。
      expect(createdLabel('2026-01-02T03:04:05'), '1月2日添加');
      expect(createdLabel(null), isNull);
      expect(createdLabel('garbage'), isNull);
    });

    testWidgets('C1:账号那一行显示脱敏手机号,不显示 account_id', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api, debugModeOverride: false);
      expect(find.text('138****0001'), findsOneWidget);
      expect(find.textContaining('acc_1'), findsNothing);
      expect(find.textContaining('账号:'), findsNothing);
    });

    testWidgets('C1:明文手机号不落盘,只存脱敏串', (t) async {
      await _toReady(t, FakeApi(hasKeys: true));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('acct_phone_masked'), '138****0001');
      expect(
        prefs.getKeys().map((k) => prefs.get(k).toString()).where((v) => v.contains('13800000001')),
        isEmpty,
        reason: '明文手机号是可辨识个人信息,一个字都不该存',
      );
    });

    testWidgets('C1:Apple 登录没有手机号,显示「Apple 登录」', (t) async {
      await AccountSession.instance.save(accountId: 'acc_1', access: 'a', refresh: 'r', loginMethod: 'apple');
      AccountSession.instance.privateKey = Uint8List(32); // 本机已有私钥 → 直接就绪
      await t.pumpWidget(_app(FakeApi(hasKeys: true), debugModeOverride: false));
      await t.pumpAndSettle();
      expect(find.text('Apple 登录'), findsOneWidget);
    });

    testWidgets('C1:debug 包里内部 id 还在(排查用),正式包里没有', (t) async {
      await _toReady(t, FakeApi(hasKeys: true), debugModeOverride: true);
      await _scrollToText(t, '账号管理');
      expect(find.textContaining('accountId=acc_1'), findsOneWidget);
    });

    testWidgets('C7:「云同步」排在第一个区块,「设备」排在「云同步」后面', (t) async {
      await _toReady(t, FakeApi(hasKeys: true), debugModeOverride: false);
      final cloud = t.getTopLeft(find.text('云同步')).dy;
      final grants = t.getTopLeft(find.text('授权')).dy;
      expect(cloud < grants, isTrue, reason: '点进账号屏十次里九次是为了"我的病历备上了没有"');
    });

    testWidgets('C2/C3:「我授权给谁」每行是中文角色 + 至 M月D日 + 添加日期,不露 grantee_kind', (t) async {
      final api = FakeApi(
        hasKeys: true,
        profiles: [
          {'profile_id': 'prf_1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        myGrants: {
          'prf_1': [
            {
              'grant_id': 'g2',
              'grantee_kind': 'account',
              'role': 'editor',
              'expires_at': '2026-12-31T12:00:00',
              'created_at': '2026-01-02T12:00:00',
            },
          ],
        },
      );
      // `debugModeOverride: false`:debug 那一行会显示 `accountId=acc_1`,里头带着
      // 「account」三个字,会误伤下面那条断言。
      await _toReady(t, api, debugModeOverride: false);
      await _scrollToMyGrants(t);

      expect(find.text('能一起录 · 至 12月31日 · 1月2日添加'), findsOneWidget);
      expect(find.textContaining('account'), findsNothing, reason: 'grantee_kind 是服务端实现细节');
      expect(find.textContaining('editor'), findsNothing);
      expect(find.textContaining('2026-'), findsNothing, reason: 'ISO 串不给用户看');
    });

    testWidgets('C6:恢复码屏除了「复制」还有「分享给自己」', (t) async {
      await t.pumpWidget(_app(FakeApi()));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.byKey(const Key('recovery_share')), findsOneWidget);
      expect(find.textContaining('不要只存在这台手机上'), findsOneWidget);
    });
  });

  // ---- A2:设备列表三态 ----
  group('A2:设备列表不再把自己的手机标成「等待批准」', () {
    test('正常设备(eph_public 为 null):「这台设备已可用」,没有批准按钮', () {
      final now = DateTime(2026, 9, 12, 12);
      final row = deviceRow({
        'device_id': 'dev1',
        'name': 'ios',
        'eph_public': null,
        // `approved` 是 `approved_priv IS NOT NULL` —— 正常设备就是 false,
        // 这正是旧文案把它写成「等待批准」的来源。
        'approved': false,
        'last_seen': '2026-09-12T11:00:00.000Z',
      }, now: now);
      expect(row.pending, isFalse);
      expect(row.status, startsWith('这台设备已可用'));
      expect(row.status, isNot(contains('等待批准')));
    });

    test('新设备(有 eph_public):「新设备,等你批准」+ 可批准', () {
      final row = deviceRow({'device_id': 'dev2', 'name': 'android', 'eph_public': 'AA==', 'approved': false});
      expect(row.pending, isTrue);
      expect(row.status, '新设备,等你批准');
    });

    test('设备名中文化:android / ios 不直接给用户看', () {
      expect(deviceRow({'device_id': 'd', 'name': 'android'}).name, '安卓手机');
      expect(deviceRow({'device_id': 'd', 'name': 'ios'}).name, 'iPhone/iPad');
      expect(deviceRow({'device_id': 'd', 'name': 'Pixel 8'}).name, 'Pixel 8', reason: '认不出的原样显示');
      expect(deviceRow({'device_id': 'dev9'}).name, 'dev9', reason: '没有名字才退回 device_id');
    });

    test('last_seen 本地化:刚刚 / 今天 / 昨天 / M月D日,不给 ISO 串', () {
      final now = DateTime(2026, 9, 12, 12);
      String at(DateTime t) => deviceRow({
        'device_id': 'd',
        'name': 'ios',
        'last_seen': t.toUtc().toIso8601String(),
      }, now: now).status;
      expect(at(DateTime(2026, 9, 12, 11, 30)), contains('刚刚'));
      expect(at(DateTime(2026, 9, 12, 1)), contains('今天'));
      expect(at(DateTime(2026, 9, 11, 23)), contains('昨天'));
      expect(at(DateTime(2026, 8, 3, 9)), contains('8月3日'));
      expect(at(DateTime(2026, 8, 3, 9)), isNot(contains('T')));
    });

    testWidgets('屏上:两台设备各自的状态照实显示(C2 之后谁都没有「批准」按钮)', (t) async {
      final api = FakeApi(hasKeys: true, devices: [
        {'device_id': 'dev1', 'name': 'ios', 'eph_public': null, 'approved': false, 'last_seen': '2026-01-01T00:00:00.000Z'},
        {'device_id': 'dev2', 'name': 'android', 'eph_public': 'AA==', 'approved': false, 'last_seen': '2026-01-01T00:00:00.000Z'},
      ]);
      await _toReady(t, api);
      await _scrollToText(t, '设备');
      expect(find.text('iPhone/iPad'), findsOneWidget);
      expect(find.text('安卓手机'), findsOneWidget);
      expect(find.text('新设备,等你批准'), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, '批准'),
        findsNothing,
        reason: '复审 C2:批准私钥不能封给服务端报上来的公钥 —— 只能走扫码那条',
      );
      expect(find.textContaining('等待批准'), findsNothing);
    });
  });

  group('已就绪:授权列表(只读,不带撤销)', () {
    testWidgets('加载中 → 成功展示,owner 行不带「撤销」按钮', (t) async {
      final api = FakeApi(hasKeys: true, profiles: [
        {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
      ]);
      await _toReady(t, api);
      // C:`prf_xxx` 是服务端内部 id,不给用户看;对不上本机成员时说「一份共享档案」。
      expect(find.text('一份共享档案'), findsOneWidget);
      expect(find.textContaining('p1'), findsNothing);
      expect(find.text('主人 · 长期有效'), findsOneWidget, reason: '角色中文化;没有到期日说「长期有效」,不露 null');
      expect(
        find.text('撤销'),
        findsNothing,
        reason: '这一行是"我在 p1 里是 owner",不是"我授权给了谁"——点这里的撤销以前恒 404',
      );
    });

    testWidgets('加载失败:显示错误,不崩', (t) async {
      final api = FakeApi(hasKeys: true, failProfiles: true);
      await _toReady(t, api);
      expect(find.textContaining('授权列表加载失败'), findsOneWidget);
    });
  });

  group('已就绪:我授权给谁 + 撤销', () {
    Map<String, dynamic> granteeRow() =>
        {'grant_id': 'g2', 'grantee_kind': 'account', 'role': 'editor', 'expires_at': null, 'created_at': '2026-01-01T00:00:00Z'};

    testWidgets('加载中 → 成功展示(带「撤销」按钮)', (t) async {
      final api = FakeApi(
        hasKeys: true,
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        myGrants: {'p1': [granteeRow()]},
      );
      await _toReady(t, api);
      await _scrollToMyGrants(t);
      expect(find.text('还没有授权给任何人'), findsNothing);
      expect(find.text('撤销'), findsOneWidget);
    });

    testWidgets('加载中显示进度圈', (t) async {
      // `myGrantsDelay` 只拖慢 GET .../grants 这一个调用,不拖累解锁本身(那走
      // 的是 [delay])——这样才能在"已进入已就绪、这一节还没回来"这个窗口里
      // 稳定截住 loading 帧,不用赌解锁跟这一节谁先回来。
      final api = FakeApi(
        hasKeys: true,
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        myGrants: {'p1': [granteeRow()]},
        myGrantsDelay: const Duration(seconds: 3),
      );
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.pump();
      await t.tap(find.text('解锁'));
      // 200ms:盖过解锁本身(FakeCrypto 20ms + restoreProfileKeys 的 GET
      // /v1/profiles 30ms),但远小于 myGrantsDelay(3s)——此刻应该已经落在
      // "已就绪,「我授权给谁」还在等" 这个窗口。
      await t.pump(const Duration(milliseconds: 200));
      await t.scrollUntilVisible(find.text('我授权给谁'), 200, scrollable: find.byType(Scrollable).first);
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      // 收尾:把剩下的延迟耗完,不留 pending timer。
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
    });

    testWidgets('没有拥有任何云档案:显示空态,不发 grants 请求', (t) async {
      final api = FakeApi(hasKeys: true, profiles: const []);
      await _toReady(t, api);
      await _scrollToMyGrants(t);
      expect(find.text('还没有授权给任何人'), findsOneWidget);
      expect(api.calls.any((c) => c.contains('/grants')), isFalse, reason: '没有拥有任何档案,不该多打一次 grants 请求');
    });

    testWidgets('加载失败:显示错误,不崩', (t) async {
      final api = FakeApi(
        hasKeys: true,
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        failMyGrants: true,
      );
      await _toReady(t, api);
      await _scrollToMyGrants(t);
      expect(find.textContaining('加载失败'), findsOneWidget);
    });

    testWidgets('撤销成功:调用 DELETE,不留错误', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 10),
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        myGrants: {'p1': [granteeRow()]},
      );
      await _toReady(t, api);
      await _scrollToMyGrants(t);
      await t.tap(find.text('撤销'));
      await t.pumpAndSettle();
      expect(api.calls, contains('DELETE /v1/profiles/p1/grants/g2'));
      expect(find.textContaining('撤销失败'), findsNothing);
    });

    // 评审 Minor 20:双击会发两个 DELETE,第二个在成功撤销之后立刻显示
    // 「撤销失败:没有找到…」—— 一次成功的操作看起来像失败了。
    testWidgets('Minor 20:连点「撤销」只发一个 DELETE', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 30),
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        myGrants: {'p1': [granteeRow()]},
      );
      await _toReady(t, api);
      await _scrollToMyGrants(t);

      await t.tap(find.text('撤销'));
      await t.pump(); // busy 起来了,按钮应该已经禁用
      expect(t.widget<TextButton>(find.widgetWithText(TextButton, '撤销')).onPressed, isNull);
      await t.tap(find.text('撤销')); // 第二下:打在一个禁用的按钮上
      await t.pumpAndSettle();

      expect(api.calls.where((c) => c.startsWith('DELETE')).length, 1);
      expect(find.textContaining('撤销失败'), findsNothing);
    });

    testWidgets('撤销失败:错误可见,列表原样还在', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 10),
        failRevoke: true,
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
        myGrants: {'p1': [granteeRow()]},
      );
      await _toReady(t, api);
      await _scrollToMyGrants(t);
      await t.tap(find.text('撤销'));
      await t.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('撤销失败'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('撤销'), findsOneWidget);
    });
  });

  // ---- B5:`inviteTransfer` 在这之前一个调用方都没有 ----
  group('B5:「转为主人」', () {
    Map<String, dynamic> granteeRow() => {
      'grant_id': 'g2',
      'grantee_kind': 'account',
      'role': 'editor',
      'expires_at': null,
      'created_at': '2026-01-01T00:00:00Z',
    };

    FakeApi apiWithGrantee() => FakeApi(
      hasKeys: true,
      delay: const Duration(milliseconds: 5),
      profiles: [
        {'profile_id': 'prf_1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
      ],
      myGrants: {'prf_1': [granteeRow()]},
    );

    /// 让当前成员对应云档案 prf_1(`inviteTransfer` 要档案密钥)。
    Future<void> setUpOwnedCloudProfile(WidgetTester t) async {
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', 'owner', null);
      });
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
    }

    testWidgets('每行都有「转为主人」,点了先弹确认,说明"现在还不会改变任何东西"', (t) async {
      final api = apiWithGrantee();
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));
      await _scrollToMyGrants(t);

      expect(find.text('转为主人'), findsOneWidget);
      await t.tap(find.byKey(const Key('transfer_g2')));
      await t.pumpAndSettle();

      expect(find.text('把这份档案交给他?'), findsOneWidget);
      expect(find.textContaining('降为可以一起录入的家人'), findsOneWidget);
      expect(find.textContaining('还不会改变任何东西'), findsOneWidget);
      expect(find.text('生成链接'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('取消:不发任何请求', (t) async {
      final api = apiWithGrantee();
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));
      await _scrollToMyGrants(t);
      await t.tap(find.byKey(const Key('transfer_g2')));
      await t.pumpAndSettle();
      api.calls.clear();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(api.calls.any((c) => c.contains('/invites')), isFalse);
    });

    testWidgets('确认:调 inviteTransfer(owner、不按天到期),弹出可分享的码', (t) async {
      final api = apiWithGrantee();
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));
      await _scrollToMyGrants(t);
      await t.tap(find.byKey(const Key('transfer_g2')));
      await t.pumpAndSettle();
      await t.tap(find.text('生成链接'));
      await t.pumpAndSettle();

      expect(api.calls, contains('POST /v1/profiles/prf_1/invites'));
      expect(api.inviteBodies.single['role'], 'owner');
      expect(
        api.inviteBodies.single.containsKey('days'),
        isFalse,
        reason: '转移一旦兑换即刻生效,不像医生邀请那样按天到期',
      );
      expect(find.text('请他扫这个码'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);
      expect(find.text('发给他'), findsOneWidget);

      // Minor 18:这条路的复制提示是通用那句(代拍那条路有自己的,见
      // `doctor_claim_link_dialog_test`)。两条都钉住,免得抽取时再丢一次。
      // 对话框内容在 `SingleChildScrollView` 里,800×600 的测试画布上这颗按钮
      // 落在视口外 —— 不先滚进来,`tap` 点的是一片空白。
      await t.ensureVisible(find.text('复制链接'));
      await t.pumpAndSettle();
      await t.tap(find.text('复制链接'));
      await t.pumpAndSettle();
      expect(find.text('链接已复制'), findsOneWidget);
    });

    // ---- 评审 Important 8:入口不能只挂在"对方已经是家属"之后 ----
    testWidgets('Important 8:自有云成员那一块本身就有转移入口,不必对方先成为家属', (t) async {
      // 只有一个自己拥有的云档案、**没有任何 grantee** —— 「我授权给谁」是空的,
      // 而红队说的正是"把档案交给一个还不是家属的人"。
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        profiles: [
          {'profile_id': 'prf_1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
      );
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      expect(find.byKey(const Key('transfer_current_profile')), findsOneWidget);
      await _scrollToMyGrants(t);
      expect(find.text('还没有授权给任何人'), findsOneWidget, reason: '前提:一个家属都没有');
      expect(find.text('转为主人'), findsNothing, reason: 'per-grantee 那条路此刻根本不存在');
    });

    testWidgets('Important 8:那个入口走同一条确认 → 生成 owner 邀请', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        profiles: [
          {'profile_id': 'prf_1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
      );
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await t.tap(find.byKey(const Key('transfer_current_profile')));
      await t.pumpAndSettle();
      expect(find.text('把这份档案交给他?'), findsOneWidget);
      await t.tap(find.text('生成链接'));
      await t.pumpAndSettle();

      expect(api.inviteBodies.single['role'], 'owner');
      expect(find.text('请他扫这个码'), findsOneWidget);
    });

    // 复审新问题 3 的 UI 面**拆成两条已有用例来保证**,不另起一条 widget 用例:
    //  · 「服务端报 editor → 本机 role 被刷成 editor」在上面的
    //    `AccountFlow.restoreProfileKeys` 组里(纯逻辑,`test()`);
    //  · 「role != owner → 没有这个入口」就是紧接着下面这一条。
    // 合起来跑不了:刷新角色会写 profiles.json,而真实文件 I/O 在
    // `pumpAndSettle` 下等不到(本文件顶部那条一贯的限制,试过,超时)。
    testWidgets('不是 owner(被授权的 editor):没有这个入口(服务端本来就 403)', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', 'editor', null);
      });
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      expect(find.byKey(const Key('transfer_current_profile')), findsNothing);
    });

    // ---- 评审 Important 9:所有权转移令牌没有生命周期 ----
    testWidgets('Important 9:连点两次只铸一个令牌(服务端没有列出/撤销 invite 的端点)', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        profiles: [
          {'profile_id': 'prf_1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
      );
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      for (var i = 0; i < 2; i++) {
        await t.tap(find.byKey(const Key('transfer_current_profile')));
        await t.pumpAndSettle();
        await t.tap(find.text('生成链接'));
        await t.pumpAndSettle();
        await t.tap(find.text('关闭'));
        await t.pumpAndSettle();
      }

      expect(
        api.inviteBodies.length,
        1,
        reason: '三次手忙脚乱的点击 = 三个各自都能交出所有权的、不可见、不可撤销的令牌',
      );
    });

    testWidgets('Important 9:脚注说真话 —— 不绑定某个人、无法撤回', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        profiles: [
          {'profile_id': 'prf_1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
      );
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));
      await t.tap(find.byKey(const Key('transfer_current_profile')));
      await t.pumpAndSettle();

      expect(find.textContaining('拿到这个码的任何人都能接受'), findsOneWidget);
      expect(find.textContaining('没有办法收回'), findsOneWidget);
      await t.tap(find.text('生成链接'));
      await t.pumpAndSettle();

      expect(find.textContaining('生成之后无法撤回'), findsOneWidget);
      expect(
        find.textContaining('你随时可以不管它'),
        findsNothing,
        reason: '那句是误导:服务端既没有列出 invite 的端点,也没有撤销的端点',
      );
    });

    testWidgets('生成失败(服务器 500):中文提示,列表原样还在', (t) async {
      final api = apiWithGrantee()..failInvite = true;
      await setUpOwnedCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));
      await _scrollToMyGrants(t);
      await t.tap(find.byKey(const Key('transfer_g2')));
      await t.pumpAndSettle();
      await t.tap(find.text('生成链接'));
      await t.pumpAndSettle();

      expect(find.text('生成转移链接失败:服务器开小差了,稍后再试'), findsOneWidget);
      expect(find.text('转为主人'), findsOneWidget);
    });
  });

  group('已就绪:按手机号添加家属', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-account-family-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    /// 给当前成员(默认档案)一个 cloudId,`_familySection` 才会显示表单而不是
    /// 「还没开通云同步」的提示。真实文件 IO(`markCloud` 落盘)包进 `runAsync`
    /// (Task 10 的教训)。
    Future<void> setUpCloudProfile(WidgetTester t) async {
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', 'owner', null);
      });
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
    }

    testWidgets('加载中显示进度圈', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 30),
        lookupResult: {'account_id': 'acc_family', 'public_key': 'QQ=='},
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await _scrollToText(t, '家属');
      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
      await _scrollToText(t, '按手机号添加家属');
      await t.tap(find.text('按手机号添加家属'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('查到账号:成功、清空输入框、按永久 editor 授权', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupResult: {'account_id': 'acc_family', 'public_key': 'QQ=='},
      );
      final rust = FakeGrantsRust();
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: rust));

      await _scrollToText(t, '家属');
      await t.enterText(find.byKey(const Key('family_phone')), '138 0000 1111');
      await _scrollToText(t, '按手机号添加家属');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(api.calls, contains('POST /v1/accounts/lookup'));
      expect(api.calls, contains('POST /v1/profiles/prf_1/grants'));
      expect(find.text('138 0000 1111'), findsNothing, reason: '成功后应清空输入框(且已去除空格发送)');
      expect(rust.sealedWith, isNotEmpty, reason: '应该封给对方公钥');
    });

    testWidgets('手机号查不到人(404):提示「没有找到使用该手机号的账号」', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupError: const ApiFailed(404, 'not found'),
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await _scrollToText(t, '家属');
      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
      await _scrollToText(t, '按手机号添加家属');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(find.text('没有找到使用该手机号的账号'), findsOneWidget);
    });

    testWidgets('B4:对方已注册、但还没设账号口令(409 no_keys):说清楚该他做什么', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupError: const ApiFailed(409, 'no_keys'),
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await _scrollToText(t, '家属');
      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
      await _scrollToText(t, '按手机号添加家属');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(
        find.text('对方已注册,但还没设置好账号口令 —— 请他在 MedMe 里打开 设置 → 账号,完成最后两步'),
        findsOneWidget,
      );
      expect(
        find.text('没有找到使用该手机号的账号'),
        findsNothing,
        reason: '这是错误归因:家属会去确认手机号、重输、放弃,而真正要做的事在对方手机上',
      );
    });

    testWidgets('限流(429):提示「查询太频繁,稍后再试」', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupError: const ApiFailed(429, 'rate_limited'),
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await _scrollToText(t, '家属');
      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
      await _scrollToText(t, '按手机号添加家属');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(find.text('操作太频繁,过一会儿再试'), findsOneWidget); // 迁进 friendlyApiError 之后的统一措辞
    });

    testWidgets('手机号格式不对(400):提示「手机号格式不对」', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupError: const ApiFailed(400, 'bad phone'),
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await _scrollToText(t, '家属');
      await t.enterText(find.byKey(const Key('family_phone')), 'abc'); // 打个不像手机号的
      await _scrollToText(t, '按手机号添加家属');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(find.text('手机号格式不对'), findsOneWidget);
    });

    testWidgets('当前成员还没开通云同步:不显示表单', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });
      await _toReady(t, api);

      expect(find.byKey(const Key('family_phone')), findsNothing);
      await _scrollToText(t, '家属');
      expect(find.textContaining('暂时不能添加家属'), findsOneWidget);
    });
  });

  group('冷启动恢复登录态(initState 里的 resumeIfLoggedIn)', () {
    testWidgets('本机已有 token,但账号服务 500:错误可见,不留未处理的 rejection', (t) async {
      // 模拟"上次登录过、这次冷启动"——本屏重建前就已经有 token 落盘,
      // `resumeIfLoggedIn` 因此不会因为"从没登录过"提前返回 null,而是真的去
      // 调 `GET /v1/account/keys`。
      await AccountSession.instance.save(accountId: 'acc_1', access: 'a', refresh: 'r');
      final api = FakeApi(failKeys500: true);

      await t.pumpWidget(_app(api));
      await t.pumpAndSettle();

      // 错误落在 `_error` 上、停在 idle——不是崩溃,也不是安静地卡住。
      expect(find.text('服务器开小差了,稍后再试'), findsOneWidget);
      expect(find.text('登录 MedMe 账号'), findsOneWidget);
      // 没有因为异常而误判成"需要设口令"或"已就绪"。
      expect(find.text('设置口令'), findsNothing);
      expect(find.text('已登录'), findsNothing);
    });

    testWidgets('本机没有 token:安静地停在 idle,不报错', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api));
      await t.pumpAndSettle();
      expect(find.text('登录 MedMe 账号'), findsOneWidget);
      expect(api.calls, isEmpty);
    });
  });

  // ---- B1:断网 → 屏上是中文,不是 `SocketException: Connection refused ...` ----
  //
  // **分两层验,各验各的:**
  //   · "真 socket 失败 → `ApiNetworkError`" 在 `test/api_client_test.dart` 里用一个
  //     真的已关闭端口验过(翻译只在 `ApiClient` 一处,那里是它的家);
  //   · 这里验"翻完的异常走到屏上长什么样"。
  //
  // 不在 widget 测试里真发 socket:`tester.tap` 起的那条 Future 链活在 fake-async
  // 的时钟里,真实 socket 的回调永远推不进来,`pumpAndSettle` 干等到超时(试过,
  // 10 分钟)。
  group('B1:断网 → 账号屏显示中文句子', () {
    testWidgets('发验证码撞上连不上:屏上「网络连不上,换个网络再试一次。」', (t) async {
      final api = FakeApi(otpError: ApiNetworkError.offline);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();

      expect(find.text('网络连不上,换个网络再试一次。'), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.text('发送验证码'), findsOneWidget, reason: '可以直接重试');
    });

    testWidgets('发验证码撞上读超时:屏上「网络太慢…」', (t) async {
      final api = FakeApi(otpError: ApiNetworkError.slow);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();

      expect(find.text('网络太慢,没能连上服务器。换个网络再试一次。'), findsOneWidget);
    });
  });

  group('AccountFlow 逻辑单测:prepareKeys 不落盘、commitKeys 才落盘', () {
    test('prepareKeys(): 只在内存里生成,不调用 PUT,不写 session', () async {
      final api = FakeApi();
      final flow = AccountFlow(api, AccountSession.instance, crypto: FakeCrypto());
      await flow.loginOtp('13800000001', '000000');
      api.calls.clear();

      final keys = await flow.prepareKeys('right');

      expect(keys.recoveryCode, 'ABCD-EFGH-JKMN-PQRS-TVWX');
      expect(api.calls, isEmpty);
      expect(AccountSession.instance.privateKey, isNull);
    });

    test('commitKeys(): 上传服务器 + 写入本机 session', () async {
      final api = FakeApi();
      final flow = AccountFlow(api, AccountSession.instance, crypto: FakeCrypto());
      await flow.loginOtp('13800000001', '000000');
      final keys = await flow.prepareKeys('right');
      api.calls.clear();

      await flow.commitKeys(keys);

      expect(api.calls, contains('PUT /v1/account/keys'));
      expect(AccountSession.instance.privateKey, isNotNull);
      expect(AccountSession.instance.publicKey, isNotNull);
    });

    test('loginOtp() 记下 loginMethod=otp——注销账号那一步靠它选重新鉴权方式', () async {
      final api = FakeApi();
      final flow = AccountFlow(api, AccountSession.instance, crypto: FakeCrypto());
      await flow.loginOtp('13800000001', '000000');
      expect(AccountSession.instance.loginMethod, 'otp');
    });
  });

  group('account_login 埋点:只报登录这一步,不掺 _afterLogin 的失败', () {
    tearDown(() => Analytics.debugSink = null);

    test('OTP 登录成功,但随后 GET /v1/account/keys 500:只报一次 account_login(ok:true),异常仍然往外抛', () async {
      final api = FakeApi(failKeys500: true);
      final flow = AccountFlow(api, AccountSession.instance, crypto: FakeCrypto());
      final events = <MapEntry<AnalyticsEvent, Map<String, Object>>>[];
      Analytics.debugSink = (e, p) => events.add(MapEntry(e, p));

      await expectLater(
        () => flow.loginOtp('13800000001', '000000'),
        throwsA(isA<ApiFailed>()),
      );

      final loginEvents = events.where((e) => e.key == AnalyticsEvent.accountLogin).toList();
      expect(loginEvents, hasLength(1), reason: '_afterLogin 的失败不该再报第二条 account_login');
      expect(loginEvents.single.value, {'method': 'otp', 'ok': true});
    });

    // `loginApple` 走的是同一段被拆开的 try/catch 结构,但会真的调
    // `SignInWithApple.getAppleIDCredential`(无法在 `flutter test` 里注入原生
    // 实现),不再单独起一条用例——上面这条 OTP 用例已经钉住了"登录成功但
    // `_afterLogin` 失败,不该多报一条 account_login"这条共享逻辑。
  });

  group('AccountFlow.restoreProfileKeys(fix round 1: Task 15 review C1)', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-restore-keys-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    test('退出登录后重新登录:服务端有、本机缺的密钥被补回来;当前锁着的成员补上后自动重开', () async {
      final wrappedKey = Uint8List.fromList(List.generate(32, (i) => i));
      final api = FakeApi(hasKeys: true, profiles: [
        {'profile_id': 'prf_locked', 'role': 'owner', 'expires_at': null, 'wrapped_profile_key': base64Encode(wrappedKey)},
      ]);
      var reopened = false;
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async => reopened = true,
      );

      // 模拟"退出登录"之后的样子:当前成员已经标记了 cloudId,但本机 secure
      // storage 里没有它的密钥(`AccountSession.clear()` 把它清掉了)。
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_locked', 'owner', null);
      expect(await AccountSession.instance.profileKey('prf_locked'), isNull);

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(await AccountSession.instance.profileKey('prf_locked'), wrappedKey);
      expect(reopened, isTrue, reason: '当前成员补齐密钥前是锁着的,补完必须自动重开一次');
      expect(flow.lastOutcome, LoginOutcome.ready);
    });

    test('当前成员本来就没锁(已有密钥):不触发重开,即便服务端也返回了它的 wrapped_profile_key', () async {
      final api = FakeApi(hasKeys: true, profiles: [
        {'profile_id': 'prf_1', 'role': 'owner', 'expires_at': null, 'wrapped_profile_key': base64Encode(Uint8List(32))},
      ]);
      var reopened = false;
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async => reopened = true,
      );

      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', 'owner', null);
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32)); // 本机已经有密钥,不是锁着的

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(reopened, isFalse, reason: '没有锁着的成员需要补,不该触发重开(不该白跑一次 FFI)');
    });

    test('/v1/profiles 请求失败:静默跳过,不影响解锁本身成功', () async {
      final api = FakeApi(hasKeys: true, failProfiles: true);
      final flow = AccountFlow(api, AccountSession.instance, crypto: FakeCrypto());

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(flow.lastOutcome, LoginOutcome.ready);
    });

    // ---- 最终评审 I3:换机/清过数据之后,服务端有、本机压根没有的云档案要被"领回来" ----

    test('I3:服务端有一个本机没有的云档案 → 新建本地成员(占位名 + 密钥 + role/到期)', () async {
      final wrappedKey = Uint8List.fromList(List.generate(32, (i) => 7));
      final api = FakeApi(hasKeys: true, profiles: [
        {
          'profile_id': 'prf_unknown_abcdef',
          'role': 'editor',
          'expires_at': '2027-01-02T03:04:05.000Z',
          'wrapped_profile_key': base64Encode(wrappedKey),
        },
      ]);
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final before = ProfileManager.instance.profiles.length;
      final currentBefore = ProfileManager.instance.currentId.value;

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      final adopted = ProfileManager.instance.profiles.where((p) => p.cloudId == 'prf_unknown_abcdef').toList();
      expect(adopted.length, 1);
      // A5:占位名不再是「云端档案 prf_un」—— 换了台新手机的人第一眼看到的不该
      // 是一串内部 id。
      expect(adopted.single.name, '正在恢复的档案');
      expect(adopted.single.role, 'editor');
      expect(adopted.single.expiresAt, DateTime.parse('2027-01-02T03:04:05.000Z'));
      expect(await AccountSession.instance.profileKey('prf_unknown_abcdef'), wrappedKey);
      expect(ProfileManager.instance.profiles.length, before + 1);
      expect(
        ProfileManager.instance.currentId.value,
        currentBefore,
        reason: '顺手补齐不该把用户正在看的成员切走(ProfileManager.create 自己会切)',
      );
    });

    // ---- A5:新领回来的成员要立刻同步 + 回填姓名,还要收拾掉那个空的默认成员 ----

    /// 服务端有一个本机没有的云档案。
    FakeApi oneUnknownCloudProfile() => FakeApi(hasKeys: true, profiles: [
      {
        'profile_id': 'prf_mine_1',
        'role': 'owner',
        'expires_at': null,
        'wrapped_profile_key': base64Encode(Uint8List(32)),
      },
    ]);

    test('A5:新建的成员被登记给后台触发器跑首同步(不在这里同步)', () async {
      final api = oneUnknownCloudProfile();
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      final adopted = ProfileManager.instance.profiles.firstWhere((p) => p.cloudId == 'prf_mine_1');
      expect(
        pendingFirstSync,
        contains(adopted.id),
        reason: '换机之后不该等"用户哪天自己切过去"才有第一次同步;'
            '但也不该在启动路径上串行跑 N 个完整同步(评审 Important 3)',
      );
      expect(adopted.name, '正在恢复的档案', reason: '同步还没跑,名字还是占位串');
    });

    test('A5:本机已有这个云成员、密钥也齐、名字也是真名 → 不重排首同步', () async {
      final api = oneUnknownCloudProfile();
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final id = ProfileManager.instance.current.id;
      await ProfileManager.instance.markCloud(id, 'prf_mine_1', 'owner', null);
      await ProfileManager.instance.rename(id, '张建国'); // 首同步早就成功过
      await AccountSession.instance.putProfileKey('prf_mine_1', Uint8List(32));

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(pendingFirstSync, isEmpty, reason: '用户早就在看它了 —— 不该白跑一次全量同步');
    });

    // 评审 Important 2:密钥是在同步**之前**就存下的,于是下一次启动那句
    // `continue`(有成员 + 有密钥)会把它整条跳过 —— 那唯一一次尝试里的一次网络
    // 抖动就让用户永久看着一个叫「正在恢复的档案」、0 份病历的成员。
    test('Important 2:首同步没成功过的成员(名字还是占位串)下次启动会被重排', () async {
      final api = oneUnknownCloudProfile();
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      // 上一次启动的残局:成员在、密钥在,但名字还是占位串(首同步没成功过)。
      final id = (await ProfileManager.instance.create(
        ProfileManager.restoringPlaceholderName,
        userManaged: false,
      ))!;
      await ProfileManager.instance.markCloud(id, 'prf_mine_1', 'owner', null);
      await ProfileManager.instance.switchTo('p-1');
      await AccountSession.instance.putProfileKey('prf_mine_1', Uint8List(32));
      resetPendingFirstSyncForTest();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(pendingFirstSync, contains(id), reason: '一次网络抖动不该把成员永久钉在占位名上');
    });

    // 复审新问题 2 的另一半:首同步成功、但病历里抽不出姓名的成员,不许每次启动
    // 都被重新排队(那会让它反复切成员、屏幕闪烁,而它其实早就同步好了)。
    test('新问题 2:空档案首同步成功(名字已变中性回退)→ 不再排队', () async {
      final api = oneUnknownCloudProfile();
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      // 上一次启动的结果:首同步跑成功了,但病历里没姓名,于是名字是中性回退。
      final id = (await ProfileManager.instance.create(
        ProfileManager.restoredFallbackName,
        userManaged: false,
      ))!;
      await ProfileManager.instance.markCloud(id, 'prf_mine_1', 'owner', null);
      await ProfileManager.instance.switchTo('p-1');
      await AccountSession.instance.putProfileKey('prf_mine_1', Uint8List(32));
      resetPendingFirstSyncForTest();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(pendingFirstSync, isEmpty, reason: '它已经同步好了 —— 再排一次就是反复闪屏');
    });

    // 复审新问题 3:转移完成之后服务端把我从 owner 降成 editor,本机不刷新就会
    // 一直以为自己还是 owner —— 账号屏那颗「把这份档案转给家人」还在,点一次 403。
    test('新问题 3:服务端的 role 变了(owner → editor)→ 本机跟着更新', () async {
      final api = FakeApi(hasKeys: true, profiles: [
        {
          'profile_id': 'prf_mine_1',
          'role': 'editor', // 已经被转走了
          'expires_at': null,
          'wrapped_profile_key': base64Encode(Uint8List(32)),
        },
      ]);
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final id = ProfileManager.instance.current.id;
      await ProfileManager.instance.markCloud(id, 'prf_mine_1', 'owner', null); // 本机还以为是 owner
      await ProfileManager.instance.rename(id, '张建国');
      await AccountSession.instance.putProfileKey('prf_mine_1', Uint8List(32));

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(ProfileManager.instance.byId(id)!.role, 'editor');
    });

    test('新问题 3:被授权档案的到期被服务端改了 → 本机跟着更新', () async {
      final newExpiry = DateTime.utc(2027, 3, 4, 5);
      final api = FakeApi(hasKeys: true, profiles: [
        {
          'profile_id': 'prf_shared',
          'role': 'viewer',
          'expires_at': newExpiry.toIso8601String(),
          'wrapped_profile_key': base64Encode(Uint8List(32)),
        },
      ]);
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final id = (await ProfileManager.instance.create('老爸', userManaged: false))!;
      await ProfileManager.instance.markCloud(id, 'prf_shared', 'viewer', DateTime.utc(2026, 1, 1));
      await ProfileManager.instance.switchTo('p-1');
      await AccountSession.instance.putProfileKey('prf_shared', Uint8List(32));

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(ProfileManager.instance.byId(id)!.expiresAt, newExpiry);
      expect(ProfileManager.instance.byId(id)!.name, '老爸', reason: '刷新授权不该动名字');
    });

    // 复审新问题 4:超时原来套在调用方(`main.dart` 启动序列)外面,而那个 Future
    // 是 `unawaited` 的 —— 纯装饰,只留下一个没人取消的 pending Timer。现在它在
    // `getJson` 这一句上,是真的。
    test('新问题 4:拉云档案清单卡住 → 到了预算就放手,不挡住解锁(也不留 pending timer)', () async {
      // 真等 10 秒就是真慢 10 秒(这是一个真实 Timer,不在 fake-async 里)——
      // 把预算改小,验的是"超时确实接在那一句上",不是那个具体秒数。
      final realBudget = profilesFetchBudget;
      profilesFetchBudget = const Duration(milliseconds: 200);
      addTearDown(() => profilesFetchBudget = realBudget);
      final api = _HangingProfilesApi();
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();

      await flow.loginOtp('13800000001', '000000');
      final sw = Stopwatch()..start();
      await flow.unlockWithPassword('right');
      sw.stop();

      expect(flow.lastOutcome, LoginOutcome.ready, reason: '拿不到清单只是"这次没补齐"');
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: '到了预算就放手 —— 不是 Net 那最坏 50 秒',
      );
      expect(pendingFirstSync, isEmpty);
      api.release();
    });

    test('A5:登记首同步不影响解锁本身成功', () async {
      final api = oneUnknownCloudProfile();
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async => false,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(flow.lastOutcome, LoginOutcome.ready);
    });

    test('A5:领回了云成员 + 默认「我」从没被用过 → 删掉那个空成员', () async {
      final api = oneUnknownCloudProfile();
      final removed = <String>[];
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async {
          removed.add(id);
          return true;
        },
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final defaultId = ProfileManager.instance.currentId.value;
      // **必须是"已知的 0"**(评审 Important 1)。这一行原来不在,于是这条用例钉住的
      // 正是那个不安全的分支(「份数未知」被当成「空」)——而
      // `claim_target.dart` 的无姓名分支会往 p-1 写病历却不改名,三条判据里的前两条
      // 照样成立。生产里这个 0 由 `ArchiveScreen` 首帧填上。
      await ProfileManager.instance.setCount(defaultId, 0);

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(removed, [defaultId], reason: '用户从没建过这个空的「我」,新手机上不该多一个它');
    });

    test('A5:份数**还没人数过** → 不删(读不到这个数就不许动手)', () async {
      final api = oneUnknownCloudProfile();
      final removed = <String>[];
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async {
          removed.add(id);
          return true;
        },
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset(); // 清掉 counts,于是"未知"
      final defaultId = ProfileManager.instance.currentId.value;
      expect(ProfileManager.instance.countFor(defaultId), isNull);

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(
        removed,
        isEmpty,
        reason: 'claim_target 的「这份病历里没有姓名,存进你当前的档案」分支会往 p-1 '
            '写病历而不改名 —— 份数未知时删它就是删病历,无确认无撤销',
      );
    });

    test('A5:默认成员被用过(改过名)→ 不删', () async {
      final api = oneUnknownCloudProfile();
      final removed = <String>[];
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async {
          removed.add(id);
          return true;
        },
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final defaultId = ProfileManager.instance.currentId.value;
      await ProfileManager.instance.rename(defaultId, '张建国');

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(removed, isEmpty);
      expect(ProfileManager.instance.byId(defaultId)?.name, '张建国');
    });

    test('A5:默认成员有病历(已知份数 > 0)→ 不删', () async {
      final api = oneUnknownCloudProfile();
      final removed = <String>[];
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async {
          removed.add(id);
          return true;
        },
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final defaultId = ProfileManager.instance.currentId.value;
      await ProfileManager.instance.setCount(defaultId, 3);

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(removed, isEmpty, reason: '有病历的成员绝不能被一条启发式删掉');
    });

    test('A5:什么都没领回来 → 不动默认成员', () async {
      final api = FakeApi(hasKeys: true, profiles: const []);
      final removed = <String>[];
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (id) async {
          removed.add(id);
          return true;
        },
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(removed, isEmpty);
    });

    test('I3:改过名之后再解锁一次——名字留着,不再多出一个重复成员', () async {
      final api = FakeApi(hasKeys: true, profiles: [
        {
          'profile_id': 'prf_unknown_abcdef',
          'role': 'owner',
          'expires_at': null,
          'wrapped_profile_key': base64Encode(Uint8List(32)),
        },
      ]);
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(),
        reopenCurrentProfileVault: () async {},
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');
      final adoptedId = ProfileManager.instance.profiles.firstWhere((p) => p.cloudId == 'prf_unknown_abcdef').id;
      await ProfileManager.instance.rename(adoptedId, '张建国');
      final count = ProfileManager.instance.profiles.length;

      // 第二次解锁(或下一次登录):同一个云档案,本机已经有入口了。
      await flow.unlockWithPassword('right');

      expect(ProfileManager.instance.profiles.length, count, reason: '不许重复领一次');
      expect(ProfileManager.instance.byId(adoptedId)!.name, '张建国', reason: '用户改的名字不能被占位名盖回去');
    });

    test('I3:密钥解不开的那一条整条跳过——不留一个永远打不开的空壳成员', () async {
      final bad = Uint8List.fromList(List.generate(32, (i) => 0xBA));
      final good = Uint8List.fromList(List.generate(32, (i) => 0x60));
      final api = FakeApi(hasKeys: true, profiles: [
        {'profile_id': 'prf_bad_one', 'role': 'viewer', 'expires_at': null, 'wrapped_profile_key': base64Encode(bad)},
        {'profile_id': 'prf_good_one', 'role': 'viewer', 'expires_at': null, 'wrapped_profile_key': base64Encode(good)},
      ]);
      final flow = AccountFlow(
        api,
        AccountSession.instance,
        crypto: FakeCrypto(openSealedFails: (blob) => blob.isNotEmpty && blob.first == 0xBA),
        reopenCurrentProfileVault: () async {},
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();

      await flow.loginOtp('13800000001', '000000');
      await flow.unlockWithPassword('right');

      expect(ProfileManager.instance.profiles.any((p) => p.cloudId == 'prf_bad_one'), isFalse);
      expect(await AccountSession.instance.profileKey('prf_bad_one'), isNull);
      expect(ProfileManager.instance.profiles.any((p) => p.cloudId == 'prf_good_one'), isTrue,
          reason: '一条坏数据不该拖累别的档案');
      expect(flow.lastOutcome, LoginOutcome.ready);
    });
  });

  group('已就绪:云同步开关 + 同步(Task 15 / UX 第二轮)', () {
    late Directory support;

    // 注意:这个组每条用例自己在 body 第一行调 `resetVaultQueueForTest()`,
    // **不放在这个 `setUp()` 里**——`SyncEngine.syncProfile` 现在走
    // `vault_boot` 的模块级 FIFO 队列(见 Task 15 review I2),而 `setUp()`
    // 跑在 `package:test` 的正常 zone,`testWidgets` 的用例体跑在
    // `flutter_test` 自己那套 fake-async zone 里——在 `setUp()` 里创建的
    // "已完成" `Future` 拿去在 fake zone 里 `.then()`,里头再起的
    // `Future.delayed` 不会被 `pumpAndSettle()` 推进,整个用例会挂到超时
    // (真排查过的坑,不是猜的)。
    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-account-cloud-sync-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    Future<void> giveCurrentProfileCloudId(WidgetTester t, {String cloudId = 'prf_1', String role = 'owner'}) async {
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, cloudId, role, null);
      });
      await AccountSession.instance.putProfileKey(cloudId, Uint8List(32));
    }

    testWidgets('还没开通:这个成员的开关是关的,没有「同步」', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      expect(
        t.widget<SwitchListTile>(find.byKey(const Key('cloud_switch_p-1'))).value,
        isFalse,
        reason: '开关的值是"此刻真的在同步吗",还没开通成功就是关的 —— 打开它就是重试',
      );
      expect(find.textContaining('还没备份上去'), findsOneWidget);
      expect(find.text('同步'), findsNothing);
    });

    testWidgets('开通云同步:加载中显示进度圈', (t) async {
      resetVaultQueueForTest();
      // `failCreateProfile: true`——绝不能让这一步在 widget 测试里真的成功:
      // 成功会让 `enableCloud()` 继续走到 `openCurrentProfileVault()`(真实
      // FRB + 重开箱),那条路径需要原生库,`flutter test` 里会挂起/崩溃(同
      // `sync_engine_test.dart` 顶部注释的限制)。这里只钉住"点下去先转圈"这
      // 一态,最终会不会成功由后面那条失败态用例覆盖。
      final api = FakeApi(hasKeys: true, failCreateProfile: true);
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.byKey(const Key('cloud_switch_p-1')));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在开通云同步…'), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('开通云同步失败(注册阶段,POST /v1/profiles 500):错误可见,仍停在"未开通"分支', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true, failCreateProfile: true);
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.byKey(const Key('cloud_switch_p-1')));
      await t.pumpAndSettle();

      expect(find.text('服务器开小差了,稍后再试'), findsOneWidget);
      expect(
        t.widget<SwitchListTile>(find.byKey(const Key('cloud_switch_p-1'))).value,
        isFalse,
        reason: '什么都没开通成功,开关得照实回到关的位置(它就是重试入口)',
      );
    });

    testWidgets('已开通:开关是开的 + 唯一那颗「同步」', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      expect(t.widget<SwitchListTile>(find.byKey(const Key('cloud_switch_p-1'))).value, isTrue);
      expect(find.textContaining('已开通云备份'), findsOneWidget);
      expect(find.text('同步'), findsOneWidget);
    });

    testWidgets('C3:开着 iCloud 同步时点「开通云同步」:原因摆在屏上,仍停在"未开通"分支', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });
      await _toReady(
        t,
        api,
        syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust(icloudOn: true)),
      );

      await t.tap(find.byKey(const Key('cloud_switch_p-1')));
      await t.pumpAndSettle();

      expect(find.textContaining('请先在设置里关闭 iCloud 同步'), findsOneWidget);
      expect(
        t.widget<SwitchListTile>(find.byKey(const Key('cloud_switch_p-1'))).value,
        isFalse,
        reason: '什么都没开通,开关回到关的位置',
      );
      expect(api.calls, isNot(contains('POST /v1/profiles')), reason: '零服务端调用');
    });

    // ---- UX 第二轮:关掉某个成员的云同步 ----

    testWidgets('关掉开关:落盘 cloudPaused、「同步」消失、文案说清云端密文怎么办', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));
      expect(find.text('同步'), findsOneWidget);

      // `setCloudPaused` 要写 profiles.json —— 真实文件 I/O 在 `pumpAndSettle` 的
      // 假时钟里跑不完(本仓库一贯的限制),所以这一跳包进 `runAsync`。
      await t.runAsync(() async {
        await t.tap(find.byKey(const Key('cloud_switch_p-1')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();

      expect(ProfileManager.instance.byId('p-1')!.cloudPaused, isTrue);
      expect(t.widget<SwitchListTile>(find.byKey(const Key('cloud_switch_p-1'))).value, isFalse);
      expect(
        // 精确匹配这一行的状态句:同一句话现在也出现在那节说明和 I8 的告知横幅里
        // (它们共用 `_cloudDefaultCopy`),`textContaining` 会一次找到三个。
        find.text('云同步已关闭 —— 关闭后本机不再上传下载;云端已有的密文会保留到你注销账号'),
        findsOneWidget,
        reason: '用户最怕的是"关掉是不是等于删库" —— 这句必须在那一行上',
      );
      expect(find.text('同步'), findsNothing, reason: '「关闭后本机不再上传下载」');
    });

    testWidgets('关掉了的成员:不在"默认开云"的待办队列里(否则下次触发又开回来)', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));
      pendingCloudEnable.add('p-1');

      await t.runAsync(() async {
        await t.tap(find.byKey(const Key('cloud_switch_p-1')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();

      expect(pendingCloudEnable, isNot(contains('p-1')));
    });

    // N1:屏上那条路也要被挡住 —— I7 之后拨**非当前**成员的开关走的是
    // `registerCloudProfile`,它原来没有 iCloud 那道闸。
    testWidgets('N1:开着 iCloud 时拨非当前成员的开关:报错,cloudId 仍是 null', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      final other = await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        final id = await ProfileManager.instance.create('爸爸');
        await ProfileManager.instance.switchTo('p-1');
        return id;
      });
      await _toReady(
        t,
        api,
        syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust(icloudOn: true)),
      );

      await t.runAsync(() async {
        await t.tap(find.byKey(Key('cloud_switch_$other')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();

      expect(find.textContaining('请先在设置里关闭 iCloud 同步'), findsOneWidget);
      expect(
        ProfileManager.instance.byId(other!)!.cloudId,
        isNull,
        reason: 'keyed 开箱不接 iCloud 容器根 —— 真开下去等于让他在容器里的病历够不着',
      );
      expect(api.calls, isNot(contains('POST /v1/profiles')));
    });

    testWidgets('家里两个成员:两行两个开关,各自独立', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final other = await t.runAsync(() async {
        final id = await ProfileManager.instance.create('爸爸');
        await ProfileManager.instance.switchTo('p-1');
        return id;
      });
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      expect(t.widget<SwitchListTile>(find.byKey(const Key('cloud_switch_p-1'))).value, isTrue);
      expect(
        t.widget<SwitchListTile>(find.byKey(Key('cloud_switch_$other'))).value,
        isFalse,
        reason: '爸爸还没开通成功 —— 开关照实是关的,打开它就是重试',
      );
      expect(find.text('爸爸'), findsOneWidget);
    });

    testWidgets('M4:已开通但箱子没 keyed 打开(同步撞 VaultMismatch):同一颗「同步」再点一次就重开箱', (t) async {
      // 「开通到一半」的现场:注册成功(cloudId 已落盘)、重开箱没成。一次普通
      // 同步在这个状态下是死路(不重开箱 → 每次都撞 VaultMismatch),以前唯一的
      // 出路是重启 App,而屏上没有任何字提示。
      //
      // C9 之后屏上只有一颗「同步」:第一次点是普通同步(撞 VaultMismatch);
      // **因为上一次失败过**,第二次点自动走会重开箱的那条(`enableCloud` 可续做)。
      // 用户不必在两颗都叫"同步"的按钮之间挑一个。
      //
      // 注册那一步不会再跑(enableCloud 对已有 cloudId 的档案跳过它),所以这条
      // 用例里没有真实文件 IO —— 不需要 runAsync 包住点击。
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final rust = _ReopenableFakeSyncRust(
        vaultRoot: '/x/profiles/${ProfileManager.instance.current.id}/vault',
      );
      final syncApi = _SyncApi(delay: const Duration(milliseconds: 1));
      final engine = SyncEngine(
        syncApi,
        AccountSession.instance,
        rust: rust,
        reopenVault: () async => rust.keyedNow = true, // 重开箱成功 = 箱子变成 keyed
      );
      await _toReady(t, api, syncEngine: engine);

      // 第一次点:普通同步,撞 VaultMismatch。
      await t.tap(find.text('同步'));
      await t.pumpAndSettle();
      expect(find.textContaining('不是这个云档案'), findsOneWidget, reason: 'VaultMismatch 的中文原文');
      expect(find.text('同步'), findsOneWidget, reason: '同一颗按钮,不多出第二颗');

      // 第二次点同一颗:上次失败过,于是走 enableCloud → 重开箱(FIFO 队列)+
      // 首同步,不必重启 App。
      await t.tap(find.text('同步'));
      await t.pumpAndSettle();

      expect(rust.keyedNow, isTrue, reason: '重开箱走了(FIFO 队列),箱子现在是 keyed 的');
      expect(syncApi.pulls, 1, reason: '重开箱之后首同步真的跑到了拉事件这一步');
      expect(find.textContaining('不是这个云档案'), findsNothing, reason: '成功之后错误清掉');
      expect(find.text('同步'), findsOneWidget);
    });

    // R1:屏上那条路 —— 上次失败过之后,「同步」走的是可续做的 `enableCloud`,而那一支
    // (已经有 cloudId)原来绕过了 iCloud 那道闸:开着 iCloud 时它会真的去 keyed 重开箱
    // (那条路不接 iCloud 容器根),而且 `saveIcloudBlocksCloud(true)` 永远不触发 ——
    // 概览屏那一行继续说错话。
    testWidgets('R1:上次失败过 +「同步」重试,开着 iCloud:拒绝、不重开箱、把原因记下来', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final rust = _FakeSyncRust(
        icloudOn: true,
        keyed: false, // 第一次普通同步撞 VaultMismatch,于是第二次点会走 enableCloud
        vaultRoot: '/x/profiles/${ProfileManager.instance.current.id}/vault',
      );
      final syncApi = _SyncApi(delay: const Duration(milliseconds: 1));
      final engine = SyncEngine(
        syncApi,
        AccountSession.instance,
        rust: rust,
        reopenVault: () async => fail('开着 iCloud 就不该重开箱'),
      );
      await _toReady(t, api, syncEngine: engine);

      await t.tap(find.text('同步'));
      await t.pumpAndSettle();
      expect(find.textContaining('不是这个云档案'), findsOneWidget);

      // 第二次点同一颗:走 enableCloud 那条可续做的支路。
      await t.runAsync(() async {
        await t.tap(find.text('同步'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await t.pumpAndSettle();

      expect(find.textContaining('请先在设置里关闭 iCloud 同步'), findsOneWidget);
      expect(syncApi.pulls, 0, reason: '一趟同步都不该起步');
      expect(
        await t.runAsync(loadIcloudBlocksCloud),
        isTrue,
        reason: '概览屏那一行要据此说真正的原因,而不是一条点不动的「点这里重试」',
      );
    });

    testWidgets('同步:加载中显示进度圈', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi();
      await _toReady(t, api, syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.text('同步'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('同步成功:展示上一次结果摘要', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi(delay: const Duration(milliseconds: 1));
      await _toReady(t, api, syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.text('同步'));
      await t.pumpAndSettle();

      expect(find.textContaining('上次同步'), findsOneWidget);
      expect(find.textContaining('推送 0 条'), findsOneWidget);
      expect(find.textContaining('拉取 0 条'), findsOneWidget);
    });

    testWidgets('同步失败(服务器 500):错误可见,不崩', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi(failPull: true, delay: const Duration(milliseconds: 1));
      await _toReady(t, api, syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.text('同步'));
      await t.pumpAndSettle();

      expect(find.text('服务器开小差了,稍后再试'), findsOneWidget);
    });

    testWidgets('同步失败:VaultMismatch 的中文消息原样展示(vault 身份核对不通过)', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi(delay: const Duration(milliseconds: 1));
      await _toReady(
        t,
        api,
        syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust(keyed: false)),
      );

      await t.tap(find.text('同步'));
      await t.pumpAndSettle();

      expect(find.textContaining('拒绝同步'), findsOneWidget);
    });
  });

  group('已就绪:退出登录(Task 15)', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-account-logout-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      // 前面几组测试可能留下带 cloudId 的档案(`ProfileManager` 是单例,跨测试不
      // 自动重置)——退回一个干净的默认档案,不然这里的"已就绪"screen 会多出
      // "云同步"分支的内容,把这一屏拉得比这组测试原本假定的更长。
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
    });

    tearDown(() async => support.delete(recursive: true));

    testWidgets('确认退出登录后回到登录入口,私钥/token 已清空', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);
      expect(find.text('已登录'), findsOneWidget);

      // 「退出登录」在这个新加的"账号管理"分组里,默认视口(800x600)之外——
      // 先滚到看得见,tap() 打在视口外的位置是个 no-op(不会报错,但也不会真的
      // 触发 onTap,弹窗永远不出现)。
      await _scrollToText(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      expect(find.text('退出登录?'), findsOneWidget); // 确认弹窗
      await t.tap(find.text('退出登录').last);
      await t.pumpAndSettle();

      expect(find.text('登录 MedMe 账号'), findsOneWidget);
      expect(AccountSession.instance.loggedIn.value, isFalse);
      expect(AccountSession.instance.privateKey, isNull);
      expect(AccountSession.instance.accountId, isNull);
    });

    testWidgets('取消退出登录:仍停在已就绪', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);
      await _scrollToText(t, '退出登录');
      await t.tap(find.text('退出登录'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      // 不用 `find.text('已登录')`——那行标题此刻已经滚出视口,`SliverList`
      // 懒实现,视口附近之外的元素本来就找不到(flutter_test 的既有行为,不
      // 代表真的从树上消失)。「退出登录」这一行本身还在(取消不该把它也弄没
      // 了)+ session 没被清,才是这个用例真正要钉住的事。
      expect(find.text('退出登录'), findsOneWidget);
      expect(AccountSession.instance.loggedIn.value, isTrue);
    });
  });

  group('已就绪:注销账号(Task 15)', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-account-delete-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
    });

    tearDown(() async => support.delete(recursive: true));

    testWidgets('注销确认弹窗取消:不进入重新鉴权表单', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);

      // 见「退出登录」测试同一条注释:这一行在新加的"账号管理"分组里,默认
      // 视口之外,tap() 之前必须先滚到看得见。
      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      expect(find.text('注销账号?'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('delete_phone')), findsNothing);
    });

    // fix round 1 (Task 15 review): C1(3) —— 文案必须说清楚"永远打不开",
    // 不能含糊成"锁定";并且要在确认之前给一条「先导出」的路,不是走完才想起来。
    testWidgets('确认弹窗文案说清楚"永远打不开"(不是锁定),并提供「先导出」入口', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);

      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();

      expect(find.textContaining('永远打不开'), findsOneWidget);
      expect(find.textContaining('没有任何办法找回'), findsOneWidget);
      expect(find.text('先导出'), findsOneWidget);

      await t.tap(find.text('先导出'));
      await t.pumpAndSettle();
      expect(find.text('导出 · 分享'), findsOneWidget); // ExportScreen 的 AppBar 标题

      // 导出完回来,确认弹窗还在,可以接着点「继续注销」——不是走了一趟导出
      // 就把整个确认流程弄丢。
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('继续注销'), findsOneWidget);
    });

    testWidgets('手机账号:确认后展开重新鉴权表单(手机号 + 验证码)', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);

      // 见「退出登录」测试同一条注释:这一行在新加的"账号管理"分组里,默认
      // 视口之外,tap() 之前必须先滚到看得见。
      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('delete_phone')), findsOneWidget);
      expect(find.byKey(const Key('delete_otp_code')), findsOneWidget);
      expect(find.text('确认注销'), findsOneWidget);
    });

    testWidgets('确认注销:加载中显示进度圈', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 20));
      await _toReady(t, api);
      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('delete_phone')), '13800000001');
      await t.enterText(find.byKey(const Key('delete_otp_code')), '000000');
      await _scrollToText(t, '确认注销');
      await t.tap(find.text('确认注销'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('确认注销成功:发对了 phone/otp_code,session 清空,回到登录入口', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await _toReady(t, api);
      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('delete_phone')), '13800000001');
      await t.enterText(find.byKey(const Key('delete_otp_code')), '000000');
      await _scrollToText(t, '确认注销');
      await t.tap(find.text('确认注销'));
      await t.pumpAndSettle();

      expect(api.deleteBodies.single, {'phone': '13800000001', 'otp_code': '000000'});
      expect(
        api.calls,
        contains('POST ${AccountFlow.deletePath}'),
        reason: 'I5:走 POST,不走带 body 的 DELETE(网关会把 body 丢掉 → 永远 401)',
      );
      expect(api.calls, isNot(contains('DELETE /v1/account')));
      expect(find.text('登录 MedMe 账号'), findsOneWidget);
      expect(AccountSession.instance.loggedIn.value, isFalse);
      expect(AccountSession.instance.accountId, isNull);
    });

    testWidgets('确认注销失败(重新鉴权不通过,401):错误可见,session 原样还在', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5), failDeleteAccount: true);
      await _toReady(t, api);
      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('delete_phone')), '13800000001');
      await t.enterText(find.byKey(const Key('delete_otp_code')), '999999');
      await _scrollToText(t, '确认注销');
      await t.tap(find.text('确认注销'));
      await t.pumpAndSettle();

      expect(find.text('登录状态已过期,请重新登录'), findsOneWidget);
      expect(find.byKey(const Key('delete_phone')), findsOneWidget); // 表单还在,可以重试
      expect(AccountSession.instance.loggedIn.value, isTrue, reason: '注销失败不该清掉本机 session');
    });

    testWidgets('取消重新鉴权表单:回到"注销账号"按钮', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);
      await _scrollToText(t, '注销账号');
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.ensureVisible(find.text('取消').last);
      await t.pumpAndSettle();
      await t.tap(find.text('取消').last);
      await t.pumpAndSettle();

      expect(find.byKey(const Key('delete_phone')), findsNothing);
      // 不用 `find.text('注销账号')`——按钮此刻多半已经滚出视口(`SliverList`
      // 懒实现,见上面「取消退出登录」用例的同一条注释)。真正要钉住的是
      // "表单已经收起、回到了未展开状态",delete_phone 消失就是这件事的证据。
    });
  });

  // ---- UX 第二轮:旧设备扫码批准新设备(spec A2 的「旧设备批准」)----
  //
  // 在这之前 `POST /v1/devices/request` 与 `GET /v1/devices/approval` 两个端点零
  // Dart 调用方:服务端、Rust 的封/拆、设备列表里那颗「批准」按钮全都在,而没有任何
  // 路径会把 `eph_public` 写上去 —— 那颗按钮是一段永不触发的 UI,而新设备上唯一的
  // 出路是口令或恢复码(正是最容易两样都想不起来的时刻)。

  group('新设备:出码等旧手机批准', () {
    late Directory support;

    /// 轮询的截止时间按真实时钟算(M10:用 tick 计数会在"一轮比 3 秒慢"时跑快),
    /// 而 `pump(Duration)` 不推进 `DateTime.now()` —— 所以这里换成一个手动拨的时钟。
    late DateTime fakeNow;

    setUp(() async {
      fakeNow = DateTime(2026, 9, 12, 10);
      approvalNow = () => fakeNow;
      addTearDown(() => approvalNow = DateTime.now);
      support = await Directory.systemTemp.createTemp('medme-device-approval-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    /// 落到解锁屏(服务端有密钥、本机没有私钥)。
    Future<void> toUnlock(WidgetTester t, FakeApi api) async {
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);
    }

    testWidgets('解锁屏顶部有这一块,口令/恢复码兜底一个都没拿掉', (t) async {
      await toUnlock(t, FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5)));

      expect(find.text('用旧手机扫码批准'), findsOneWidget);
      expect(find.byKey(const Key('device_approval_start')), findsOneWidget);
      // 兜底还在。
      expect(find.text('解锁'), findsOneWidget);
      expect(find.text('口令忘了?改用恢复码解锁'), findsOneWidget);
      expect(find.byKey(const Key('lost_everything')), findsOneWidget);
    });

    testWidgets('加载中:点「生成二维码」先转圈', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 30));
      await toUnlock(t, api);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pump(const Duration(milliseconds: 200));
    });

    testWidgets('成功出码:登记 eph_public(带 X-Device-Id),屏上是码 + 倒计时 + "码里没有秘密"', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await toUnlock(t, api);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));

      expect(api.calls, contains('POST /v1/devices/request'));
      expect(api.deviceRequestBodies.single['eph_public'], isNotNull);
      expect(
        api.sentHeaders['/v1/devices/request']!['X-Device-Id'],
        isNotNull,
        reason: '服务端靠这个头认"谁在请求批准"',
      );
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining('等旧手机扫码批准'), findsOneWidget);
      expect(find.textContaining('这张码里没有你的病历也没有密钥'), findsOneWidget);

      await t.tap(find.byKey(const Key('device_approval_cancel')));
      await t.pumpAndSettle();
    });

    testWidgets('旧手机批准了:轮询拿到 → 不用口令直接进"已登录"', (t) async {
      // 头一次轮询回 null(旧手机还没扫),第二次才给 —— 钉住"它真的在轮询",
      // 不是靠第一次侥幸命中。
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        approvalSealed: _sealedApproval,
        approvalPending: 1,
      );
      await toUnlock(t, api);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));

      for (var i = 0; i < 2; i++) {
        await t.pump(const Duration(seconds: 3));
        await t.pump(const Duration(milliseconds: 200));
      }

      expect(api.approvalPolls, 2);
      expect(find.text('已登录'), findsOneWidget);
      expect(AccountSession.instance.privateKey, isNotNull, reason: '账号私钥是从那份批准里拆出来的');
      await t.pumpAndSettle();
    });

    testWidgets('失败:生成二维码撞 500 → 中文错误,按钮还在可以再试', (t) async {
      final api = _FailingRequestApi();
      await toUnlock(t, api);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('服务器开小差了,稍后再试'), findsOneWidget);
      expect(find.byKey(const Key('device_approval_start')), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
    });

    testWidgets('两分钟没人批准:停轮询、收起码、指回口令那条路', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await toUnlock(t, api);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byType(QrImageView), findsOneWidget);

      // 截止时间按真实时钟算(M10),而 `pump(Duration)` 只推进 Flutter 的假时钟 ——
      // 所以测试自己把那个可注入的时钟往前拨。
      fakeNow = fakeNow.add(const Duration(seconds: 130));
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('等了两分钟还没等到批准'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing, reason: '别让他对着一张已经作废的码继续等');
      // 轮询真的停了:再等一轮,请求数不涨。
      final polls = api.approvalPolls;
      await t.pump(const Duration(seconds: 6));
      expect(api.approvalPolls, polls);
      await t.pumpAndSettle();
    });

    // M10:一轮轮询比 3 秒慢的时候(慢网、服务端卡顿),按 tick 计数的老写法会
    // ① 在上一轮还没回来时就发下一个请求(重叠),② 把倒计时减快 —— 屏上写着
    // "还剩 30 秒"而真实只过了 15 秒。
    testWidgets('M10:上一轮还没回来时不发第二个请求,倒计时按真实时间走', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        approvalDelay: const Duration(seconds: 9), // 一轮 9 秒,比 3 秒的节拍慢得多
      );
      await toUnlock(t, api);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));

      // 三个节拍过去(9 秒),而第一轮还在路上。
      for (var i = 0; i < 3; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 3));
        await t.pump(const Duration(seconds: 3));
      }
      expect(api.approvalPolls, 1, reason: '上一轮没回来就不发下一个');
      expect(find.textContaining('还剩 111 秒'), findsOneWidget, reason: '120 - 9,按真实时间走');

      await t.tap(find.byKey(const Key('device_approval_cancel')));
      // 那一轮 9 秒的请求还挂在路上 —— 等它落地,否则用例结束时留一个 pending timer。
      await t.pump(const Duration(seconds: 10));
      await t.pumpAndSettle();
    });

    testWidgets('拿到的批准拆不开:说清要重新生成一张,码清掉', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        approvalSealed: _sealedApproval,
      );
      // `openSealed` 对这份 blob 抛异常 —— 模拟"用户中途重新生成过一张码",
      // 旧手机封的是上一把临时公钥。
      await t.pumpWidget(_app(api, crypto: FakeCrypto(openSealedFails: (_) => true)));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('请重新生成二维码'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('已登录'), findsNothing, reason: '拆不开就不该进去');
      await t.pumpAndSettle();
    });
  });

  group('C1:新设备收到的私钥必须和服务端给的公钥是一对', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-approval-c1-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    /// 恶意服务器:自造一对密钥,把**自己的**私钥封给新设备的临时公钥,同时在
    /// `GET /v1/account/keys` 里给出自己那把公钥。新设备若照单全收,之后"默认开云"
    /// 会把每个档案密钥封给服务器的公钥 —— 端到端加密整体失效,而用户什么都看不见。
    testWidgets('服务端给的 public_key 与拆出来的私钥不匹配:拒绝、不保存、不进 ready', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        approvalSealed: _sealedApproval,
        serverPublicKey: Uint8List.fromList(List.filled(32, 7)), // ← 和私钥配不上
      );
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);
      expect(find.text('输入口令解锁'), findsOneWidget);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('对不上你账号的密钥'), findsOneWidget);
      expect(find.text('已登录'), findsNothing, reason: '配不上就不许进去');
      expect(AccountSession.instance.privateKey, isNull, reason: '一个字节都不许落盘');
      expect(AccountSession.instance.publicKey, isNull);
      await t.pumpAndSettle();
    });

    testWidgets('配得上:照常进去(探针不是一道挡住正常路径的闸)', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        approvalSealed: _sealedApproval,
      );
      await t.pumpWidget(_app(api));
      await _loginUpTo(t);

      await t.tap(find.byKey(const Key('device_approval_start')));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(seconds: 3));
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('已登录'), findsOneWidget);
      expect(AccountSession.instance.privateKey, isNotNull);
      await t.pumpAndSettle();
    });
  });

  group('旧设备:扫码批准新设备', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-scan-approve-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    /// 新设备那张码(device_id 固定,公钥 32 字节全 0)。
    String code(String deviceId) =>
        'mdv1.$deviceId.${base64UrlEncode(Uint8List(32)).replaceAll('=', '')}';

    /// 服务器 `devices` 表里那一行记着的同一把公钥(I3:两边必须逐字节一致)。
    final ephOnServer = base64Encode(Uint8List(32));

    testWidgets('入口在「设备」那一节最上面', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await _toReady(t, api);
      await _scrollToText(t, '扫码批准新设备');

      expect(find.byKey(const Key('scan_approve_device')), findsOneWidget);
    });

    testWidgets('扫到别的码(地铁广告、付款码):说清这不是批准码,零服务端调用', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await _toReady(t, api, scanQr: (_) async => 'https://example.com/whatever');
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();

      expect(find.textContaining('这不是 MedMe 的批准码'), findsOneWidget);
      expect(api.deviceApproveBodies, isEmpty);
    });

    testWidgets('扫到的设备不在这个账号下:不批,照实说该怎么办', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5), devices: const []);
      await _toReady(t, api, scanQr: (_) async => code('dev_unknown'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();

      expect(find.textContaining('这台设备不在你的账号下'), findsOneWidget);
      expect(api.deviceApproveBodies, isEmpty);
    });

    // M14:`device_approve` 把 `eph_public` 置回 NULL(取走即删那一套),所以**已经
    // 批准过**的设备再被扫一次,I3 那道核对会说「和服务器记录不一致」—— 而真相是
    // "你已经批准过了,等那台手机自己来取"。同一个字段的两种含义,得分开说。
    testWidgets('M14:已经批准过的设备再扫一次:说"已经批准过了",不说"不一致"', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        devices: [
          // 批准之后的样子:eph_public 被置回 null,approved_priv 还等着被取走。
          {'device_id': 'dev_new', 'name': 'ios', 'eph_public': null, 'approved': true},
        ],
      );
      await _toReady(t, api, scanQr: (_) async => code('dev_new'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();

      expect(find.textContaining('已经批准过了'), findsOneWidget);
      expect(find.textContaining('和服务器记录的不一致'), findsNothing);
      expect(api.deviceApproveBodies, isEmpty);
    });

    testWidgets('M14:早就可用的设备再扫一次:说"不需要再批准"', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        devices: [
          // 批准已经被取走:两列都是 null —— 这台设备此刻就是"已可用"。
          {'device_id': 'dev_new', 'name': 'ios', 'eph_public': null, 'approved': false},
        ],
      );
      await _toReady(t, api, scanQr: (_) async => code('dev_new'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();

      expect(find.textContaining('已经可以用了'), findsOneWidget);
      expect(api.deviceApproveBodies, isEmpty);
    });

    testWidgets('确认弹窗写明是哪台设备;取消 → 零 approve 请求', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        devices: [
          {'device_id': 'dev_new', 'name': 'android', 'eph_public': ephOnServer, 'approved': false},
        ],
      );
      await _toReady(t, api, scanQr: (_) async => code('dev_new'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();

      expect(find.text('批准这台新设备?'), findsOneWidget);
      expect(
        find.textContaining('安卓手机 · 新设备,等你批准'),
        findsOneWidget,
        reason: '弹窗要写清是哪台设备、什么时候出现的;给用户看「android」毫无意义',
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(api.deviceApproveBodies, isEmpty);
    });

    // I3:码里那把公钥必须和服务器 `devices` 表里那一行**逐字节一致**。否则有两条
    // 互相独立的坏路:① 有人给用户一张自造的码(公钥是攻击者的),服务器上那台设备
    // 记的是另一把 —— 批准密文就封给了攻击者;② 用户扫到的是一张过期的码(新手机
    // 中途重新生成过),封出去的东西那台手机拆不开,而他只会看到"批准了但还是进不去"。
    testWidgets('I3:码里的公钥和服务器记录不一致:拒绝,零 approve 请求', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        devices: [
          // 服务器记的是另一把公钥(全 9),而扫到的码里是全 0。
          {
            'device_id': 'dev_new',
            'name': 'ios',
            'eph_public': base64Encode(Uint8List.fromList(List.filled(32, 9))),
            'approved': false,
          },
        ],
      );
      await _toReady(t, api, scanQr: (_) async => code('dev_new'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();

      expect(find.textContaining('这个码和服务器记录的不一致'), findsOneWidget);
      expect(find.text('批准这台新设备?'), findsNothing, reason: '连确认弹窗都不该弹');
      expect(api.deviceApproveBodies, isEmpty);
    });

    testWidgets('确认批准:封给那把临时公钥,带上 X-Device-Id', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        devices: [
          {'device_id': 'dev_new', 'name': 'ios', 'eph_public': ephOnServer, 'approved': false},
        ],
      );
      await _toReady(t, api, scanQr: (_) async => code('dev_new'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm_approve_device')));
      await t.pumpAndSettle();

      expect(api.deviceApproveBodies.single['device_id'], 'dev_new');
      expect(api.deviceApproveBodies.single['approved_priv'], isNotNull);
      expect(api.sentHeaders['/v1/devices/approve']!['X-Device-Id'], isNotNull);
      expect(find.textContaining('已批准'), findsOneWidget);
    });

    testWidgets('批准失败(服务端 500):中文错误可见,不崩', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        failApprove: true,
        devices: [
          {'device_id': 'dev_new', 'name': 'ios', 'eph_public': ephOnServer, 'approved': false},
        ],
      );
      await _toReady(t, api, scanQr: (_) async => code('dev_new'));
      await _scrollToText(t, '扫码批准新设备');

      await t.tap(find.byKey(const Key('scan_approve_device')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm_approve_device')));
      await t.pumpAndSettle();

      expect(find.textContaining('批准失败'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('AccountFlow.requestDeviceApproval:码的内容', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-approval-code-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    test('`mdv1.<device_id>.<临时公钥>`:解得回来,而且公钥与登记上去的那把是同一把', () async {
      final api = FakeApi(delay: Duration.zero);
      final flow = AccountFlow(api, AccountSession.instance, crypto: FakeCrypto(delay: Duration.zero));

      final req = await flow.requestDeviceApproval();

      final parsed = parseDeviceApprovalCode(req.code);
      expect(parsed, isNotNull);
      expect(parsed!.ephPublic.length, 32);
      expect(
        base64Encode(parsed.ephPublic),
        api.deviceRequestBodies.single['eph_public'],
        reason: '码里那把公钥必须就是服务端登记的那把,否则旧设备封出来的东西谁也拆不开',
      );
      expect(parsed.deviceId, await deviceId());
      // 码里一个秘密都没有:临时私钥只在返回值里,从不进那串字。
      expect(req.code.contains(base64UrlEncode(req.ephSecret)), isFalse);
    });
  });

  // I8:登录/设完密钥那一刻,屏上必须把"默认开云"这件事说出来 —— 默认上传是一个
  // **代替用户做的决定**,他至少有权在发生的那一刻知道,并且知道怎么关。
  group('I8:默认开云的一次性告知', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-cloud-notice-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    testWidgets('第一次进到「已登录」:三件事都在屏上(默认上传 / 可按成员关 / 关了云端密文留着)', (t) async {
      await _toReady(t, FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5)));

      expect(find.byKey(const Key('cloud_notice')), findsOneWidget);
      final text = t.widget<Text>(find.byKey(const Key('cloud_notice_text'))).data!;
      expect(text, contains('默认都会加密备份到云端'));
      expect(text, contains('把它的开关关掉'));
      expect(text, contains('云端已有的密文会保留到你注销账号'));
    });

    testWidgets('点「知道了」:收起来,而且落盘 —— 下次不再出现', (t) async {
      await _toReady(t, FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5)));

      await t.tap(find.byKey(const Key('cloud_notice_ack')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('cloud_notice')), findsNothing);
      expect(await t.runAsync(loadCloudDefaultNoticeSeen), isTrue);
    });

    // M16:那个标记原来是全局的 —— 同一台手机上换一个账号登录,他**从没**被告知过
    // "你的病历会自动上云",而那正是需要被告知的那一刻。退出登录时清掉它
    // (`AccountSession.clear()` 本来就在清一串账号态的 key,顺路一条)。
    testWidgets('M16:退出登录之后换个账号登录 → 这句话还会说一次', (t) async {
      await _toReady(t, FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5)));
      await t.tap(find.byKey(const Key('cloud_notice_ack')));
      await t.pumpAndSettle();
      expect(await t.runAsync(loadCloudDefaultNoticeSeen), isTrue);

      await t.runAsync(() => AccountSession.instance.clear());

      expect(
        await t.runAsync(loadCloudDefaultNoticeSeen),
        isFalse,
        reason: '下一个用这台手机登录的人也有权在那一刻知道这件事',
      );
    });

    testWidgets('已经看过:不再出现', (t) async {
      SharedPreferences.setMockInitialValues({'cloud_default_notice_seen': true});
      await _toReady(t, FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5)));

      expect(find.byKey(const Key('cloud_notice')), findsNothing);
    });
  });

  group('cloudRowStatus(纯函数):开关那一行的状态句', () {
    // N3:**不能说「已备份」** —— I7 之后非当前成员只"注册"过(服务端一个空档案 +
    // 本机一把密钥),病历一条都还没上去。「已开通云备份」对两种状态都是真话。
    test('已开通:说「已开通」+ 角色,不说「已备份」', () {
      final s = cloudRowStatus(const Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner'));
      expect(s, '已开通云备份 · 主人');
      expect(s, isNot(contains('已备份到')), reason: '只注册过的成员云上还没有他的病历');
    });

    test('还没开通:说会自动重试,也可以自己打开这个开关', () {
      expect(cloudRowStatus(const Profile(id: 'p-1', name: '我')), contains('还没备份上去'));
    });

    // M9:关掉一个**从来没上过云**的成员时,"云端已有的密文"根本不存在 ——
    // 那句话会让用户以为云上躺着一份他的病历。
    test('M9:关掉的成员从没上过云 → 不许提"云端已有的密文会保留"', () {
      final s = cloudRowStatus(const Profile(id: 'p-1', name: '我', cloudPaused: true));
      expect(s, contains('云同步已关闭'));
      expect(s, isNot(contains('云端已有的密文')));
    });

    test('关掉的成员上过云 → 照实说云端那份密文怎么办', () {
      final s = cloudRowStatus(const Profile(id: 'p-1', name: '我', cloudId: 'prf_1', cloudPaused: true));
      expect(s, contains('云端已有的密文会保留到你注销账号'));
    });

    // I5:开着 iCloud 同步时"打开这个开关立刻再试一次"是句空话。
    test('I5:开着 iCloud 同步 → 说真正的原因,不说"再试一次"', () {
      final s = cloudRowStatus(const Profile(id: 'p-1', name: '我'), icloudOn: true);
      expect(s, contains('iCloud 同步'));
      expect(s, isNot(contains('再试一次')));
    });

    test('F1:已经有 cloudId 也一样说 iCloud —— 这一笔只会在 iCloud 挡住我们时为真', () {
      final s = cloudRowStatus(
        const Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner'),
        icloudOn: true,
      );
      expect(s, contains('iCloud 同步'));
      expect(s, isNot(contains('已开通云备份')));
    });
  });

  group('parseDeviceApprovalCode(纯函数)', () {
    String pub() => base64UrlEncode(Uint8List(32)).replaceAll('=', '');

    test('正常的码:认出 device_id 与 32 字节公钥', () {
      final p = parseDeviceApprovalCode('mdv1.devA.${pub()}');
      expect(p!.deviceId, 'devA');
      expect(p.ephPublic.length, 32);
    });

    test('别的二维码一律返回 null(不是错误,只是不是我要的东西)', () {
      expect(parseDeviceApprovalCode('https://medmenow.com/claim/#g1.x.y'), isNull);
      expect(parseDeviceApprovalCode('mdv0.devA.${pub()}'), isNull, reason: '版本不对');
      expect(parseDeviceApprovalCode('mdv1.devA'), isNull, reason: '少一段');
      expect(parseDeviceApprovalCode('mdv1..${pub()}'), isNull, reason: '空 device_id');
      expect(parseDeviceApprovalCode('mdv1.devA.not-base64!!'), isNull);
      expect(
        parseDeviceApprovalCode('mdv1.devA.${base64UrlEncode(Uint8List(16))}'),
        isNull,
        reason: 'X25519 公钥恒为 32 字节 —— 长度不对就别拿去调服务端',
      );
    });
  });

  group('KDF 真机基准(Task 14a,debug-only)', () {
    Future<void> scrollToBench(WidgetTester t) async {
      final finder = find.text('KDF 基准测试(仅 debug)');
      await t.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
      await t.ensureVisible(finder);
      await t.pumpAndSettle();
    }

    testWidgets('非 debug:这一行不显示', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api, debugModeOverride: false);
      await _scrollToText(t, '注销账号');
      expect(find.text('KDF 基准测试(仅 debug)'), findsNothing);
      expect(find.byKey(const Key('kdf_bench_run')), findsNothing);
    });

    testWidgets('debug:这一行显示;点「运行」用假 bench 函数渲染出表格', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(
        t,
        api,
        debugModeOverride: true,
        kdfBenchFn: ({required int mKib, required int t, required int p}) async => BigInt.from(mKib ~/ 100 + t),
      );
      await scrollToBench(t);
      expect(find.text('KDF 基准测试(仅 debug)'), findsOneWidget);

      await t.tap(find.byKey(const Key('kdf_bench_run')));
      await t.pumpAndSettle();

      // 4 档 m_kib × 2 档 t = 8 格结果,外加表头一行。
      expect(find.byKey(const Key('kdf_bench_table')), findsOneWidget);
      final table = t.widget<Table>(find.byKey(const Key('kdf_bench_table')));
      expect(table.children.length, 1 + 4 * 2);
      expect(find.text('16384'), findsNWidgets(2)); // t=2、t=3 两行
      expect(find.text('131072'), findsNWidgets(2));

      await scrollToBench(t);
      expect(find.byKey(const Key('kdf_bench_copy')), findsOneWidget);
    });

    testWidgets('某一格 bench 报错:那一格显示 ERROR,其它格照常继续', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(
        t,
        api,
        debugModeOverride: true,
        kdfBenchFn: ({required int mKib, required int t, required int p}) async {
          if (mKib == 16384) throw Exception('below argon2 floor');
          return BigInt.from(mKib ~/ 100 + t);
        },
      );
      await scrollToBench(t);
      await t.tap(find.byKey(const Key('kdf_bench_run')));
      await t.pumpAndSettle();

      final table = t.widget<Table>(find.byKey(const Key('kdf_bench_table')));
      expect(table.children.length, 1 + 4 * 2, reason: '报错的两格(t=2/3)照样有行,不是被跳过');
      expect(find.textContaining('ERROR'), findsNWidgets(2));
      expect(find.text('32768'), findsNWidgets(2)); // 其它 m_kib 正常跑完(t=2、t=3)
    });
  });
}
