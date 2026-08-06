// 文档详情页化验表(`widgets/report_content.dart` 的 `_LabTableView` /
// `_LabRowView`,`ReportContent` 富渲染其中一种形态)的窄屏溢出回归测试。
//
// 同一份根因在这个屏上的第二个现场:eGFR 那行的「偏低」chip 同样会被挤到
// 第二行。之前见过一次、说了要修没修,这次跟概览页那处(见
// `lab_line_row_overflow_test.dart`)一起修——两处都是名称+pill 用 `Wrap`,
// 名字/单位一长或字号一放大,pill 就被挤到 Wrap 的下一行。
//
// 覆盖同一组视口/字号矩阵:真机复现尺寸(Mate 9,360×640)、常见大屏机
// (360×800)、平板/横屏宽视口,每种再叠 2× 系统字号——只测模拟器默认视口
// (1080×2400)看不出这个问题,这正是当初漏掉它的原因。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/report_content.dart';

/// 缺陷复现的真机视口:华为 Mate 9,逻辑分辨率约 360×640。
void useMate9(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 常见大屏机,逻辑分辨率约 360×800。
void useTallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 平板/横屏宽视口——验证窄屏修法没有在宽屏上带出新问题。
void useTabletLandscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(1024 * 2, 768 * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

// 单空格化验行(文本提取/OCR 折叠多空格后的真实形态,见 `report_content.dart`
// 顶部注释)。第一行是表头,后面≥3 行数据行才会被识别成化验表
// (`tryParseLabRun` 的 `minLabRows = 3`)。第一条 eGFR 就是真机上出问题的那行:
// 项目名 7 字 + 单位 `ml/min/1.73m2` 很长,值又是两位小数。
const labText = '''
项目 结果 单位 参考范围 提示
估算肾小球滤过率 56.00 ml/min/1.73m2 90-120 ↓
低密度脂蛋白胆固醇 3.80 mmol/L 0-3.4 ↓
肌酐 95 umol/L 57-97 正常
''';

Future<List<FlutterErrorDetails>> pumpLabTable(
  WidgetTester tester, {
  required double textScale,
}) async {
  // 捕获 overflow:见 `lab_line_row_overflow_test.dart` 同一处注释——
  // `RenderFlex` 溢出走 `FlutterError.reportError`,`tester.takeException()`
  // 抓不到;而恢复 `FlutterError.onError` 必须在下面的 `expect` 之前完成,
  // 不能只靠 `addTearDown`,否则真溢出时 `expect` 抛出的 `TestFailure` 会在
  // 恢复之前同步抛出,框架自己的 pending-exception 追踪收不到它,报出一条
  // 不知所云的框架内部断言而不是一次干净的失败。
  final errors = <FlutterErrorDetails>[];
  final originalOnError = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = originalOnError);

  await tester.pumpWidget(
    MaterialApp(
      theme: MedMe.theme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(MedShape.s3),
            child: const ReportContent(text: labText),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  FlutterError.onError = originalOnError; // 必须在下面的 expect 之前恢复,见上面的注释。
  return errors;
}

void main() {
  final viewports = <String, void Function(WidgetTester)>{
    '360×640(Mate 9,缺陷复现尺寸)': useMate9,
    '360×800(常见大屏机)': useTallPhone,
    '1024×768(平板/横屏)': useTabletLandscape,
  };
  const scales = [1.0, 2.0];

  for (final viewportEntry in viewports.entries) {
    for (final scale in scales) {
      final label = '${viewportEntry.key} · ${scale}x 字号';

      testWidgets('$label:化验表不溢出、eGFR 行 pill 还在、项目名不被砍', (
        tester,
      ) async {
        viewportEntry.value(tester);
        final errors = await pumpLabTable(tester, textScale: scale);

        expect(
          errors,
          isEmpty,
          reason: errors
              .map((e) => e.exceptionAsString().split('\n').first)
              .join('\n'),
        );

        // 两条异常行的 pill 都在(表里的「偏低」只有 low 状态会给,肌酐是
        // 正常不给 pill,和 lab_status.dart 的规矩一致)。
        expect(find.text('偏低'), findsNWidgets(2));

        // 项目名整段可读。
        expect(find.text('估算肾小球滤过率'), findsOneWidget);
        expect(find.text('低密度脂蛋白胆固醇'), findsOneWidget);

        // 长单位仍然完整显示在结果列里。
        expect(find.textContaining('ml/min/1.73m2'), findsOneWidget);
      });
    }
  }
}
