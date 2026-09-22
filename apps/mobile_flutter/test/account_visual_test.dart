// 口令/换机/出码/代拍四屏。三屏各有一处品牌渐变(s12 的主按钮、s15 与 s14 的
// 居中主卡),s13 的渐变在首次那张 sheet 的「好,出码」上。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';
import 'package:mobile_flutter/screens/qr_notice_sheet.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/link_qr_dialog.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_screen_test.dart' show FakeApi, FakeCrypto;
import 'stage3_visual_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `size`/`scale` 非空时包一层 `MediaQuery`(同 `pumpStage3` 的手法),覆盖整个
  // `MaterialApp`(不只 `home:`)——`showDialog` 默认走 root navigator,它的
  // `Overlay` 与 `home:` 内容同一层,只包 `home:` 盖不到后面弹出来的对话框
  // (s13 的「交给别人」弹窗用得到这一点)。
  Widget sizedApp(Widget home, {Size? size, double scale = 1.0}) {
    final app = MaterialApp(home: home);
    if (size == null) return app;
    return MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)), child: app);
  }

  /// 登录 + 口令解锁,一路落到「已就绪」——要求 `api.hasKeys == true`。原来只有
  /// R25 那组在用,Task 16 的 s13 弹窗测试也要落到「已就绪」才碰得到「把这份
  /// 病历交给别人」,提到 `main()` 顶层给两组共用(纯挪动,加两个默认参数)。
  Future<void> toReady(WidgetTester t, FakeApi api, {Size? size, double scale = 1.0}) async {
    if (size != null) {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1.0;
    }
    addTearDown(t.view.reset);
    await t.pumpWidget(sizedApp(
      AccountScreen(flow: AccountFlow(api, AccountSession.instance, crypto: FakeCrypto())),
      size: size, scale: scale,
    ));
    await t.enterText(find.byKey(const Key('phone')), '13800000001');
    await t.tap(find.text('发送验证码'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('code')), '000000');
    await t.tap(find.text('登录'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('password')), 'right');
    await t.pump();
    // 减法稿(Task 2):MedFieldPanel/两块 MedEntryTile 从阴影换成描边后解锁屏
    // 又长高了几像素,「解锁」默认视口下常年滚出可点区域——先滚到位再点
    // (同 account_screen_test.dart `_tapUnlockButton` 那个坑)。`scrollUntilVisible`
    // 只保证矩形与视口有交集,不保证整块都进来、点得中它的几何中心,还要
    // `ensureVisible` 再对齐一次。
    final unlockButton = find.text('解锁');
    await t.scrollUntilVisible(unlockButton, 200, scrollable: find.byType(Scrollable).first);
    await t.ensureVisible(unlockButton);
    await t.pumpAndSettle();
    await t.tap(unlockButton);
    await t.pumpAndSettle();
    // 切到「已就绪」用的是同一个 ListView,上面那截滚动偏移原样继承下来——滚回去,
    // 让调用方拿到的起点跟减法稿之前一样(「已登录」排在已就绪内容最前面)。
    await t.scrollUntilVisible(find.text('已登录'), -200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
  }

  testWidgets('恢复码框:等宽 20 号、字距 .1em、#F1F4F8 底、#0E6285 字、圆角 14', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: RecoveryCodeBox(
      code: '7K3M-QW9P-XR2D-HB8N-4TVL'))));
    final t = tester.widget<Text>(find.text('7K3M-QW9P-XR2D-HB8N-4TVL'));
    expect(t.style!.fontSize, 20);
    expect(t.style!.letterSpacing, closeTo(2.0, 0.01));   // .1em × 20px
    expect(t.style!.color, MedColors.light.sealInk);
    final d = tester.widget<Container>(find.ancestor(
      of: find.text('7K3M-QW9P-XR2D-HB8N-4TVL'), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, MedColors.light.paper);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBlock));  // 14
  });

  testWidgets('输入框面板:白底、圆角 16、1px line 细边', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: MedFieldPanel(child: Text('口令,至少 6 位')))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedFieldPanel), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));  // 16
    expect(d.border, Border.all(color: MedColors.light.line));
    expect(d.boxShadow, isNull);
  });

  testWidgets('二维码框:白底 160×160 + 10 padding + 圆角 16 + 1px line 细边', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: MedQrFrame(child: SizedBox(width: 160, height: 160)))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedQrFrame), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.border, Border.all(color: MedColors.light.line));
    expect(d.boxShadow, isNull);
    // R9:圆角 16 也要断言,不能只停在名字里。
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));
  });

  testWidgets('出码首次 sheet:一颗主按钮 + 一颗次按钮,零主卡', (tester) async {
    await pumpStage3(tester, const Scaffold(body: QrNoticeBody()));
    expectSurfaceBudget(button: 1);
    expect(find.byType(MedSecondaryButton), findsOneWidget);
  });

  testWidgets('四屏各自的尺寸/字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, const Scaffold(body: SingleChildScrollView(
      child: Column(children: [
        MedFieldPanel(child: Text('口令,至少 6 位')),
        RecoveryCodeBox(code: '7K3M-QW9P-XR2D-HB8N-4TVL'),
      ]))));
  });

  // ── R8:_Tile 从 archive_screen.dart 提到 med_card.dart 改名 MedEntryTile ──
  group('MedEntryTile(原 archive_screen.dart 的私有 _Tile,纯搬家改名)', () {
    testWidgets('两颗等宽白块,点得动', (tester) async {
      var tapped = false;
      await pumpStage3(tester, Scaffold(body: Row(children: [
        Expanded(child: MedEntryTile(
          icon: Icons.vpn_key_outlined,
          label: '输口令', onTap: () => tapped = true)),
        const SizedBox(width: 14),
        Expanded(child: MedEntryTile(
          icon: Icons.description_outlined,
          label: '用恢复码', onTap: () {})),
      ])));
      expect(find.text('输口令'), findsOneWidget);
      expect(find.text('用恢复码'), findsOneWidget);
      expect(find.byType(MedIcon), findsWidgets);
      await tester.tap(find.text('输口令'));
      expect(tapped, isTrue);
    });

    testWidgets('400×800 与 360×640 × 1.0/2.0 字号不溢出(s15 的两块并排样式)', (tester) async {
      await expectNoOverflowAtBothSizes(tester, Scaffold(body: Row(children: [
        Expanded(child: MedEntryTile(
          icon: Icons.vpn_key_outlined,
          label: '输口令', onTap: () {})),
        const SizedBox(width: 14),
        Expanded(child: MedEntryTile(
          icon: Icons.description_outlined,
          label: '用恢复码', onTap: () {})),
      ])));
    });
  });

  // ── s14:doctor_home_screen.dart 的 PatientGrantedSection 改 MedIcon ──
  testWidgets('PatientGrantedSection:「病人让我看的病历」行改用 MedIcon', (tester) async {
    await pumpStage3(tester, Scaffold(body: PatientGrantedSection(
      profiles: const [
        Profile(id: 'p-1', name: '张建国', cloudId: 'prf_1', role: 'viewer'),
      ],
      onTap: (_) {},
    )));
    expect(
      find.descendant(of: find.byType(PatientGrantedSection), matching: find.byType(MedIcon)),
      findsWidgets,
    );
  });

  // ── R25:account_screen.dart 里没有 Task 认领的三处(云端备份行/云端整理行/
  // 「把这份病历交给别人」)。这三处只在「已就绪」阶段才渲染,得走一遍真实登录流程
  // 才碰得到 —— 复用 account_screen_test.dart 里公开的 FakeApi/FakeCrypto。
  group('R25:云端备份/云端整理两行落 MedCard,交给别人变 sealInk', () {
    late Directory support;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      AccountSession.instance.resetForTest();
      resetPendingFirstSyncForTest();
      AccountFlow.resetRestoreGuardForTest();
      Grants.clearInviteCache();
      support = await Directory.systemTemp.createTemp('medme-account-visual-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    testWidgets('云端备份行与云端整理行:MedCard + MedIcon,字符串不变', (t) async {
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', 'owner', null);
      });
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
      await toReady(t, FakeApi(hasKeys: true));

      final memberSwitch = find.byKey(Key('cloud_switch_${ProfileManager.instance.current.id}'));
      expect(memberSwitch, findsOneWidget);
      final memberCard = find.ancestor(of: memberSwitch, matching: find.byType(MedCard));
      expect(memberCard, findsOneWidget, reason: '不再是 Material Card');
      expect(find.descendant(of: memberCard, matching: find.byType(MedIcon)), findsWidgets);

      final extractSwitch = find.byKey(const Key('cloud_extract_switch'));
      expect(extractSwitch, findsOneWidget);
      final extractCard = find.ancestor(of: extractSwitch, matching: find.byType(MedCard));
      expect(extractCard, findsOneWidget);
      expect(find.descendant(of: extractCard, matching: find.byType(MedIcon)), findsWidgets);

      // 字符串一个没变,开关语义/回调也没变——只是外壳换了。
      expect(find.text('云端整理'), findsOneWidget);
      expect(t.widget<SwitchListTile>(memberSwitch).value, isTrue);
    });

    testWidgets('「把这份病历交给别人」:文字色 sealInk,没有新增图标', (t) async {
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', 'owner', null);
      });
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
      await toReady(t, FakeApi(hasKeys: true));

      final btn = find.byKey(const Key('transfer_current_profile'));
      await t.scrollUntilVisible(btn, 200, scrollable: find.byType(Scrollable).first);
      expect(btn, findsOneWidget);
      expect(
        t.widget<Text>(find.descendant(of: btn, matching: find.text('把这份病历交给别人'))).style!.color,
        MedColors.light.sealInk,
      );
      expect(find.descendant(of: btn, matching: find.byType(MedIcon)), findsNothing,
          reason: '这一行本来就没有图标位,不许给它新加一个');
    });
  });

  // ── Task 16(Task 13 review Important 遗留):s12/s15/s13 三个组合屏之前只测过
  // 拆出来的小组件(RecoveryCodeBox/MedFieldPanel/MedQrFrame/MedEntryTile 对),
  // 没有走真实登录流程,在「真的那一屏」上断言过渐变预算、也没跑过溢出矩阵——
  // 这三处都得先登录才碰得到,复用上面 R25 那组的 FakeApi 驱动手法。
  group('Task 16:s12/s15/s13 组合屏的渐变预算 + 溢出矩阵', () {
    late Directory support;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      AccountSession.instance.resetForTest();
      resetPendingFirstSyncForTest();
      AccountFlow.resetRestoreGuardForTest();
      Grants.clearInviteCache();
      support = await Directory.systemTemp.createTemp('medme-account-visual-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });

    tearDown(() async => support.delete(recursive: true));

    /// `setUp` 只在每个 `testWidgets` 开头跑一次——溢出矩阵那个测试在同一个
    /// `testWidgets` 里循环 4 次重新登录,前一轮登出来的真实 session 会让
    /// `AccountScreen.initState` 的 `resumeIfLoggedIn()` 直接跳过 `idle`(找不到
    /// 'phone' 输入框)。每次落到新的一屏之前都重置一遍,行为同 `setUp`。
    void resetSession() {
      AccountSession.instance.resetForTest();
      resetPendingFirstSyncForTest();
      AccountFlow.resetRestoreGuardForTest();
      Grants.clearInviteCache();
    }

    /// s12(设一个口令):注册新账号(`FakeApi()` 默认 `hasKeys: false`),
    /// 「设好了」之后落在恢复码画面。
    Future<void> toRecoveryScreen(WidgetTester t, {Size? size, double scale = 1.0}) async {
      resetSession();
      if (size != null) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1.0;
      }
      addTearDown(t.view.reset);
      await t.pumpWidget(sizedApp(
        AccountScreen(flow: AccountFlow(FakeApi(), AccountSession.instance, crypto: FakeCrypto())),
        size: size, scale: scale,
      ));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('code')), '000000');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('password')), 'right1');
      await t.pump();
      await t.tap(find.text('设好了'));
      await t.pumpAndSettle();
    }

    /// s15(换新手机):登录到解锁屏、不输密码——`_deviceApprovalBlock` 的
    /// `HeroCard` 只在这个阶段的树上,输对密码进「已就绪」它就没了。
    Future<void> toUnlockScreen(WidgetTester t, {Size? size, double scale = 1.0}) async {
      resetSession();
      if (size != null) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1.0;
      }
      addTearDown(t.view.reset);
      await t.pumpWidget(sizedApp(
        AccountScreen(flow: AccountFlow(
          FakeApi(hasKeys: true, delay: const Duration(milliseconds: 5)),
          AccountSession.instance,
          crypto: FakeCrypto(),
        )),
        size: size, scale: scale,
      ));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('code')), '000000');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();
    }

    testWidgets('s12:渐变预算 1(「我抄好了」),复制/分享是 Wrap 里两颗按钮', (t) async {
      await toRecoveryScreen(t);
      expectSurfaceBudget(button: 1);
      expect(find.byType(Wrap), findsOneWidget);
      expect(find.widgetWithText(TextButton, '复制'), findsOneWidget);
      expect(find.widgetWithText(MedSecondaryButton, '发给自己'), findsOneWidget);
    });

    testWidgets('s15:渐变预算 1(HeroCard 包住 device-approval 块)', (t) async {
      await toUnlockScreen(t);
      expectSurfaceBudget(hero: 1);
      expect(find.byType(HeroCard), findsOneWidget);
    });

    /// s13 用的 `MedQrFrame` 这颗组件,在个人模式里还有第二条调用路径:「已就绪」
    /// 屏 B5「把这份病历交给别人」→ `link_qr_dialog.dart` 的 `hero: false` 分支
    /// (R28:「同一个组件」,budget 0 不受影响,因为这条路**没有** `MedCard`——
    /// `hero:false` 时 `block` 是裸 `Column`,`MedCard` 只出现在 s13 真正的出码
    /// 整屏 `qr_share_screen.dart:591`,那一屏另有 `qr_share_screen_test.dart`,
    /// 不在这份文件管辖内)。
    ///
    /// 走真实 `_transferOwnership` 业务流程要先过一道确认弹窗(「生成链接」)、
    /// 再等 `Grants.inviteTransfer` 真实调用——那条链路的正确性不是这里要测的
    /// 东西(`account_screen_test.dart` 管)。这里直接调用 `showLinkQrDialog`
    /// 本尊(与 `proxy_handoff_visual_test.dart` 测 `showDoctorClaimLinkDialog`
    /// 同一个手法),只看这一路的视觉组合対不对、溢不溢出。
    Widget transferHarness() => Scaffold(body: Center(child: Builder(
      builder: (context) => ElevatedButton(
        key: const Key('open_transfer'),
        onPressed: () => showLinkQrDialog(
          context,
          title: '请他扫这个码',
          url: 'https://medme.example/c#accountVisualFixtureTransferId0123456789ABCDEF',
          body: '让对方用手机相机拍下这个码,或者把链接发给他。他点开并接受之后,'
              '「张建国」这份病历就归他所有,你降为可以一起录入的家人。',
          footnote: '拿到这个码的任何人都能接受(它不绑定某一个人),15 天内有效,'
              '生成之后无法撤回。只发给你真正要交给的那个人。',
          shareSubject: '把这份病历交给你',
          shareLabel: '发给他',
        ),
        child: const Text('open'),
      ),
    )));

    Future<void> toTransferDialog(WidgetTester t, {Size? size, double scale = 1.0}) async {
      await pumpStage3(t, transferHarness(), size: size ?? const Size(400, 800), textScale: scale);
      await t.tap(find.byKey(const Key('open_transfer')));
      await t.pumpAndSettle();
    }

    testWidgets('s13 的 MedQrFrame 在「交给别人」弹窗里原样出现,没有 HeroCard(R28)', (t) async {
      await toTransferDialog(t);

      expect(find.byType(MedQrFrame), findsOneWidget);
      expect(find.byType(HeroCard), findsNothing);
      expect(find.byType(MedCard), findsNothing);
    });

    // 逐个尺寸/字号生成独立 testWidgets,不在一个测试里循环 4 遍重新登录——
    // `AccountScreen` 的真实登录会往 secure storage/shared_preferences 的 mock
    // 后端里写真数据,`setUp` 只在每个 testWidgets 开头重置一次;分开成独立测试,
    // 每一个都吃得到一次干净的 `setUp`,不用自己找补全部持久层的重置。
    for (final size in kStage3Sizes) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('s12 的 Wrap 不溢出:$size @ ${scale}x', (t) async {
          await toRecoveryScreen(t, size: size, scale: scale);
          expect(t.takeException(), isNull);
        });

        testWidgets('s15 的 HeroCard 块不溢出:$size @ ${scale}x', (t) async {
          await toUnlockScreen(t, size: size, scale: scale);
          expect(t.takeException(), isNull);
        });

        testWidgets('s13 弹窗的 MedQrFrame 不溢出:$size @ ${scale}x', (t) async {
          await toTransferDialog(t, size: size, scale: scale);
          expect(t.takeException(), isNull);
        });
      }
    }
  });
}
