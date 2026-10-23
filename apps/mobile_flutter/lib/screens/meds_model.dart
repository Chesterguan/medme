// 「用药」页的纯函数(2026-10-23 spec §5)。
/// 族 key → 中文(与 Rust `generic_tables::FAMILIES` 同一份词)。
const Map<String, String> kFamilyLabel = {
  'cardio': '心血管', 'infection': '感染', 'respiratory': '呼吸', 'renal': '肾',
  'endocrine': '内分泌', 'immune': '免疫', 'neuro': '神经', 'digestive': '消化',
  'oncology': '肿瘤', 'blood': '血液', 'musculoskeletal': '骨骼肌肉', 'other': '其他',
  'uncoded': '未归类',
};

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

/// 过敏行的搜索:物质或反应含查询串。
bool allergyMatches(Map<String, dynamic> a, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return '${a['substance'] ?? ''}'.toLowerCase().contains(q) ||
      '${a['reaction'] ?? ''}'.toLowerCase().contains(q);
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
