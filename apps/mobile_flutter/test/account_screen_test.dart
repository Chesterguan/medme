import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
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
  final Duration delay;
  final calls = <String>[];

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
  Future<void> delete(String path, {Map<String, String>? headers}) async {
    calls.add('DELETE $path');
    await Future<void>.delayed(delay);
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
}

Widget _app(FakeApi api, {SyncCrypto? crypto}) =>
    MaterialApp(home: AccountScreen(flow: AccountFlow(api, AccountSession.instance, crypto: crypto ?? FakeCrypto())));

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
Future<void> _toReady(WidgetTester t, FakeApi api, {SyncCrypto? crypto}) async {
  await t.pumpWidget(_app(api, crypto: crypto));
  await _loginUpTo(t);
  await t.enterText(find.byKey(const Key('password')), 'right');
  await t.tap(find.text('解锁'));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
  });

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
  });
}
