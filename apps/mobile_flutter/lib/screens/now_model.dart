// 「现在」页的纯函数(2026-10-23 spec §4):化验按族归类、12 个月窗。不碰 FFI、不碰 widget,
// 好测。
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 化验「key → 族」表(`vault_profile_lab_families` 下发的 JSON):族顺序、每族的 key、
/// 词典大类 → 族(`common` = 血常规/电解质/肝功能/尿液 那一排),以及 12 个月窗的天数。
class LabFamilies {
  LabFamilies({
    required this.recentDays,
    required this.families,
    required this.panelFamily,
  });

  factory LabFamilies.fromJson(Map<String, dynamic> json) {
    final fams = <({String key, String label, List<String> keys})>[];
    for (final f in (json['families'] as List? ?? const [])) {
      if (f is! Map) continue;
      fams.add((
        key: '${f['key']}',
        label: '${f['label']}',
        keys: (f['keys'] as List? ?? const []).map((k) => '$k').toList(),
      ));
    }
    final pf = <String, String>{
      for (final e in (json['panel_family'] as Map? ?? const {}).entries) '${e.key}': '${e.value}',
    };
    return LabFamilies(
      recentDays: (json['recent_days'] as num?)?.toInt() ?? 365,
      families: fams,
      panelFamily: pf,
    );
  }

  /// 没拿到表(FFI 失败)时的兜底:所有化验都进「其他化验」。
  factory LabFamilies.empty() => LabFamilies(recentDays: 365, families: const [], panelFamily: const {});

  final int recentDays;
  final List<({String key, String label, List<String> keys})> families;
  final Map<String, String> panelFamily;

  /// 一条序列归到哪些族:先按覆盖表的 key(可多族,如肌酐在心血管与肾),没有再按词典
  /// 大类;大类是通用一排 → `['common']`;都没有 → `['other']`。
  List<String> familiesOfSeries(TrendSeriesDto s) {
    final key = s.analyteKey;
    final out = <String>[];
    if (key != null) {
      for (final f in families) {
        if (f.keys.contains(key)) out.add(f.key);
      }
    }
    if (out.isNotEmpty) return out;
    final byPanel = s.panel == null ? null : panelFamily[s.panel!];
    if (byPanel != null) return [byPanel];
    return const ['other'];
  }
}

/// 最近 / 更早:序列**最近有日期的点**在 `today − recentDays` 之内 → recent;更早 → earlier;
/// 全部点都没有日期 → 两边都不进(画不出来,也不算「更早」)。
({List<TrendSeriesDto> recent, List<TrendSeriesDto> earlier}) trendRecentSplit(
  List<TrendSeriesDto> all, {
  required DateTime today,
  required int recentDays,
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

/// 「现在」族卡里「最近的用药」那一行要列的药名:`med_table.rows` 里 180 天内有记录、
/// 原文没写停、且 ATC 落在这个族的。
List<String> recentMedNamesOfFamily(List<Map<String, dynamic>> medRows, String family) => [
  for (final r in medRows)
    if (r['stale'] != true && r['stopped'] == null && r['family'] == family) '${r['name']}',
];

List<Map<String, dynamic>> asMapList(dynamic v) =>
    (v as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
