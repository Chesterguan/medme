// 「用药」页(2026-10-23 spec §5、§11.2 验收 9)。合成数据,Doe, Jane 的形状。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/meds_model.dart';
import 'package:mobile_flutter/screens/meds_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';

Map<String, dynamic> _row(String name, String raw, String dose, String family, {bool stale = false, Map<String, dynamic>? stopped, List<Map<String, dynamic>> nodes = const []}) => {
  'name': name, 'raw_name': raw, 'raw_names': [raw], 'drug_key': name, 'dose': dose,
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
          _row('华法林', 'Warfarin', '4mg', 'cardio', nodes: [
            {'at': '2024-03-10', 'kind': 'first', 'from': null, 'to': '5mg daily', 'text': 'Warfarin', 'evidence': ['ev:0:1'], 'unverified': false},
            {'at': '2025-01-14', 'kind': 'change', 'from': '5mg daily', 'to': '4mg daily', 'text': 'Warfarin', 'evidence': ['ev:1:1'], 'unverified': false},
          ]),
          _row('赖诺普利', 'Lisinopril', '10mg', 'cardio'),
          _row('左甲状腺素', 'Levothyroxine', '50mcg', 'endocrine'),
        ]
      : [],
  'earlier': [
    _row('伏立康唑', 'Voriconazole', '200mg bid', 'infection', stopped: {'at': '2025-11-17', 'evidence': 'ev:1:2'}, nodes: [
      {'at': '2025-06-14', 'kind': 'first', 'from': null, 'to': '200mg bid', 'text': 'Voriconazole', 'evidence': ['ev:0:1'], 'unverified': false},
      {'at': '2025-11-17', 'kind': 'stopped', 'from': '200mg bid', 'to': '病历写了停药', 'text': 'Voriconazole discontinued', 'evidence': ['ev:1:2'], 'unverified': false},
    ]),
    _row('美托洛尔', 'Metoprolol', '25mg', 'cardio', stale: true),
  ],
  'allergies': allergies
      ? [
          {'substance': 'Penicillin', 'reaction': 'Rash', 'evidence': ['ev:0:3']},
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
  await t.pumpWidget(_wrap(MedsScreen(key: UniqueKey(), load: () async => view ?? _view()), scale: scale));
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
    test('medNodeText 三种节点', () {
      expect(medNodeText({'kind': 'first', 'to': '5mg'}), '记录中自此起 5mg');
      expect(medNodeText({'kind': 'change', 'from': '5mg', 'to': '4mg'}), '5mg → 4mg');
      expect(medNodeText({'kind': 'stopped', 'to': '病历写了停药', 'text': 'X discontinued'}), '病历写了停药「X discontinued」');
    });
  });

  testWidgets('三段计数;最近行写「记录中自 … 起 · N 天前有记录」;更早行写停药', (t) async {
    await _pump(t);
    expect(find.text('最近的用药 · 3'), findsOneWidget);
    expect(find.text('180 天内有记录'), findsOneWidget);
    expect(find.text('过敏 · 1'), findsOneWidget);
    expect(find.text('更早的用药 · 2'), findsOneWidget);
    expect(find.text('记录中自 2025-01-14 起 · 12 天前有记录'), findsNWidgets(3));
    expect(find.text('病历写了停药 · 2025-11-17'), findsOneWidget);
    expect(find.text('记录中自 2025-01-14 起 · 600 天没有新记录'), findsOneWidget);
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

  testWidgets('过敏行可点(有依据);空过敏「记录里没找到过敏史」;空最近「最近 180 天没有用药记录」', (t) async {
    await _pump(t);
    // 单条依据 → 直接 push 原件页,真 FFI 在测试里拿不到文档,所以只验这一行是可点的。
    final ink = find.ancestor(of: find.textContaining('Penicillin'), matching: find.byType(InkWell)).first;
    expect(t.widget<InkWell>(ink).onTap, isNotNull);
    expect(find.byType(EvidencePickerBody), findsNothing);
    await _pump(t, view: _view(allergies: false, recent: false));
    expect(find.text('记录里没找到过敏史'), findsOneWidget);
    expect(find.text('最近 180 天没有用药记录'), findsOneWidget);
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
