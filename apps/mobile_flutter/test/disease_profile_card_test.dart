// 「病程档案」入口卡(`widgets/disease_profile_card.dart`)与独立页
// (`screens/disease_profile_screen.dart`)的看门测试。钉住的都是硬规矩:
//
//  1. **三态各说各的实话**:一个病种包都没装上 → 只说「还没准备好」,不摆一份不
//     存在的档案;装上了还没开启 → 给一颗「开启」,**不自动开、不替用户贴标签**
//     (spec §4/§5.1);开启了 → 显示包给的那条摘要。
//  2. **开关只由事件决定**:点「开启」恰好记一条 `enable`(日期是今天),记完
//     重算;记不上就**不假装已经开了**。
//  3. **一句写死的病种文案都没有** —— 病名、标题、空态提示、免责声明全来自包,
//     逐字。
//  4. 独立页**三态各验一次**(加载中 / 成功 / 失败,memory `test-all-three-states`),
//     而且真实引擎产出(golden)在窄屏 + 2× 系统字号下一路滚到底都不溢出。
//
// 取数口子([DiseaseProfileSource])整个换成假的:那四件事要么走 FFI、要么走平台
// 通道,`flutter test` 不带原生库,一条都跑不起来。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/disease_profile_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';

/// 与 `test/profile_sections_test.dart` 同一份 golden:合成 SLE 语料跑出来的真实
/// 引擎产出(CWD 是 `apps/mobile_flutter`,相对路径两层上到仓库根)。
final _golden =
    jsonDecode(
          File(
            '../../packages/profile/testdata/golden_profile_view.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

List<Map<String, dynamic>> _goldenSections() => (_golden['sections'] as List)
    .map((s) => (s as Map).cast<String, dynamic>())
    .toList();

/// 「装上了,还没开启」—— 引擎在这种情况下不算任何东西,`sections` 是空的。
Map<String, dynamic> _offView() => {
  'package_id': 'sle',
  'package_version': '2026.09.1',
  'display_name': '系统性红斑狼疮',
  'enabled': false,
  'disclaimer': '仅整理你的病历,不做诊断',
  'sections': const [],
  'sources': const [],
};

Map<String, dynamic> _onView({List<Map<String, dynamic>>? sections}) => {
  ..._offView(),
  'enabled': true,
  'sections':
      sections ??
      [
        {
          'kind': 'reminders',
          'id': null,
          'title': '待补 / 逾期',
          'empty_hint': null,
          'body': {
            'items': [
              {'id': 'a', 'action': '该补钙和维生素 D 了'},
              {'id': 'b', 'action': '做一次骨密度'},
            ],
          },
        },
      ],
};

/// 假的取数口子。**一个实例只造一次** `DiseaseProfileSource`(卡片把它存成
/// `late final`),不然计数会落在不同的对象上。
class _Fake {
  _Fake({this.ids = const ['sle'], Map<String, dynamic>? view})
    : view = view ?? _onView();

  List<String> ids;
  Map<String, dynamic> view;

  /// 非 null 时 `view()` 抛这个 —— 「算不出来 / 没有包」那一路。
  Object? viewError;

  /// 非 null 时 `record()` 抛这个 —— 「这次没记上」那一路。
  Object? recordError;

  /// 每次 `refresh()` 之后跑一下 —— 「重新拉一遍包」在真机上会把缓存里那份坏的
  /// 整份换掉,这个钩子就是用来摆出那个结果的。
  void Function()? onRefresh;

  final List<List<String>> calls = <List<String>>[];
  int views = 0;
  int refreshes = 0;

  late final DiseaseProfileSource source = DiseaseProfileSource(
    installed: () async => ids,
    view: (id) async {
      views++;
      final err = viewError;
      if (err != null) throw err;
      return jsonEncode(view);
    },
    record: (kind, pkg, at) async {
      calls.add([kind, pkg, at]);
      final err = recordError;
      if (err != null) throw err;
    },
    refresh: () async {
      refreshes++;
      onRefresh?.call();
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

Widget _page(DiseaseProfileSource source, {double textScale = 1.0}) =>
    MaterialApp(
      theme: MedMe.theme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: DiseaseProfileScreen(packageId: 'sle', source: source),
      ),
    );

void _usePhone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(400 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 今天(设备本地日期),`YYYY-MM-DD`。**不复用 app 里那个格式化函数** ——
/// 它正是被测的东西之一。
String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

void main() {
  group('入口卡', () {
    testWidgets('一个病种包都没装上:只说还没准备好,并且静默拉过一次清单', (t) async {
      _usePhone(t);
      final fake = _Fake(ids: const []);
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      expect(fake.refreshes, 1, reason: '第一次显示时拉一次清单,静默');
      expect(fake.views, 0, reason: '没有包就别去算视图');
      expect(find.textContaining('病程档案'), findsOneWidget);
      expect(find.textContaining('还没准备好'), findsOneWidget);
      // 没有包时**一个字都不许假装已经有一份档案**。
      expect(find.text('开启'), findsNothing);
    });

    // ── task-26 F2:缓存里那份被改过一个字节 ────────────────────────────
    //
    // `cache_load` 每次读都重新验签,所以那份包算不出任何东西;而磁盘上那个文件的
    // 名字还在,「装着哪几个包」看谁都是装着 —— 光原地重试一万次也只会一万次验不过。
    testWidgets('缓存里那份验不过:重新拉一遍包,卡片自己活过来', (t) async {
      _usePhone(t);
      final fake = _Fake()..viewError = StateError('没有可用的病种包:sle');
      fake.onRefresh = () => fake.viewError = null; // 坏的那份被整份换掉了
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      expect(fake.refreshes, 1, reason: '验不过 = 没装上,得重新拉一遍');
      expect(find.text('病程档案 · 系统性红斑狼疮'), findsOneWidget, reason: '自愈之后该活过来');
      expect(find.textContaining('还没准备好'), findsNothing);
    });

    testWidgets('缓存好好的:一次都不联网', (t) async {
      _usePhone(t);
      final fake = _Fake();
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      expect(fake.refreshes, 0, reason: '装着的那份算得出来,就没有任何理由去联网');
      expect(fake.views, 1);
    });

    testWidgets('装上了但还没开启:给一颗「开启」,不替用户贴标签', (t) async {
      _usePhone(t);
      final fake = _Fake(view: _offView());
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      expect(find.text('开启'), findsOneWidget);
      // spec §5.1:不自动贴标签。卡上可以说「可以整理这个病」,不能说他患有什么。
      for (final banned in ['你患有', '确诊', '你的病是']) {
        expect(find.textContaining(banned), findsNothing, reason: banned);
      }
      expect(fake.calls, isEmpty, reason: '没点之前一条事件都不许记');
    });

    testWidgets('开启了:标题带上包给的病名,摘要那一行原文来自包', (t) async {
      _usePhone(t);
      final fake = _Fake();
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      expect(find.text('病程档案 · 系统性红斑狼疮'), findsOneWidget);
      expect(find.text('待补 / 逾期'), findsOneWidget, reason: '标题来自包');
      expect(find.text('2 项'), findsOneWidget);
      expect(find.text('开启'), findsNothing, reason: '已经开着了');
    });

    testWidgets('开启了但这一块还没数据:原样举着包给的那句空态提示', (t) async {
      _usePhone(t);
      final fake = _Fake(
        view: _onView(
          sections: [
            {
              'kind': 'reminders',
              'id': null,
              'title': '待补 / 逾期',
              'empty_hint': '该查的都查过了',
              'body': const {'items': []},
            },
          ],
        ),
      );
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      expect(find.text('该查的都查过了'), findsOneWidget);
    });

    testWidgets('点「开启」:恰好记一条 enable(日期是今天),记完重算', (t) async {
      _usePhone(t);
      final fake = _Fake(view: _offView());
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();
      expect(fake.views, 1);

      // 点下去之后这个包就是开着的了 —— 开关状态由事件算出来,所以重算必须
      // 真的再问一次口子,不是本地翻一个 bool。
      fake.view = _onView();
      await t.tap(find.text('开启'));
      await t.pumpAndSettle();

      expect(fake.calls.length, 1, reason: '恰好一条');
      expect(fake.calls.single.sublist(0, 2), ['enable', 'sle']);
      expect(fake.calls.single[2], _today(), reason: 'at = 今天,YYYY-MM-DD');
      // 记完重算现在走两条路:`record()` 记上了会 `bumpVaultRevision()`(F-A 修
      // 复,首页待办卡与防抖同步推送靠这个信号才知道要重算),而这张卡自己也
      // 监听着 `vaultRevision`(收外部改动的信号,见下面「添加了新病历」那条)——
      // 于是一次 enable 触发两次重算:bump 同步唤醒监听器一次,`_enable` 自己
      // 在 `record()` 之后又显式重算一次。两次都是纯投影,多算不是错,只是多余。
      expect(fake.views, 3, reason: '记完重算(bump 一次 + _enable 自己一次)');
      expect(find.text('待补 / 逾期'), findsOneWidget);
    });

    testWidgets('记不上就不假装已经开了', (t) async {
      _usePhone(t);
      final fake = _Fake(view: _offView())..recordError = StateError('病历箱没开');
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      await t.tap(find.text('开启'));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull, reason: '记不上不许把这一屏带塌');
      expect(find.text('开启'), findsOneWidget, reason: '还是没开启的那一态');
      expect(find.textContaining('没记上'), findsOneWidget);
      expect(fake.views, 1, reason: '没记上就别重算');
    });

    testWidgets('添加了新病历:这张卡当场重算,不停在旧的那句话上', (t) async {
      // 三个 tab 用 `IndexedStack` 保活(`vault_events.dart`),切走再切回来
      // `initState` 不会再跑一次 —— 不听这个信号,卡上那句「待补 / 逾期 N 项」
      // 会一直停在开 App 那一刻。
      _usePhone(t);
      final fake = _Fake();
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();
      expect(fake.views, 1);

      bumpVaultRevision();
      await t.pumpAndSettle();
      expect(fake.views, 2);
    });

    testWidgets('2× 字号:三态都不溢出', (t) async {
      _usePhone(t);
      for (final fake in [
        _Fake(ids: const []),
        _Fake(view: _offView()),
        _Fake(view: _golden),
      ]) {
        await t.pumpWidget(
          _wrap(DiseaseProfileCard(source: fake.source), textScale: 2.0),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('卡片不下结论 —— 真实引擎产出下也没有那几句话', (t) async {
      _usePhone(t);
      final fake = _Fake(view: _golden);
      await t.pumpWidget(_wrap(DiseaseProfileCard(source: fake.source)));
      await t.pumpAndSettle();

      for (final banned in ['确诊', '已缓解', '判断缓解', '计算 SLEDAI']) {
        expect(find.textContaining(banned), findsNothing, reason: banned);
      }
    });
  });

  group('独立页', () {
    testWidgets('加载中:转圈,不先摆一个空页', (t) async {
      _usePhone(t);
      final never = Completer<String>();
      final source = DiseaseProfileSource(
        installed: () async => const ['sle'],
        view: (id) => never.future,
        record: (kind, pkg, at) async {},
        refresh: () async {},
      );
      await t.pumpWidget(_page(source));
      await t.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // 还不知道病名时用这一块自己的名字,不占位编一个病名。
      expect(find.text('病程档案'), findsOneWidget);
    });

    testWidgets('成功:包给的 section 按包给的顺序全画出来,免责声明逐字在最后', (t) async {
      // 视口拉高,好让 `ListView` 一次把整页布局出来 —— 顺序只能整页比。
      // 24000:包的 `note`(每条「与指南口径有差」的话)进了渲染层之后,整页比
      // 原来高出一截,12000 装不下最后那句免责声明,`ListView` 压根不建它。
      _usePhone(t, height: 24000);
      final fake = _Fake(view: _golden);
      await t.pumpWidget(_page(fake.source));
      await t.pumpAndSettle();

      // 标题是包给的病名。
      expect(find.text('系统性红斑狼疮'), findsOneWidget);

      double dy(String text) => t.getTopLeft(find.text(text)).dy;
      var last = -1.0;
      for (final s in _goldenSections()) {
        final title = s['title'] as String?;
        if (title == null || title.isEmpty) continue;
        expect(find.text(title), findsOneWidget, reason: title);
        final y = dy(title);
        expect(y, greaterThan(last), reason: '「$title」没按包给的顺序摆');
        last = y;
      }

      // 免责声明:**包给的那句**,逐字,而且在所有 section 后面。
      final disclaimer = _golden['disclaimer'] as String;
      expect(find.text(disclaimer), findsOneWidget);
      expect(dy(disclaimer), greaterThan(last));
    });

    testWidgets('出处:默认收起,展开后包里每一条题录逐字都在', (t) async {
      // 卡片里印的是出处 id(「出处 S12」),全文只有这一块 —— 没有它,那些 id
      // 就是查不到去处的编号。视口拉高,好让展开后的二十几条一次都布局出来。
      _usePhone(t, height: 20000);
      final fake = _Fake(view: _golden);
      final cites = (_golden['sources'] as List)
          .map((s) => '${(s as Map)['id']} · ${s['cite']}')
          .toList();
      expect(cites.length, 24, reason: 'golden 里就是这么多条,数变了要来看一眼');

      await t.pumpWidget(_page(fake.source));
      await t.pumpAndSettle();
      expect(find.text('出处'), findsOneWidget);
      expect(find.text(cites.first), findsNothing, reason: '默认收起');

      await t.tap(find.text('出处'));
      await t.pumpAndSettle();
      for (final cite in cites) {
        expect(find.text(cite), findsOneWidget, reason: cite);
      }

      // 再点一下收回去 —— 收起来才算「可折叠」。
      await t.tap(find.text('出处'));
      await t.pumpAndSettle();
      expect(find.text(cites.first), findsNothing);
    });

    testWidgets('失败:一句话 + 重试,点了真的重算', (t) async {
      _usePhone(t);
      final fake = _Fake()..viewError = StateError('没有可用的病种包:sle');
      await t.pumpWidget(_page(fake.source));
      await t.pumpAndSettle();

      expect(find.textContaining('打不开'), findsOneWidget);
      // Rust 那句错误原文(路径、包 id)对用户没用,不摆给他看。
      expect(find.textContaining('sle'), findsNothing);

      // 一次「算不出来」现在是两次调用:先重新拉一遍包(F2 的自愈),再算一次;
      // 这条用例里拉包不改变什么(`_Fake` 没挂 `onRefresh`),所以第二次照样不行。
      expect(fake.views, 2, reason: '自愈:重新拉一遍包之后再算一次');
      expect(fake.refreshes, 1);

      fake.viewError = null;
      await t.tap(find.text('重试'));
      await t.pumpAndSettle();
      expect(fake.views, 3);
      expect(find.text('待补 / 逾期'), findsOneWidget);
    });

    testWidgets('点「关闭病程档案」:记一条 disable 并重算', (t) async {
      _usePhone(t, height: 2000);
      final fake = _Fake();
      await t.pumpWidget(_page(fake.source));
      await t.pumpAndSettle();

      fake.view = _offView();
      await t.tap(find.text('关闭病程档案'));
      await t.pumpAndSettle();

      expect(fake.calls.single.sublist(0, 2), ['disable', 'sle']);
      expect(fake.calls.single[2], _today());
      expect(fake.views, 2, reason: '记完重算');
      expect(find.text('开启病程档案'), findsOneWidget);
    });

    testWidgets('400×800、2× 字号:真实引擎产出一路滚到底都不溢出', (t) async {
      _usePhone(t);
      final fake = _Fake(view: _golden);
      await t.pumpWidget(_page(fake.source, textScale: 2.0));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      // 屏外的那些块 `ListView` 还没 build 过 —— 滚下去才算真的验过。
      for (var i = 0; i < 12; i++) {
        await t.drag(find.byType(ListView), const Offset(0, -1200));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: '第 $i 屏溢出');
      }
    });
  });

  group('record 记上了要唤醒首页待办与同步推送', () {
    // 开关病程档案写下的是一条真实的病历箱文档 —— 首页待办卡(`ArchiveScreen`
    // 监听 `vaultRevision`)和防抖同步推送都靠这个信号才知道要重新算一次。
    test('记上了:vaultRevision +1', () async {
      final source = DiseaseProfileSource(record: (kind, pkg, at) async {});
      final before = vaultRevision.value;

      final ok = await source.record('enable', 'x');

      expect(ok, isTrue);
      expect(vaultRevision.value, before + 1);
    });

    test('没记上:vaultRevision 不动', () async {
      final source = DiseaseProfileSource(
        record: (kind, pkg, at) async => throw StateError('x'),
      );
      final before = vaultRevision.value;

      final ok = await source.record('enable', 'x');

      expect(ok, isFalse);
      expect(vaultRevision.value, before);
    });
  });
}
