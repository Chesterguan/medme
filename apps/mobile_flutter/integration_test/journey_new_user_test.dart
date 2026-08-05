// 用户视角四:**全新用户,空保险箱**。
//
// 五个 tab 每一个的空态各是什么样?这一屏最容易撒的谎是「说假话的空态」——
// 一片留白会被读成「你没有过敏史」「你没查过这项」,而真相只是「我们没读到」。
// 规范 §六:空态必须(1)说的是我们**观察到**什么,不是用户身上有没有事;
// (2)给出路。这两条逐 tab 验一遍。
//
// 顺带把原 `archive_test.dart`(断言旧三 tab 的「健康档案」)收编到这里。
//
//     flutter test integration_test/journey_new_user_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

/// 屏上所有可见文字。
List<String> visibleTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空保险箱:五个 tab 的空态都不撒谎、都有出路', (tester) async {
    final watch = OverflowWatch('空态巡检')..start();
    addTearDown(watch.stop);

    await bootApp(tester);

    // ── 概览 ──
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('还没有病历'));
    expect(find.text('导入第一份病历'), findsOneWidget, reason: '概览空态没有出路按钮');
    expect(find.textContaining('只保存在这台手机上'), findsWidgets);

    // ── 趋势 ──
    await gotoTab(tester, HomeTab.trends);
    await waitFor(tester, find.text('还画不出趋势'));
    expect(find.text('去档案导入化验单'), findsOneWidget, reason: '趋势空态没有出路按钮');
    // 说的是「我们观察到什么」,不是「你没查过」。
    expect(find.textContaining('趋势需要同一个指标'), findsOneWidget);

    // ── 档案 ──
    await gotoTab(tester, HomeTab.archive);
    await waitFor(tester, find.text('还没有病历'));
    expect(find.text('导入'), findsWidgets, reason: '档案空态没有右上角「导入」出路');
    expect(find.textContaining('载入示例数据'), findsWidgets);

    // ── 应急卡 ──(这一屏的空态最要命:留白 = 「无过敏史」)
    await gotoTab(tester, HomeTab.emergency);
    await waitFor(tester, find.text('过敏史'));
    final emergencyTexts = visibleTexts(tester);
    debugPrint('[空态巡检] 应急卡文案: $emergencyTexts');
    expect(
      emergencyTexts.any((s) => s.contains('这不等于没有过敏')),
      isTrue,
      reason: '应急卡空过敏史没有把「没读到 ≠ 没有」说出来 —— 会被急救医生读成无过敏史',
    );
    // 血型这一栏是刻意留空的,并且说明了为什么。
    expect(find.text('未登记'), findsOneWidget);
    expect(find.textContaining('输血前本来就要现场配血'), findsOneWidget);
    // 诊断/用药的空态同样是「没读到」的口径。
    expect(
      emergencyTexts.any((s) => s.contains('已导入的病历里没有读到诊断名')),
      isTrue,
    );

    // ── 设置 ──(空箱子也得能用)
    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('载入示例数据(张建国)'));
    expect(find.text('清空所有数据 · 重置保险箱'), findsOneWidget);
    expect(find.text('导出 · 分享'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);

    watch.assertClean();
  });

  testWidgets('空保险箱:「看病带这个」浮层的每一节都说人话', (tester) async {
    final watch = OverflowWatch('空箱看病带这个')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('看病带这个'));
    await tester.tap(find.text('看病带这个'));
    await settle(tester, total: const Duration(seconds: 3));

    await waitFor(tester, find.text('复制全文给医生'), what: '「看病带这个」浮层');

    // 四个区块的空态。
    expect(find.text('我想问医生的'), findsOneWidget);
    expect(find.text('加一条'), findsOneWidget, reason: '笔记空态没有出路');
    expect(find.text('我最近的变化'), findsOneWidget);
    expect(find.text('医生可能要问的'), findsOneWidget);
    expect(find.textContaining('这不等于你不过敏'), findsOneWidget,
        reason: '空过敏史被留白 —— 医生会读成「无过敏史」');
    expect(find.text('医生要看原件 · 出示二维码'), findsOneWidget);

    watch.assertClean();
  });

  testWidgets('空保险箱:五个 tab 来回快切 20 次不崩、不错位', (tester) async {
    final watch = OverflowWatch('快切')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    for (var i = 0; i < 20; i++) {
      selectedTab.value = i % HomeTab.count;
      await tester.pump(const Duration(milliseconds: 30));
    }
    await settle(tester, total: const Duration(seconds: 2));
    // 最后一次是 i=19 → 19 % 5 == 4 → 设置。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('设置')),
      findsOneWidget,
      reason: '快切之后 tab 与内容对不上',
    );
    watch.assertClean();
  });
}
