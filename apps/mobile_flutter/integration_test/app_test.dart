// 骨架冒烟 —— **三 tab 信息架构**(病历 / 趋势 / 我)。
//
// 这个文件的断言跟着 IA 改过两轮:最早是「健康档案 / 导出分享 / 设置」三 tab,
// 中间一版是「概览 / 趋势 / 档案 / 应急卡 / 设置」五 tab,UX Stage 1 收成现在这
// 三个(mockup `s1`/`s2`/`s5`)。「给医生看」与「急救卡」都**不是 tab** —— 前者
// 从「病历」首页那颗白底方块推进去,后者在那一页里(见 `harness.dart` 的
// `gotoForDoctor` / `gotoEmergencyCard`)。
//
//     flutter test integration_test/app_test.dart -d <device>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('启动 + 三个一级 tab 都在、都点得动、都不崩', (tester) async {
    final watch = OverflowWatch('三 tab 冒烟')..start();
    addTearDown(watch.stop);

    await bootApp(tester);

    // 底栏三项俱在,顺序即 HomeTab 的定义。
    final bar = find.byType(NavigationBar);
    for (final label in tabLabels) {
      expect(
        find.descendant(of: bar, matching: find.text(label)),
        findsOneWidget,
        reason: '底栏缺了「$label」',
      );
    }
    expect(HomeTab.count, tabLabels.length);

    // 逐个点过去,每个 tab 的顶栏标题要对上 —— 只看底栏高亮不够,
    // `IndexedStack` 错位一格的表现正是「点趋势进了我」。
    for (final label in tabLabels) {
      await tapTab(tester, label);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text(label)),
        findsOneWidget,
        reason: '点了底栏「$label」,顶栏标题却不是「$label」',
      );
    }

    // 再倒着点一遍(来回切换不该积累状态)。
    for (final label in tabLabels.reversed) {
      await tapTab(tester, label);
    }
    expect(find.byType(NavigationBar), findsOneWidget);

    watch.assertClean();
  });

  testWidgets('程序化切 tab 与手点是同一条路径(goToRecords / goToTrends 等)', (
    tester,
  ) async {
    await bootApp(tester, reset: false);

    for (final (idx, label) in [
      (HomeTab.records, '病历'),
      (HomeTab.trends, '趋势'),
      (HomeTab.me, '我'),
    ]) {
      await gotoTab(tester, idx);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text(label)),
        findsOneWidget,
        reason: 'selectedTab=$idx 应当落在「$label」',
      );
    }
  });
}
