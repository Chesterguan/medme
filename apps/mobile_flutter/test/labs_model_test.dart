import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/labs_model.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';

TrendSeriesDto _s(String name, {String? panel, String? key, List<String?> dates = const ['2026-01-01']}) => TrendSeriesDto(
  name: name,
  analyteKey: key ?? name,
  panel: panel,
  valuesConverted: false,
  anyAbnormal: false,
  points: [for (final d in dates) TrendPointDto(date: d, value: 1, documentId: 1, unverified: false)],
  selfMeasured: false,
);

void main() {
  test('labGroupOf:肝功能 / 肾功能 并成肝肾,炎症/感染 → 感染,其余 → 其他', () {
    expect(labGroupOf(_s('ALT', panel: '肝功能')), '肝肾');
    expect(labGroupOf(_s('肌酐', panel: '肾功能')), '肝肾');
    expect(labGroupOf(_s('CRP', panel: '炎症/感染')), '感染');
    expect(labGroupOf(_s('血红蛋白', panel: '血常规')), '血常规');
    expect(labGroupOf(_s('INR', panel: '凝血')), '凝血');
    expect(labGroupOf(_s('TSH', panel: '甲状腺功能')), '其他');
    expect(labGroupOf(_s('x', panel: null)), '其他');
  });

  test('trendRecentSplit:364 天进、366 天出、全无日期两边都不进', () {
    final today = DateTime(2026, 10, 22);
    final r = trendRecentSplit([
      _s('a', dates: ['2025-10-23']),
      _s('b', dates: ['2025-10-21']),
      _s('c', dates: [null]),
    ], today: today);
    expect(r.recent.map((s) => s.name), ['a']);
    expect(r.earlier.map((s) => s.name), ['b']);
  });

  test('labsVisible + sortByLatest + labGroupChips', () {
    final all = [
      _s('肌酐', panel: '肾功能', dates: ['2026-01-01']),
      _s('ALT', panel: '肝功能', dates: ['2026-03-01']),
      _s('血肌酐', panel: '肾功能', dates: ['2026-02-01']),
      _s('INR', panel: '凝血', dates: ['2026-04-01']),
    ];
    expect(labsVisible(all, group: '肝肾', query: '').map((s) => s.name), ['肌酐', 'ALT', '血肌酐']);
    expect(labsVisible(all, group: kAllGroup, query: '肌酐').map((s) => s.name), ['肌酐', '血肌酐']);
    expect(sortByLatest(all).map((s) => s.name), ['INR', 'ALT', '血肌酐', '肌酐']);
    final chips = labGroupChips(all);
    expect(chips.first, (group: '全部', count: 4));
    expect(chips.map((c) => c.group), ['全部', '凝血', '肝肾']);
  });
}
