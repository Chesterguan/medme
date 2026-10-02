// 病程档案三视图(spec 2026-09-30):`state` / `journey` / `evidence` 三种 section
// 的渲染看门。吃的是真实引擎产出(`packages/profile/testdata/golden_profile_view_llm.json`,
// 李静语料 + 云抽取那条路跑出来的 golden),钉的是硬规矩:
//  1. 三段在窄屏 + 2× 字号下不溢出、不崩;
//  2. 「未知」就是未知,值为 null 的变量显示「未知」,不塌成别的结论;
//  3. 依据能点:点一条依据,页面拿到的是那条依据本身(含 doc/quote),不是别的;
//  4. 没核对上的节点/依据标「需核对」,照样显示。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';

final _golden =
    jsonDecode(
          File(
            '../../packages/profile/testdata/golden_profile_view_llm.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

List<Map<String, dynamic>> get _sections => (_golden['sections'] as List)
    .map((s) => (s as Map).cast<String, dynamic>())
    .toList();

Map<String, dynamic> _section(String kind) =>
    _sections.firstWhere((s) => s['kind'] == kind);

Map<String, Map<String, dynamic>> _evidenceById() {
  final items = (_section('evidence')['body'] as Map)['items'] as List;
  return {
    for (final e in items)
      (e as Map)['id'] as String: e.cast<String, dynamic>(),
  };
}

Widget _wrap(Widget child, {double textScale = 1.0, double width = 360}) =>
    MaterialApp(
      theme: MedMe.theme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  testWidgets('three sections render from the golden without overflow', (
    t,
  ) async {
    for (final kind in ['state', 'journey', 'evidence']) {
      await t.pumpWidget(
        _wrap(ProfileSectionView(_section(kind)), textScale: 2.0, width: 320),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$kind 在 2× 字号窄屏下崩了');
    }
  });

  testWidgets('state rows show value, as-of and stale wording from the engine', (
    t,
  ) async {
    await t.pumpWidget(_wrap(ProfileSectionView(_section('state'))));
    await t.pumpAndSettle();
    // golden:激素 7.5 mg/天,截至 2026-06-15,超过 90 天没有新记录。
    expect(find.textContaining('7.5', findRichText: true), findsWidgets);
    expect(find.textContaining('截至 2026-06-15'), findsWidgets);
    expect(find.textContaining('超过 90 天没有新记录'), findsWidgets);
  });

  testWidgets('a variable without a value says 未知, not something stronger', (
    t,
  ) async {
    final s = Map<String, dynamic>.from(_section('state'));
    s['body'] = {
      'vars': [
        {
          'key': 'x',
          'label': '某项',
          'value': null,
          'unit': null,
          'as_of': null,
          'stale': false,
          'stale_after_days': 90,
          'evidence': <String>[],
          'note': '最近 10 天内没有化验结果,算不出来',
          'source': 'S1',
        },
      ],
    };
    await t.pumpWidget(_wrap(ProfileSectionView(s)));
    await t.pumpAndSettle();
    expect(find.text('未知'), findsOneWidget);
    expect(find.textContaining('最近 10 天内没有化验结果'), findsOneWidget);
    expect(find.textContaining('未达'), findsNothing);
  });

  testWidgets('tapping an evidence chip hands the page that evidence', (
    t,
  ) async {
    Map<String, dynamic>? opened;
    final links = ProfileLinks(
      evidenceById: _evidenceById(),
      onOpen: (e) => opened = e,
    );
    await t.pumpWidget(
      _wrap(ProfileSectionView(_section('state'), links: links)),
    );
    await t.pumpAndSettle();
    final chip = find.byType(ActionChip).first;
    await t.ensureVisible(chip);
    await t.tap(chip);
    await t.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened!['id'], startsWith('ev:'));
    expect(opened!['quote'], isA<String>());
    expect(opened!['doc'], isA<num>());
  });

  testWidgets('journey lane shows from → to and opens the first evidence', (
    t,
  ) async {
    Map<String, dynamic>? opened;
    final links = ProfileLinks(
      evidenceById: _evidenceById(),
      onOpen: (e) => opened = e,
    );
    await t.pumpWidget(
      _wrap(ProfileSectionView(_section('journey'), links: links)),
    );
    await t.pumpAndSettle();
    // golden 激素泳道:50mg qd → 20mg qd。
    final change = find.text('50mg qd → 20mg qd');
    expect(change, findsOneWidget);
    await t.ensureVisible(change);
    await t.tap(change);
    await t.pumpAndSettle();
    expect(opened?['quote'], contains('醋酸泼尼松片'));
  });

  testWidgets('unverified node and evidence are shown with 需核对', (t) async {
    final journey = Map<String, dynamic>.from(_section('journey'));
    journey['body'] = {
      'lanes': [
        {
          'key': 'flare',
          'label': '复发 / 加重',
          'quality': 'needs_review',
          'nodes': [
            {
              'at': '2025-02-01',
              'kind': 'flare',
              'from': null,
              'to': '病情活动加重',
              'text': '病情活动加重',
              'evidence': ['ev:0:1'],
              'unverified': true,
            },
          ],
        },
      ],
    };
    await t.pumpWidget(_wrap(ProfileSectionView(journey)));
    await t.pumpAndSettle();
    expect(find.textContaining('病情活动加重'), findsOneWidget);
    expect(find.textContaining('需核对'), findsWidgets);
  });
}
