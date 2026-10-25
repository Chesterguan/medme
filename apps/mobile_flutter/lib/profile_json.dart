// 通用视图 / 用药视图 JSON 的几个小工具(健康摘要、用药页共用)。
List<Map<String, dynamic>> asMapList(dynamic v) =>
    (v as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

/// 病历 tab 的一行概况(checkpoint 1 F4):最近 12 个月有诊断的族里各取最近一条诊断的写法,最多三条。
List<String> overviewDiagnoses(Map<String, dynamic> view, {int max = 3}) {
  for (final s in asMapList(view['sections'])) {
    if (s['kind'] != 'family_cards' || (s['package_id'] ?? 'general') != 'general') continue;
    final fams = asMapList((s['body'] as Map?)?['families'])
        .where((f) => f['key'] != 'other' && f['key'] != 'uncoded')
        .toList()
      ..sort((a, b) => '${b['last_seen'] ?? ''}'.compareTo('${a['last_seen'] ?? ''}'));
    final out = <String>[];
    for (final f in fams) {
      final dx = asMapList(f['diagnoses'])..sort((a, b) => '${b['last_seen'] ?? ''}'.compareTo('${a['last_seen'] ?? ''}'));
      final t = dx.isEmpty ? null : (dx.first['texts'] as List?)?.firstOrNull;
      if (t != null && '$t'.isNotEmpty) out.add('$t');
      if (out.length >= max) break;
    }
    return out;
  }
  return const [];
}

/// 族卡里「最近的用药」那一行要列的药名:`med_table.rows` 里 180 天内有记录、
/// 原文没写停、且 ATC 落在这个族的。
List<String> recentMedNamesOfFamily(List<Map<String, dynamic>> medRows, String family) => [
  for (final r in medRows)
    if (r['stale'] != true && r['stopped'] == null && r['family'] == family) '${r['name']}',
];
