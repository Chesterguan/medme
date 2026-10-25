// 点击即看原件(2026-10-23 spec §7):单条直开、多条弹层选、自填只弹引文;引文按 span 定位。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/theme.dart';

Map<String, dynamic> _view() => {
  'documents': [
    {'index': 0, 'document_id': 100, 'title': '出院记录', 'date': '2024-03-10'},
    {'index': 1, 'document_id': 101, 'title': '门诊病历', 'date': '2025-01-14'},
  ],
  'sections': [
    {
      'kind': 'evidence',
      'package_id': 'general',
      'body': {
        'items': [
          {'id': 'ev:0:1', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': 'Warfarin 5mg daily', 'span': [10, 18], 'origin': 'regex', 'verified': true},
          {'id': 'ev:1:1', 'doc': 1, 'date': '2025-01-14', 'title': '门诊病历', 'quote': 'Warfarin 4mg daily', 'span': null, 'origin': 'llm', 'verified': false},
          {'id': 'ev:self:1', 'doc': null, 'date': '2026-01-01', 'title': null, 'quote': '血压 130/80', 'span': null, 'origin': 'self_entry', 'verified': true},
        ],
      },
    },
  ],
};

Map<String, dynamic> _medsView() => {
  'documents': [
    {'index': 0, 'document_id': 100},
  ],
  'evidence': [
    {'id': 'ev:0:7', 'doc': 0, 'quote': 'Penicillin  Rash', 'span': [3, 13], 'verified': true},
  ],
};

class _Opened {
  final calls = <(int, String?, List<int>?)>[];
  void call(BuildContext context, int docId, {String? highlight, List<int>? highlightSpan}) =>
      calls.add((docId, highlight, highlightSpan));
}

Widget _host(void Function(BuildContext) onTap) => MaterialApp(
  theme: MedMe.theme(),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(onPressed: () => onTap(context), child: const Text('点')),
    ),
  ),
);

void main() {
  group('highlightIndex', () {
    test('没有 span → 第一处;原文里没有 → null', () {
      expect(highlightIndex('INR 2.4\nINR 2.4', 'INR 2.4', null), 0);
      expect(highlightIndex('INR 2.4', '肌酐', null), isNull);
      expect(highlightIndex('INR 2.4', '', null), isNull);
    });
    test('span 指向第二处 → 第二处(含中文,字节 → UTF-16 换算)', () {
      // 'INR 2.4\nINR 2.4':第二行的 "2.4" 字节偏移 12..15
      expect(highlightIndex('INR 2.4\nINR 2.4', 'INR 2.4', [12, 15]), 8);
      // '肌酐 95\n肌酐 95':每个汉字 3 字节;第二行 "95" 的字节偏移 = 3+3+1+2+1 +3+3+1 = 17
      expect(highlightIndex('肌酐 95\n肌酐 95', '肌酐 95', [17, 19]), 6);
    });
    test('span 越界或对不上 → 退回第一处', () {
      expect(highlightIndex('INR 2.4\nINR 2.4', 'INR 2.4', [999, 1002]), 0);
      expect(highlightIndex('INR 2.4\nINR 2.4', 'INR 2.4', [12]), 0);
    });
  });

  group('EvidenceIndex', () {
    test('通用视图与用药视图两种形状都收;自填 doc 为 null', () {
      final a = EvidenceIndex.fromView(_view());
      expect(a.byId('ev:0:1')!['quote'], 'Warfarin 5mg daily');
      expect(a.docIdOf(a.byId('ev:0:1')!), 100);
      expect(a.docIdOf(a.byId('ev:self:1')!), isNull);
      expect(a.byId(42), isNull);
      final b = EvidenceIndex.fromView(_medsView());
      expect(b.docIdOf(b.byId('ev:0:7')!), 100);
    });
    test('evidenceHeadline:日期 · 标题 · 需核对;自填标「自己填的」', () {
      final a = EvidenceIndex.fromView(_view());
      expect(evidenceHeadline(a.byId('ev:1:1')!), '2025-01-14 · 门诊病历 · 需核对');
      expect(evidenceHeadline(a.byId('ev:self:1')!), '2026-01-01 · 自己填的');
    });
  });

  group('openEvidence', () {
    testWidgets('0 条:不开、不弹', (t) async {
      final opened = _Opened();
      final idx = EvidenceIndex.fromView(_view());
      await t.pumpWidget(_host((c) => openEvidence(c, idx, ['ev:nope'], open: opened.call)));
      await t.tap(find.text('点'));
      await t.pumpAndSettle();
      expect(opened.calls, isEmpty);
      expect(find.byType(EvidencePickerBody), findsNothing);
    });
    testWidgets('1 条:直接开那一份,带引文与 span', (t) async {
      final opened = _Opened();
      final idx = EvidenceIndex.fromView(_view());
      await t.pumpWidget(_host((c) => openEvidence(c, idx, ['ev:0:1'], open: opened.call)));
      await t.tap(find.text('点'));
      await t.pumpAndSettle();
      expect(opened.calls.length, 1);
      expect(opened.calls.single.$1, 100);
      expect(opened.calls.single.$2, 'Warfarin 5mg daily');
      expect(opened.calls.single.$3, [10, 18]);
    });
    testWidgets('自填那一条:没有原件,只弹引文', (t) async {
      final opened = _Opened();
      final idx = EvidenceIndex.fromView(_view());
      await t.pumpWidget(_host((c) => openEvidence(c, idx, ['ev:self:1'], open: opened.call)));
      await t.tap(find.text('点'));
      await t.pump();
      expect(opened.calls, isEmpty);
      expect(find.text('血压 130/80'), findsOneWidget);
    });
    testWidgets('2 条:弹层列两行,点第二行开第二份', (t) async {
      final opened = _Opened();
      final idx = EvidenceIndex.fromView(_view());
      await t.pumpWidget(_host((c) => openEvidence(c, idx, ['ev:0:1', 'ev:1:1'], open: opened.call)));
      await t.tap(find.text('点'));
      await t.pumpAndSettle();
      expect(find.byType(EvidencePickerBody), findsOneWidget);
      expect(find.text('原件 · 2 份'), findsOneWidget);
      expect(find.text('2025-01-14 · 门诊病历 · 需核对'), findsOneWidget);
      await t.tap(find.text('Warfarin 4mg daily'));
      await t.pumpAndSettle();
      expect(opened.calls.length, 1);
      expect(opened.calls.single.$1, 101);
      expect(opened.calls.single.$2, 'Warfarin 4mg daily');
      expect(opened.calls.single.$3, isNull);
    });
  });

  testWidgets('HighlightedText 高亮 start 起的那一处', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: MedMe.theme(),
      home: const Scaffold(
        body: HighlightedText(text: 'INR 2.4\nINR 2.4', highlight: 'INR 2.4', start: 8),
      ),
    ));
    // 高亮段单独一个 widget(打开后要能 ensureVisible 滚到它):前文 + 高亮,后文为空不画。
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(t.widget<SelectableText>(find.byType(SelectableText).at(0)).data, 'INR 2.4\n');
    final hl = t.widget<SelectableText>(find.byType(SelectableText).at(1));
    expect(hl.data, 'INR 2.4');
    expect(hl.style?.fontWeight, FontWeight.w600);
  });
}
