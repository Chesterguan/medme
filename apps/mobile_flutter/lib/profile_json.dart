// 通用视图 / 用药视图 JSON 的几个小工具(健康摘要、用药页共用)。
List<Map<String, dynamic>> asMapList(dynamic v) =>
    (v as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

/// 族卡里「最近的用药」那一行要列的药名:`med_table.rows` 里 180 天内有记录、
/// 原文没写停、且 ATC 落在这个族的。
List<String> recentMedNamesOfFamily(List<Map<String, dynamic>> medRows, String family) => [
  for (final r in medRows)
    if (r['stale'] != true && r['stopped'] == null && r['family'] == family) '${r['name']}',
];
