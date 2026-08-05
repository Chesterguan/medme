// 用户视角二:**手抖 / 乱按的用户**。
//
// 全程走**真实 UI**(概览 → 记录 → 输入框 → 保存),不走 FFI 后门 —— 这一条
// 用例要验的正是「UI 这一层挡不挡得住」。覆盖:空值、只填一半、0、-1、999999、
// 小数、中文字符、超长数字串、反复快速点保存、录入中途退出。
//
// 背景:真机实测里有人把收缩压存成了 138388 mmHg(见
// `manual_entry_sheet.dart` 的 `_plausibleRanges` 文档)。
//
//     flutter test integration_test/journey_fat_finger_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

/// 从概览的「记录」快捷操作打开录入弹层。
Future<void> openEntrySheet(WidgetTester tester) async {
  await gotoTab(tester, HomeTab.overview);
  await waitFor(tester, find.text('记录'));
  await tester.tap(find.text('记录').first);
  await settle(tester);
  await waitFor(tester, find.text('保存'), what: '录入弹层的「保存」按钮');
}

Finder get sysBox => find.byType(TextField).at(0);
Finder get diaBox => find.byType(TextField).at(1);
Finder get saveBtn => find.widgetWithText(FilledButton, '保存');

Future<int> recordCount() async => (await patientProfile()).recordCount;

/// 关掉弹层(点蒙层)。
Future<void> dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空值 / 半填 / 越界 / 乱字符 —— 一条都不许静默落库', (tester) async {
    final watch = OverflowWatch('手抖用户')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    expect(await recordCount(), 0, reason: '起点应当是空保险箱');

    await openEntrySheet(tester);

    // ① 什么都不填直接保存。
    await tester.tap(saveBtn);
    await settle(tester);
    expect(find.text('请输入完整的数值'), findsOneWidget,
        reason: '空值保存没有提示,用户会以为存上了');
    expect(await recordCount(), 0);

    // ② 只填收缩压。
    await tester.enterText(sysBox, '128');
    await settle(tester);
    await tester.tap(saveBtn);
    await settle(tester);
    expect(find.text('请输入完整的数值'), findsOneWidget, reason: '半填也必须拦住');
    expect(await recordCount(), 0);

    // ③ 0 / 0 —— 生理上不可能。
    await tester.enterText(sysBox, '0');
    await tester.enterText(diaBox, '0');
    await settle(tester);
    await tester.tap(saveBtn);
    await settle(tester);
    expect(find.textContaining('超出可能范围'), findsOneWidget,
        reason: '0/0 被放行了');
    expect(await recordCount(), 0);

    // ④ 负数:输入框的 formatter 应当直接吃掉减号(存进去的是 1)。
    await tester.enterText(sysBox, '-1');
    await settle(tester);
    final sysText = tester.widget<TextField>(sysBox).controller!.text;
    debugPrint('[手抖用户] 输入 "-1" 后框里是: "$sysText"');
    expect(sysText.contains('-'), isFalse, reason: '数字框吃进了减号');

    // ⑤ 999999 —— 真机上出过的 138388 同一类。
    await tester.enterText(sysBox, '999999');
    await tester.enterText(diaBox, '888888');
    await settle(tester);
    await tester.tap(saveBtn);
    await settle(tester);
    expect(find.textContaining('超出可能范围'), findsOneWidget,
        reason: '六位数血压被放行了(真机上出过 138388)');
    expect(await recordCount(), 0);

    // ⑥ 中文字符:formatter 应当整个吃掉。
    await tester.enterText(sysBox, '一百三十八');
    await settle(tester);
    final cn = tester.widget<TextField>(sysBox).controller!.text;
    debugPrint('[手抖用户] 输入中文后框里是: "$cn"');
    expect(cn, isEmpty, reason: '数字框吃进了中文字符: "$cn"');

    // ⑦ 超长数字串。
    await tester.enterText(sysBox, '12345678901234567890');
    await tester.enterText(diaBox, '98765432109876543210');
    await settle(tester);
    await tester.tap(saveBtn);
    await settle(tester);
    expect(find.textContaining('超出可能范围'), findsOneWidget,
        reason: '20 位数字被放行了');
    expect(await recordCount(), 0);

    // ⑧ 填反了:88/138。
    await tester.enterText(sysBox, '88');
    await tester.enterText(diaBox, '138');
    await settle(tester);
    await tester.tap(saveBtn);
    await settle(tester);
    expect(find.textContaining('应大于舒张压'), findsOneWidget,
        reason: '收缩压 < 舒张压 没被交叉校验挡住');
    expect(await recordCount(), 0);

    // ⑨ 小数是合法的(体重 65.5、体温 36.8 都要能填),血压小数也不该崩。
    await tester.enterText(sysBox, '128.5');
    await tester.enterText(diaBox, '82.5');
    await settle(tester);
    await tester.tap(saveBtn);
    await settle(tester);
    await waitGone(tester, find.text('保存'), what: '保存成功后弹层应当关闭');
    expect(await recordCount(), 1, reason: '合法的小数值没能存进去');

    watch.assertClean();
  });

  testWidgets('反复快速点保存 —— 不能存出两条重复记录', (tester) async {
    await bootApp(tester);
    await openEntrySheet(tester);

    await tester.enterText(sysBox, '133');
    await tester.enterText(diaBox, '87');
    await settle(tester);

    // 连点五次,中间只 pump 一帧 —— 模拟老人「点了没反应」于是猛戳。
    // 按钮可能在第一下之后就随弹层一起消失(这正是我们希望的),所以每次先看
    // 还在不在;`tap` 一个不存在的 finder 会直接抛,不是「没存出重复记录」。
    for (var i = 0; i < 5; i++) {
      if (saveBtn.evaluate().isEmpty) break;
      await tester.tap(saveBtn, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 1));
    }
    await settle(tester, total: const Duration(seconds: 3));

    final n = await recordCount();
    debugPrint('[手抖用户] 连点 5 次保存后库里有 $n 条');
    expect(n, 1, reason: '连点保存存出了 $n 条记录');
  });

  testWidgets('录入到一半退出 —— 不留半条记录', (tester) async {
    await bootApp(tester);
    await openEntrySheet(tester);

    await tester.enterText(sysBox, '140');
    await settle(tester);
    await dismissSheet(tester);

    expect(await recordCount(), 0, reason: '中途退出留下了记录');

    // 再打开一次,不该带着上次的残留值。
    await openEntrySheet(tester);
    final left = tester.widget<TextField>(sysBox).controller!.text;
    debugPrint('[手抖用户] 重开弹层,收缩压框里是: "$left"');
    expect(left, isEmpty, reason: '重开录入弹层带着上次没存的值: "$left"');
    await dismissSheet(tester);
  });

  testWidgets('六选一每一种都点得动,切换类型不崩', (tester) async {
    final watch = OverflowWatch('六选一')..start();
    addTearDown(watch.stop);

    await bootApp(tester);
    await openEntrySheet(tester);

    for (final kind in ['心率', '体重', '体温', '血糖', '笔记', '血压']) {
      await tester.tap(find.text(kind).first);
      await settle(tester);
      expect(find.text('保存'), findsOneWidget, reason: '切到「$kind」后弹层没了');
    }
    await dismissSheet(tester);
    watch.assertClean();
  });
}
