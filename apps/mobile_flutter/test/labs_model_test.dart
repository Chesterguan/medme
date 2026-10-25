import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/labs_model.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';

TrendSeriesDto _s(String name, {String? panel, String? key, List<String?> dates = const ['2026-01-01'], String? lastFlag}) => TrendSeriesDto(
  name: name,
  analyteKey: key ?? name,
  panel: panel,
  valuesConverted: false,
  anyAbnormal: lastFlag != null,
  points: [
    for (final (i, d) in dates.indexed)
      TrendPointDto(date: d, value: 1, flag: i == dates.length - 1 ? lastFlag : null, documentId: 1, unverified: false),
  ],
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

  test('trendRecentSplit:364 天进、366 天出、全无日期两边都不进;recentDays null = 全部进', () {
    final today = DateTime(2026, 10, 22);
    final all = [
      _s('a', dates: ['2025-10-23']),
      _s('b', dates: ['2025-10-21']),
      _s('c', dates: [null]),
    ];
    final r = trendRecentSplit(all, today: today);
    expect(r.recent.map((s) => s.name), ['a']);
    expect(r.earlier.map((s) => s.name), ['b']);
    final all91 = trendRecentSplit(all, today: today, recentDays: 91);
    expect(all91.recent, isEmpty);
    expect(all91.earlier.length, 2);
    final every = trendRecentSplit(all, today: today, recentDays: null);
    expect(every.recent.length, 2);
    expect(every.earlier, isEmpty);
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

  test('keyLabKeys:通用关键项 + 有诊断的族的化验表 key;diagnosedFamiliesOf 读两段', () {
    final view = {
      'sections': [
        {
          'kind': 'family_cards', 'package_id': 'general',
          'body': {
            'families': [{'key': 'cardio'}],
            'earlier_families': [{'key': 'infection'}],
          },
        },
      ],
    };
    expect(diagnosedFamiliesOf(view), {'cardio', 'infection'});
    final table = familyLabKeysOf({
      'families': [
        {'key': 'cardio', 'label': '心血管', 'keys': ['bnp', 'inr']},
        {'key': 'infection', 'label': '感染', 'keys': ['voriconazole_level']},
        {'key': 'renal', 'label': '肾', 'keys': ['egfr', 'urine_acr']},
      ],
    });
    final keys = keyLabKeys(diagnosedFamilies: diagnosedFamiliesOf(view), familyLabKeys: table);
    expect(keys, containsAll(['creatinine', 'hgb', 'bnp', 'voriconazole_level']));
    expect(keys, isNot(contains('urine_acr')), reason: '没有肾病诊断,肾族的表不进关键指标');
  });

  test('labTiers:关键 / 其他 / 更早三层;只看异常只留最近值偏高偏低的', () {
    final today = DateTime(2026, 10, 22);
    final all = [
      _s('肌酐', key: 'creatinine', dates: ['2026-10-01'], lastFlag: 'H'),
      _s('MCH', key: 'mch', dates: ['2026-09-01']),
      _s('MPV', key: 'mpv', dates: ['2026-09-02'], lastFlag: 'L'),
      _s('LDH', key: 'ldh', dates: ['2024-01-01']),
      _s('伏立康唑浓度', key: 'voriconazole_level', dates: ['2026-08-01']),
    ];
    final keys = {'creatinine', 'voriconazole_level'};
    final t = labTiers(all, today: today, recentDays: 365, keyKeys: keys);
    expect(t.key.map((s) => s.name), ['肌酐', '伏立康唑浓度']);
    expect(t.other.map((s) => s.name), ['MPV', 'MCH']);
    expect(t.earlier.map((s) => s.name), ['LDH']);
    final ab = labTiers(all, today: today, recentDays: 365, keyKeys: keys, abnormalOnly: true);
    expect(ab.key.map((s) => s.name), ['肌酐']);
    expect(ab.other.map((s) => s.name), ['MPV']);
    expect(ab.earlier, isEmpty);
    final three = labTiers(all, today: today, recentDays: 60, keyKeys: keys);
    expect(three.key.map((s) => s.name), ['肌酐']);
    expect(three.earlier.map((s) => s.name), ['伏立康唑浓度', 'LDH'], reason: '60 天外的进更早,按最近倒序');
    expect(labLatestAbnormal(all[0]), isTrue);
    expect(labLatestAbnormal(all[1]), isFalse);
  });
}
