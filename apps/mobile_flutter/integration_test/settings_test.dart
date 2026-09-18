// 「我」tab 与它下面那一层「关于」的集成测试 —— 合并了旧的 `settings_test.dart`
// 与 `export_test.dart`。
//
// 三轮 IA 改下来,这个文件的落点搬过两次:
//   · `export_test` 最早断言「导出分享」是一个**一级 tab**;五 tab 版把它收进
//     「设置 → 数据出口」;**UX Stage 1 又把它搬进「给医生看」那一页,叫「导出文件」**
//     (「我」首屏不再有任何导出入口)。
//   · `settings_test` 最早断言清空确认弹窗的标题是「清空保险箱?」,现在是
//     「清空所有数据?」;那一行本身也从「我」的首屏挪进了「我 → 关于 → 删掉全部」,
//     文案是「清空所有数据 · 重置病历箱」。
//
//     flutter test integration_test/settings_test.dart -d <device>

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

  testWidgets('「我 → 关于」各分组都渲染得出来', (tester) async {
    final watch = OverflowWatch('关于屏')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    await gotoAbout(tester);
    // 「关于」是一整条 `ListView`,「删掉全部」那一节在屏外 —— 先翻到底,
    // 否则 `ListView` 压根不构建它(finder 超时最常见的假警报)。
    expect(await scrollToFind(tester, find.text('清空所有数据 · 重置病历箱')), isTrue,
        reason: '「关于」翻到底也找不到「清空所有数据」');
    await scrollToTop(tester);

    for (final t in [
      '关于',
      'MedMe 主页',
      '隐私政策',
      '用户协议',
      '医疗免责声明',
      '示例数据',
      '载入示例数据(张建国)',
      '删掉全部',
      '清空所有数据 · 重置病历箱',
    ]) {
      expect(find.text(t), findsWidgets, reason: '「关于」屏缺了「$t」');
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

    await gotoAbout(tester);
    expect(await scrollToFind(tester, find.text('清空所有数据 · 重置病历箱')), isTrue);
    await tester.tap(find.text('清空所有数据 · 重置病历箱'));
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

    // 自测血压落在「趋势」的「关键化验」里(概览解散之后那一块搬去了那儿)。
    await gotoTab(tester, HomeTab.trends);
    await waitFor(tester, find.text('关键化验'));

    await gotoAbout(tester);
    expect(await scrollToFind(tester, find.text('清空所有数据 · 重置病历箱')), isTrue);
    await tester.tap(find.text('清空所有数据 · 重置病历箱'));
    await settle(tester, total: const Duration(seconds: 2));
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await settle(tester, total: const Duration(seconds: 6));

    expect((await patientProfile()).recordCount, 0, reason: '确认清空后还有记录');

    // 三个 tab 都是保活的(`IndexedStack`),必须靠 `vaultRevision` 自己刷回空态。
    await gotoTab(tester, HomeTab.records);
    await waitFor(tester, find.text('还没有病历'),
        what: '清空后「病历」应当刷回空态(保活屏没刷新 = 用户以为没清掉)');
  });

  testWidgets('导出文件:只剩「导出时间线」一张卡,出码的门已经不在这儿', (tester) async {
    final watch = OverflowWatch('导出文件')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    // 唯一的门:病历 → 给医生看 → 导出文件(「我」首屏已经没有导出入口)。
    await gotoForDoctor(tester);
    expect(await scrollToFind(tester, find.text('导出文件')), isTrue);
    await tester.tap(find.text('导出文件'));
    await settle(tester, total: const Duration(seconds: 2));

    await waitFor(tester, find.text('导出时间线'), what: '「导出文件」二级页');
    // 终审 I2:这一页曾经还有一张「当面给医生看 / 出示二维码」的卡 —— 那是第二扇
    // 出码的门(深度 4,而且与「出码给医生看」是同一件事的两个名字)。删掉了。
    expect(find.text('当面给医生看'), findsNothing, reason: '第二扇出码的门回潮了');
    expect(find.text('出示二维码'), findsNothing);

    // 导出:点开的是应用内对话框,取消关闭 —— 不真的触发导出(会拉系统分享面板)。
    // 钉的是对话框里那句独一无二的正文(标题「导出时间线」与卡片同名,分不开)。
    const dialogOnly = '时间范围(可选,留空即导出全部)';
    await tester.tap(find.text('选择范围并导出'));
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text(dialogOnly), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text(dialogOnly), findsNothing);

    watch.assertClean();
  });

  testWidgets('载入示例数据:进度可见、落在自己的成员里、不混进你的病历', (tester) async {
    await bootApp(tester);
    await seedOne();
    bumpVaultRevision();

    await gotoAbout(tester);
    expect(await scrollToFind(tester, find.text('载入示例数据(张建国)')), isTrue);
    await tester.tap(find.text('载入示例数据(张建国)'));

    // 载入是流式的,给它足够时间(22 份要跑 OCR 之外的整条落库路径)。
    await waitFor(tester, find.textContaining('已载入'),
        timeout: const Duration(minutes: 5), what: '载入完成的 SnackBar');
    await settle(tester, total: const Duration(seconds: 2));

    // 载入完必须切回用户原来看的那个成员,且他自己的那一条还在。
    expect((await patientProfile()).recordCount, 1,
        reason: '载入示例数据把用户自己的病历换掉了(或混进去了)');
    expect(find.textContaining('张建国(示例)'), findsWidgets,
        reason: 'SnackBar 没说清示例数据放在哪个成员里');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
