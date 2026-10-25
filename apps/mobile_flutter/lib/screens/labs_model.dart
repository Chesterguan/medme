// 「化验 · 按指标」的纯函数(修订 2):分类 chip 分组、12 个月窗。不碰 FFI、不碰 widget。
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 分类 chip(修订 2 定的八颗);`kAllGroup` = 全部。
const String kAllGroup = '全部';
const List<String> kLabGroups = ['血常规', '血糖', '电解质', '凝血', '肝肾', '感染', '其他'];

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
/// 全部点都没有日期 → 两边都不进(画不出来,也不算「更早」)。
({List<TrendSeriesDto> recent, List<TrendSeriesDto> earlier}) trendRecentSplit(
  List<TrendSeriesDto> all, {
  required DateTime today,
  int recentDays = 365,
}) {
  final cutoff = DateTime(today.year, today.month, today.day).subtract(Duration(days: recentDays));
  final recent = <TrendSeriesDto>[];
  final earlier = <TrendSeriesDto>[];
  for (final s in all) {
    final pts = trendDatedPoints(s);
    if (pts.isEmpty) continue;
    final last = DateTime.tryParse(pts.last.date!);
    if (last == null) continue;
    (last.isBefore(cutoff) ? earlier : recent).add(s);
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
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return out;
}

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
