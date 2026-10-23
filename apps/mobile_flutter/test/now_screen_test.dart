// 「现在」页(2026-10-23 spec §4、§11.2 验收 7/8)。全部合成数据,Doe, Jane 的形状。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/now_model.dart';
import 'package:mobile_flutter/screens/now_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

final _today = DateTime(2026, 10, 22);

Map<String, dynamic> _view({bool withSle = false, bool lijingStyle = false}) => {
  'package_id': 'general',
  'disclaimer': '只整理你病历里已有的记录,不做诊断。',
  'documents': [
    {'index': 0, 'document_id': 100, 'title': '出院记录', 'date': '2024-03-10'},
    {'index': 1, 'document_id': 101, 'title': '门诊病历', 'date': '2026-09-14'},
  ],
  'sources': withSle ? [{'id': 'S1', 'cite': 'EULAR 2019'}] : [],
  if (withSle)
    'packages': [
      {'id': 'sle', 'display_name': '系统性红斑狼疮', 'family': 'immune', 'applies': true},
    ],
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
              'diagnoses': [
                {'code': 'M32.14', 'texts': ['Lupus nephritis'], 'first_seen': '2025-01-01', 'last_seen': '2026-08-01', 'doc_count': 3, 'evidence': ['ev:1:2'], 'unverified': false},
              ],
              'labs': [],
            },
          if (withSle && lijingStyle)
            {
              'key': 'uncoded', 'label': '未归类', 'count': 1, 'last_seen': '2026-08-01',
              'diagnoses': [
                {'code': null, 'texts': ['系统性红斑狼疮'], 'first_seen': '2025-01-01', 'last_seen': '2026-08-01', 'doc_count': 3, 'evidence': ['ev:1:2'], 'unverified': false},
              ],
              'labs': [],
            },
        ],
        'earlier_families': [
          {
            'key': 'cardio', 'label': '心血管', 'count': 1, 'last_seen': '2024-03-10',
            'diagnoses': [
              {'code': 'I35.0', 'texts': ['Severe aortic stenosis'], 'first_seen': '2024-03-03', 'last_seen': '2024-03-10', 'doc_count': 2, 'evidence': ['ev:0:2'], 'unverified': false},
            ],
            'labs': [],
          },
        ],
        'common_labs': [],
      },
    },
    {
      'kind': 'med_table', 'id': 'general_meds', 'package_id': 'general', 'title': '现在',
      'body': {
        'rows': [
          {'name': '华法林', 'raw_name': 'Warfarin', 'dose': '4mg', 'family': 'cardio', 'stale': false, 'evidence': ['ev:1:1'], 'unverified': false},
          {'name': '美托洛尔', 'raw_name': 'Metoprolol', 'dose': '25mg', 'family': 'cardio', 'stale': true, 'evidence': [], 'unverified': false},
        ],
        'stale_after_days': 180,
      },
    },
    {
      'kind': 'evidence', 'id': 'general_evidence', 'package_id': 'general', 'title': '依据',
      'body': {
        'items': [
          {'id': 'ev:0:1', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': 'Presence of prosthetic heart valve [Z95.2]', 'span': [3, 10], 'origin': 'llm', 'verified': true},
          {'id': 'ev:1:1', 'doc': 1, 'date': '2026-09-14', 'title': '门诊病历', 'quote': 'Status post AVR', 'span': null, 'origin': 'llm', 'verified': true},
          {'id': 'ev:0:2', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': 'Severe aortic stenosis', 'span': null, 'origin': 'llm', 'verified': true},
          {'id': 'ev:1:2', 'doc': 1, 'date': '2026-08-01', 'title': '门诊病历', 'quote': 'Lupus nephritis', 'span': null, 'origin': 'llm', 'verified': true},
        ],
      },
    },
    if (withSle)
      {
        'kind': 'state', 'id': 'sle_state', 'package_id': 'sle', 'title': '现在',
        'body': {
          'as_of': '2026-10-22',
          'vars': [
            {'key': 'gc_equiv', 'label': '激素等效量', 'value': '7.5', 'unit': 'mg/天', 'since': '2026-08-01', 'stale': false, 'evidence': ['ev:1:2'], 'unverified': false, 'verified': true},
          ],
        },
      },
  ],
};

TrendSeriesDto _series(String name, String key, String? panel, List<String> dates, {bool self = false}) => TrendSeriesDto(
  name: name,
  analyteKey: key,
  panel: panel,
  unit: 'u',
  refLow: 1,
  refHigh: 10,
  valuesConverted: false,
  anyAbnormal: false,
  points: [for (final (i, d) in dates.indexed) TrendPointDto(date: d, value: 5.0 + i, unit: 'u', documentId: 100 + i, unverified: false)],
  selfMeasured: self,
);

List<TrendSeriesDto> _allSeries() => [
  _series('INR', 'inr', '凝血', ['2025-01-01', '2026-10-01']),
  _series('肌酐', 'creatinine', '肾功能', ['2026-09-15']),
  _series('血红蛋白', 'hemoglobin', '血常规', ['2026-09-15']),
  _series('甲胎蛋白', 'afp', '肿瘤标志物', ['2026-05-01']),
  _series('乳酸脱氢酶', 'ldh', null, ['2024-01-01']), // 更早
  _series('血压(收缩压)', 'bp_systolic', null, ['2026-10-10'], self: true),
];

final _families = LabFamilies.fromJson({
  'recent_days': 365,
  'families': [
    {'key': 'cardio', 'label': '心血管', 'keys': ['inr', 'creatinine']},
    {'key': 'renal', 'label': '肾', 'keys': ['creatinine']},
    {'key': 'immune', 'label': '免疫', 'keys': []},
  ],
  'panel_family': {'凝血': 'cardio', '肾功能': 'renal', '血常规': 'common'},
});

Widget _wrap(Widget child, {double scale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(size: const Size(393, 852), textScaler: TextScaler.linear(scale)),
    child: child,
  ),
);

Future<void> _pump(WidgetTester t, {Map<String, dynamic>? view, List<TrendSeriesDto>? series, double scale = 1.0}) async {
  // 393 宽、给足高度:ListView 把每一行都建出来,点得到;与 archive_timeline_test 同一手法。
  t.view.physicalSize = const Size(393 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(_wrap(
    NowScreen(
      key: UniqueKey(), // 同一测试里 pump 两次:不让 State 被复用(late final _future 只初始化一次)
      today: _today,
      load: () async => (view ?? _view(), series ?? _allSeries(), _families),
    ),
    scale: scale,
  ));
  await t.pumpAndSettle();
}

Future<void> _expandAll(WidgetTester t) async {
  // 每点一次列表都重建,按下标重找而不是攥着旧 widget;展开后新出现的折叠(出处)也要点到。
  var i = 0;
  while (i < find.byType(ExpansionTile).evaluate().length) {
    await t.tap(find.byType(ExpansionTile).at(i));
    await t.pumpAndSettle();
    i++;
  }
}

void main() {
  testWidgets('族卡:展开后诊断行、最近的用药一行、化验趋势行;更早的诊断/化验各一行', (t) async {
    await _pump(t);
    expect(find.text('心血管 · 1 条诊断 · 最近 2026-09-14'), findsOneWidget);
    expect(find.text('更早的诊断 · 1 条'), findsOneWidget);
    expect(find.text('更早的化验 · 1 项'), findsOneWidget);
    expect(find.textContaining('Presence of prosthetic'), findsNothing, reason: '默认折叠');
    await t.tap(find.text('心血管 · 1 条诊断 · 最近 2026-09-14'));
    await t.pumpAndSettle();
    expect(find.textContaining('Presence of prosthetic'), findsOneWidget);
    expect(find.text('首次 2024-03-10 · 最近 2026-09-14 · 2 份记录提到'), findsOneWidget);
    expect(find.text('最近的用药:华法林'), findsOneWidget, reason: '美托洛尔 stale 不列');
    // 族内化验行:INR 与肌酐(肌酐同时在肾,肾没有诊断卡)。
    expect(find.descendant(of: find.byType(FamilyTile), matching: find.byType(LabTrendRow)), findsNWidgets(2));
    expect(find.descendant(of: find.byType(FamilyTile), matching: find.byType(TrendChart)), findsNWidgets(2));
    // 通用一排 + 其他化验(肿瘤标志物无族、自测)。
    expect(find.text('血常规 / 电解质 / 肝功能'), findsOneWidget);
    expect(find.text('其他化验 · 2'), findsOneWidget);
  });

  testWidgets('更早的化验展开后是趋势行;更早的诊断展开后有 I35.0', (t) async {
    await _pump(t);
    await t.tap(find.text('更早的化验 · 1 项'));
    await t.pumpAndSettle();
    expect(find.text('乳酸脱氢酶'), findsOneWidget);
    await t.tap(find.text('更早的诊断 · 1 条'));
    await t.pumpAndSettle();
    expect(find.textContaining('Severe aortic stenosis'), findsOneWidget);
  });

  testWidgets('诊断行多条依据 → 弹层;点一条进原件', (t) async {
    await _pump(t);
    await t.tap(find.text('心血管 · 1 条诊断 · 最近 2026-09-14'));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Presence of prosthetic').first);
    await t.pumpAndSettle();
    expect(find.byType(EvidencePickerBody), findsOneWidget);
    expect(find.text('原件 · 2 份'), findsOneWidget);
  });

  testWidgets('搜索「肌酐」:整页只剩命中的行,族卡隐藏', (t) async {
    await _pump(t);
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '肌酐');
    await t.pumpAndSettle();
    expect(find.byType(LabTrendRow), findsOneWidget);
    expect(find.descendant(of: find.byType(LabTrendRow), matching: find.text('肌酐')), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
  });

  testWidgets('空箱子:只写一行', (t) async {
    await _pump(t, view: {'sections': [], 'documents': []}, series: []);
    expect(find.text('还没有诊断或化验记录'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
  });

  testWidgets('包段:有 M32 诊断 → 在免疫族卡内,不在页首;Jane 无包 → 不出现', (t) async {
    await _pump(t, view: _view(withSle: true));
    expect(find.textContaining('红斑狼疮'), findsNothing, reason: '折叠时不在页首');
    await t.tap(find.text('免疫 · 1 条诊断 · 最近 2026-08-01'));
    await t.pumpAndSettle();
    expect(find.text('系统性红斑狼疮(病种包)'), findsOneWidget);
    expect(find.text('激素等效量'), findsOneWidget);
    await _pump(t);
    await _expandAll(t);
    expect(find.textContaining('红斑狼疮'), findsNothing);
  });

  testWidgets('包段:诊断无码落在「未归类」时,包段独立一段排在族卡之后', (t) async {
    await _pump(t, view: _view(withSle: true, lijingStyle: true));
    expect(find.text('系统性红斑狼疮(病种包)'), findsOneWidget);
  });

  testWidgets('措辞:不出现开启 / 进程 / 依据 / 活动 / 已解决 / 在吃 / 已停', (t) async {
    await _pump(t, view: _view(withSle: true));
    await _expandAll(t);
    for (final w in ['开启', '进程', '依据', '活动', '已解决', '在吃', '已停', '当前用药']) {
      expect(find.textContaining(w), findsNothing, reason: w);
    }
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393×852 字号 $scale:全部展开不溢出', (t) async {
      await _pump(t, view: _view(withSle: true), scale: scale);
      await _expandAll(t);
      expect(t.takeException(), isNull);
    });
  }
}
