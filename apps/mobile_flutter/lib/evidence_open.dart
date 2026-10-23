// 「依据」改成点击即看原件(2026-10-23 spec §7):任何带 `ev:` id 的值点一下就进原件并高亮;
// 一条直接进,多条先弹一层选。没有「依据」tab。
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 一份视图 JSON 里的依据索引:`ev:<doc>:<n>` → 依据条目;`documents[]` 桥 → document_id。
/// 通用视图(`vault_profile_view_general`)与用药视图(`vault_profile_meds_view`)同一形状:
/// 前者的依据在 `sections[kind == evidence].body.items`,后者在顶层 `evidence[]`;都收。
class EvidenceIndex {
  EvidenceIndex({required this.evidenceById, required this.documentIds});

  factory EvidenceIndex.fromView(Map<String, dynamic> view) {
    final evidence = <String, Map<String, dynamic>>{};
    void take(dynamic items) {
      if (items is! List) return;
      for (final e in items) {
        if (e is Map && e['id'] is String) {
          evidence[e['id'] as String] = e.cast<String, dynamic>();
        }
      }
    }

    take(view['evidence']);
    for (final s in (view['sections'] as List? ?? const [])) {
      if (s is Map && s['kind'] == 'evidence') {
        final body = s['body'];
        take(body is Map ? body['items'] : null);
      }
    }
    final docs = <int, int>{
      for (final d in (view['documents'] as List? ?? const []))
        if (d is Map && d['index'] is num && d['document_id'] is num)
          (d['index'] as num).toInt(): (d['document_id'] as num).toInt(),
    };
    return EvidenceIndex(evidenceById: evidence, documentIds: docs);
  }

  final Map<String, Map<String, dynamic>> evidenceById;
  final Map<int, int> documentIds;

  Map<String, dynamic>? byId(dynamic id) => id is String ? evidenceById[id] : null;

  /// `doc`(`SourceDoc::index`)→ document_id;自填(`ev:self:*`)或桥上没有 → null。
  int? docIdOf(Map<String, dynamic> e) {
    final idx = (e['doc'] as num?)?.toInt();
    return idx == null ? null : documentIds[idx];
  }

  List<Map<String, dynamic>> resolve(Iterable<dynamic> ids) =>
      ids.map(byId).whereType<Map<String, dynamic>>().toList();
}

/// 打开原件的动作(可注入,测试不碰 FFI)。
typedef OpenDocument = void Function(
  BuildContext context,
  int docId, {
  String? highlight,
  List<int>? highlightSpan,
});

void _pushDocument(
  BuildContext context,
  int docId, {
  String? highlight,
  List<int>? highlightSpan,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DocumentDetailScreen(
        docId: docId,
        highlight: highlight,
        highlightSpan: highlightSpan,
      ),
    ),
  );
}

/// 0 条:什么都不做;1 条:直接进原件(自填的没有原件 → 一条 SnackBar 显示引文);
/// ≥2 条:底部弹层列「日期 · 标题 · 引文」,点一条再进。
Future<void> openEvidence(
  BuildContext context,
  EvidenceIndex index,
  Iterable<dynamic> ids, {
  OpenDocument open = _pushDocument,
}) async {
  final items = index.resolve(ids);
  if (items.isEmpty) return;
  if (items.length == 1) {
    _openOne(context, index, items.single, open);
    return;
  }
  final picked = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(child: EvidencePickerBody(items: items)),
  );
  if (picked == null || !context.mounted) return;
  _openOne(context, index, picked, open);
}

void _openOne(
  BuildContext context,
  EvidenceIndex index,
  Map<String, dynamic> e,
  OpenDocument open,
) {
  final docId = index.docIdOf(e);
  if (docId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      appSnackBar(content: Text('${e['quote'] ?? ''}')),
    );
    return;
  }
  final span = e['span'];
  open(
    context,
    docId,
    highlight: e['quote'] as String?,
    highlightSpan: span is List && span.length == 2
        ? [(span[0] as num).toInt(), (span[1] as num).toInt()]
        : null,
  );
}

/// 多条依据的选择层:每条一行「日期 · 标题」+ 引文一行。
class EvidencePickerBody extends StatelessWidget {
  const EvidencePickerBody({super.key, required this.items});

  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(MedShape.s3, 0, MedShape.s3, MedShape.s3),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: MedShape.s2),
            child: Text(
              '原件 · ${items.length} 份',
              style: MedType.subtitle.copyWith(color: c.ink),
            ),
          ),
          for (final e in items)
            InkWell(
              onTap: () => Navigator.of(context).pop(e),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      evidenceHeadline(e),
                      style: MedType.body.copyWith(color: c.ink),
                    ),
                    if ('${e['quote'] ?? ''}'.isNotEmpty)
                      Text(
                        '${e['quote']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「日期 · 标题 · 需核对」,缺哪个省哪个;自填的标「自己填的」。
String evidenceHeadline(Map<String, dynamic> e) {
  final date = fmtDate(e['date'] as String?);
  final title = e['title'] as String?;
  return [
    if (date.isNotEmpty) date,
    if (title != null && title.isNotEmpty) title
    else if (e['origin'] == 'self_entry') '自己填的',
    if (e['verified'] == false) '需核对',
  ].join(' · ');
}

/// 引文在原文里的起点(UTF-16 下标)。`span` 是 Rust 给的 needle(药名/数值)的
/// **UTF-8 字节偏移**,`quote` 常是含它的整行:把字节偏移换成 UTF-16 下标后,取**包含该
/// 下标的那一处** `quote`;换算失败、找不到都退回第一处;原文里没有 `quote` → null。
int? highlightIndex(String text, String quote, List<int>? span) {
  if (quote.isEmpty) return null;
  final first = text.indexOf(quote);
  if (first < 0) return null;
  if (span == null || span.length != 2) return first;
  final bytes = utf8.encode(text);
  final start = span[0];
  if (start < 0 || start > bytes.length) return first;
  final idx = utf8.decode(bytes.sublist(0, start), allowMalformed: true).length;
  final at = text.lastIndexOf(quote, idx);
  if (at >= 0 && idx < at + quote.length) return at;
  return first;
}
