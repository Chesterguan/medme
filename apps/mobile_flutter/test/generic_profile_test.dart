// 通用病程档案(2026-10-22 spec,稿 A)的看门测试:一张入口卡 + 档案页按族折叠 + 病种包作段。
//
//  · 入口卡门槛(spec §4 / §9 第 8 条):带码诊断 ≥3 → 族 chip 行;<3 → 只出一行「已有 N 条
//    诊断记录」;一条诊断一种药都没有 → 「还没有诊断或用药记录」;JSON 缺键 → 同样退到这一句,不抛。
//  · 每个装着的包一行:没开 → 「开启」按钮(点了恰好记一条 enable);开了 → 「已开启」。
//  · 档案页三 tab(现在 / 进程 / 依据),393×852 × 三档字号每个 tab 不溢出;用药行文案逐字
//    「记录中自 YYYY-MM-DD 起」;全视图不出现「开始吃」「已停」「在吃」(spec §8.2 第 14 条)。
//
// 取数口子换成假的(FFI 上不了 host);通用视图用 Rust 侧真实引擎产出的 golden。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/disease_profile_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';

final Map<String, dynamic> _golden = jsonDecode(
  File('../../packages/profile/testdata/golden_generic_view.json').readAsStringSync(),
) as Map<String, dynamic>;

/// 真实引擎产出 + 手机侧顶层附的两个键。
Map<String, dynamic> _general({
  List<Map<String, dynamic>> packages = const [],
  List<Map<String, dynamic>>? sections,
}) => {
  ..._golden,
  'sections': ?sections,
  'packages': packages,
  'documents': const [],
};

Map<String, dynamic> _dx(String? code, {String text = 'x'}) => {
  'code': code,
  'texts': [text],
  'first_seen': '2024-01-01',
  'last_seen': '2026-01-01',
  'doc_count': 1,
  'evidence': const [],
  'unverified': false,
};

/// 只带诊断的最小通用视图(用药表空)。
Map<String, dynamic> _withDiagnoses(List<Map<String, dynamic>> cardio) => _general(
  sections: [
    {
      'kind': 'family_cards', 'id': 'general_families', 'title': '现在', 'empty_hint': null,
      'package_id': 'general',
      'body': {
        'families': [
          if (cardio.isNotEmpty)
            {'key': 'cardio', 'label': '心血管', 'count': cardio.length, 'last_seen': '2026-01-01',
             'diagnoses': cardio, 'labs': const []},
        ],
        'common_labs': const [],
      },
    },
    {
      'kind': 'med_table', 'id': 'general_meds', 'title': '现在', 'empty_hint': null,
      'package_id': 'general', 'body': {'rows': const [], 'stale_after_days': 180},
    },
    {'kind': 'journey', 'id': 'general_journey', 'title': '进程', 'empty_hint': null,
     'package_id': 'general', 'body': {'lanes': const []}},
    {'kind': 'evidence', 'id': 'general_evidence', 'title': '依据', 'empty_hint': null,
     'package_id': 'general', 'body': {'items': const []}},
  ],
);

class _Fake {
  _Fake(this.general);

  Map<String, dynamic> general;
  Object? generalError;
  final List<List<String>> calls = <List<String>>[];

  late final DiseaseProfileSource source = DiseaseProfileSource(
    installed: () async => const [],
    view: (id) async => '{}',
    record: (kind, pkg, at) async => calls.add([kind, pkg, at]),
    refresh: () async {},
    general: () async {
      final err = generalError;
      if (err != null) throw err;
      return jsonEncode(general);
    },
  );
}

Widget _card(DiseaseProfileSource source, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: DiseaseProfileCard(source: source))),
  ),
);

Widget _page(DiseaseProfileSource source, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: DiseaseProfileScreen(source: source),
  ),
);

void _usePhone(WidgetTester tester, {double height = 852}) {
  tester.view.physicalSize = Size(393 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 当前 tab 那张 ListView 的 Scrollable(TabBarView 本身也是一个 Scrollable,得点名)。
Finder _tabList() =>
    find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first;

/// 整棵树里所有 Text 的内容拼成一串。
String _allText(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join('\n');

const _kBanned = ['开始吃', '已停', '在吃', '慢性病', '活动期', '控制良好'];

void main() {
  group('入口卡', () {
    testWidgets('带码诊断 ≥3:一行族 chip、用药一行、最近住院一行', (t) async {
      final f = _Fake(_general());
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(find.text('病程档案'), findsOneWidget);
      expect(find.textContaining('心血管 3'), findsOneWidget);
      expect(find.textContaining('感染 1'), findsOneWidget);
      expect(find.textContaining('用药 5 种'), findsOneWidget);
      expect(find.textContaining('2 种超过 180 天没新记录'), findsOneWidget);
      expect(find.textContaining('最近住院 2025-06-02 → 2025-06-14'), findsOneWidget);
      expect(find.textContaining('已有'), findsNothing);
    });

    testWidgets('带码诊断 2 条:只出「已有 2 条诊断记录」,不展开族', (t) async {
      final f = _Fake(_withDiagnoses([_dx('I35.0'), _dx('Z95.2')]));
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(find.textContaining('已有 2 条诊断记录'), findsOneWidget);
      expect(find.textContaining('心血管'), findsNothing);
    });

    testWidgets('一条诊断一种药都没有:只写「还没有诊断或用药记录」', (t) async {
      final f = _Fake(_withDiagnoses(const []));
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(find.textContaining('还没有诊断或用药记录'), findsOneWidget);
    });

    testWidgets('JSON 缺 sections / packages 键:不抛,退到「还没有诊断或用药记录」', (t) async {
      final f = _Fake({'package_id': 'general'});
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining('还没有诊断或用药记录'), findsOneWidget);
    });

    testWidgets('取不到通用视图:一句「还没准备好」,不摆空档案', (t) async {
      final f = _Fake(_general())..generalError = StateError('ffi');
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining('还没准备好'), findsOneWidget);
    });

    testWidgets('装了没开的包:一行 + 「开启」,点了恰好记一条 enable', (t) async {
      final f = _Fake(_general(packages: [
        {'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': false},
      ]));
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(find.textContaining('系统性红斑狼疮'), findsOneWidget);
      expect(find.text('开启'), findsOneWidget);
      await t.tap(find.text('开启'));
      await t.pumpAndSettle();
      expect(f.calls, [
        ['enable', 'sle', isA<String>()],
      ]);
    });

    testWidgets('开着的包:「已开启」,没有「开启」按钮', (t) async {
      final f = _Fake(_general(packages: [
        {'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': true},
      ]));
      await t.pumpWidget(_card(f.source));
      await t.pumpAndSettle();
      expect(find.textContaining('系统性红斑狼疮:已开启'), findsOneWidget);
      expect(find.text('开启'), findsNothing);
    });

    for (final scale in [1.0, 1.3, 1.6]) {
      testWidgets('393 宽 字号 $scale:入口卡不溢出', (t) async {
        _usePhone(t);
        final f = _Fake(_general(packages: [
          {'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': false},
        ]));
        await t.pumpWidget(_card(f.source, textScale: scale));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  });

  group('档案页', () {
    testWidgets('三 tab;现在页按族折叠,展开后诊断原文 + 码 + N 份记录提到;用药行「记录中自 … 起」', (t) async {
      _usePhone(t);
      final f = _Fake(_general());
      await t.pumpWidget(_page(f.source));
      await t.pumpAndSettle();
      expect(find.widgetWithText(Tab, '现在'), findsOneWidget);
      expect(find.widgetWithText(Tab, '进程'), findsOneWidget);
      expect(find.widgetWithText(Tab, '依据'), findsOneWidget);
      expect(find.textContaining('心血管'), findsWidgets);
      // 族默认折叠:诊断原文还没出现;展开后出现。
      expect(find.textContaining('Status post AVR'), findsNothing);
      await t.tap(find.textContaining('心血管').first);
      await t.pumpAndSettle();
      expect(find.textContaining('Status post AVR'), findsOneWidget);
      expect(find.textContaining('Z95.2'), findsWidgets);
      expect(find.textContaining('10 份记录提到'), findsOneWidget);
      // 用药行。
      await t.scrollUntilVisible(find.textContaining('记录中自 2025-01-14 起'), 300, scrollable: _tabList());
      expect(find.textContaining('记录中自 2025-01-14 起'), findsOneWidget);
      expect(find.textContaining('病历写了停药'), findsOneWidget);
      expect(find.textContaining('天没有新记录'), findsWidgets);
      // 进程页。
      await t.tap(find.widgetWithText(Tab, '进程'));
      await t.pumpAndSettle();
      expect(find.textContaining('住院 9 天'), findsOneWidget);
      expect(find.textContaining('住院 12 天'), findsOneWidget);
    });

    testWidgets('包作页内一段:开着的包段在通用段后面,带关闭按钮;没开的只有一行 + 开启', (t) async {
      // 高给足:ListView 懒建,包那一段在通用段后面,得让它真的建出来、点得到。
      _usePhone(t, height: 4000);
      final sle = {
        'kind': 'state', 'id': 'sle_state', 'title': '狼疮 · 现在', 'empty_hint': null,
        'package_id': 'sle',
        'body': {'vars': [
          {'key': 'gc', 'label': '激素', 'value': '5', 'unit': 'mg/天', 'as_of': '2026-03-16',
           'stale': false, 'stale_after_days': 90, 'evidence': const [], 'note': null, 'source': null},
        ]},
      };
      final f = _Fake(_general(
        packages: [{'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': true}],
        sections: [...(_golden['sections'] as List).cast<Map<String, dynamic>>(), sle],
      ));
      await t.pumpWidget(_page(f.source));
      await t.pumpAndSettle();
      expect(find.text('关闭病程档案'), findsOneWidget);
      expect(find.textContaining('系统性红斑狼疮'), findsWidgets);
      expect(find.text('狼疮 · 现在'), findsOneWidget);
      await t.tap(find.text('关闭病程档案'));
      await t.pumpAndSettle();
      expect(f.calls.last, ['disable', 'sle', isA<String>()]);

      final g = _Fake(_general(packages: [
        {'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': false},
      ]));
      // 同一位置同类型的 widget 会复用上一个 State(`late final` 的取数口子跟着留下来),先拆掉。
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_page(g.source));
      await t.pumpAndSettle();
      expect(find.text('开启病程档案'), findsOneWidget);
      expect(find.text('狼疮 · 现在'), findsNothing);
      await t.tap(find.text('开启病程档案'));
      await t.pumpAndSettle();
      expect(g.calls.last, ['enable', 'sle', isA<String>()]);
    });

    testWidgets('措辞:全视图不出现「开始吃」「已停」「在吃」等结论词', (t) async {
      _usePhone(t);
      final f = _Fake(_general());
      await t.pumpWidget(_page(f.source));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('心血管').first);
      await t.pumpAndSettle();
      for (final tab in ['现在', '进程', '依据']) {
        await t.tap(find.widgetWithText(Tab, tab));
        await t.pumpAndSettle();
        final text = _allText(t);
        for (final w in _kBanned) {
          expect(text.contains(w), isFalse, reason: '「$tab」里出现了「$w」');
        }
      }
      // 源码级也扫一遍这三个文件,只扫 spec §8.2 第 14 条点名的三个词(其它屏合法地说
      // 「正在吃的药」,所以不进全局文案闸;「活动期」是包的病级节律标签,渲染层的词表里本来就有)。
      for (final path in [
        'lib/widgets/disease_profile_card.dart',
        'lib/screens/disease_profile_screen.dart',
        'lib/widgets/profile_sections.dart',
      ]) {
        final src = File(path).readAsStringSync();
        for (final w in const ['开始吃', '已停', '在吃']) {
          expect(src.contains(w), isFalse, reason: '$path 里写了「$w」');
        }
      }
    });

    for (final scale in [1.0, 1.3, 1.6]) {
      testWidgets('393×852 字号 $scale:三个 tab 全部展开都不溢出', (t) async {
        _usePhone(t);
        final f = _Fake(_general(packages: [
          {'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': false},
        ]));
        await t.pumpWidget(_page(f.source, textScale: scale));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        for (final fam in ['心血管', '感染', '未归类']) {
          await t.tap(find.textContaining(fam).first);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: '展开「$fam」后');
        }
        for (final tab in ['进程', '依据']) {
          await t.tap(find.widgetWithText(Tab, tab));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: '「$tab」');
        }
      });
    }
  });
}
