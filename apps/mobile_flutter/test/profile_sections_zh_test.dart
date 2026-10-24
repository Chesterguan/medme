// 通用病程档案族卡的中文化(2026-10-23 spec §2.1.4 / §4.1):诊断有 ICD 中文名时
// 中文在前、英文原文退到小字;「看原文 / 看中文」一键切换;表里没有的码英文仍是主行。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: MedMe.theme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Map<String, dynamic> _familyCards(List<Map<String, dynamic>> diagnoses) => {
  'kind': 'family_cards',
  'id': 'general_families',
  'title': '诊断',
  'body': {
    'families': [
      {
        'key': 'cardio',
        'label': '心血管',
        'count': diagnoses.length,
        'last_seen': '2026-09-14',
        'diagnoses': diagnoses,
        'labs': <Map<String, dynamic>>[],
      },
    ],
    'common_labs': <Map<String, dynamic>>[],
  },
};

const _dx = [
  {
    'code': 'I35.0',
    'texts': ['Aortic stenosis'],
    'name_zh': '主动脉瓣狭窄',
    'name_zh_level': 'sub4',
    'doc_count': 2,
    'evidence': <String>[],
  },
  {
    'code': 'N18.3',
    'texts': ['CKD stage 3'],
    'name_zh': '慢性肾衰竭',
    'name_zh_level': 'cat3',
    'doc_count': 1,
    'evidence': <String>[],
  },
  {
    'code': 'Z79.01',
    'texts': ['Long term use of anticoagulants'],
    'doc_count': 1,
    'evidence': <String>[],
  },
];

/// 主行:诊断行里**只有主行**是 `Text.rich`(码、族名跟在后面),小字行是普通 `Text`。
/// 只认 `textSpan != null`,否则切换是空操作时小字行也能冒充主行(审查 I4)。
Finder _mainRow(String prefix) => find.byWidgetPredicate(
  (w) => w is Text && w.textSpan != null && w.textSpan!.toPlainText().startsWith(prefix),
);

void main() {
  testWidgets(
    'family card shows the Chinese ICD name first and the English original after 看原文',
    (t) async {
      await t.pumpWidget(_wrap(ProfileSectionView(_familyCards(_dx))));
      await t.tap(find.textContaining('心血管'));
      await t.pumpAndSettle();

      expect(_mainRow('主动脉瓣狭窄'), findsOneWidget, reason: '主行是中文名');
      expect(find.textContaining('(类目)'), findsOneWidget, reason: 'cat3 命中标「(类目)」');
      expect(find.textContaining('Aortic stenosis'), findsOneWidget, reason: '英文原文在小字行');
      expect(_mainRow('Long term use'), findsOneWidget, reason: '表外码:英文仍是主行');

      await t.tap(find.text('看原文'));
      await t.pumpAndSettle();
      expect(_mainRow('Aortic stenosis'), findsOneWidget, reason: '切换后主行是英文');
      expect(find.textContaining('主动脉瓣狭窄'), findsOneWidget, reason: '中文退到小字,仍可见');
      expect(find.text('看中文'), findsOneWidget);
    },
  );

  testWidgets('without any name_zh the family card renders as before, with no toggle', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView(_familyCards([_dx[2]]))));
    await t.tap(find.textContaining('心血管'));
    await t.pumpAndSettle();
    expect(_mainRow('Long term use of anticoagulants'), findsOneWidget);
    expect(find.text('看原文'), findsNothing);
  });
}
