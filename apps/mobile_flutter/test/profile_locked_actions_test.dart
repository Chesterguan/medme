// `ProfileLockedActions`(见 `main.dart`)——`ProfileLocked` 开箱失败屏的两个
// 动作:「去登录」「切换成员」。见 Task 15 review C1:退出登录/换设备清过
// secure storage 之后,已开通云同步的成员会变成这个状态,原来这一屏没有任何
// 按钮,用户会被困死在这一屏出不去。
//
// `VaultBootstrap` 本身的 `_open` 会真的调 FFI 开箱,`flutter test` 没法把
// 整个 `VaultBootstrap` 逼进错误状态;这两个按钮"点了该发生什么"跟开箱成不
// 成功无关,拆成独立 widget 单独测(同 `vault_bootstrap_error_text_test.dart`
// 把纯函数拆出来单测的道理)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只覆盖 `AccountScreen` idle 阶段用得到的方法——够把它推到「登录 MedMe 账号」
/// 那一屏就行,这个测试不关心登录流程本身(那是 `account_screen_test.dart` 的事)。
class _NoopApi extends ApiClient {
  _NoopApi() : super(base: 'http://x');
}

Widget _app({required VoidCallback onDone}) => MaterialApp(
      home: Scaffold(
        body: ProfileLockedActions(
          onDone: onDone,
          accountFlow: AccountFlow(_NoopApi(), AccountSession.instance),
          // `showMemberSwitcherSheet` 默认会真的发 HTTP 请求清过期档案——测试
          // 环境不该有真实网络往返,注入假的。
          switchTo: (_) async {},
          purgeExpired: () async => 0,
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
    // `showMemberSwitcherSheet` 会碰 `ProfileManager`(读成员列表)——给它一个
    // 真实临时目录 + 干净的默认成员表,不依赖上一条用例可能留下的状态。
    support = await Directory.systemTemp.createTemp('medme-profile-locked-actions-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
  });

  tearDown(() async => support.delete(recursive: true));

  testWidgets('两个按钮都在:「去登录」「切换成员」', (t) async {
    await t.pumpWidget(_app(onDone: () {}));
    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('切换成员'), findsOneWidget);
  });

  testWidgets('「去登录」导航到账号屏,返回后调用 onDone(VaultBootstrap 借此重试开箱)', (t) async {
    var done = false;
    await t.pumpWidget(_app(onDone: () => done = true));

    await t.tap(find.text('去登录'));
    await t.pumpAndSettle();
    expect(find.text('登录 MedMe 账号'), findsOneWidget); // AccountScreen 的 idle 阶段
    expect(done, isFalse, reason: '还没返回,不该提前调 onDone');

    await t.pageBack();
    await t.pumpAndSettle();
    expect(done, isTrue);
  });

  testWidgets('「切换成员」打开切换器,关闭后调用 onDone', (t) async {
    var done = false;
    await t.pumpWidget(_app(onDone: () => done = true));

    await t.tap(find.text('切换成员'));
    await t.pumpAndSettle();
    expect(find.text('切换成员'), findsWidgets); // 底部弹层标题也叫这个名字
    // 「我」出现两次:头像圆圈里的首字母 + 成员名本身,定位那一整行(只有
    // 一个成员,`ListTile` 唯一)。
    final memberTile = find.byType(ListTile);
    expect(memberTile, findsOneWidget);

    // 只有一个成员,点它(等于当前成员)会把切换器关掉而不触发真正的切换。
    await t.tap(memberTile);
    await t.pumpAndSettle();
    expect(done, isTrue);
  });
}
