// 「记录」录入弹层在**放大字号**下的横向溢出回归测试(BUG-5)。
//
// ## 缺陷现场
//
// `manual_entry_sheet.dart` 的 `_WhenRow`(「测量时间」那一行)原本是一个 `Row`:
//
//     [图标][「测量时间」][Spacer][日期时间][箭头]
//
// 两个 `Text` 都是**非 flex 子项**,而 `RenderFlex` 给非 flex 子项的主轴约束是
// **无穷大** —— 它们各自按固有宽度铺开,谁也不会折行。系统字号 ×2.0 时 `Spacer`
// 先被挤成 0,还差 31px,于是横向溢出。×1.0 / ×1.3 / ×1.5 全干净,只有 ×2.0 露出来
// —— 所以这里把四档都压一遍,只测一档就是漏掉它的原因。
//
// 违反的是 007 §2.5「字号可放大,不可砍」:不能截断日期、不能缩字号,只能换行。
// 同屏的 `QuickActions` 用 `Wrap`、`_MemberTabs` 按 `textScaler` 算高度都是为这条,
// 这一行漏了。
//
// ## 断言的三条硬约束
//
// 1. **不溢出** —— 任何视口 × 任何字号;
// 2. **不砍字** —— 「测量时间」四个字和完整的日期时间都还在,没有省略号;
// 3. **点得着** —— 这一行是个可点的入口(改测量时间),换行之后不能变成点不动的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/manual_entry_sheet.dart';

/// 溢出走 `FlutterError.reportError`,不是被抛出的 Dart 异常 ——
/// `tester.takeException()` 接的是后者,接不住前者(与
/// `lab_line_row_overflow_test.dart` 同一条,那里有详细说明)。
///
/// 恢复必须在 `expect` 之前完成,不能只靠 `addTearDown`:这里真抓到溢出时
/// `expect` 会同步抛 `TestFailure`,那时 `addTearDown` 还没机会运行,框架自己那份
/// handler 收不到,一次干净的失败会变成一条不知所云的内部断言。
Future<List<FlutterErrorDetails>> pumpSheet(
  WidgetTester tester, {
  required double textScale,
  required double width,
  required double height,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final errors = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = original);

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                // 点「保存」才会碰 FFI;只开不存,测试环境里没有原生库可用。
                onPressed: () => showManualEntrySheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  FlutterError.onError = original; // 必须在 expect 之前恢复,见上面的注释。
  return errors;
}

void main() {
  const viewports = {
    '360×640(华为 Mate 9,项目反复踩过的窄屏)': (360.0, 640.0),
    '360×800(常见大屏机)': (360.0, 800.0),
    '414×896(宽视口)': (414.0, 896.0),
  };
  // ×2.0 是缺陷现场;另外三档一起压住,防止「修好了 2.0 却把 1.0 弄折行」。
  const scales = [1.0, 1.3, 1.5, 2.0];

  for (final vp in viewports.entries) {
    for (final scale in scales) {
      testWidgets('${vp.key} · $scale× 字号:「测量时间」一行不溢出、不砍字、点得着', (
        tester,
      ) async {
        final errors = await pumpSheet(
          tester,
          textScale: scale,
          width: vp.value.$1,
          height: vp.value.$2,
        );

        expect(
          errors,
          isEmpty,
          reason: errors
              .map((e) => e.exceptionAsString().split('\n').first)
              .join('\n'),
        );

        // 不砍字:标签整段可读。
        expect(find.text('测量时间'), findsOneWidget);
        final label = tester.widget<Text>(find.text('测量时间'));
        expect(
          label.overflow,
          isNot(TextOverflow.ellipsis),
          reason: '007 §2.5:字号可放大,不可砍 —— 不许用省略号解决放不下',
        );

        // 不砍字:完整的日期时间也在(`yyyy-MM-dd HH:mm`,默认就是「现在」)。
        final stamp = find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.data != null &&
              RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$').hasMatch(w.data!),
        );
        expect(stamp, findsOneWidget, reason: '日期时间被截断或拆行成了两个 Text');

        // 点得着:这一行是改测量时间的入口,换行之后不能退化成点不动的。
        await tester.tap(find.text('测量时间'));
        await tester.pumpAndSettle();
        expect(
          find.byType(DatePickerDialog),
          findsOneWidget,
          reason: '「测量时间」那一行仍然要能唤起日期选择',
        );
      });
    }
  }
}
