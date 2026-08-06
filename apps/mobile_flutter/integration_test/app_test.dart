// 骨架冒烟 —— **五 tab 信息架构**(概览 / 趋势 / 档案 / 应急卡 / 设置)。
//
// 这个文件此前断言的是**旧的三 tab**(健康档案 / 导出分享 / 设置),而 IA 早在
// `feat/mobile-ia` 就换成了五个;加上 `patrolTest` 在 `flutter test` 下起不来,
// 这批测试整体是死的。改写详见 `harness.dart` 顶部。
//
//     flutter test integration_test/app_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('启动 + 五个一级 tab 都在、都点得动、都不崩', (tester) async {
    final watch = OverflowWatch('五 tab 冒烟')..start();
    addTearDown(watch.stop);

    await bootApp(tester);

    // 底栏五项俱在,顺序即 HomeTab 的定义。
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
    // `IndexedStack` 错位一格的表现正是「点应急卡进了设置」。
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

  testWidgets('程序化切 tab 与手点是同一条路径(goToArchive / goToTrends 等)', (
    tester,
  ) async {
    await bootApp(tester, reset: false);

    for (final (idx, label) in [
      (HomeTab.overview, '概览'),
      (HomeTab.trends, '趋势'),
      (HomeTab.archive, '档案'),
      (HomeTab.emergency, '应急卡'),
      (HomeTab.settings, '设置'),
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
