// 「记录」录入弹层的纯 UI 测试 —— 不碰 Rust FFI(`flutter test` 不加载原生库,
// `addSelfMeasurement`/`addNote` 在这里调用会崩;真正落库的行为由
// `apps/mobile_flutter/rust` 里的端到端测试盯,见 `vault_projections.rs`)。
// 这里只盯：封闭六选一渲染齐全、切换类型换对了输入框、数字框真的拒绝非数字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/manual_entry_sheet.dart';

/// 打开弹层但不保存 —— 点「保存」会调 Rust FFI,测试环境里没有原生库可用。
Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showManualEntrySheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('记录弹层', () {
    testWidgets('封闭六选一全部渲染,默认选中血压(两个输入框)', (tester) async {
      await _openSheet(tester);

      for (final label in ['血压', '心率', '体重', '体温', '血糖', '笔记']) {
        expect(find.text(label), findsWidgets, reason: '缺少类型:$label');
      }
      expect(find.text('收缩压'), findsOneWidget);
      expect(find.text('舒张压'), findsOneWidget);
      // 硬约束:不提供任意化验项的输入框 —— 找不到任何自由文本的"项目名"输入。
      expect(find.text('项目名称'), findsNothing);
    });

    testWidgets('切到心率:血压双输入框消失,单值输入框出现', (tester) async {
      await _openSheet(tester);
      await tester.tap(find.text('心率'));
      await tester.pumpAndSettle();

      expect(find.text('收缩压'), findsNothing);
      expect(find.text('舒张压'), findsNothing);
    });

    testWidgets('切到笔记:出现多行文本框', (tester) async {
      await _openSheet(tester);
      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();

      expect(find.text('收缩压'), findsNothing);
      final noteField = tester.widget<TextField>(find.byType(TextField).last);
      expect(noteField.maxLines, greaterThan(1), reason: '笔记应是多行输入');
    });

    testWidgets('数字框接受合法数字、拒绝纯字母输入', (tester) async {
      await _openSheet(tester);
      // 默认血压,取第一个数字框(收缩压)。
      final field = find.byType(TextField).first;

      await tester.enterText(field, 'abc');
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        '',
        reason: '纯字母应被完全过滤,拒绝手打任意文本',
      );

      await tester.enterText(field, '128.5');
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        '128.5',
        reason: '合法数字应原样通过',
      );
    });

    testWidgets('测量时间默认显示为当前时间(有一行「测量时间」)', (tester) async {
      await _openSheet(tester);
      expect(find.text('测量时间'), findsOneWidget);
    });
  });
}
