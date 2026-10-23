import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/now_model.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';

TrendSeriesDto _s({String? key, String? panel, List<String?> dates = const ['2026-01-01']}) => TrendSeriesDto(
  name: key ?? 'x',
  analyteKey: key,
  panel: panel,
  valuesConverted: false,
  anyAbnormal: false,
  points: [for (final d in dates) TrendPointDto(date: d, value: 1, documentId: 1, unverified: false)],
  selfMeasured: false,
);

final _fam = LabFamilies.fromJson({
  'recent_days': 365,
  'families': [
    {'key': 'cardio', 'label': '心血管', 'keys': ['inr', 'creatinine']},
    {'key': 'renal', 'label': '肾', 'keys': ['creatinine', 'egfr']},
    {'key': 'other', 'label': '其他', 'keys': []},
  ],
  'panel_family': {'血常规': 'common', '肾功能': 'renal'},
});

void main() {
  test('familiesOfSeries:覆盖表可多族;大类兜底;通用一排;都没有 → other', () {
    expect(_fam.familiesOfSeries(_s(key: 'inr')), ['cardio']);
    expect(_fam.familiesOfSeries(_s(key: 'creatinine')), ['cardio', 'renal']);
    expect(_fam.familiesOfSeries(_s(key: 'hemoglobin', panel: '血常规')), ['common']);
    expect(_fam.familiesOfSeries(_s(key: 'uric_acid', panel: '肾功能')), ['renal']);
    expect(_fam.familiesOfSeries(_s(key: null, panel: null)), ['other']);
    expect(_fam.recentDays, 365);
    expect(LabFamilies.empty().familiesOfSeries(_s(key: 'inr')), ['other']);
  });

  test('trendRecentSplit:364 天进、366 天出、全无日期两边都不进;看的是最近有日期的点', () {
    final today = DateTime(2026, 10, 22);
    final r = trendRecentSplit([
      _s(key: 'a', dates: ['2025-10-23']), // 364 天
      _s(key: 'b', dates: ['2025-10-21']), // 366 天
      _s(key: 'c', dates: [null, null]),
      _s(key: 'd', dates: ['2020-01-01', '2026-10-01', null]),
    ], today: today, recentDays: 365);
    expect(r.recent.map((s) => s.name), ['a', 'd']);
    expect(r.earlier.map((s) => s.name), ['b']);
    // 刚好 365 天:进。
    final edge = trendRecentSplit([_s(key: 'e', dates: ['2025-10-22'])], today: today, recentDays: 365);
    expect(edge.recent.length, 1);
  });

  test('recentMedNamesOfFamily:180 天内、没写停、同族', () {
    final rows = [
      {'name': '华法林', 'family': 'cardio', 'stale': false},
      {'name': '美托洛尔', 'family': 'cardio', 'stale': true},
      {'name': '伏立康唑', 'family': 'infection', 'stale': false, 'stopped': {'at': '2025-11-17'}},
      {'name': '赖诺普利', 'family': 'cardio', 'stale': false},
    ];
    expect(recentMedNamesOfFamily(rows, 'cardio'), ['华法林', '赖诺普利']);
    expect(recentMedNamesOfFamily(rows, 'infection'), isEmpty);
  });
}
