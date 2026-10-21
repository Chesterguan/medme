// 真正的「添加病历」弹层(showImportSheet 走的 showModalBottomSheet),在真机
// iPhone 14 Pro 尺寸 × 大字号下拉起来,必须不溢出。sheets_visual_test 只 pump
// AddSheetBody 本体,带不上 sheet 的高度上限,2026-10-21 真机 86px 溢出就是这么漏的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/import_flow.dart';

void main() {
  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('添加病历弹层 393x852 字号 $scale 不溢出', (tester) async {
      tester.view.physicalSize = const Size(393 * 3, 852 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showImportSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('导入 Epic 病历包'), findsOneWidget);
      expect(errors.where((e) => e.toString().contains('overflowed')), isEmpty,
          reason: errors.map((e) => e.exceptionAsString()).join('\n'));
    });
  }
}
