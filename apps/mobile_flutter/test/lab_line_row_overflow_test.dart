// `LabLine`(`widgets/lab_status.dart`,概览页「最近的关键化验」卡片每一行的
// 唯一渲染实现)的窄屏溢出回归测试。
//
// 真机(华为 Mate 9,1080×1920,逻辑分辨率 360×640)实测发现:`估算肾小球滤过率`
// 这一行——项目名 7 个字 + 单位 `ml/min/1.73m2` 很长——「偏低」pill 被挤到
// 第二行、日期和参考区间又折到第三行,一行变三行;紧接着 `低密度脂蛋白胆固醇`
// 那行的 pill 被卡片底边直接切掉。模拟器默认视口(1080×2400)看不出这个问题,
// 所以这里用真机同款的窄屏视口复现它,并且额外覆盖大屏手机、平板/横屏、以及
// 2× 系统字号——这四个维度任何一个只测一种取值,都可能像这次一样漏掉真实设备
// 上才会触发的挤压。
//
// 根因是同一个:项目名和右侧「数值+单位」都是不受宽度约束的 Text,数值列越宽
// (长单位)就越能反过来把名称列挤没,进而把 pill 挤出当前行。修法见
// `lab_status.dart` 里 `LabLine.build` 的注释——pill 固定在名称行首(像左侧
// 色条一样占恒定位置,不参与「挤不下就换行」的竞争),数值/单位收进
// `Expanded` 放不下时自己折行而不是横向溢出。全程不砍字号、不截断项目名、
// 不丢 pill——这里的断言就是对着这三条硬约束写的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

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

/// 平板/横屏宽视口——验证窄屏修法(名称行首固定 pill、数值列收进 Expanded)
/// 没有在宽屏上带出新问题(比如把宽屏也压成两栏挤在一起)。
void useTabletLandscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(1024 * 2, 768 * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

/// 概览页「最近的关键化验」卡片里,一张卡两行的真实结构:
/// `MedCard` → 卡内 vertical padding → 每行再套一层 horizontal padding
/// (`overview_screen.dart` 的 `_LabSnapshot`)。直接拿 `LabLine` 单测,不拉起
/// 整个概览屏(那需要后端状态/provider),但外层套的 padding 和真实用法一致,
/// 复现的是同一份可用宽度。
Future<List<FlutterErrorDetails>> pumpLabRows(
  WidgetTester tester, {
  required double textScale,
}) async {
  // 捕获 overflow:`RenderFlex` 溢出走 `FlutterError.reportError`(见
  // rendering/debug_overflow_indicator.dart),不是被抛出的 Dart 异常,
  // `tester.takeException()` 接的是后者,接不住前者。
  //
  // 恢复必须在 `expect` 之前完成,不能只靠 `addTearDown`——如果这里真的抓到了
  // 溢出(下面 `expect(errors, isEmpty, ...)` 失败),`expect` 会抛
  // `TestFailure`,而这个异常是在测试体里同步抛出的,此时 `addTearDown` 还没
  // 机会运行,`FlutterError.onError` 仍然指向这份自定义 handler——框架自己那份
  // 用来追踪「当前测试的 pending exception」的 handler 就收不到这个
  // `TestFailure`,于是在 `binding.dart` 里断言
  // `_pendingExceptionDetails != null` 失败,把一次干净的「有溢出」测试失败
  // 変成一条不知所云的框架内部断言。`addTearDown` 留着只是兜底(万一
  // `pumpWidget` 本身提前抛出)。
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
            child: MedCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MedShape.s2,
                      ),
                      // 缺陷现场 1:名字 7 字 + 长单位,「偏低」被挤到第二行、
                      // 日期+参考区间折到第三行。
                      child: LabLine(
                        name: '估算肾小球滤过率',
                        value: 56,
                        unit: 'ml/min/1.73m2',
                        flag: 'L',
                        refLow: 90,
                        meta: '2024-06-01',
                        onTap: () {},
                      ),
                    ),
                    const Divider(height: 1, thickness: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MedShape.s2,
                      ),
                      // 缺陷现场 2:紧接着的下一行,pill 被卡片底边直接切掉。
                      child: LabLine(
                        name: '低密度脂蛋白胆固醇',
                        value: 3.8,
                        unit: 'mmol/L',
                        flag: 'L',
                        refHigh: 3.4,
                        meta: '2024-06-01',
                        onTap: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
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

      testWidgets('$label:两行都不溢出、pill 都在、项目名不被砍', (
        tester,
      ) async {
        viewportEntry.value(tester);
        final errors = await pumpLabRows(tester, textScale: scale);

        expect(
          errors,
          isEmpty,
          reason: errors
              .map((e) => e.exceptionAsString().split('\n').first)
              .join('\n'),
        );

        // pill 两行都在,没有因为挤不下被吞掉。
        expect(
          find.text('偏低'),
          findsNWidgets(2),
          reason: '状态同时编码在色条和 pill 上,少了 pill 色盲用户读不到结论',
        );

        // 项目名整段可读——不砍字、不省略号截断。
        expect(find.text('估算肾小球滤过率'), findsOneWidget);
        expect(find.text('低密度脂蛋白胆固醇'), findsOneWidget);

        // 数值 + 单位仍然完整显示(长单位没有把自己或旁边的内容挤没)。
        expect(find.textContaining('ml/min/1.73m2'), findsOneWidget);
        expect(find.textContaining('mmol/L'), findsOneWidget);
      });
    }
  }
}
