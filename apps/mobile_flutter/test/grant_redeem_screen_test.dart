// Task 11 review round 1 · item 3 + item 8:GrantRedeemScreen 的三态 + 未登录
// 绕道 AccountScreen,以及结果页按**实际拿到的角色**说话(不是兑换前的猜测)。
//
// `Grants.redeem` 末尾会碰真实 Rust 原生库(开箱、首同步),`flutter test` 没有
// 原生库——所以这里的假 `Grants` 整体重写 `redeem`,不调用真实实现的任何部分
// (同 `qr_share_screen_test.dart` 的 `_FailingGrants`/`_SucceedingGrants` 套路)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/account_screen.dart';

class _ThrowingApi extends ApiClient {
  _ThrowingApi() : super(base: 'http://x');
}

class _FakeGrants extends Grants {
  _FakeGrants({this.result, this.error, this.delay = Duration.zero, this.onRedeemCalled})
      : super(_ThrowingApi(), AccountSession.instance);
  final Profile? result;
  final Object? error;
  final Duration delay;
  final VoidCallback? onRedeemCalled;

  @override
  Future<Profile> redeem(GrantLink l, {Future<void> Function(Profile)? afterStored}) async {
    onRedeemCalled?.call();
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (error != null) throw error!;
    return result!;
  }
}

final _link = GrantLink(inviteId: 'inv_1', token: 'tokenABCDEFGHIJKLMNOPQRSTUV');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AccountSession.instance.resetForTest();
    AccountSession.instance.loggedIn.value = true; // 默认已登录,未登录场景单独测
  });

  // ---- C5:这一屏原来只有一句问话,用户不知道点下去会发生什么 ----
  testWidgets('C5:确认页说清楚"会看到对方的病历",权限留给下一步(因为此刻真的还不知道)', (t) async {
    await t.pumpWidget(MaterialApp(
      home: GrantRedeemScreen(
        link: _link,
        grants: _FakeGrants(result: const Profile(id: 'p-2', name: '张三', role: 'viewer')),
      ),
    ));

    expect(find.text('要接受对方给你的这份病历吗?'), findsOneWidget);
    expect(find.textContaining('这份病历会出现在你的 MedMe 里'), findsOneWidget);
    expect(find.textContaining('下一步告诉你'), findsOneWidget);
    // 角色由服务端在兑换那一刻才揭晓,这一步**不许**替它猜一个。
    expect(find.textContaining('只读'), findsNothing);
    expect(find.textContaining('主人'), findsNothing);
  });

  testWidgets('加载中显示进度圈', (t) async {
    await t.pumpWidget(MaterialApp(
      home: GrantRedeemScreen(
        link: _link,
        grants: _FakeGrants(
          result: const Profile(id: 'p-2', name: '张三', role: 'viewer'),
          delay: const Duration(milliseconds: 200),
        ),
      ),
    ));
    await t.tap(find.text('加入'));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.pumpAndSettle();
  });

  testWidgets('成功·viewer:显示只读到期日,不是「主人」措辞', (t) async {
    await t.pumpWidget(MaterialApp(
      home: GrantRedeemScreen(
        link: _link,
        grants: _FakeGrants(
          result: Profile(id: 'p-2', name: '张三', role: 'viewer', expiresAt: DateTime(2026, 11, 3)),
        ),
      ),
    ));
    await t.tap(find.text('加入'));
    await t.pumpAndSettle();

    expect(find.text('已加入「张三」的档案'), findsOneWidget);
    expect(find.text('只读,至 11月3日'), findsOneWidget);
    expect(find.textContaining('主人'), findsNothing);
  });

  testWidgets('成功·owner(代拍转移):显示「成为主人」,老账号已降级的说明', (t) async {
    await t.pumpWidget(MaterialApp(
      home: GrantRedeemScreen(
        link: _link,
        grants: _FakeGrants(result: const Profile(id: 'p-2', name: '张三', role: 'owner')),
      ),
    ));
    await t.tap(find.text('加入'));
    await t.pumpAndSettle();

    expect(find.text('你已成为「张三」档案的主人'), findsOneWidget);
    expect(find.textContaining('降为编辑'), findsOneWidget);
    expect(find.textContaining('只读'), findsNothing);
  });

  testWidgets('失败:错误可见,按钮可再点重试', (t) async {
    await t.pumpWidget(MaterialApp(
      home: GrantRedeemScreen(
        link: _link,
        grants: _FakeGrants(error: const ApiFailed(410, 'used or expired')),
      ),
    ));
    await t.tap(find.text('加入'));
    await t.pumpAndSettle();

    // B2:410 说人话,不把状态码念给用户听。
    expect(find.textContaining('邀请码已经过期或被用过'), findsOneWidget);
    expect(find.textContaining('410'), findsNothing);
    expect(find.text('加入'), findsOneWidget); // 按钮还在,可以重试
    expect(find.text('已加入'), findsNothing);
  });

  testWidgets('未登录:先绕道账号屏,不直接尝试兑换', (t) async {
    AccountSession.instance.loggedIn.value = false;
    var redeemCalled = false;
    await t.pumpWidget(MaterialApp(
      home: GrantRedeemScreen(
        link: _link,
        grants: _FakeGrants(
          result: const Profile(id: 'p-2', name: '张三', role: 'viewer'),
          onRedeemCalled: () => redeemCalled = true,
        ),
      ),
    ));
    await t.tap(find.text('加入'));
    await t.pumpAndSettle();

    expect(find.byType(AccountScreen), findsOneWidget);
    expect(redeemCalled, isFalse);
    expect(find.text('已加入「张三」的档案'), findsNothing);
  });
}
