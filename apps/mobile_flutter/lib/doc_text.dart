// 文档正文的几个纯函数(checkpoint 1 F6 / F7 / F10):折掉 Epic 每页重复的页眉、找「跳到」锚点、
// 按关键词找到要高亮的那一行。不碰 widget、不碰 FFI。

/// 折掉每页重复的页眉(F7):Epic 导出的 PDF 每页顶上都印医院名 / 地址 / 姓名 / MRN / Adm 那 6 行,
/// 还有「… (continued)」小节行。做法:首页保留,后面凡是**与前 6 个非空行之一逐字相同**的行、以及
/// 含「(continued)」的行都去掉。不按页眉模式硬编码医院名,换一家医院也适用。
String foldRepeatedHeaders(String text, {int headerLines = 6}) {
  final lines = text.split('\n');
  final header = <String>[];
  var i = 0;
  for (; i < lines.length && header.length < headerLines; i++) {
    final t = lines[i].trim();
    if (t.isNotEmpty) header.add(t);
  }
  final headerSet = header.toSet();
  final out = <String>[...lines.take(i)];
  final continued = RegExp(r'\(continued\)', caseSensitive: false);
  var lastBlank = false;
  for (final l in lines.skip(i)) {
    final t = l.trim();
    if (t.isNotEmpty && (headerSet.contains(t) || continued.hasMatch(t))) continue;
    // 折掉之后别留一串空行。
    if (t.isEmpty) {
      if (lastBlank) continue;
      lastBlank = true;
    } else {
      lastBlank = false;
    }
    out.add(l);
  }
  return out.join('\n');
}

/// 「跳到」锚点(F6):出院诊断 / 住院经过 / 出院用药 / 随访,中英文标题都认;返回出现的那些
/// (标签, 行号),按行号排。同一标签只取第一处。行内写法也认(Epic 的「Discharge Diagnoses: …」
/// 诊断就跟在同一行后面),只有「随访」要求是短标题行,免得命中正文里的 follow-up 句子。
List<({String label, int line})> docAnchors(String text) {
  final rules = <(String, RegExp, bool)>[
    ('出院诊断', RegExp(r'^\s*(discharge\s+diagnos\w*|final\s+diagnos\w*|出院诊断)\s*[::]?', caseSensitive: false), false),
    ('住院经过', RegExp(r'^\s*(brief\s+hospital\s+course|hospital\s+course|住院经过|诊疗经过|病程)\s*[::]?', caseSensitive: false), false),
    ('出院用药', RegExp(r'^\s*(discharge\s+medications?|medications?\s+at\s+discharge|出院带药|出院用药|出院医嘱)\s*[::]?', caseSensitive: false), false),
    ('随访', RegExp(r'^\s*(follow[\s-]?up|随访|复诊)', caseSensitive: false), true),
  ];
  final lines = text.split('\n');
  final out = <({String label, int line})>[];
  for (final (label, re, shortOnly) in rules) {
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if ((!shortOnly || t.length <= 60) && re.hasMatch(t)) {
        out.add((label: label, line: i));
        break;
      }
    }
  }
  out.sort((a, b) => a.line.compareTo(b.line));
  return out;
}

/// 找第一行同时含全部关键词(大小写不敏感)的行(F10:从指标详情点回原件,带「Creatinine」与
/// 「0.88」定位);返回 (起始偏移, 该行文字),找不到 null。
({int start, String line})? findLineWith(String text, List<String> tokens) {
  final toks = tokens.map((t) => t.trim().toLowerCase()).where((t) => t.isNotEmpty).toList();
  if (toks.isEmpty) return null;
  var offset = 0;
  for (final l in text.split('\n')) {
    final lower = l.toLowerCase();
    if (toks.every(lower.contains)) return (start: offset, line: l);
    offset += l.length + 1;
  }
  // 退一步:只要名字那一个词。
  if (toks.length > 1) return findLineWith(text, [tokens.first]);
  return null;
}
