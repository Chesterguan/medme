// 「用药」页的纯函数(2026-10-23 spec §5;修订 2 返工 2026-10-25:按药类分组、按时间区间重切)。
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;

/// 族 key → 中文(与 Rust `generic_tables::FAMILIES` 同一份词)。
const Map<String, String> kFamilyLabel = {
  'cardio': '心血管', 'infection': '感染', 'respiratory': '呼吸', 'renal': '肾',
  'endocrine': '内分泌', 'immune': '免疫', 'neuro': '神经', 'digestive': '消化',
  'oncology': '肿瘤', 'blood': '血液', 'musculoskeletal': '骨骼肌肉', 'other': '其他',
  'uncoded': '未归类',
};

/// 药类(按 ATC 一级 / 二级码分;词典认不出的药没有 ATC → 「其他」)。顺序即页面顺序。
const List<String> kMedClassOrder = ['抗感染', '心血管', '抗凝', '电解质 / 营养', '其他'];

String medClassOf(String? atc) {
  final a = (atc ?? '').toUpperCase();
  if (a.isEmpty) return '其他';
  if (a.startsWith('B01')) return '抗凝';
  if (a.startsWith('J') || a.startsWith('P')) return '抗感染';
  if (a.startsWith('C')) return '心血管';
  if (a.startsWith('A11') || a.startsWith('A12') || a.startsWith('B03') || a.startsWith('B05')) return '电解质 / 营养';
  return '其他';
}

/// 搜索命中:查询串(大小写不敏感)是药名、词典名或任一原文写法的子串。
bool medMatches(Map<String, dynamic> row, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final names = <String>[
    '${row['name'] ?? ''}',
    '${row['raw_name'] ?? ''}',
    for (final n in (row['raw_names'] as List? ?? const [])) '$n',
  ];
  return names.any((n) => n.toLowerCase().contains(q));
}

/// 族筛选:`family` 为空 → 全部。
List<Map<String, dynamic>> medsByFamily(List<Map<String, dynamic>> rows, String? family) =>
    family == null ? rows : rows.where((r) => r['family'] == family).toList();

/// 过敏行的搜索:物质、反应或任一原文写法含查询串。
bool allergyMatches(Map<String, dynamic> a, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return '${a['substance'] ?? ''}'.toLowerCase().contains(q) ||
      '${a['reaction'] ?? ''}'.toLowerCase().contains(q) ||
      (a['aliases'] as List? ?? const []).any((x) => '$x'.toLowerCase().contains(q));
}

/// 最近 / 更早(checkpoint 1 F11):时间区间决定看哪一段;「最近」= 区间内、原文没写停、且最后一次
/// 记录距今 ≤ 180 天(Rust 的 `stale`);区间内但超过 180 天没新记录的归「更早」。无日期的进更早。
({List<Map<String, dynamic>> recent, List<Map<String, dynamic>> earlier}) medsSplit(
  List<Map<String, dynamic>> all, {
  required DateTime today,
  required int? recentDays,
}) {
  final cutoff = recentDays == null ? null : DateTime(today.year, today.month, today.day).subtract(Duration(days: recentDays));
  final recent = <Map<String, dynamic>>[];
  final earlier = <Map<String, dynamic>>[];
  for (final r in all) {
    final last = DateTime.tryParse('${r['last_seen'] ?? ''}');
    final within = last != null && (cutoff == null || !last.isBefore(cutoff));
    (r['stopped'] == null && within && r['stale'] != true ? recent : earlier).add(r);
  }
  return (recent: recent, earlier: earlier);
}

/// 按药类分组,类按 `kMedClassOrder`,类内按最近记录倒序(无日期最后,再按名字)。
List<({String label, List<Map<String, dynamic>> rows})> medsByClass(List<Map<String, dynamic>> rows) {
  final sorted = [...rows]..sort((a, b) {
    final la = '${a['last_seen'] ?? ''}';
    final lb = '${b['last_seen'] ?? ''}';
    if (la.isEmpty != lb.isEmpty) return la.isEmpty ? 1 : -1;
    final c = lb.compareTo(la);
    return c != 0 ? c : '${a['name']}'.compareTo('${b['name']}');
  });
  return [
    for (final cls in kMedClassOrder)
      if (sorted.any((r) => medClassOf(r['atc'] as String?) == cls))
        (label: cls, rows: sorted.where((r) => medClassOf(r['atc'] as String?) == cls).toList()),
  ];
}

/// 更早的药一行的小字:「2024-11-16 → 2025-03-19 · 12 次记录」。
String medEarlierLine(Map<String, dynamic> row) {
  final first = fmtDate(row['first_seen'] as String?);
  final last = fmtDate(row['last_seen'] as String?);
  final n = (row['mention_count'] as num?)?.toInt();
  final stopped = row['stopped'];
  return [
    if (first.isNotEmpty && last.isNotEmpty) first == last ? first : '$first → $last',
    if (n != null) '$n 次记录',
    if (stopped is Map) '病历写了停药 ${fmtDate(stopped['at'] as String?)}',
  ].join(' · ');
}

/// 剂量链节点的一句话:`first` → 「记录中自此起 X」;`change` → 「A → B」;`stopped` → 「病历写了停药」+ 原文。
String medNodeText(Map<String, dynamic> n) {
  final to = '${n['to'] ?? ''}';
  final from = n['from'] as String?;
  final text = n['text'] as String?;
  return switch (n['kind']) {
    'change' => '${from ?? '?'} → $to',
    'stopped' => text == null || text.isEmpty ? '病历写了停药' : '病历写了停药「$text」',
    _ => '记录中自此起 $to',
  };
}
