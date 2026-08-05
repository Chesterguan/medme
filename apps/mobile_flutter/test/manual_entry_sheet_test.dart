// 「记录」录入弹层的纯 UI 测试 —— 不碰 Rust FFI(`flutter test` 不加载原生库,
// `addSelfMeasurement`/`addNote` 在这里调用会崩;真正落库的行为由
// `apps/mobile_flutter/rust` 里的端到端测试盯,见 `vault_projections.rs`)。
// 这里只盯：封闭六选一渲染齐全、切换类型换对了输入框、数字框真的拒绝非数字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/manual_entry_sheet.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

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

    testWidgets('填入不可能的收缩压后点保存:显示范围错误,不触达 FFI(不崩)', (tester) async {
      // 真机实测复现:华为 Mate 9 上把收缩压存成了 138388 mmHg。这条钉住
      // "保存"按钮的处理链路——校验没过时必须在调 Rust FFI 之前就 return,
      // 测试环境没有原生库,真调到 FFI 会崩(见文件顶部注释)。
      await _openSheet(tester);
      final systolic = find.byType(TextField).at(0);
      final diastolic = find.byType(TextField).at(1);
      await tester.enterText(systolic, '138388');
      await tester.enterText(diastolic, '82');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('超出可能范围'), findsOneWidget);
    });

    testWidgets('收缩压填反成比舒张压小,点保存显示交叉校验错误', (tester) async {
      await _openSheet(tester);
      final systolic = find.byType(TextField).at(0);
      final diastolic = find.byType(TextField).at(1);
      await tester.enterText(systolic, '88');
      await tester.enterText(diastolic, '138');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('应大于舒张压'), findsOneWidget);
    });
  });

  group('manualEntryRangeError —— 保存前的可能性校验(纯函数,不依赖 FFI)', () {
    // 真机实测复现:华为 Mate 9 上把收缩压存成了 138388 mmHg —— 物理上不
    // 可能,必须拒绝保存,而不是原样存进去把趋势图 Y 值域拉爆。
    test('①范围外的值(如 138388 mmHg 收缩压)被拒绝', () {
      final err = manualEntryRangeError([
        const SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 138388, unit: 'mmHg'),
        const SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 82, unit: 'mmHg'),
      ]);
      expect(err, isNotNull);
      expect(err, contains('收缩压'));
    });

    // 这条最容易被写错成"一刀切拒绝":200/110 是真实且危险的血压(高血压
    // 危象),不是打错,必须能存进去——之后由 Rust 侧 home_ref_range/
    // aggregate 标"偏高",不归这层管。
    test('②范围内的危急值(200/110 血压)必须放行,不能被当成非法值拒绝', () {
      final err = manualEntryRangeError([
        const SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 200, unit: 'mmHg'),
        const SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 110, unit: 'mmHg'),
      ]);
      expect(err, isNull);
    });

    test('②其余四项的危急但真实的值也必须放行', () {
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'body_temperature', value: 40, unit: 'Cel'),
        ]),
        isNull,
        reason: '40°C 高热是真实值',
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'heart_rate', value: 180, unit: '/min'),
        ]),
        isNull,
        reason: '180 次/分(运动/心动过速)是真实值',
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'glucose', value: 25, unit: 'mmol/L'),
        ]),
        isNull,
        reason: '25 mmol/L 严重高血糖是真实值',
      );
    });

    test('③收缩压必须大于舒张压——88/138 明显填反了', () {
      final err = manualEntryRangeError([
        const SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 88, unit: 'mmHg'),
        const SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 138, unit: 'mmHg'),
      ]);
      expect(err, isNotNull);
      expect(err, contains('舒张压'));
    });

    test('③收缩压等于舒张压也被拒绝(不是真实生理状态)', () {
      final err = manualEntryRangeError([
        const SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 100, unit: 'mmHg'),
        const SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 100, unit: 'mmHg'),
      ]);
      expect(err, isNotNull);
    });

    test('单值项(无配对字段)各自的边界:25/250 次心率放行,边界外拒绝', () {
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'heart_rate', value: 25, unit: '/min'),
        ]),
        isNull,
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'heart_rate', value: 250, unit: '/min'),
        ]),
        isNull,
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'heart_rate', value: 24.9, unit: '/min'),
        ]),
        isNotNull,
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'heart_rate', value: 250.1, unit: '/min'),
        ]),
        isNotNull,
      );
    });

    test('体重边界:1kg/400kg 放行,边界外拒绝', () {
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'body_weight', value: 1, unit: 'kg'),
        ]),
        isNull,
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'body_weight', value: 400, unit: 'kg'),
        ]),
        isNull,
      );
      expect(
        manualEntryRangeError([
          const SelfMeasuredValueDto(analyteKey: 'body_weight', value: 400.1, unit: 'kg'),
        ]),
        isNotNull,
      );
    });
  });
}
