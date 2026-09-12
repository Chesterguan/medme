// Task 11 review round 1 · item 1 (CRITICAL):出码是不是走授权链接这条路,
// 必须先判 `role == 'owner'`(发邀请是服务端 owner-only 操作,editor/viewer
// 一律 403),而且**即使是 owner**,邀请创建失败时也不能停在死胡同——必须回退
// 到原来的加密上传路径,不能是个死胡同。
//
// 原路径的密文生成(`qrShareBlob`)是真实 FRB 调用——`flutter test` 没有原生库
// 时它不是抛异常,是真的把整个测试进程卡住退不出去(这里踩过一次,120s 超时都
// 救不回来)。所以 [QrShareScreen] 加了一个 `qrShareBlobFn` 注入点,测试传一个
// 立即失败的假实现,只验证"确实回退过去尝试了原路径",不必也不能真的跑通它。
//
// ⚠️ 真实文件 IO(`Directory.systemTemp.createTemp` 给 path_provider 当假根目录)
// 必须放在 `setUp()`/`tearDown()` 里,不能直接写在 `testWidgets` 回调体内——
// 那个回调体跑在一个"假时钟" zone 里,真实 `dart:io` 的完成回调进不来,会直接
// 卡死且 `--timeout` 都救不回来(同 `member_switcher_locked_test.dart` 顶部那条
// 教训;第一版这里踩过一次)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/qr_share_screen.dart';

class _ThrowingApi extends ApiClient {
  _ThrowingApi() : super(base: 'http://x');
}

class _FailingGrants extends Grants {
  _FailingGrants() : super(_ThrowingApi(), AccountSession.instance);

  @override
  Future<GrantLink> inviteDoctor(Profile p) async {
    throw const ApiFailed(500, 'invite create failed');
  }
}

class _SucceedingGrants extends Grants {
  _SucceedingGrants() : super(_ThrowingApi(), AccountSession.instance);

  @override
  Future<GrantLink> inviteDoctor(Profile p) async =>
      GrantLink(inviteId: 'inv_ok', token: 'tokenABCDEFGHIJKLMNOPQRSTUV');
}

/// editor/viewer 档案根本不该调到这里——调用即测试失败,不是返回错误让代码
/// 自己去 catch(那样测不出"压根没试过"和"试了但失败了"的区别)。
class _NeverInvitedGrants extends Grants {
  _NeverInvitedGrants() : super(_ThrowingApi(), AccountSession.instance);

  @override
  Future<GrantLink> inviteDoctor(Profile p) async {
    fail('不是 owner 的档案不该尝试发邀请——服务端本来就会 403');
  }
}

/// 原路径的假密文生成:立即失败,验证的是"确实退回来尝试了",不是"原路径真的
/// 能跑通"(那需要真实 Rust 库)。
Future<(Uint8List, String, int)> _fakeQrShareBlobFails({required int expiresDays}) async {
  throw Exception('fake: 原路径被调用到了(不含原生库,这里只验证调用发生)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-qr-share-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    AccountSession.instance.resetForTest();
  });

  tearDown(() async => support.delete(recursive: true));

  group('shouldTryGrantLink(纯函数)', () {
    const owner = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    const editor = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'editor');
    const viewer = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'viewer');
    const noCloud = Profile(id: 'p-1', name: '我');

    test('登录 + owner + 已开通云同步 → true', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: owner), isTrue);
    });

    test('editor → false(发邀请是 owner-only,不该摸黑试)', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: editor), isFalse);
    });

    test('viewer → false', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: viewer), isFalse);
    });

    test('未登录 → false,即使是 owner', () {
      expect(shouldTryGrantLink(loggedIn: false, profile: owner), isFalse);
    });

    test('没有 cloudId(未开通云同步) → false', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: noCloud), isFalse);
    });
  });

  /// owner 档案就绪(登录 + 有公钥 + 当前成员 cloudId/role 已设),role 由调用方
  /// 再覆盖。真实文件 IO(`markCloud` 落盘)包进 `runAsync`。
  Future<void> setUpOwnerProfile(WidgetTester t, {String role = 'owner'}) async {
    AccountSession.instance.publicKey = Uint8List(32);
    AccountSession.instance.accountId = 'acc_1';
    AccountSession.instance.access = 'tok';
    AccountSession.instance.loggedIn.value = true;
    await t.runAsync(() async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', role, null);
    });
  }

  testWidgets('editor 档案:直接走原路径,压根不尝试发邀请', (t) async {
    await setUpOwnerProfile(t, role: 'editor');

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _NeverInvitedGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    // 走到了原路径(假实现抛出的通用错误态),而不是 `_NeverInvitedGrants` 里的
    // `fail()`(那会让整个测试直接红,断言写在假实现内部)。
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('owner + 邀请创建失败:不留在授权链接的报错态里,转去尝试原路径', (t) async {
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _FailingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump(); // 触发 initState 里的 _generate
    await t.pump(const Duration(milliseconds: 50));

    // 断言的是"没有卡在授权链接特有的报错态里"——原路径的假实现接下来会在 catch
    // 里落地成"生成失败"这个**通用**错误态,这正是回退发生了的证据:如果没有
    // 回退,失败会停在 `_grantMode == true` 的状态上,不会走到这里。
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('owner + 邀请创建成功:出码,不触碰原路径', (t) async {
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _SucceedingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    // 出码成功(这一步顺带跑过 `Analytics.track(shareQrShown, {})`——空 props
    // 不在目录允许集合之外,断言不炸就是它没违反目录契约)。
    expect(find.text('请医生扫这个码'), findsOneWidget);
    expect(find.text('生成失败'), findsNothing);
  });
}
