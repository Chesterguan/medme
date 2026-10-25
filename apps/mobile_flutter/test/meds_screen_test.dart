// 「用药」页(2026-10-23 spec §5、§11.2 验收 9)。合成数据,Doe, Jane 的形状。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/meds_model.dart';
import 'package:mobile_flutter/screens/meds_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

Map<String, dynamic> _row(String name, String raw, String dose, String family, {String? atc, bool stale = false, Map<String, dynamic>? stopped, List<Map<String, dynamic>> nodes = const []}) => {
  'name': name, 'raw_name': raw, 'raw_names': [raw], 'drug_key': name, 'dose': dose, 'atc': atc, 'mention_count': 3,
  'since': '2025-01-14', 'first_seen': '2024-03-10', 'last_seen': stale ? '2025-03-01' : '2026-10-10',
  'days_since': stale ? 600 : 12, 'stale': stale, 'stopped': ?stopped,
  'family': family, 'evidence': ['ev:1:1'], 'unverified': false, 'nodes': nodes,
};

Map<String, dynamic> _view({bool allergies = true, bool recent = true}) => {
  'stale_after_days': 180,
  'documents': [
    {'index': 0, 'document_id': 100, 'title': '出院记录', 'date': '2024-03-10'},
    {'index': 1, 'document_id': 101, 'title': '门诊病历', 'date': '2025-01-14'},
  ],
  'recent': recent
      ? [
          _row('华法林', 'Warfarin', '4mg', 'cardio', atc: 'B01AA03', nodes: [
            {'at': '2024-03-10', 'kind': 'first', 'from': null, 'to': '5mg daily', 'text': 'Warfarin', 'evidence': ['ev:0:1'], 'unverified': false},
            {'at': '2025-01-14', 'kind': 'change', 'from': '5mg daily', 'to': '4mg daily', 'text': 'Warfarin', 'evidence': ['ev:1:1'], 'unverified': false},
          ]),
          _row('赖诺普利', 'Lisinopril', '10mg', 'cardio', atc: 'C09AA03'),
          _row('左甲状腺素', 'Levothyroxine', '50mcg', 'endocrine', atc: 'H03AA01'),
        ]
      : [],
  'earlier': [
    _row('伏立康唑', 'Voriconazole', '200mg bid', 'infection', atc: 'J02AC03', stopped: {'at': '2025-11-17', 'evidence': 'ev:1:2'}, nodes: [
      {'at': '2025-06-14', 'kind': 'first', 'from': null, 'to': '200mg bid', 'text': 'Voriconazole', 'evidence': ['ev:0:1'], 'unverified': false},
      {'at': '2025-11-17', 'kind': 'stopped', 'from': '200mg bid', 'to': '病历写了停药', 'text': 'Voriconazole discontinued', 'evidence': ['ev:1:2'], 'unverified': false},
    ]),
    _row('美托洛尔', 'Metoprolol', '25mg', 'cardio', atc: 'C07AB02', stale: true),
  ],
  'allergies': allergies
      ? [
          {'substance': 'Penicillin', 'reaction': 'Rash', 'evidence': ['ev:0:3'], 'aliases': ['Penicillin · Rash', 'PENICILLINS']},
        ]
      : [],
  'evidence': [
    {'id': 'ev:0:1', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': 'Warfarin 5mg daily', 'span': [0, 8], 'origin': 'llm', 'verified': true},
    {'id': 'ev:1:1', 'doc': 1, 'date': '2025-01-14', 'title': '门诊病历', 'quote': 'Warfarin 4mg daily', 'span': null, 'origin': 'llm', 'verified': true},
    {'id': 'ev:1:2', 'doc': 1, 'date': '2025-11-17', 'title': '门诊病历', 'quote': 'Voriconazole discontinued', 'span': null, 'origin': 'regex', 'verified': true},
    {'id': 'ev:0:3', 'doc': 0, 'date': '2024-03-10', 'title': '出院记录', 'quote': '• Penicillin  Rash', 'span': null, 'origin': 'regex', 'verified': true},
  ],
};

Widget _wrap(Widget child, {double scale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(size: const Size(393, 852), textScaler: TextScaler.linear(scale)),
    child: child,
  ),
);

Future<void> _pump(WidgetTester t, {Map<String, dynamic>? view, double scale = 1.0}) async {
  t.view.physicalSize = const Size(393 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    medsFilterFamily.value = null;
  });
  await t.pumpWidget(_wrap(MedsScreen(key: UniqueKey(), today: DateTime(2026, 10, 22), load: () async => view ?? _view()), scale: scale));
  await t.pumpAndSettle();
}

void main() {
  group('纯函数', () {
    test('medMatches:药名 / 词典名 / 原文写法,大小写不敏感', () {
      final r = _row('华法林', 'Warfarin', '4mg', 'cardio');
      expect(medMatches(r, 'warf'), isTrue);
      expect(medMatches(r, '华法'), isTrue);
      expect(medMatches(r, 'vori'), isFalse);
      expect(medMatches(r, ''), isTrue);
    });
    test('medClassOf:ATC → 药类;medsSplit 按区间重切;medsByClass 同类相邻、类内按最近倒序;medEarlierLine', () {
      expect(medClassOf('B01AA03'), '抗凝');
      expect(medClassOf('J01CA04'), '抗感染');
      expect(medClassOf('C07AB02'), '心血管');
      expect(medClassOf('A12AA04'), '电解质 / 营养');
      expect(medClassOf('H03AA01'), '其他');
      expect(medClassOf(null), '其他');
      final rows = [..._view()['recent'] as List, ..._view()['earlier'] as List].cast<Map<String, dynamic>>();
      final s = medsSplit(rows, today: DateTime(2026, 10, 22), recentDays: 365);
      expect(s.recent.map((r) => r['name']), ['华法林', '赖诺普利', '左甲状腺素']);
      expect(s.earlier.map((r) => r['name']), ['伏立康唑', '美托洛尔']);
      final all = medsSplit(rows, today: DateTime(2026, 10, 22), recentDays: null);
      expect(all.recent.length, 4, reason: '全部:没写停的都算最近');
      expect(all.earlier.map((r) => r['name']), ['伏立康唑']);
      expect(medsByClass(s.recent).map((g) => g.label), ['心血管', '抗凝', '其他']);
      expect(medEarlierLine(s.earlier[1]), '2024-03-10 → 2025-03-01 · 3 次记录');
      expect(medEarlierLine(s.earlier[0]), '2024-03-10 → 2026-10-10 · 3 次记录 · 病历写了停药 2025-11-17');
      expect(allergyMatches({'substance': 'Penicillin', 'aliases': ['PENICILLINS']}, 'penicillins'), isTrue);
    });
    test('medNodeText 三种节点', () {
      expect(medNodeText({'kind': 'first', 'to': '5mg'}), '记录中自此起 5mg');
      expect(medNodeText({'kind': 'change', 'from': '5mg', 'to': '4mg'}), '5mg → 4mg');
      expect(medNodeText({'kind': 'stopped', 'to': '病历写了停药', 'text': 'X discontinued'}), '病历写了停药「X discontinued」');
    });
  });

  testWidgets('过敏在最上;三段计数;最近按药类分组;更早一味药一行「首次 → 最近 · N 次记录」;区间切全部', (t) async {
    await _pump(t);
    expect(find.text('最近的用药 · 3'), findsOneWidget);
    expect(find.text('1 年内有记录'), findsOneWidget);
    expect(find.text('过敏 · 1'), findsOneWidget);
    expect(find.text('更早的用药 · 2'), findsOneWidget);
    // 过敏在最近的用药之上。
    expect(t.getTopLeft(find.text('过敏 · 1')).dy, lessThan(t.getTopLeft(find.text('最近的用药 · 3')).dy));
    expect(find.text('抗凝 · 1'), findsOneWidget);
    expect(find.text('心血管 · 1'), findsNWidgets(2), reason: '最近一组、更早一组');
    expect(find.text('抗感染 · 1'), findsOneWidget);
    expect(find.text('记录中自 2025-01-14 起 · 12 天前有记录'), findsNWidgets(3));
    expect(find.text('2024-03-10 → 2026-10-10 · 3 次记录 · 病历写了停药 2025-11-17'), findsOneWidget);
    expect(find.text('2024-03-10 → 2025-03-01 · 3 次记录'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('range:all')));
    await t.pumpAndSettle();
    expect(find.text('最近的用药 · 4'), findsOneWidget);
    expect(find.text('更早的用药 · 1'), findsOneWidget);
  });

  testWidgets('搜「vori」:只剩伏立康唑,三段标题还在', (t) async {
    await _pump(t);
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'vori');
    await t.pumpAndSettle();
    expect(find.text('最近的用药 · 0'), findsOneWidget);
    expect(find.text('过敏 · 0'), findsOneWidget);
    expect(find.text('更早的用药 · 1'), findsOneWidget);
    expect(find.byType(MedRowView), findsOneWidget);
    expect(find.textContaining('伏立康唑'), findsOneWidget);
  });

  testWidgets('点开更早行:剂量链两节点,「原件 ›」可点,进弹层或原件', (t) async {
    await _pump(t);
    await t.tap(find.textContaining('伏立康唑'));
    await t.pumpAndSettle();
    expect(find.text('记录中自此起 200mg bid'), findsOneWidget);
    expect(find.text('病历写了停药「Voriconazole discontinued」'), findsOneWidget);
    expect(find.text('原件 ›'), findsNWidgets(2));
    await t.tap(find.textContaining('华法林'));
    await t.pumpAndSettle();
    expect(find.text('5mg daily → 4mg daily'), findsOneWidget);
  });

  testWidgets('过敏行点开看原文写法 + 查看原件;空过敏「记录里没找到过敏史」;空最近「1 年内没有用药记录」', (t) async {
    await _pump(t);
    expect(find.textContaining('1 份记录'), findsOneWidget);
    await t.tap(find.textContaining('Penicillin'));
    await t.pumpAndSettle();
    expect(find.text('病历里的写法 · 2'), findsOneWidget);
    expect(find.text('PENICILLINS'), findsOneWidget);
    expect(find.text('查看原件 · 1 份'), findsOneWidget);
    expect(find.byType(EvidencePickerBody), findsNothing);
    await _pump(t, view: _view(allergies: false, recent: false));
    expect(find.text('记录里没找到过敏史'), findsOneWidget);
    expect(find.text('1 年内没有用药记录'), findsOneWidget);
  });

  testWidgets('过敏很多(12 条):卡不超过 1/3 屏、卡内可滚、不溢出', (t) async {
    final v = _view();
    v['allergies'] = [
      for (var i = 0; i < 12; i++) {'substance': 'Allergen $i', 'reaction': 'Hives', 'evidence': ['ev:0:3'], 'aliases': ['Allergen $i']},
    ];
    await _pump(t, view: v);
    expect(t.takeException(), isNull);
    expect(find.text('过敏 · 12'), findsOneWidget);
    final card = find.ancestor(of: find.textContaining('Allergen 0'), matching: find.byType(MedCard)).first;
    expect(t.getSize(card).height, lessThanOrEqualTo(852 / 3 + 3), reason: '1/3 屏 + 卡的边框');
  });

  testWidgets('族预填:只剩心血管行,chip 可清掉', (t) async {
    medsFilterFamily.value = 'cardio';
    await _pump(t);
    expect(find.text('最近的用药 · 2'), findsOneWidget);
    expect(find.text('更早的用药 · 1'), findsOneWidget);
    expect(find.byType(InputChip), findsOneWidget);
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    expect(find.text('最近的用药 · 3'), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('措辞:不出现在吃 / 已停 / 当前用药 / 活动', (t) async {
    await _pump(t);
    for (final w in ['在吃', '已停', '当前用药', '在用药', '活动', '已解决']) {
      expect(find.textContaining(w), findsNothing, reason: w);
    }
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:全部点开不溢出', (t) async {
      await _pump(t, scale: scale);
      for (var i = 0; i < find.byType(MedRowView).evaluate().length; i++) {
        await t.tap(find.byType(MedRowView).at(i));
        await t.pumpAndSettle();
      }
      expect(t.takeException(), isNull);
    });
  }
}
