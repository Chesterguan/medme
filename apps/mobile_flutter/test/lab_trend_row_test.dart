import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

TrendSeriesDto _series({
  String name = '肌酐',
  List<(String?, double, int)> pts = const [('2025-01-01', 90, 1), ('2025-06-01', 104, 2), ('2026-01-01', 112, 3)],
  String? unit = 'µmol/L',
}) => TrendSeriesDto(
  name: name,
  analyteKey: 'creatinine',
  unit: unit,
  refLow: 44,
  refHigh: 133,
  valuesConverted: false,
  anyAbnormal: false,
  panel: '肾功能',
  points: [
    for (final (d, v, id) in pts)
      TrendPointDto(date: d, value: v, unit: unit, flag: null, documentId: id, unverified: false),
  ],
  selfMeasured: false,
);

Widget _wrap(Widget child, {double scale = 1.0, double width = 393}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(size: Size(width, 852), textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: SingleChildScrollView(child: SizedBox(width: width, child: child))),
  ),
);

void main() {
  testWidgets('收起:名称、迷你折线、最近值;点开:大折线 + 历年数值行,点一行回原件', (t) async {
    final opened = <int>[];
    await t.pumpWidget(_wrap(LabTrendRow(series: _series(), onOpenDoc: opened.add)));
    expect(find.text('肌酐'), findsOneWidget);
    expect(find.byType(CustomPaint), findsAtLeast(1));
    expect(find.text('112'), findsOneWidget);
    expect(find.text('参考 44–133'), findsOneWidget);
    expect(find.text('2025-01-01 起 3 次'), findsOneWidget);
    expect(find.byType(TrendChart), findsOneWidget);
    await t.tap(find.text('肌酐'));
    await t.pumpAndSettle();
    expect(find.byType(TrendChart), findsNWidgets(2));
    expect(find.text('2025-06-01'), findsOneWidget);
    await t.tap(find.text('2025-06-01'));
    expect(opened, [2]);
  });

  testWidgets('单点序列:不抛,画一个点,文案「只有这一次」', (t) async {
    await t.pumpWidget(_wrap(LabTrendRow(series: _series(pts: const [('2025-01-01', 90, 1)]), onOpenDoc: (_) {})));
    expect(t.takeException(), isNull);
    expect(find.text('只有这一次'), findsOneWidget);
    expect(find.byType(TrendChart), findsOneWidget);
  });

  testWidgets('全无日期:整行不画', (t) async {
    await t.pumpWidget(_wrap(LabTrendRow(series: _series(pts: const [(null, 90, 1)]), onOpenDoc: (_) {})));
    expect(find.text('肌酐'), findsNothing);
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:长名称 + 长单位展开不溢出', (t) async {
      await t.pumpWidget(_wrap(
        LabTrendRow(
          series: _series(name: '25-羟基维生素D(总)化学发光法', unit: 'ng/mL(换算自nmol/L)'),
          onOpenDoc: (_) {},
        ),
        scale: scale,
      ));
      await t.tap(find.byType(InkWell).first);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }

  test('trendSearch:名字子串、大小写不敏感、空串原样', () {
    final all = [_series(name: '肌酐'), _series(name: 'INR'), _series(name: '血肌酐')];
    expect(trendSearch(all, '肌酐').map((s) => s.name), ['肌酐', '血肌酐']);
    expect(trendSearch(all, 'inr').map((s) => s.name), ['INR']);
    expect(trendSearch(all, '  ').length, 3);
  });
}
