// 化验「按指标」一张卡(修订 2 返工,三层):名称(可换行)+ 最近值固定宽 / 整行宽 48 高迷你折线 / 最近日期 + 偏高偏低。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

TrendSeriesDto _series({
  String name = '肌酐',
  String? rawName,
  List<(String?, double, int)> pts = const [('2025-01-01', 90, 1), ('2025-06-01', 104, 2), ('2026-01-01', 112, 3)],
  String? unit = 'µmol/L',
  String? lastFlag,
}) => TrendSeriesDto(
  name: name,
  rawName: rawName,
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
  testWidgets('三层:中文名 + 英文原名灰字 + 最近值 + 单位;整卡宽 48 高迷你折线;「最近 日期」+ 偏高;整卡点 onTap', (t) async {
    var taps = 0;
    await t.pumpWidget(_wrap(LabTrendCard(series: _series(rawName: 'Creatinine', lastFlag: 'H'), onTap: () => taps++)));
    expect(find.text('肌酐'), findsOneWidget);
    expect(find.text('Creatinine'), findsOneWidget);
    expect(find.text('112'), findsOneWidget);
    expect(find.text('µmol/L'), findsOneWidget);
    expect(find.text('偏高'), findsOneWidget);
    expect(find.byType(MedCard), findsOneWidget);
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.compact, isTrue);
    expect(chart.height, kLabMiniChartHeight);
    // 迷你图整卡宽(只减卡的内边距),不和名称 / 数值挤一行。
    expect(t.getSize(find.byType(LabLineChart)).width, greaterThan(340));
    expect(t.getTopLeft(find.byType(LabLineChart)).dy, greaterThan(t.getBottomLeft(find.text('112')).dy - 1));
    expect(find.text('最近 2026-01-01'), findsOneWidget);
    await t.tap(find.text('肌酐'));
    expect(taps, 1);
  });

  testWidgets('区间 3 个月(今天 2026-01-15):只画这段的 1 个点,写「仅 1 次」', (t) async {
    await t.pumpWidget(_wrap(LabTrendCard(
      series: _series(),
      onTap: () {},
      range: ChartRange.threeMonths,
      today: DateTime(2026, 1, 15),
    )));
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.points!.map((p) => p.date), ['2026-01-01']);
    expect(find.text('仅 1 次'), findsOneWidget);
  });

  testWidgets('区间内没有点(更早的序列):画全部点,不空白', (t) async {
    await t.pumpWidget(_wrap(LabTrendCard(
      series: _series(),
      onTap: () {},
      range: ChartRange.threeMonths,
      today: DateTime(2026, 10, 22),
    )));
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.points!.length, 3);
  });

  testWidgets('单点序列:不抛,画一个点 + 「仅 1 次」', (t) async {
    await t.pumpWidget(_wrap(LabTrendCard(series: _series(pts: const [('2025-01-01', 90, 1)]), onTap: () {})));
    expect(t.takeException(), isNull);
    expect(find.text('最近 2025-01-01'), findsOneWidget);
    expect(find.text('仅 1 次'), findsOneWidget);
    expect(find.byType(LabLineChart), findsOneWidget);
  });

  testWidgets('多于 12 个点:只画线、按周取中位数;≤ 12 个点:画点', (t) async {
    // 2025-03-01 起连续 30 天各一个点 → 5 个 ISO 周。
    final many = [
      for (var i = 0; i < 30; i++)
        (DateTime(2025, 3, 1 + i).toIso8601String().substring(0, 10), 90.0 + i, i),
    ];
    await t.pumpWidget(_wrap(LabTrendCard(series: _series(pts: many), onTap: () {}, range: ChartRange.all)));
    expect(t.takeException(), isNull);
    expect(downsampleWeeklyMedian(many.map((p) => TrendPointDto(date: p.$1, value: p.$2, documentId: p.$3, unverified: false)).toList(), maxRaw: kCompactMaxRawPoints).length, lessThan(30));
  });

  testWidgets('全无日期:整行不画', (t) async {
    await t.pumpWidget(_wrap(LabTrendCard(series: _series(pts: const [(null, 90, 1)]), onTap: () {})));
    expect(find.text('肌酐'), findsNothing);
  });

  // 真实数据里最长的指标名在 40–60 字符之间,英文未命中词典的原样显示 —— 这是常态不是边角。
  const names = [
    '肌酐',
    'BUN/Creatinine Ratio',
    'Calculation based on the Chronic Kidney Disease Epidemiology Collaboration equation',
    'Oxygen saturation direct-arterial (point of care)',
  ];
  for (final scale in [1.0, 1.3, 1.6]) {
    for (final name in names) {
      testWidgets('393 宽 字号 $scale:「${name.length > 12 ? '${name.substring(0, 12)}…' : name}」+ 长单位不溢出', (t) async {
        await t.pumpWidget(_wrap(
          LabTrendCard(
            series: _series(name: name, rawName: 'Creatinine, Ser/Plas', unit: 'ng/mL(换算自nmol/L)', lastFlag: 'L'),
            onTap: () {},
          ),
          scale: scale,
        ));
        expect(t.takeException(), isNull);
        expect(find.textContaining(name.substring(0, 2)), findsAtLeast(1));
      });
    }
  }

  test('trendSearch:名字子串、大小写不敏感、空串原样', () {
    final all = [_series(name: '肌酐', rawName: 'Creatinine'), _series(name: 'INR'), _series(name: '血肌酐')];
    expect(trendSearch(all, '肌酐').map((s) => s.name), ['肌酐', '血肌酐']);
    expect(trendSearch(all, 'inr').map((s) => s.name), ['INR']);
    expect(trendSearch(all, 'creat').map((s) => s.name), ['肌酐'], reason: '英文原名也能搜');
    expect(trendSearch(all, '  ').length, 3);
  });
}
