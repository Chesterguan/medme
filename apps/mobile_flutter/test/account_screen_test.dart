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

class FakeApi extends ApiClient {
  FakeApi({this.failLogin = false, this.hasKeys = false}) : super(base: 'http://x');
  final bool failLogin;
  final bool hasKeys;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (path == '/v1/auth/login' && failLogin) throw const ApiFailed(401, 'bad code');
    if (path == '/v1/auth/login') return {'account_id': 'acc_1', 'access': 'a', 'refresh': 'r'};
    return {'ok': true};
  }

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    if (path == '/v1/account/keys') {
      if (!hasKeys) throw const ApiFailed(404, 'no keys');
      return {
        'public_key': 'AA==',
        'wrapped_priv_pw': 'AA==',
        'wrapped_priv_rc': 'AA==',
        'kdf_salt': 'AA==',
        'kdf_params': {'m_kib': 8, 't': 1, 'p': 1},
      };
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> putJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('PUT $path');
    return {'ok': true};
  }
}

class FakeCrypto implements SyncCrypto {
  @override
  Future<(Uint8List, Uint8List)> accountKeysNew() async => (Uint8List(32), Uint8List(32));
  @override
  Future<Uint8List> wrapPrivate(Uint8List s, String pw, Uint8List salt, int m, int t, int p) async => Uint8List(40);
  @override
  Future<Uint8List> unwrapPrivatePw(Uint8List b, String pw, Uint8List salt, int m, int t, int p) async {
    if (pw != 'right') throw Exception('crypto');
    return Uint8List(32);
  }

  @override
  Future<String> recoveryCodeNew() async => 'ABCD-EFGH-JKMN-PQRS-TVWX';
  @override
  Future<Uint8List> wrapPrivateRc(Uint8List s, String code) async => Uint8List(40);
  @override
  Future<Uint8List> unwrapPrivateRc(Uint8List b, String code) async => Uint8List(32);
}

Widget _app(FakeApi api) => MaterialApp(home: AccountScreen(flow: AccountFlow(api, AccountSession.instance, crypto: FakeCrypto())));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
  });

  testWidgets('登录:加载中 → 进入设口令 → 展示恢复码并要求确认', (t) async {
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
    expect(api.calls, contains('PUT /v1/account/keys'));
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

  testWidgets('已有密钥、本机无私钥 → 解锁;口令错报错', (t) async {
    final api = FakeApi(hasKeys: true);
    await t.pumpWidget(_app(api));
    await t.enterText(find.byKey(const Key('phone')), '13800000001');
    await t.tap(find.text('发送验证码'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('code')), '000000');
    await t.tap(find.text('登录'));
    await t.pumpAndSettle();
    expect(find.text('输入口令解锁'), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), 'wrong');
    await t.tap(find.text('解锁'));
    await t.pumpAndSettle();
    expect(find.textContaining('口令不对'), findsOneWidget);
  });
}
