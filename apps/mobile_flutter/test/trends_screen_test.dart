// 「趋势」整屏测试:筛选交互(大类 chip / 只看异常 / 搜索三者怎么叠加)、页尾
// 「只测过一次的」折叠、s2 自上而下的顺序。
//
// 整屏**不注入 `load` 时**不可 pump —— `TrendsScreen` 在字段初始化那一刻就调
// `viewTrends()`(FFI),`flutter test` 不带原生库会直接崩(与
// `test/mobile_ia_test.dart` 顶部注释同一条限制)。这个文件全程靠注入 `load`
// 绕开 FFI(与 `ForDoctorScreen` 同款)。
//
// Task 6(趋势重整)删掉了「化验快照」「最近就诊」两块从概览搬来的独立卡片
// (原 `KeyLabsSnapshot`/`RecentVisitsCard`——前者并进了下面的 `TrendRow` 列表,
// 后者没有下家),这个文件不再测它们;`trendVisible`/`trendSplit` 这两个纯函数
// 的断言在 `test/mobile_ia_test.dart` 里。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';

/// 病程档案那一块的假口子:这一屏的测试不关心它的内容,只要它别去碰 FFI 与网络
/// (卡片自己的三态由 `test/disease_profile_card_test.dart` 验)。
DiseaseProfileSource noProfilePackage() => DiseaseProfileSource(
  installed: () async => const [],
  view: (id) async => '{}',
  record: (kind, pkg, at) async {},
  refresh: () async {},
);

void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

TrendPointDto _pt(String date, double v, {String? flag}) => TrendPointDto(
  date: date,
  value: v,
  flag: flag,
  documentId: 1,
  unverified: false,
);

/// 跨两个大类、混着「测过 ≥ 2 次」与「只测过一次」的夹具:
///  · 肌酐(肾功能,2 次,正常)
///  · 估算肾小球滤过率(肾功能,2 次,异常)—— multi 里排前面
///  · 促甲状腺激素(甲状腺功能,1 次,正常)—— 单次,进页尾折叠
List<TrendSeriesDto> _fixture() => [
  TrendSeriesDto(
    name: '肌酐',
    unit: 'umol/L',
    valuesConverted: false,
    anyAbnormal: false,
    panel: '肾功能',
    selfMeasured: false,
    points: [_pt('2026-01-05', 80), _pt('2026-06-05', 84)],
  ),
  TrendSeriesDto(
    name: '估算肾小球滤过率',
    unit: 'ml/min/1.73m2',
    valuesConverted: false,
    anyAbnormal: true,
    panel: '肾功能',
    selfMeasured: false,
    points: [_pt('2026-01-05', 55, flag: 'L'), _pt('2026-06-05', 50, flag: 'L')],
  ),
  TrendSeriesDto(
    name: '促甲状腺激素',
    unit: 'mIU/L',
    valuesConverted: false,
    anyAbnormal: false,
    panel: '甲状腺功能',
    selfMeasured: false,
    points: [_pt('2026-06-05', 2.1)],
  ),
];

Widget _app(
  List<TrendSeriesDto> series, {
  List<String> catalog = const ['肾功能', '甲状腺功能'],
}) => MaterialApp(
  theme: MedMe.theme(),
  home: TrendsScreen(
    load: () async => (series, catalog),
    profileSource: noProfilePackage(),
  ),
);

void main() {
  group('筛选:大类 chip、只看异常、搜索 —— 叠加,不互相让位', () {
    testWidgets(
      '点「肾功能」→ 只剩肾功能项;再点「只看异常」→ 只剩异常;'
      '搜「肌酐」→ 只剩肌酐且开关不影响',
      (tester) async {
        useNarrowPhone(tester);
        await tester.pumpWidget(_app(_fixture()));
        await tester.pumpAndSettle();

        // 初始:开关默认关(Task 6),三条全在——两条趋势 + 一条折进
        // 「只测过一次的」。
        expect(find.text('肌酐'), findsOneWidget);
        expect(find.text('估算肾小球滤过率'), findsOneWidget);
        expect(find.text('只测过一次的 1 项'), findsOneWidget);

        await tester.tap(find.text('肾功能 2'));
        await tester.pumpAndSettle();
        expect(find.text('肌酐'), findsOneWidget);
        expect(find.text('估算肾小球滤过率'), findsOneWidget);
        expect(
          find.text('只测过一次的 1 项'),
          findsNothing,
          reason: '促甲状腺激素属于甲状腺功能,选中肾功能之后不在可见集合里',
        );

        // 「只看异常」是这一排横向滚动 chip 的最后一颗,在 360dp 窄屏上一开始
        // 不在可视区(甚至还没建出来)——先滚到它出现,再点,模拟真实手指操作。
        await tester.dragUntilVisible(
          find.text('只看异常'),
          find.byType(PanelChipsRow),
          const Offset(-80, 0),
        );
        await tester.tap(find.text('只看异常'));
        await tester.pumpAndSettle();
        expect(find.text('肌酐'), findsNothing, reason: '肌酐正常,被只看异常挡掉');
        expect(find.text('估算肾小球滤过率'), findsOneWidget);

        // 搜索:忽略只看异常(仍然开着),但受大类约束(仍然选中肾功能)。
        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '肌酐');
        await tester.pumpAndSettle();
        // `find.text` 同时认 `Text` 与 `EditableText`——这时候搜索框自己的
        // 输入内容也是「肌酐」,会多算一个;只认渲染在正文里的 `Text`。
        expect(
          find.byWidgetPredicate((w) => w is Text && w.data == '肌酐'),
          findsOneWidget,
          reason: '搜索无视只看异常,肌酐虽正常也要找得到',
        );
        expect(find.text('估算肾小球滤过率'), findsNothing, reason: '名字不含「肌酐」');
      },
    );
  });

  group('页尾折叠:只测过一次的序列', () {
    testWidgets('single 为空时不出现这一行', (tester) async {
      useNarrowPhone(tester);
      final noSingles = [
        TrendSeriesDto(
          name: '肌酐',
          unit: 'umol/L',
          valuesConverted: false,
          anyAbnormal: false,
          panel: '肾功能',
          selfMeasured: false,
          points: [_pt('2026-01-05', 80), _pt('2026-06-05', 84)],
        ),
      ];
      await tester.pumpWidget(_app(noSingles, catalog: const ['肾功能']));
      await tester.pumpAndSettle();
      expect(find.textContaining('只测过一次的'), findsNothing);
    });

    testWidgets('非空时点它展开出 LabLine(名称 · 日期)', (tester) async {
      useNarrowPhone(tester);
      await tester.pumpWidget(_app(_fixture()));
      await tester.pumpAndSettle();

      expect(find.text('只测过一次的 1 项'), findsOneWidget);
      expect(find.text('促甲状腺激素'), findsNothing, reason: '折起时不重复渲染整行');

      await tester.tap(find.text('只测过一次的 1 项'));
      await tester.pumpAndSettle();
      expect(find.text('促甲状腺激素'), findsOneWidget);
      expect(find.text('2026-06-05'), findsOneWidget);
    });
  });

  // ── 整屏:自上而下的顺序是固定的 ────────────────────────────────────────────
  testWidgets('整屏按顺序自上而下摆;没有「最近就诊」,没有「记录一下」', (tester) async {
    // 注入 `load` 就一次 FFI 都不碰,整屏 pump 得起来(与 `ForDoctorScreen.load`
    // 同一手法)。视口拉高是为了让 `ListView` 一次把全部内容都布局出来,
    // 好按 y 坐标比顺序 —— 顺序只能整屏验,逐块 pump 验不到。
    tester.view.physicalSize = const Size(360 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_fixture()));
    await tester.pumpAndSettle();

    double dy(String text) => tester.getTopLeft(find.text(text)).dy;
    // 病程档案 → 关键化验 → 第一条趋势名(异常的排前面,「估算肾小球滤过率」
    // 先于「肌酐」,见 `trendSplit` 的文档)→ 只测过一次的。
    expect(dy('病程档案'), lessThan(dy('关键化验')));
    expect(dy('关键化验'), lessThan(dy('估算肾小球滤过率')));
    expect(dy('估算肾小球滤过率'), lessThan(dy('只测过一次的 1 项')));
    // 病程档案入口**恒在**(mockup `s2` 的第一块)。这一屏的测试里一个病种包都
    // 没装上,所以它说的是「还没准备好」——「装上了 / 开启了」那两态在
    // `test/disease_profile_card_test.dart` 里验。
    expect(find.textContaining('还没准备好'), findsOneWidget);
    // 顶栏只有「趋势」两个字,不加成员 chip(s2)。
    expect(find.text('趋势'), findsOneWidget);
    // Task 5/6:「记录一下」「最近就诊」都不再是这一屏的一部分。
    expect(find.text('记录一下'), findsNothing);
    expect(find.text('最近就诊'), findsNothing);
  });
}
