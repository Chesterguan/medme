// 「病程档案」入口卡(`widgets/disease_profile_card.dart`)与独立页
// (`screens/disease_profile_screen.dart`)的看门测试 —— 2026-10-22 通用病程档案(稿 A)之后
// 剩下的那些硬规矩(族折叠、门槛、包作段在 `generic_profile_test.dart`):
//
//  1. **取数失败不摆空档案**:一句「还没准备好」;一个包都没装上时静默拉一次清单。
//  2. **开关只由事件决定**:记不上就**不假装已经开了**;添加了新病历这张卡当场重算。
//  3. 独立页**三态各验一次**(加载中 / 成功 / 失败,memory `test-all-three-states`);
//     出处默认收起、展开后包里每一条题录逐字都在;2× 字号一路滚到底不溢出(含开着的 SLE 包段)。
//  4. 真实引擎产出下卡片上没有结论性措辞。
//
// 取数口子([DiseaseProfileSource])整个换成假的:那几件事要么走 FFI、要么走平台通道,
// `flutter test` 不带原生库,一条都跑不起来。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/disease_profile_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';

Map<String, dynamic> _readGolden(String name) =>
    jsonDecode(File('../../packages/profile/testdata/$name').readAsStringSync()) as Map<String, dynamic>;

/// 通用层真实引擎产出(Doe, Jane)。
final _general = _readGolden('golden_generic_view.json');

/// SLE 包真实引擎产出(李静);它的 sections 叠在通用段后面时带 `package_id: sle`。
final _sle = _readGolden('golden_profile_view.json');

List<Map<String, dynamic>> _sections(Map<String, dynamic> v) =>
    (v['sections'] as List).map((s) => (s as Map).cast<String, dynamic>()).toList();

/// 手机侧 `vault_profile_view_general` 的形状:通用 golden + `packages[]` + `documents[]`;
/// `withSle` = SLE 包装着并开着,它的段叠在后面、出处合并进来。
Map<String, dynamic> _view({bool withSle = false, bool sleEnabled = true}) => {
  ..._general,
  'sections': [
    ..._sections(_general),
    if (withSle && sleEnabled)
      for (final s in _sections(_sle)) {...s, 'package_id': 'sle'},
  ],
  'sources': withSle && sleEnabled ? _sle['sources'] : const [],
  'packages': [
    if (withSle) {'id': 'sle', 'display_name': '系统性红斑狼疮', 'enabled': sleEnabled},
  ],
  'documents': const [],
};

class _Fake {
  _Fake({Map<String, dynamic>? view, this.ids = const []}) : view = view ?? _view();

  Map<String, dynamic> view;
  List<String> ids;
  Object? generalError;
  Object? recordError;
  final List<List<String>> calls = <List<String>>[];
  int generals = 0;
  int refreshes = 0;

  late final DiseaseProfileSource source = DiseaseProfileSource(
    installed: () async => ids,
    view: (id) async => '{}',
    record: (kind, pkg, at) async {
      calls.add([kind, pkg, at]);
      final err = recordError;
      if (err != null) throw err;
    },
    refresh: () async => refreshes++,
    general: () async {
      generals++;
      final err = generalError;
      if (err != null) throw err;
      return jsonEncode(view);
    },
  );
}

Widget _wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Widget _page(DiseaseProfileSource source, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: DiseaseProfileScreen(source: source),
  ),
);

void _usePhone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(400 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 今天(设备本地日期),`YYYY-MM-DD`。**不复用 app 里那个格式化函数**。
String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

void main() {
  group('入口卡', () {
    testWidgets('一个包都没装上:静默拉一次清单;拉不到就只画通用摘要', (t) async {
      final f = _Fake();
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: f.source)));
      await t.pumpAndSettle();
      expect(f.refreshes, 1);
      expect(f.generals, 1, reason: '清单没拉到新包就不重算');
      expect(find.textContaining('心血管 3'), findsOneWidget);
    });

    testWidgets('装着包:一次都不联网', (t) async {
      final f = _Fake(view: _view(withSle: true), ids: const ['sle']);
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: f.source)));
      await t.pumpAndSettle();
      expect(f.refreshes, 0);
    });

    testWidgets('记不上就不假装已经开了', (t) async {
      final f = _Fake(view: _view(withSle: true, sleEnabled: false), ids: const ['sle'])
        ..recordError = StateError('disk full');
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: f.source)));
      await t.pumpAndSettle();
      await t.tap(find.text('开启'));
      await t.pumpAndSettle();
      expect(f.calls.single.sublist(0, 2), ['enable', 'sle']);
      expect(f.calls.single[2], _today());
      expect(find.text('开启'), findsOneWidget, reason: '没记上,按钮还在');
      expect(find.textContaining('这次没记上'), findsOneWidget);
    });

    testWidgets('添加了新病历:这张卡当场重算', (t) async {
      final f = _Fake();
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: f.source)));
      await t.pumpAndSettle();
      expect(f.generals, 1);
      bumpVaultRevision();
      await t.pumpAndSettle();
      expect(f.generals, 2);
    });

    testWidgets('卡片不下结论 —— 真实引擎产出下也没有那几句话', (t) async {
      final f = _Fake(view: _view(withSle: true), ids: const ['sle']);
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: f.source)));
      await t.pumpAndSettle();
      final text = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
      for (final w in ['开始吃', '已停', '在吃', '慢性病', '活动期', '控制良好']) {
        expect(text.contains(w), isFalse, reason: w);
      }
    });
  });

  group('独立页', () {
    testWidgets('加载中:转圈,不先摆一个空页', (t) async {
      _usePhone(t);
      final never = Completer<String>();
      final source = DiseaseProfileSource(
        installed: () async => const [],
        view: (id) async => '{}',
        record: (kind, pkg, at) async {},
        refresh: () async {},
        general: () => never.future,
      );
      await t.pumpWidget(_page(source));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('病程档案'), findsOneWidget);
    });

    testWidgets('成功:包段在通用段后面、按包给的顺序;免责声明在「现在」最后', (t) async {
      _usePhone(t, height: 24000);
      final f = _Fake(view: _view(withSle: true), ids: const ['sle']);
      await t.pumpWidget(_page(f.source));
      await t.pumpAndSettle();
      double dy(String text) => t.getTopLeft(find.text(text).last).dy;
      // 通用段的头(族折叠条)在包段的头之前。
      final generalTop = t.getTopLeft(find.textContaining('心血管 · 3 条诊断')).dy;
      final pkgHeader = dy('系统性红斑狼疮(病种包)');
      expect(pkgHeader, greaterThan(generalTop));
      // 包段按包给的顺序(只看「现在」tab 里的那些)。
      const tab0 = {'state', 'status_card', 'score_card', 'reminders', 'checklist'};
      var last = pkgHeader;
      for (final s in _sections(_sle)) {
        if (!tab0.contains(s['kind'])) continue;
        final title = s['title'] as String?;
        if (title == null || title.isEmpty || title == '现在') continue;
        expect(find.text(title), findsWidgets, reason: title);
        final y = dy(title);
        expect(y, greaterThan(last), reason: '「$title」没按包给的顺序摆');
        last = y;
      }
      final disclaimer = _general['disclaimer'] as String;
      expect(find.text(disclaimer), findsOneWidget);
      expect(dy(disclaimer), greaterThan(last));
    });

    testWidgets('出处:默认收起,展开后包里每一条题录逐字都在', (t) async {
      _usePhone(t, height: 20000);
      final f = _Fake(view: _view(withSle: true), ids: const ['sle']);
      final cites = (_sle['sources'] as List).map((s) => '${(s as Map)['id']} · ${s['cite']}').toList();
      expect(cites.length, 24, reason: 'golden 里就是这么多条,数变了要来看一眼');
      await t.pumpWidget(_page(f.source));
      await t.pumpAndSettle();
      expect(find.text('出处'), findsOneWidget);
      expect(find.text(cites.first), findsNothing, reason: '默认收起');
      await t.tap(find.text('出处'));
      await t.pumpAndSettle();
      for (final cite in cites) {
        expect(find.text(cite), findsOneWidget, reason: cite);
      }
      await t.tap(find.text('出处'));
      await t.pumpAndSettle();
      expect(find.text(cites.first), findsNothing);
    });

    testWidgets('失败:一句话 + 重试,点了真的重算', (t) async {
      _usePhone(t);
      final f = _Fake()..generalError = StateError('保险箱尚未打开 /tmp/x');
      await t.pumpWidget(_page(f.source));
      await t.pumpAndSettle();
      expect(find.textContaining('打不开'), findsOneWidget);
      expect(find.textContaining('/tmp/x'), findsNothing, reason: 'Rust 那句错误原文不摆给用户看');
      f.generalError = null;
      await t.tap(find.text('重试'));
      await t.pumpAndSettle();
      expect(f.generals, 2);
      expect(find.textContaining('心血管'), findsWidgets);
    });

    testWidgets('400×800、2× 字号:通用段 + SLE 包段一路滚到底都不溢出', (t) async {
      _usePhone(t);
      final f = _Fake(view: _view(withSle: true), ids: const ['sle']);
      await t.pumpWidget(_page(f.source, textScale: 2.0));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      for (final fam in ['心血管', '感染', '未归类']) {
        await t.tap(find.textContaining(fam).first);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: '展开「$fam」后');
      }
      for (var i = 0; i < 16; i++) {
        await t.drag(find.byType(ListView).first, const Offset(0, -1200));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: '第 $i 屏溢出');
      }
    });
  });
}
