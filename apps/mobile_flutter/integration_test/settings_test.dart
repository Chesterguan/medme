// 「设置」屏集成测试 —— 合并了旧的 `settings_test.dart` 与 `export_test.dart`。
//
// 旧的两个都过期了:
//   · `export_test` 断言「导出分享」是一个**一级 tab**,而五 tab IA 里它收进了
//     设置的「数据出口」一节(见 `settings_screen.dart` 那段长注释);
//   · `settings_test` 断言清空确认弹窗的标题是「清空保险箱?」,现在是
//     「清空所有数据?」,正文也整句换过。
//
//     flutter test integration_test/settings_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

Future<void> seedOne() => addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'bp_systolic', value: 130, unit: 'mmHg'),
        SelfMeasuredValueDto(
            analyteKey: 'bp_diastolic', value: 84, unit: 'mmHg'),
      ],
      measuredAt: DateTime.now().toUtc().toIso8601String(),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('设置屏各分组都渲染得出来', (tester) async {
    final watch = OverflowWatch('设置屏')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('载入示例数据(张建国)'));

    for (final t in [
      '模式',
      '保险箱',
      '数据出口',
      '导出 · 分享',
      '示例数据',
      '数据管理',
      '清空所有数据 · 重置保险箱',
      '关于',
    ]) {
      expect(find.text(t), findsWidgets, reason: '设置屏缺了「$t」');
    }
    // 安卓上不该出现 iCloud 那一节(那是 iOS 专属,露出来就是死开关)。
    expect(find.text('iCloud 同步(实验性)'), findsNothing);

    watch.assertClean();
  });

  testWidgets('清空:必须二次确认,取消不误删', (tester) async {
    await bootApp(tester);
    await seedOne();
    bumpVaultRevision();
    expect((await patientProfile()).recordCount, 1);

    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('清空所有数据 · 重置保险箱'));
    await tester.tap(find.text('清空所有数据 · 重置保险箱'));
    await settle(tester, total: const Duration(seconds: 2));

    expect(find.text('清空所有数据?'), findsOneWidget, reason: '清空没有二次确认');
    expect(find.textContaining('此操作不可撤销'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text('清空所有数据?'), findsNothing);
    expect((await patientProfile()).recordCount, 1, reason: '点了取消却把数据删了');
  });

  testWidgets('清空:确认之后真的清干净,且各屏跟着刷新', (tester) async {
    await bootApp(tester);
    await seedOne();
    bumpVaultRevision();

    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('最近的关键化验'));

    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('清空所有数据 · 重置保险箱'));
    await tester.tap(find.text('清空所有数据 · 重置保险箱'));
    await settle(tester, total: const Duration(seconds: 2));
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await settle(tester, total: const Duration(seconds: 6));

    expect((await patientProfile()).recordCount, 0, reason: '确认清空后还有记录');

    // 概览是保活的(`IndexedStack`),必须靠 `vaultRevision` 自己刷回空态。
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('还没有病历'),
        what: '清空后概览应当刷回空态(保活屏没刷新 = 用户以为没清掉)');
  });

  testWidgets('导出 · 分享:两张动作卡在,弹的是应用内确认框(不拉系统)', (tester) async {
    final watch = OverflowWatch('导出分享')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('导出 · 分享'));
    await tester.tap(find.text('导出 · 分享'));
    await settle(tester, total: const Duration(seconds: 2));

    await waitFor(tester, find.text('导出时间线'), what: '导出·分享二级页');
    expect(find.text('当面给医生看'), findsWidgets);

    // 导出:点开的是应用内对话框,取消关闭 —— 不真的触发分享(会拉系统面板)。
    await tester.tap(find.text('导出时间线').last);
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text('导出并分享'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text('导出并分享'), findsNothing);

    watch.assertClean();
  });

  testWidgets('载入示例数据:进度可见、落在自己的成员里、不混进你的档案', (tester) async {
    await bootApp(tester);
    await seedOne();
    bumpVaultRevision();

    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('载入示例数据(张建国)'));
    await tester.tap(find.text('载入示例数据(张建国)'));

    // 载入是流式的,给它足够时间(22 份要跑 OCR 之外的整条落库路径)。
    await waitFor(tester, find.textContaining('已载入'),
        timeout: const Duration(minutes: 5), what: '载入完成的 SnackBar');
    await settle(tester, total: const Duration(seconds: 2));

    // 载入完必须切回用户原来看的那个成员,且他自己的那一条还在。
    expect((await patientProfile()).recordCount, 1,
        reason: '载入示例数据把用户自己的档案换掉了(或混进去了)');
    expect(find.textContaining('张建国(示例)'), findsWidgets,
        reason: 'SnackBar 没说清示例数据放在哪个成员里');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
