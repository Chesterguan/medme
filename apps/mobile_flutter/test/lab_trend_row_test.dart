// 化验「按指标」一行(修订 2 返工,三层):名称 + 最近值 / 整行宽迷你折线 + 两端年月 / 最近日期。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';

TrendSeriesDto _series({
  String name = '肌酐',
  List<(String?, double, int)> pts = const [('2025-01-01', 90, 1), ('2025-06-01', 104, 2), ('2026-01-01', 112, 3)],
  String? unit = 'µmol/L',
  String? lastFlag,
}) => TrendSeriesDto(
  name: name,
  analyteKey: 'creatinine',
  unit: unit,
  refLow: 44,
  refHigh: 133,
  valuesConverted: false,
  anyAbnormal: lastFlag != null,
  panel: '肾功能',
  points: [
    for (final (i, (d, v, id)) in pts.indexed)
      TrendPointDto(date: d, value: v, unit: unit, flag: i == pts.length - 1 ? lastFlag : null, documentId: id, unverified: false),
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
  testWidgets('三层:名称 + 最近值 + 单位;整行宽迷你折线 + 两端年月;「最近 日期」;整行点 onTap', (t) async {
    var taps = 0;
    await t.pumpWidget(_wrap(LabTrendRow(series: _series(lastFlag: 'H'), onTap: () => taps++)));
    expect(find.text('肌酐'), findsOneWidget);
    expect(find.text('112'), findsOneWidget);
    expect(find.text('µmol/L'), findsOneWidget);
    expect(find.text('偏高'), findsOneWidget);
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.compact, isTrue);
    expect(chart.height, 36);
    // 迷你图整行宽:和这一行一样宽(减去无 padding)。
    expect(t.getSize(find.byType(LabLineChart)).width, 393);
    expect(find.text('2025-01'), findsOneWidget);
    expect(find.text('2026-01'), findsOneWidget);
    expect(find.text('最近 2026-01-01'), findsOneWidget);
    await t.tap(find.text('肌酐'));
    expect(taps, 1);
  });

  testWidgets('区间 3 个月(今天 2026-01-15):只画这段的点,只剩一个年月标签', (t) async {
    await t.pumpWidget(_wrap(LabTrendRow(
      series: _series(),
      onTap: () {},
      range: ChartRange.threeMonths,
      today: DateTime(2026, 1, 15),
    )));
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.points!.map((p) => p.date), ['2026-01-01']);
    expect(find.text('2026-01'), findsOneWidget);
    expect(find.text('2025-01'), findsNothing);
  });

  testWidgets('区间内没有点(更早的序列):画全部点,不空白', (t) async {
    await t.pumpWidget(_wrap(LabTrendRow(
      series: _series(),
      onTap: () {},
      range: ChartRange.threeMonths,
      today: DateTime(2026, 10, 22),
    )));
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.points!.length, 3);
  });

  testWidgets('单点序列:不抛,画一个点', (t) async {
    await t.pumpWidget(_wrap(LabTrendRow(series: _series(pts: const [('2025-01-01', 90, 1)]), onTap: () {})));
    expect(t.takeException(), isNull);
    expect(find.text('最近 2025-01-01'), findsOneWidget);
    expect(find.byType(LabLineChart), findsOneWidget);
  });

  testWidgets('全无日期:整行不画', (t) async {
    await t.pumpWidget(_wrap(LabTrendRow(series: _series(pts: const [(null, 90, 1)]), onTap: () {})));
    expect(find.text('肌酐'), findsNothing);
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:长名称 + 长单位不溢出', (t) async {
      await t.pumpWidget(_wrap(
        LabTrendRow(
          series: _series(name: '25-羟基维生素D(总)化学发光法', unit: 'ng/mL(换算自nmol/L)'),
          onTap: () {},
        ),
        scale: scale,
      ));
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
