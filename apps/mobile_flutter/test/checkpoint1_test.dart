// checkpoint 1 的几条修正:F3 最近就诊跳过摘要文档、F4 概况行、F9 结论卡、F6 跳到 chip、F10 滚到高亮。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/meds_model.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/overview_row.dart';

DocumentSummaryDto _doc(int id, String type, String date, {String? title}) =>
    DocumentSummaryDto(id: id, docType: type, docDate: '${date}T00:00:00+00:00', title: title, pageCount: 1, provider: 'UF Health Shands');

DocumentDetailDto _detail(String type, String text, {String? impression, String? title}) => DocumentDetailDto(
  document: DocumentSummaryDto(id: 1, docType: type, pageCount: 1, provider: 'UF Health Shands', docDate: '2026-10-07', title: title),
  sourceFile: const SourceFileMetaDto(id: 1, originalName: 'x.pdf', mimeType: 'application/pdf', byteSize: 0, importedAt: '2026-10-07'),
  ocrText: text,
  impression: impression,
);

Widget _wrap(Widget child) => MaterialApp(theme: MedMe.theme(), home: Scaffold(body: child));

void main() {
  test('F3 recentVisitDate:Epic 病历摘要(打印日)不算最近就诊', () {
    final groups = [
      TimelineGroupDto.document(doc: _doc(1, 'other', '2026-10-20', title: 'Epic 病历摘要')),
      TimelineGroupDto.document(doc: _doc(2, 'lab_report', '2026-10-12', title: 'Labs')),
    ];
    expect(recentVisitDate(groups), startsWith('2026-10-12'));
    expect(recentVisitDate(groups.sublist(0, 1)), isNull);
  });

  test('F11 medsSplit:区间内但超过 180 天没新记录(stale)的归更早', () {
    final rows = [
      {'name': 'a', 'last_seen': '2026-10-10', 'stale': false},
      {'name': 'b', 'last_seen': '2026-02-01', 'stale': true},
      {'name': 'c', 'last_seen': '2026-09-01', 'stale': false, 'stopped': {'at': '2026-09-01'}},
    ];
    final s = medsSplit(rows, today: DateTime(2026, 10, 22), recentDays: 365);
    expect(s.recent.map((r) => r['name']), ['a']);
    expect(s.earlier.map((r) => r['name']), ['b', 'c']);
  });

  test('F4 overviewText:诊断最多三条 ｜ 最近用药 N ｜ 过敏 N', () {
    final view = {
      'sections': [
        {
          'kind': 'family_cards', 'package_id': 'general',
          'body': {
            'families': [
              {'key': 'cardio', 'last_seen': '2026-10-12', 'diagnoses': [{'texts': ['Status post AVR'], 'last_seen': '2026-10-12'}, {'texts': ['Old'], 'last_seen': '2025-01-01'}]},
              {'key': 'infection', 'last_seen': '2026-10-01', 'diagnoses': [{'texts': ['Endocarditis'], 'last_seen': '2026-10-01'}]},
              {'key': 'other', 'last_seen': '2026-10-13', 'diagnoses': [{'texts': ['Fatigue'], 'last_seen': '2026-10-13'}]},
            ],
          },
        },
      ],
    };
    final meds = {'recent': [{}, {}], 'allergies': [{}, {}, {}]};
    expect(overviewText(view, meds), 'Status post AVR · Endocarditis ｜ 最近用药 2 ｜ 过敏 3');
    expect(overviewText({'sections': []}, {'recent': [], 'allergies': []}), '');
  });

  testWidgets('F4 OverviewRow 画出概况一行', (t) async {
    await t.pumpWidget(_wrap(OverviewRow(load: () async => ({'sections': <Map<String, dynamic>>[]}, {'recent': [{}], 'allergies': []}))));
    await t.pumpAndSettle();
    expect(find.text('最近用药 1 ｜ 过敏 0'), findsOneWidget);
  });

  testWidgets('F9 影像先放结论卡;F1 标题 = document.title、副标 类型 · 医院 · 日期', (t) async {
    await t.pumpWidget(_wrap(DetailBody(detail: _detail('imaging_report', 'Ordering user: x\nFINDINGS: lungs clear\nIMPRESSION: No acute disease.\n', impression: 'No acute disease.', title: 'CT Chest'))));
    await t.pumpAndSettle();
    expect(find.text('结论'), findsOneWidget);
    expect(find.text('No acute disease.'), findsOneWidget);
    expect(find.text('CT Chest'), findsOneWidget);
    expect(find.text('影像 · UF Health Shands · 2026-10-07'), findsOneWidget);
  });

  testWidgets('F6 出院小结顶部「跳到」chip,点一下不抛;F7 页眉只剩一份', (t) async {
    const header = 'SHANDS HOSPITAL\nHealth Information\nPO Box 100\nGainesville\nDoe, Jane\nMRN: 1\n';
    const text = '${header}Discharge Diagnoses:\nAS\n\n${header}Hospital Course:\nfine\n\nDischarge Medications:\nWarfarin\n\nFollow-up:\n2 weeks\n';
    await t.pumpWidget(_wrap(DetailBody(detail: _detail('discharge_summary', text, title: '出院小结'))));
    await t.pumpAndSettle();
    expect(find.text('跳到'), findsOneWidget);
    for (final l in ['出院诊断', '住院经过', '出院用药', '随访']) {
      expect(find.byKey(ValueKey('anchor:$l')), findsOneWidget);
    }
    await t.tap(find.byKey(const ValueKey('anchor:随访')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.textContaining('SHANDS HOSPITAL'), findsOneWidget, reason: '后页重复页眉折掉');
  });

  testWidgets('F10 带项目名 + 数值点回原件:那一行整行高亮', (t) async {
    await t.pumpWidget(_wrap(DetailBody(
      detail: _detail('lab_report', 'Creatinine 1.20 mg/dL\nCreatinine 0.88 mg/dL\nSodium 137\n', title: 'Labs'),
      highlightTokens: const ['Creatinine', '0.88'],
    )));
    await t.pumpAndSettle();
    expect(find.byType(HighlightedText), findsOneWidget);
    expect(find.text('Creatinine 0.88 mg/dL'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
