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
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_screen_test.dart' show FakeApi, FakeCrypto;
import 'stage3_visual_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('输入框面板:白底、圆角 16、卡阴影', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: MedFieldPanel(child: Text('口令,至少 6 位')))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedFieldPanel), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));  // 16
    expect(d.boxShadow, MedBrand.cardShadow);
  });

  testWidgets('二维码框:白底 160×160 + 10 padding + 圆角 16 + qrShadow', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: MedQrFrame(child: SizedBox(width: 160, height: 160)))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedQrFrame), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.boxShadow, MedBrand.qrShadow);
    // R9:圆角 16 也要断言,不能只停在名字里。
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));
  });

  testWidgets('出码首次 sheet:一颗主按钮 + 一颗次按钮,零主卡', (tester) async {
    await pumpStage3(tester, const Scaffold(body: QrNoticeBody()));
    expectGradientBudget(button: 1);
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
          icon: Icons.vpn_key_outlined, category: GlossCategory.med,
          label: '输口令', onTap: () => tapped = true)),
        const SizedBox(width: 14),
        Expanded(child: MedEntryTile(
          icon: Icons.description_outlined, category: GlossCategory.clinic,
          label: '用恢复码', onTap: () {})),
      ])));
      expect(find.text('输口令'), findsOneWidget);
      expect(find.text('用恢复码'), findsOneWidget);
      expect(tester.widgetList<GlossIconTile>(find.byType(GlossIconTile)).map((g) => g.category),
          [GlossCategory.med, GlossCategory.clinic]);
      await tester.tap(find.text('输口令'));
      expect(tapped, isTrue);
    });

    testWidgets('400×800 与 360×640 × 1.0/2.0 字号不溢出(s15 的两块并排样式)', (tester) async {
      await expectNoOverflowAtBothSizes(tester, Scaffold(body: Row(children: [
        Expanded(child: MedEntryTile(
          icon: Icons.vpn_key_outlined, category: GlossCategory.med,
          label: '输口令', onTap: () {})),
        const SizedBox(width: 14),
        Expanded(child: MedEntryTile(
          icon: Icons.description_outlined, category: GlossCategory.clinic,
          label: '用恢复码', onTap: () {})),
      ])));
    });
  });

  // ── s14:doctor_home_screen.dart 的 PatientGrantedSection 改光泽图标块(med) ──
  testWidgets('PatientGrantedSection:「病人让我看的病历」行改用 med 光泽图标块', (tester) async {
    await pumpStage3(tester, Scaffold(body: PatientGrantedSection(
      profiles: const [
        Profile(id: 'p-1', name: '张建国', cloudId: 'prf_1', role: 'viewer'),
      ],
      onTap: (_) {},
    )));
    expect(
      tester.widgetList<GlossIconTile>(find.descendant(
        of: find.byType(PatientGrantedSection), matching: find.byType(GlossIconTile))).single.category,
      GlossCategory.med,
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

    Future<void> toReady(WidgetTester t, FakeApi api) async {
      await t.pumpWidget(MaterialApp(
        home: AccountScreen(flow: AccountFlow(api, AccountSession.instance, crypto: FakeCrypto())),
      ));
      await t.enterText(find.byKey(const Key('phone')), '13800000001');
      await t.tap(find.text('发送验证码'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('code')), '000000');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('password')), 'right');
      await t.pump();
      await t.tap(find.text('解锁'));
      await t.pumpAndSettle();
    }

    testWidgets('云端备份行(lab)与云端整理行(clinic):MedCard + 光泽图标块,字符串不变', (t) async {
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
      expect(
        t.widget<GlossIconTile>(find.descendant(of: memberCard, matching: find.byType(GlossIconTile))).category,
        GlossCategory.lab,
      );

      final extractSwitch = find.byKey(const Key('cloud_extract_switch'));
      expect(extractSwitch, findsOneWidget);
      final extractCard = find.ancestor(of: extractSwitch, matching: find.byType(MedCard));
      expect(extractCard, findsOneWidget);
      expect(
        t.widget<GlossIconTile>(find.descendant(of: extractCard, matching: find.byType(GlossIconTile))).category,
        GlossCategory.clinic,
      );

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
      expect(find.descendant(of: btn, matching: find.byType(GlossIconTile)), findsNothing,
          reason: '这一行本来就没有图标位,不许给它新加一个');
    });
  });
}
