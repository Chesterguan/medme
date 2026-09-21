// 用户视角四:**全新用户,空病历箱**。
//
// 每一屏的空态各是什么样?这一屏最容易撒的谎是「说假话的空态」—— 一片留白会被
// 读成「你没有过敏史」「你没查过这项」,而真相只是「我们没读到」。
// 规范 §六:空态必须(1)说的是我们**观察到**什么,不是用户身上有没有事;
// (2)给出路。这两条逐屏验一遍。
//
// UX Stage 1 之后要巡的不再是五个 tab,而是**三个 tab + 两张推进去的整页**:
// 病历 / 趋势 / 我,以及「给医生看」(从「病历」那颗白底方块进)与它里面的
// 「急救卡」。顺带把原 `archive_test.dart`(断言旧三 tab 的那一版)收编到这里。
//
//     flutter test integration_test/journey_new_user_test.dart -d <device>

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

  testWidgets('空病历箱:三个 tab + 给医生看 + 急救卡,空态都不撒谎、都有出路', (tester) async {
    final watch = OverflowWatch('空态巡检')..start();
    addTearDown(watch.stop);

    await bootApp(tester);

    // ── 病历(`s1`)──
    await gotoTab(tester, HomeTab.records);
    await waitFor(tester, find.text('还没有病历'));
    // 出路有两处,都得在:hero 卡下面那颗主色方块「添加」,以及空态那句话里
    // 指给它看的文案(顶栏**刻意没有**按钮,见 `archive_screen.dart` 的注释)。
    expect(find.text('添加'), findsWidgets, reason: '「病历」空态没有「添加」这条出路');
    expect(find.textContaining('点上面那颗「添加」'), findsOneWidget,
        reason: '空态没把出路指给用户看');
    expect(find.textContaining('载入示例数据'), findsWidgets,
        reason: '空态没给第二条出路(我 → 关于 里的示例数据)');

    // ── 趋势(`s2`)──
    await gotoTab(tester, HomeTab.trends);
    await waitFor(tester, find.text('还画不出趋势'));
    expect(find.text('去「病历」添加化验单'), findsOneWidget, reason: '趋势空态没有出路按钮');
    // 说的是「我们观察到什么」,不是「你没查过」。
    expect(find.textContaining('趋势需要同一个指标'), findsOneWidget);

    // ── 给医生看(整页,`s4`)──
    await gotoForDoctor(tester);
    expect(find.text('我想问医生的'), findsOneWidget);
    expect(find.text('加一条'), findsOneWidget, reason: '笔记空态没有出路');
    expect(find.text('我最近的变化'), findsOneWidget);
    expect(find.text('医生可能要问的'), findsOneWidget);
    expect(find.textContaining('这不等于你不过敏'), findsOneWidget,
        reason: '空过敏史被留白 —— 医生会读成「无过敏史」');
    // 一屏只有一颗主按钮,而且钉在底部:出码。全 App 出码只有这一条路。
    expect(find.text('出码给医生看'), findsOneWidget);
    // 跟着正文滚的三条次要入口。
    expect(await scrollToFind(tester, find.text('导出文件')), isTrue);
    expect(find.text('急救卡'), findsOneWidget);

    // ── 急救卡 ──(这一屏的空态最要命:留白 = 「无过敏史」)
    await gotoEmergencyCard(tester);
    final emergencyTexts = visibleTexts(tester);
    debugPrint('[空态巡检] 急救卡文案: $emergencyTexts');
    expect(
      emergencyTexts.any((s) => s.contains('这不等于没有过敏')),
      isTrue,
      reason: '急救卡空过敏史没有把「没读到 ≠ 没有」说出来 —— 会被急救医生读成无过敏史',
    );
    // 空过敏史那一节的标题自己就说「未识别」——「留白 = 无过敏史」正是要挡的那件事。
    expect(find.text('过敏史(未识别)'), findsOneWidget);
    // 血型这一栏是刻意留空的,并且说明了为什么。
    expect(find.text('未登记'), findsOneWidget);
    expect(find.textContaining('输血前本来就要现场配血'), findsOneWidget);
    // 诊断/用药的空态同样是「没读到」的口径。
    expect(
      emergencyTexts.any((s) => s.contains('已添加的病历里没有读到诊断名')),
      isTrue,
    );

    // ── 我 → 关于 ──(空箱子也得能用)
    await gotoAbout(tester);
    expect(find.text('清空所有数据 · 重置病历箱'), findsOneWidget);
    expect(find.text('隐私政策'), findsWidgets);
    // 「导出 · 分享」那一节 Task 17 已从「我」搬走:导出只在「给医生看」页里。
    expect(find.text('导出文件'), findsNothing, reason: '「关于」里不该再有第二个导出入口');

    watch.assertClean();
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('空病历箱:「我」首屏就是 s5 那五行,一行不多一行不少', (tester) async {
    final watch = OverflowWatch('我首屏')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    await gotoTab(tester, HomeTab.me);
    await waitFor(tester, find.text('关于 / 隐私政策'));

    for (final t in ['云端', '这台手机上的病历', '口令与恢复码', '我的设备', '关于 / 隐私政策']) {
      expect(find.text(t), findsWidgets, reason: '「我」首屏缺了「$t」');
    }
    // Task 17 从这一屏撤掉的两节,不许回潮。
    expect(find.text('数据出口'), findsNothing);
    expect(find.text('删掉全部'), findsNothing, reason: '「删掉全部」应当只在「关于」里');
    // 安卓上不该出现 iCloud 那一节(那是 iOS 专属,露出来就是死开关)。
    expect(find.text('iCloud 同步(实验性)'), findsNothing);

    watch.assertClean();
  });

  testWidgets('空病历箱:三个 tab 来回快切 20 次不崩、不错位', (tester) async {
    final watch = OverflowWatch('快切')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    for (var i = 0; i < 20; i++) {
      selectedTab.value = i % HomeTab.count;
      await tester.pump(const Duration(milliseconds: 30));
    }
    await settle(tester, total: const Duration(seconds: 2));
    // 最后一次是 i=19 → 19 % 3 == 1 → 趋势。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('趋势')),
      findsOneWidget,
      reason: '快切之后 tab 与内容对不上',
    );
    watch.assertClean();
  });
}
