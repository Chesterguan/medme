// 概览屏(`screens/overview_screen.dart`)快捷操作区的多视口回归测试。
//
// 2026-08-05 改版:「就诊单」从四等分快捷操作的第四格挪成了独立一整条的
// `VisitSheetBanner`,`QuickActions` 从四列改成三列。不能整屏 `pumpWidget`
// `OverviewScreen`——它在字段初始化那一刻就调 `viewVisitSummary()`(FFI),
// `flutter test` 不带 Rust 原生库会直接崩(与 `manual_entry_sheet_test.dart`、
// `visit_summary_sheet_test.dart` 同一条限制)。`QuickActions`/`VisitSheetBanner`
// 本身不碰 FFI(只吃 `VoidCallback`),所以能被公开出来单独测。
//
// 长文案在窄屏三等分 + 大字号下最容易撑爆(`overview_screen.dart` 里
// `QuickActions` 的类文档就提过这个教训),所以这里同样压 360×640(华为 Mate 9)
// 这类矮屏,叠 2× 字号。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/overview_screen.dart';
import 'package:mobile_flutter/theme.dart';

void useViewport(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    ),
  ),
);

void main() {
  group('QuickActions:三列不溢出', () {
    for (final size in [const Size(360, 640), const Size(360, 800)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${size.width.toInt()}×${size.height.toInt()} @$scale×', (
          tester,
        ) async {
          useViewport(tester, size.width, size.height);
          await tester.pumpWidget(
            wrap(
              QuickActions(
                onArchiveIn: () {},
                onManualEntry: () {},
                onEmergency: () {},
              ),
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('存档'), findsOneWidget);
          expect(find.text('记录'), findsOneWidget);
          expect(find.text('应急卡'), findsOneWidget);
          // 就诊单已经挪出这三列,不该再出现在这里。
          expect(find.text('就诊单'), findsNothing);
          expect(find.text('看病带这个'), findsNothing);
        });
      }
    }

    testWidgets('三颗都能点,各自触发对应回调', (tester) async {
      useViewport(tester, 390, 844);
      var archiveIn = false, manualEntry = false, emergency = false;
      await tester.pumpWidget(
        wrap(
          QuickActions(
            onArchiveIn: () => archiveIn = true,
            onManualEntry: () => manualEntry = true,
            onEmergency: () => emergency = true,
          ),
        ),
      );

      await tester.tap(find.text('存档'));
      await tester.tap(find.text('记录'));
      await tester.tap(find.text('应急卡'));
      expect(archiveIn, isTrue);
      expect(manualEntry, isTrue);
      expect(emergency, isTrue);
    });
  });

  group('VisitSheetBanner:更显眼的独立一条,不溢出', () {
    for (final size in [const Size(360, 640), const Size(360, 800)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${size.width.toInt()}×${size.height.toInt()} @$scale×', (
          tester,
        ) async {
          useViewport(tester, size.width, size.height);
          await tester.pumpWidget(
            wrap(VisitSheetBanner(onTap: () {}), textScale: scale),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('看病带这个'), findsOneWidget);
        });
      }
    }

    testWidgets('点击触发回调', (tester) async {
      useViewport(tester, 390, 844);
      var tapped = false;
      await tester.pumpWidget(
        wrap(VisitSheetBanner(onTap: () => tapped = true)),
      );
      await tester.tap(find.text('看病带这个'));
      expect(tapped, isTrue);
    });
  });
}
