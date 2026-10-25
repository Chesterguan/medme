import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';

TrendPointDto _p(String date, double v, {String? flag}) =>
    TrendPointDto(date: date, value: v, unit: 'u', flag: flag, documentId: 1, unverified: false);

TrendSeriesDto _s(List<TrendPointDto> pts, {double? lo, double? hi}) => TrendSeriesDto(
  name: '肌酐', analyteKey: 'creatinine', unit: 'u', refLow: lo, refHigh: hi,
  valuesConverted: false, anyAbnormal: false, points: pts, selfMeasured: false,
);

void main() {
  test('cleanUnit:占位单位不显示,正常单位原样', () {
    expect(cleanUnit('(CALC)'), isNull);
    expect(cleanUnit('(CALC'), isNull);
    expect(cleanUnit('Detected)'), isNull);
    expect(cleanUnit('1'), isNull);
    expect(cleanUnit(''), isNull);
    expect(cleanUnit('pg/mL (ng/L)'), 'pg/mL (ng/L)');
    expect(cleanUnit('mg/dL'), 'mg/dL');
  });

  test('pointsInRange:相对最近一个点;3 个月 / 1 年 / 全部', () {
    final pts = [_p('2024-01-10', 1), _p('2025-09-01', 2), _p('2026-08-20', 3), _p('2026-10-01', 4)];
    expect(pointsInRange(pts, ChartRange.threeMonths).length, 2);
    expect(pointsInRange(pts, ChartRange.oneYear).length, 2);
    expect(pointsInRange(pts, ChartRange.all).length, 4);
  });

  test('downsampleWeeklyMedian:≤60 点原样;>60 点按周中位数,异常 flag 保留', () {
    final few = [for (var i = 0; i < 10; i++) _p('2026-01-${(i + 1).toString().padLeft(2, '0')}', i.toDouble())];
    expect(downsampleWeeklyMedian(few).length, 10);
    // 同一周 7 天、3 周 × 7 + 其它 = 100 个点
    final many = <TrendPointDto>[];
    var d = DateTime(2026, 1, 5); // 周一
    for (var i = 0; i < 100; i++) {
      many.add(_p('${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}', (i % 7).toDouble(), flag: i == 99 ? 'H' : null));
      d = d.add(const Duration(days: 1));
    }
    final ds = downsampleWeeklyMedian(many);
    expect(ds.length, lessThanOrEqualTo(16));
    expect(ds.first.value, 3, reason: '0..6 的中位数');
    expect(ds.last.flag, 'H');
  });

  test('niceStep / fmtTick', () {
    expect(niceStep(100, 4), 20);
    expect(niceStep(7, 4), 2);
    expect(fmtTick(2), '2');
    expect(fmtTick(2.5), '2.5');
  });

  testWidgets('画得出:完整版与迷你版都不抛,单点也不抛', (t) async {
    final pts = [for (var i = 0; i < 80; i++) _p('2026-${(i ~/ 28 + 1).toString().padLeft(2, '0')}-${(i % 28 + 1).toString().padLeft(2, '0')}', 90 + (i % 5).toDouble())];
    await t.pumpWidget(MaterialApp(theme: MedMe.theme(), home: Scaffold(body: Column(children: [
      LabLineChart(series: _s(pts, lo: 44, hi: 133), height: 200),
      SizedBox(width: 78, height: 24, child: LabLineChart(series: _s(pts, lo: 44, hi: 133), height: 24, compact: true)),
      LabLineChart(series: _s([_p('2026-01-01', 5)]), height: 120),
    ]))));
    expect(t.takeException(), isNull);
    expect(find.byType(CustomPaint), findsAtLeast(3));
  });
}
