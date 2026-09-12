import 'dart:convert';
import 'dart:io';
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
import 'package:shared_preferences/shared_preferences.dart';

/// 假 API——每个方法都记进 [calls],方便断言"到底调没调、调了几次"；每个失败
/// 分支都是构造时的一个 flag,默认全部成功。所有异步方法都真的 `Future.delayed`
/// 一下(而不是立刻 resolve)——纯微任务链在 `pump()` 单帧内就会跑完,测不出
/// "加载中" 这一态,必须有一个真 Timer 撑住那一帧。
class FakeApi extends ApiClient {
  FakeApi({
    this.failOtp = false,
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
    this.delay = const Duration(milliseconds: 30),
  }) : super(base: 'http://x');

  final bool failOtp;
  final bool failLogin;
  final bool hasKeys;
  final bool failPut;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> profiles;
  final bool failDevices;
  final bool failProfiles;
  final bool failApprove;
  final bool failRevoke;
  /// `GET /v1/account/keys` 报 500(不是 404)——`_afterLogin` 只吞 404,
  /// 非 404 一律 rethrow;用来测 `resumeIfLoggedIn` 冷启动那条路径接不接得住。
  final bool failKeys500;
  /// `GET /v1/accounts/lookup` 的假响应/假失败——测「按手机号添加家属」。
  final Map<String, dynamic>? lookupResult;
  final ApiFailed? lookupError;
  /// `DELETE /v1/account`(注销账号)的假失败,默认成功——测「注销账号」三态。
  final bool failDeleteAccount;
  final ApiFailed? failDeleteAccountError;
  /// `POST /v1/profiles`(开通云同步的注册那一步)的假失败——测「开通云同步」
  /// 失败态,不必也不能真的走到重开箱那一步(`flutter test` 没有原生库)。
  final bool failCreateProfile;
  final Duration delay;
  final calls = <String>[];
  /// 每次 `delete()` 收到的 body,按调用顺序——测「注销账号」发对了 phone/otp_code。
  final deleteBodies = <Object?>[];

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    await Future<void>.delayed(delay);
    if (path == '/v1/auth/otp') {
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
        'public_key': 'AA==',
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
    if (path == '/v1/accounts/lookup') {
      if (lookupError != null) throw lookupError!;
      return lookupResult;
    }
    if (path == '/v1/profiles') {
      if (failProfiles) throw const ApiFailed(500, 'profiles failed');
      return profiles;
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
}

/// 假加密——同样真的 delay 一下(Argon2id 本来就该花时间),口令/恢复码只有
/// 配置的那一个值判"对"，方便同时测成功和失败分支。
class FakeCrypto implements SyncCrypto {
  FakeCrypto({
    this.rightPassword = 'right',
    this.rightRecoveryCode = 'GOODCODE',
    this.failAccountKeysNew = false,
    this.delay = const Duration(milliseconds: 20),
  });

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

  /// 恒等透传——不追求真实密码学正确性(同这个类其它方法的一贯做法),测试只
  /// 关心"服务端返回的 wrapped_profile_key 最终原样存进了 `pk_<cloudId>`"。
  @override
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob) async {
    await _wait();
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
  _FakeSyncRust({this.keyed = true, String? vaultRoot}) : vaultRoot = vaultRoot ?? '/x/profiles/p-1/vault';
  final bool keyed;
  final String vaultRoot;

  @override
  Future<Uint8List> profileKeyNew() async => Uint8List(32);

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

/// 假 API——只覆盖「立即同步」用得到的两个方法(拉事件 + 拉对象清单),专测
/// `_syncNow` 的三态。加一个真延迟(同文件顶部 `FakeApi` 的道理):纯微任务链
/// 在 `pump()` 单帧内就会跑完,测不出"加载中"这一态。
class _SyncApi extends ApiClient {
  _SyncApi({this.failPull = false, this.delay = const Duration(milliseconds: 20)}) : super(base: 'http://x');
  final bool failPull;
  final Duration delay;

  @override
  Future<(dynamic, Map<String, String>)> getJsonWithHeaders(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    await Future<void>.delayed(delay);
    if (failPull) throw const ApiFailed(500, 'pull failed');
    return (const [], {'x-seq-map': '{}'});
  }

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async => const [];

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async => {'ok': true};
}

Widget _app(FakeApi api, {SyncCrypto? crypto, Grants? grants, SyncEngine? syncEngine}) => MaterialApp(
      home: AccountScreen(
        flow: AccountFlow(api, AccountSession.instance, crypto: crypto ?? FakeCrypto()),
        grants: grants,
        syncEngine: syncEngine,
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
Future<void> _toReady(WidgetTester t, FakeApi api, {SyncCrypto? crypto, Grants? grants, SyncEngine? syncEngine}) async {
  await t.pumpWidget(_app(api, crypto: crypto, grants: grants, syncEngine: syncEngine));
  await _loginUpTo(t);
  await t.enterText(find.byKey(const Key('password')), 'right');
  await t.tap(find.text('解锁'));
  await t.pumpAndSettle();
}

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

      await t.enterText(find.byKey(const Key('password')), 'right');
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
      await t.enterText(find.byKey(const Key('password')), 'right');
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
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.tap(find.text('生成密钥'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('生成密钥失败(KDF/加密层报错):错误可见,停留设置口令,未调用 PUT', (t) async {
      final api = FakeApi();
      await t.pumpWidget(_app(api, crypto: FakeCrypto(failAccountKeysNew: true)));
      await _loginUpTo(t);
      await t.enterText(find.byKey(const Key('password')), 'right');
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
      await t.enterText(find.byKey(const Key('password')), 'right');
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
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.tap(find.text('生成密钥'));
      await t.pumpAndSettle();
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget);

      await t.tap(find.text('我已抄下恢复码'));
      await t.pumpAndSettle();
      expect(find.textContaining('put failed'), findsOneWidget);
      expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget); // 恢复码原样还在
      expect(find.text('我已抄下恢复码'), findsOneWidget); // 可以直接重试
      expect(AccountSession.instance.privateKey, isNull);
    });
  });

  group('登录/OTP 三态', () {
    testWidgets('发送验证码失败:显示错误,仍停在这一步,可重试', (t) async {
      final api = FakeApi(failOtp: true);
      await t.pumpWidget(_app(api));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      expect(find.textContaining('rate_limited'), findsOneWidget);
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
      expect(find.textContaining('bad code'), findsOneWidget); // 失败态
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

  group('已就绪:设备列表 + 批准', () {
    testWidgets('加载中 → 成功展示(待批准设备带「批准」按钮)', (t) async {
      final api = FakeApi(hasKeys: true, devices: [
        {'device_id': 'dev2', 'name': 'iPhone 15', 'eph_public': 'AA==', 'approved': false},
      ]);
      await _toReady(t, api);
      expect(find.text('iPhone 15'), findsOneWidget);
      expect(find.text('批准'), findsOneWidget);
    });

    testWidgets('加载失败:显示错误,不崩', (t) async {
      final api = FakeApi(hasKeys: true, failDevices: true);
      await _toReady(t, api);
      expect(find.textContaining('devices failed'), findsOneWidget);
    });

    testWidgets('批准成功:调用 devices/approve,不留错误', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 10),
        devices: [
          {'device_id': 'dev2', 'name': 'iPhone 15', 'eph_public': 'AA==', 'approved': false},
        ],
      );
      await _toReady(t, api);
      await t.tap(find.text('批准'));
      await t.pumpAndSettle();
      expect(api.calls, contains('POST /v1/devices/approve'));
      expect(find.textContaining('批准失败'), findsNothing);
    });

    testWidgets('批准失败:错误可见,设备列表原样还在(没有被清空/崩溃)', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 10),
        failApprove: true,
        devices: [
          {'device_id': 'dev2', 'name': 'iPhone 15', 'eph_public': 'AA==', 'approved': false},
        ],
      );
      await _toReady(t, api);
      await t.tap(find.text('批准'));
      await t.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('批准失败'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('iPhone 15'), findsOneWidget);
      expect(find.text('批准'), findsOneWidget); // 列表还在,按钮还在,可以重试
    });
  });

  group('已就绪:授权列表 + 撤销', () {
    testWidgets('加载中 → 成功展示(owner 行带「撤销」按钮)', (t) async {
      final api = FakeApi(hasKeys: true, profiles: [
        {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
      ]);
      await _toReady(t, api);
      expect(find.textContaining('p1'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
    });

    testWidgets('加载失败:显示错误,不崩', (t) async {
      final api = FakeApi(hasKeys: true, failProfiles: true);
      await _toReady(t, api);
      expect(find.textContaining('profiles failed'), findsOneWidget);
    });

    testWidgets('撤销成功:调用 DELETE,不留错误', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 10),
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
      );
      await _toReady(t, api);
      await t.tap(find.text('撤销'));
      await t.pumpAndSettle();
      expect(api.calls, contains('DELETE /v1/profiles/p1/grants/g1'));
      expect(find.textContaining('撤销失败'), findsNothing);
    });

    testWidgets('撤销失败:错误可见,授权列表原样还在', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 10),
        failRevoke: true,
        profiles: [
          {'profile_id': 'p1', 'role': 'owner', 'grant_id': 'g1', 'expires_at': null},
        ],
      );
      await _toReady(t, api);
      await t.tap(find.text('撤销'));
      await t.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('撤销失败'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.textContaining('p1'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
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

      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
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

      await t.enterText(find.byKey(const Key('family_phone')), '138 0000 1111');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(api.calls, contains('GET /v1/accounts/lookup'));
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

      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(find.text('没有找到使用该手机号的账号'), findsOneWidget);
    });

    testWidgets('限流(429):提示「查询太频繁,稍后再试」', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupError: const ApiFailed(429, 'rate_limited'),
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await t.enterText(find.byKey(const Key('family_phone')), '13800001111');
      await t.tap(find.text('按手机号添加家属'));
      await t.pumpAndSettle();

      expect(find.text('查询太频繁,稍后再试'), findsOneWidget);
    });

    testWidgets('手机号格式不对(400):提示「手机号格式不对」', (t) async {
      final api = FakeApi(
        hasKeys: true,
        delay: const Duration(milliseconds: 5),
        lookupError: const ApiFailed(400, 'bad phone'),
      );
      await setUpCloudProfile(t);
      await _toReady(t, api, grants: Grants(api, AccountSession.instance, rust: FakeGrantsRust()));

      await t.enterText(find.byKey(const Key('family_phone')), 'abc'); // 打个不像手机号的
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
      expect(find.textContaining('keys server error'), findsOneWidget);
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
  });

  group('已就绪:开通云同步 + 立即同步(Task 15)', () {
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

    testWidgets('还没开通:显示「开通云同步」按钮,没有「立即同步」', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      expect(find.text('开通云同步'), findsOneWidget);
      expect(find.text('立即同步'), findsNothing);
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

      await t.tap(find.text('开通云同步'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
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

      await t.tap(find.text('开通云同步'));
      await t.pumpAndSettle();

      expect(find.textContaining('create profile failed'), findsOneWidget);
      expect(find.text('开通云同步'), findsOneWidget, reason: '没进入"已开通"分支,按钮还在,可以重试');
    });

    testWidgets('已开通:展示"已开通"分支 + 「立即同步」入口,没有「开通云同步」按钮', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      await _toReady(t, api, syncEngine: SyncEngine(api, AccountSession.instance, rust: _FakeSyncRust()));

      expect(find.textContaining('已开通云同步'), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      expect(find.text('开通云同步'), findsNothing);
    });

    testWidgets('立即同步:加载中显示进度圈', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi();
      await _toReady(t, api, syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.text('立即同步'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('立即同步成功:展示上一次结果摘要', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi(delay: const Duration(milliseconds: 1));
      await _toReady(t, api, syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.text('立即同步'));
      await t.pumpAndSettle();

      expect(find.textContaining('上次同步'), findsOneWidget);
      expect(find.textContaining('推送 0 条'), findsOneWidget);
      expect(find.textContaining('拉取 0 条'), findsOneWidget);
    });

    testWidgets('立即同步失败(服务器 500):错误可见,不崩', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi(failPull: true, delay: const Duration(milliseconds: 1));
      await _toReady(t, api, syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust()));

      await t.tap(find.text('立即同步'));
      await t.pumpAndSettle();

      expect(find.textContaining('pull failed'), findsOneWidget);
    });

    testWidgets('立即同步失败:VaultMismatch 的中文消息原样展示(vault 身份核对不通过)', (t) async {
      resetVaultQueueForTest();
      final api = FakeApi(hasKeys: true);
      await giveCurrentProfileCloudId(t);
      final syncApi = _SyncApi(delay: const Duration(milliseconds: 1));
      await _toReady(
        t,
        api,
        syncEngine: SyncEngine(syncApi, AccountSession.instance, rust: _FakeSyncRust(keyed: false)),
      );

      await t.tap(find.text('立即同步'));
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
      await t.ensureVisible(find.text('退出登录'));
      await t.pumpAndSettle();
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

      await t.ensureVisible(find.text('退出登录'));
      await t.pumpAndSettle();
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
      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
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

      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
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
      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
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
      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('delete_phone')), '13800000001');
      await t.enterText(find.byKey(const Key('delete_otp_code')), '000000');
      await t.ensureVisible(find.text('确认注销'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认注销'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('确认注销成功:发对了 phone/otp_code,session 清空,回到登录入口', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5));
      await _toReady(t, api);
      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('delete_phone')), '13800000001');
      await t.enterText(find.byKey(const Key('delete_otp_code')), '000000');
      await t.ensureVisible(find.text('确认注销'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认注销'));
      await t.pumpAndSettle();

      expect(api.deleteBodies.single, {'phone': '13800000001', 'otp_code': '000000'});
      expect(find.text('登录 MedMe 账号'), findsOneWidget);
      expect(AccountSession.instance.loggedIn.value, isFalse);
      expect(AccountSession.instance.accountId, isNull);
    });

    testWidgets('确认注销失败(重新鉴权不通过,401):错误可见,session 原样还在', (t) async {
      final api = FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5), failDeleteAccount: true);
      await _toReady(t, api);
      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('注销账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('继续注销'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('delete_phone')), '13800000001');
      await t.enterText(find.byKey(const Key('delete_otp_code')), '999999');
      await t.ensureVisible(find.text('确认注销'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认注销'));
      await t.pumpAndSettle();

      expect(find.textContaining('reauth required'), findsOneWidget);
      expect(find.byKey(const Key('delete_phone')), findsOneWidget); // 表单还在,可以重试
      expect(AccountSession.instance.loggedIn.value, isTrue, reason: '注销失败不该清掉本机 session');
    });

    testWidgets('取消重新鉴权表单:回到"注销账号"按钮', (t) async {
      final api = FakeApi(hasKeys: true);
      await _toReady(t, api);
      await t.ensureVisible(find.text('注销账号'));
      await t.pumpAndSettle();
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
}
