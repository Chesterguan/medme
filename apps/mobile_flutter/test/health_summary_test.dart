// 「我 → 健康摘要」(修订 2 验收 5)。合成数据,Doe, Jane 的形状。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/health_summary_screen.dart';
import 'package:mobile_flutter/theme.dart';

Map<String, dynamic> _view({bool withSle = false, bool lijingStyle = false}) => {
  'package_id': 'general',
  'disclaimer': '只整理你病历里已有的记录,不做诊断。',
  'documents': [
    {'index': 0, 'document_id': 100, 'title': '出院记录', 'date': '2024-03-10'},
    {'index': 1, 'document_id': 101, 'title': '门诊病历', 'date': '2026-09-14'},
  ],
  'sources': withSle ? [{'id': 'S1', 'cite': 'EULAR 2019'}] : [],
  if (withSle) 'packages': [{'id': 'sle', 'display_name': '系统性红斑狼疮', 'family': 'immune', 'applies': true}],
  'sections': [
    {
      'kind': 'family_cards', 'id': 'general_families', 'package_id': 'general', 'title': '现在',
      'body': {
        'recent_days': 365,
        'families': [
          {
            'key': 'cardio', 'label': '心血管', 'count': 1, 'last_seen': '2026-09-14',
            'diagnoses': [
              {'code': 'Z95.2', 'texts': ['Presence of prosthetic heart valve'], 'first_seen': '2024-03-10', 'last_seen': '2026-09-14', 'doc_count': 2, 'evidence': ['ev:0:1', 'ev:1:1'], 'unverified': false},
            ],
            'labs': [],
          },
          if (withSle && !lijingStyle)
            {
              'key': 'immune', 'label': '免疫', 'count': 1, 'last_seen': '2026-08-01',
              'diagnoses': [{'code': 'M32.14', 'texts': ['Lupus nephritis'], 'first_seen': '2025-01-01', 'last_seen': '2026-08-01', 'doc_count': 3, 'evidence': ['ev:1:2'], 'unverified': false}],
              'labs': [],
            },
          {
            'key': 'other', 'label': '其他', 'count': 1, 'last_seen': '2026-09-01',
            'diagnoses': [{'code': 'R53.83', 'texts': ['Fatigue', 'Other fatigue', 'Fatigue, unspecified'], 'first_seen': '2026-09-01', 'last_seen': '2026-09-01', 'doc_count': 1, 'evidence': ['ev:1:1'], 'unverified': false}],
            'labs': [],
          },
          if (withSle && lijingStyle)
            {
              'key': 'uncoded', 'label': '未归类', 'count': 1, 'last_seen': '2026-08-01',
              'diagnoses': [{'code': null, 'texts': ['系统性红斑狼疮'], 'first_seen': '2025-01-01', 'last_seen': '2026-08-01', 'doc_count': 3, 'evidence': ['ev:1:2'], 'unverified': false}],
              'labs': [],
            },
        ],
        'earlier_families': [
          {
            'key': 'cardio', 'label': '心血管', 'count': 1, 'last_seen': '2024-03-10',
            'diagnoses': [{'code': 'I35.0', 'texts': ['Severe aortic stenosis'], 'first_seen': '2024-03-03', 'last_seen': '2024-03-10', 'doc_count': 2, 'evidence': ['ev:0:2'], 'unverified': false}],
            'labs': [],
          },
        ],
        'common_labs': [],
      },
    },
    {
      'kind': 'med_table', 'id': 'general_meds', 'package_id': 'general', 'title': '现在',
      'body': {'rows': [{'name': '华法林', 'raw_name': 'Warfarin', 'dose': '4mg', 'family': 'cardio', 'stale': false, 'evidence': ['ev:1:1'], 'unverified': false}], 'stale_after_days': 180},
    },
    {
      'kind': 'journey', 'id': 'general_journey', 'package_id': 'general', 'title': '进程',
      'body': {
        'lanes': [
          {'key': 'surgery', 'label': '手术', 'quality': 'doc', 'severity': 'normal', 'nodes': [
            {'at': '2024-03-03', 'kind': 'doc', 'from': null, 'to': 'Surgical aortic valve replacement', 'text': null, 'evidence': ['ev:0:3'], 'unverified': false},
          ]},
        ],
      },
    },
    {
      'kind': 'evidence', 'id': 'general_evidence', 'package_id': 'general', 'title': '依据',
      'body': {'items': [
        {'id': 'ev:0:1', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': 'Presence of prosthetic heart valve [Z95.2]', 'span': null, 'origin': 'llm', 'verified': true},
        {'id': 'ev:1:1', 'doc': 1, 'date': '2026-09-14', 'title': '门诊病历', 'quote': 'Status post AVR', 'span': null, 'origin': 'llm', 'verified': true},
        {'id': 'ev:0:2', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': 'Severe aortic stenosis', 'span': null, 'origin': 'llm', 'verified': true},
        {'id': 'ev:0:3', 'doc': 0, 'date': '2024-03-03', 'title': '手术记录', 'quote': 'Surgical aortic valve replacement', 'span': null, 'origin': 'doc', 'verified': true},
        {'id': 'ev:1:2', 'doc': 1, 'date': '2026-08-01', 'title': '门诊病历', 'quote': 'Lupus nephritis', 'span': null, 'origin': 'llm', 'verified': true},
      ]},
    },
    if (withSle)
      {
        'kind': 'state', 'id': 'sle_state', 'package_id': 'sle', 'title': '现在',
        'body': {'as_of': '2026-10-22', 'vars': [
          {'key': 'gc_equiv', 'label': '激素等效量', 'value': '7.5', 'unit': 'mg/天', 'since': '2026-08-01', 'stale': false, 'evidence': ['ev:1:2'], 'unverified': false, 'verified': true},
        ]},
      },
  ],
};

Map<String, dynamic> _meds() => {
  'documents': [{'index': 0, 'document_id': 100, 'title': '出院记录', 'date': '2024-03-10'}],
  'recent': [], 'earlier': [],
  'allergies': [{'substance': 'Penicillin', 'reaction': 'Rash', 'evidence': ['ev:0:9']}],
  'evidence': [{'id': 'ev:0:9', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': '• Penicillin  Rash', 'span': null, 'origin': 'regex', 'verified': true}],
  'stale_after_days': 180,
};

Widget _wrap(Widget child, {double scale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(data: MediaQueryData(size: const Size(393, 852), textScaler: TextScaler.linear(scale)), child: child),
);

Future<void> _pump(WidgetTester t, {Map<String, dynamic>? view, double scale = 1.0}) async {
  t.view.physicalSize = const Size(393 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(_wrap(HealthSummaryScreen(key: UniqueKey(), load: () async => (view ?? _view(), _meds())), scale: scale));
  await t.pumpAndSettle();
}

Future<void> _expandAll(WidgetTester t) async {
  var i = 0;
  while (i < find.byType(ExpansionTile).evaluate().length) {
    await t.tap(find.byType(ExpansionTile).at(i));
    await t.pumpAndSettle();
    i++;
  }
}

void main() {
  testWidgets('四段:诊断族卡、手术史、植入物、过敏;更早的诊断折叠', (t) async {
    await _pump(t);
    expect(find.text('诊断 / 问题'), findsOneWidget);
    expect(find.text('心血管 · 1 条诊断 · 最近 2026-09-14'), findsOneWidget);
    expect(find.text('手术史 · 1'), findsOneWidget);
    expect(find.text('Surgical aortic valve replacement'), findsOneWidget);
    expect(find.text('植入物 · 1'), findsOneWidget);
    expect(find.textContaining('Presence of prosthetic'), findsOneWidget, reason: '植入物段列 Z95.2;族卡折叠着');
    expect(find.text('过敏 · 1'), findsOneWidget);
    expect(find.text('Penicillin · Rash'), findsOneWidget);
    // 「其他」不是族:排到族卡后,和更早的诊断一起折叠;写法最多两种 + 「还有 N 个写法」。
    expect(find.text('其他 1 条'), findsNothing);
    expect(find.text('更早的诊断与未归类 · 2 条'), findsOneWidget);
    expect(find.textContaining('Severe aortic stenosis'), findsNothing);
    expect(find.textContaining('Fatigue'), findsNothing);
    await t.tap(find.text('更早的诊断与未归类 · 2 条'));
    await t.pumpAndSettle();
    expect(find.textContaining('Severe aortic stenosis'), findsOneWidget);
    expect(find.textContaining('Fatigue'), findsOneWidget);
    expect(find.text('Other fatigue · 还有 1 个写法'), findsOneWidget);
    expect(find.text('Fatigue, unspecified'), findsNothing);
  });

  testWidgets('族卡展开:诊断行 + 最近的用药一行;诊断多依据 → 弹层', (t) async {
    await _pump(t);
    await t.tap(find.text('心血管 · 1 条诊断 · 最近 2026-09-14'));
    await t.pumpAndSettle();
    expect(find.text('最近的用药:华法林'), findsOneWidget);
    await t.tap(find.textContaining('Presence of prosthetic').first);
    await t.pumpAndSettle();
    expect(find.byType(EvidencePickerBody), findsOneWidget);
  });

  testWidgets('包段:有 M32 诊断在免疫族卡内;无码落「未归类」时独立一段;Jane 无包', (t) async {
    await _pump(t, view: _view(withSle: true));
    expect(find.textContaining('红斑狼疮'), findsNothing);
    await t.tap(find.text('免疫 · 1 条诊断 · 最近 2026-08-01'));
    await t.pumpAndSettle();
    expect(find.text('系统性红斑狼疮(病种包)'), findsOneWidget);
    expect(find.text('激素等效量'), findsOneWidget);
    await _pump(t, view: _view(withSle: true, lijingStyle: true));
    expect(find.text('系统性红斑狼疮(病种包)'), findsOneWidget);
    await _pump(t);
    await _expandAll(t);
    expect(find.textContaining('红斑狼疮'), findsNothing);
  });

  testWidgets('措辞:不出现开启 / 进程 / 依据 / 活动期 / 已解决 / 在吃 / 已停 / 当前用药', (t) async {
    await _pump(t, view: _view(withSle: true));
    await _expandAll(t);
    for (final w in ['开启', '进程', '依据', '活动期', '已解决', '在吃', '已停', '当前用药']) {
      expect(find.textContaining(w), findsNothing, reason: w);
    }
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:全部展开不溢出', (t) async {
      await _pump(t, view: _view(withSle: true), scale: scale);
      await _expandAll(t);
      expect(t.takeException(), isNull);
    });
  }
}
