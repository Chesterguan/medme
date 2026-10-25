// 「化验 · 按指标」的纯函数(修订 2 返工):分类 chip 分组、全局时间区间、关键 / 其他 / 更早三层。
// 不碰 FFI、不碰 widget。
import 'package:mobile_flutter/profile_json.dart' show asMapList;
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart' show labStatusOf;
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 分类 chip(修订 2 定的八颗);`kAllGroup` = 全部。
const String kAllGroup = '全部';
const List<String> kLabGroups = ['血常规', '血糖', '电解质', '凝血', '肝肾', '感染', '其他'];

/// 通用的关键指标(实施者的决定:医生扫一眼先看的那十来项);再加上用户有诊断的族的化验表
/// key(ADR 0012 `LAB_KEYS`,如心血管族的 INR / BNP、感染族的伏立康唑浓度 / 半乳甘露聚糖)。
const List<String> kKeyLabKeys = [
  'creatinine', 'egfr', 'potassium', 'sodium', 'hgb', 'wbc', 'plt', 'glucose', 'hba1c', 'alt', 'crp', 'inr',
];

/// 词典大类 → chip 分组。肝功能 / 肾功能 并成「肝肾」,炎症/感染 → 「感染」,其余(含认不出的、
/// 自测、血脂、甲状腺…)→ 「其他」。
String labGroupOf(TrendSeriesDto s) => switch (s.panel) {
  '血常规' => '血常规',
  '血糖' => '血糖',
  '电解质' => '电解质',
  '凝血' => '凝血',
  '肝功能' || '肾功能' => '肝肾',
  '炎症/感染' => '感染',
  _ => '其他',
};

/// 最近 / 更早:序列**最近有日期的点**在 `today − recentDays` 之内 → recent;更早 → earlier;
/// `recentDays == null`(全部)→ 都算 recent;全部点都没有日期 → 两边都不进(画不出来,也不算「更早」)。
({List<TrendSeriesDto> recent, List<TrendSeriesDto> earlier}) trendRecentSplit(
  List<TrendSeriesDto> all, {
  required DateTime today,
  int? recentDays = 365,
}) {
  final cutoff = recentDays == null
      ? null
      : DateTime(today.year, today.month, today.day).subtract(Duration(days: recentDays));
  final recent = <TrendSeriesDto>[];
  final earlier = <TrendSeriesDto>[];
  for (final s in all) {
    final pts = trendDatedPoints(s);
    if (pts.isEmpty) continue;
    final last = DateTime.tryParse(pts.last.date!);
    if (last == null) continue;
    (cutoff != null && last.isBefore(cutoff) ? earlier : recent).add(s);
  }
  return (recent: recent, earlier: earlier);
}

/// 按最近一次结果日期倒序(同日按名字)。
List<TrendSeriesDto> sortByLatest(List<TrendSeriesDto> list) {
  // 最近日期各算一次,不在比较器里反复排点(几百条序列 × 几百个点)。
  final latest = <TrendSeriesDto, String>{
    for (final s in list) s: trendDatedPoints(s).lastOrNull?.date ?? '',
  };
  final out = [...list];
  out.sort((a, b) {
    final c = latest[b]!.compareTo(latest[a]!);
    if (c != 0) return c;
    // 同一天:词典认得的中文名在前,没命中词典的英文原名在后。
    final za = _startsCjk(a.name) ? 0 : 1;
    final zb = _startsCjk(b.name) ? 0 : 1;
    return za != zb ? za - zb : a.name.compareTo(b.name);
  });
  return out;
}

bool _startsCjk(String s) => s.isNotEmpty && s.codeUnitAt(0) >= 0x3400;

/// chip + 搜索一起筛。
List<TrendSeriesDto> labsVisible(List<TrendSeriesDto> all, {required String group, required String query}) {
  final q = query.trim().toLowerCase();
  return [
    for (final s in all)
      if ((group == kAllGroup || labGroupOf(s) == group) && (q.isEmpty || s.name.toLowerCase().contains(q))) s,
  ];
}

/// 每颗 chip 的计数(0 的不画,只剩「全部」整排不画 —— 与病历页同规矩)。
List<({String group, int count})> labGroupChips(List<TrendSeriesDto> all) {
  final counts = <String, int>{for (final g in kLabGroups) g: 0};
  for (final s in all) {
    counts[labGroupOf(s)] = counts[labGroupOf(s)]! + 1;
  }
  return [
    (group: kAllGroup, count: all.length),
    for (final g in kLabGroups)
      if (counts[g]! > 0) (group: g, count: counts[g]!),
  ];
}

/// 最近一次结果偏高 / 偏低。
bool labLatestAbnormal(TrendSeriesDto s) {
  final pts = trendDatedPoints(s);
  return pts.isNotEmpty && labStatusOf(pts.last.flag) != null;
}

/// 通用视图里用户有诊断的族(最近与更早都算)。
Set<String> diagnosedFamiliesOf(Map<String, dynamic> view) {
  for (final s in asMapList(view['sections'])) {
    if (s['kind'] != 'family_cards' || (s['package_id'] ?? 'general') != 'general') continue;
    final body = s['body'] as Map? ?? const {};
    return {
      for (final f in [...asMapList(body['families']), ...asMapList(body['earlier_families'])]) '${f['key']}',
    };
  }
  return const {};
}

/// `vault_profile_lab_families` 的 JSON → 族 key → 化验 key 列表。
Map<String, List<String>> familyLabKeysOf(Map<String, dynamic> table) => {
  for (final f in asMapList(table['families'])) '${f['key']}': [for (final k in (f['keys'] as List? ?? const [])) '$k'],
};

/// 关键指标的 key 集合:通用关键项 + 有诊断的族的化验表 key。
Set<String> keyLabKeys({required Set<String> diagnosedFamilies, required Map<String, List<String>> familyLabKeys}) => {
  ...kKeyLabKeys,
  for (final f in diagnosedFamilies) ...?familyLabKeys[f],
};

typedef LabTiers = ({List<TrendSeriesDto> key, List<TrendSeriesDto> other, List<TrendSeriesDto> earlier});

/// 三层:关键指标 / 其他指标(折叠)/ 更早(超过区间没结果,折叠)。各层按最近结果倒序。
LabTiers labTiers(
  List<TrendSeriesDto> all, {
  required DateTime today,
  required int? recentDays,
  required Set<String> keyKeys,
  bool abnormalOnly = false,
}) {
  final split = trendRecentSplit(all, today: today, recentDays: recentDays);
  bool keep(TrendSeriesDto s) => !abnormalOnly || labLatestAbnormal(s);
  final recent = split.recent.where(keep).toList();
  return (
    key: sortByLatest([for (final s in recent) if (keyKeys.contains(s.analyteKey)) s]),
    other: sortByLatest([for (final s in recent) if (!keyKeys.contains(s.analyteKey)) s]),
    earlier: sortByLatest(split.earlier.where(keep).toList()),
  );
}
