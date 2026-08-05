// 五 tab 信息架构 + 三块新界面的看门测试。
//
// 这个文件盯的**不是排版**,是几条一旦破掉就会在临床上说假话的规矩:
//
//  1. 化验状态只认 Rust 给的 `flag`,**绝不**从参考区间反推;
//  2. 趋势图 UI 自己再 gate 一次 `is_renderable`,无日期的点不画;
//  3. 应急卡上的血型永远是「未登记」,而且**没有输入框**;
//  4. 「在用药」四个字不许出现在任何一屏上(`MedSpan.status` 恒为 active);
//  5. tab 数、页面数、底栏项数三者恒等。
//
// 这几条在代码里都各自带着长注释解释为什么,但注释拦不住重构。测试能。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/emergency_contact.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// 整屏 widget(自带 `Scaffold`)的外壳 —— **不能**套 [wrap] 的
/// `SingleChildScrollView`:那会给里面的 `ListView` 一个无穷高约束,布局直接炸。
Widget wrapScreen(Widget screen, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: screen,
  ),
);

Int64List ids(List<int> xs) => Int64List.fromList(xs);

TrendPointDto pt(String? date, double v, {String? flag}) =>
    TrendPointDto(date: date, value: v, flag: flag, documentId: 1);

TrendSeriesDto series(List<TrendPointDto> points, {double? lo, double? hi}) =>
    TrendSeriesDto(
      name: '肌酐',
      unit: 'umol/L',
      refLow: lo,
      refHigh: hi,
      // 与 Rust 侧 `aggregate.rs` 的 `abnormal` 同一条判据:只认 H/L。夹具里若写
      // `flag != null`,将来有人喂一个印着 `N`(正常)的点进来,这里就会静默把它
      // 标成异常,测试跟着假绿。
      anyAbnormal: points.any((p) => p.flag == 'H' || p.flag == 'L'),
      panel: null,
      points: points,
      selfMeasured: false,
    );

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  group('化验状态只认 flag,不从参考区间反推', () {
    test('H / L / 箭头认得出,大小写不敏感', () {
      expect(labStatusOf('H'), LabStatus.high);
      expect(labStatusOf('h'), LabStatus.high);
      expect(labStatusOf('↑'), LabStatus.high);
      expect(labStatusOf('L'), LabStatus.low);
      expect(labStatusOf('↓'), LabStatus.low);
    });

    test('没有标记 = 正常,而正常不上色(返回 null,不是某个「正常」档)', () {
      expect(labStatusOf(null), isNull);
      expect(labStatusOf(''), isNull);
      expect(labStatusOf('  '), isNull);
    });

    test('「N」是 Rust 明确判定的正常 —— 与「没有标记」同样什么都不画', () {
      // Rust 侧 flag 的取值域是 `"H" | "L" | "N" | null`(`labs.rs` 的
      // `LabObservation::flag`、`aggregate.rs` 的自测值同一套):有参考区间且值落在
      // 区间内 → `"N"`,没有区间可判 → `null`。这里曾经只认 H/L,`"N"` 掉进
      // `unknown`,于是一个**内部编码**被当成印刷体印给用户:22 项血常规里 20 项
      // 各挂一个灰色「N」pill。
      expect(labStatusOf('N'), isNull);
      expect(labStatusOf('n'), isNull, reason: '大小写不敏感,与 H/L 一致');
      expect(labStatusOf(' N '), isNull, reason: '两头的空白不该改变判定');
    });

    testWidgets('flag = N 的行:没有 pill、正文墨色、色条透明', (tester) async {
      // 上面那条纯函数断言的用户可见兑现 —— 「正常不上色」这条规则(设计系统 §二)
      // 对「明确正常」和「没有标记」必须给出同一个结果,否则一份血常规里 1–2 项真正
      // 的异常会被二十个 N 淹没。
      await tester.pumpWidget(
        wrap(
          const LabLine(
            name: '血小板计数',
            value: 210,
            unit: '10^9/L',
            flag: 'N',
            refLow: 125,
            refHigh: 350,
          ),
        ),
      );
      expect(find.text('N'), findsNothing, reason: '内部编码不许出现在界面上');
      expect(find.byType(MedPill), findsNothing, reason: '正常不给 pill');
      final ctx = tester.element(find.byType(LabLine));
      expect(
        tester.widget<Text>(find.text('210 10^9/L')).style?.color,
        MedColors.of(ctx).ink,
        reason: '正常值用正文墨色,不上高/低色',
      );
      // 参考区间照常显示 —— 显示与判定是两件事。
      expect(find.textContaining('参考 125–350'), findsOneWidget);
    });

    testWidgets('「HH」「危」仍然原样透出 —— 认 N 不许把真读不懂的记号一起吞掉', (
      tester,
    ) async {
      // 这才是 BUG-2 最危险的那一半:N 泛滥的时候,「HH」跟例行正常值长得一模一样。
      await tester.pumpWidget(
        wrap(const LabLine(name: '血钾', value: 7.1, unit: 'mmol/L', flag: 'HH')),
      );
      expect(find.text('HH'), findsOneWidget);
    });

    test('认不出的标记不吞掉,原样成为 unknown', () {
      // 某些医院印「HH」(危急高)、「危」、「*」。我们读到了就得显示,
      // 悄悄当成正常比显示得难看危险得多。
      expect(labStatusOf('HH'), LabStatus.unknown);
      expect(labStatusOf('危'), LabStatus.unknown);
      expect(labStatusOf('*'), LabStatus.unknown);
    });

    testWidgets('值远超参考区间但 flag 为空 → **不上色**', (tester) async {
      // 这是整个改动里最要紧的一条断言。三个投影 DTO 每个点都带着 refLow/refHigh,
      // 拿来反推异常唾手可得(hosted-viewer 的 sparkSVG 就是这么干的)。谁哪天
      // 「顺手补上」那个判定,红的应该是这里 —— 007 §2.5:怎么算在 Rust。
      await tester.pumpWidget(
        wrap(
          const LabLine(
            name: '白细胞计数',
            value: 99.9, // 参考区间 4–10 的十倍
            unit: '10^9/L',
            flag: null,
            refLow: 4,
            refHigh: 10,
          ),
        ),
      );
      // 没有 pill —— UI 没有替化验单下任何结论。
      expect(find.text('偏高'), findsNothing);
      expect(find.text('偏低'), findsNothing);
      // 数值墨色是正文 ink,不是 high。
      final ctx = tester.element(find.byType(LabLine));
      final valueText = tester.widget<Text>(find.text('99.9 10^9/L'));
      expect(valueText.style?.color, MedColors.of(ctx).ink);
      // 参考区间照样显示给人看 —— 显示与判定是两件事。
      expect(find.textContaining('参考 4–10'), findsOneWidget);
    });

    testWidgets('flag 说偏高就上高色,哪怕值落在参考区间内', (tester) async {
      // 反过来的同一条规矩:化验单印了 H,我们就报 H,不拿区间去「纠正」它。
      // 原件才是真相(不同实验室、不同人群的判定边界本来就不止 refLow/refHigh)。
      await tester.pumpWidget(
        wrap(
          const LabLine(
            name: '血红蛋白',
            value: 5,
            flag: 'H',
            refLow: 4,
            refHigh: 10,
          ),
        ),
      );
      expect(find.text('偏高'), findsOneWidget);
      final ctx = tester.element(find.byType(LabLine));
      expect(
        tester.widget<Text>(find.text('5')).style?.color,
        MedColors.of(ctx).high,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('趋势:UI 自己 gate 一次 is_renderable', () {
    test('全部点都无日期的序列不可渲染(与 handoff.rs:369 同判据)', () {
      expect(
        trendSeriesIsRenderable(series([pt(null, 88), pt(null, 91)])),
        isFalse,
      );
    });

    test('只要有一个点带日期就可渲染', () {
      expect(
        trendSeriesIsRenderable(series([pt(null, 88), pt('2024-03-01', 91)])),
        isTrue,
      );
    });

    test('无日期的点被跳过,不画', () {
      final s = series([
        pt('2024-03-01', 91),
        pt(null, 88), // 画不到时间轴上的任何位置
        pt('2022-01-05', 70),
      ]);
      final drawn = trendDatedPoints(s);
      expect(drawn.length, 2);
      expect(drawn.every((p) => p.date != null), isTrue);
    });

    test('点按日期升序 —— 顺序错乱会画出一条来回折返的假线', () {
      final drawn = trendDatedPoints(
        series([pt('2024-03-01', 91), pt('2022-01-05', 70), pt('2023-06-02', 80)]),
      );
      expect(drawn.map((p) => p.date).toList(), [
        '2022-01-05',
        '2023-06-02',
        '2024-03-01',
      ]);
    });

    testWidgets('边界输入都画得出来,不抛', (tester) async {
      // 单点、同一天的多点、值全等(Y 跨度为 0)、无参考区间 —— 这几种真实存在,
      // 而它们正是除零/无穷大最容易钻出来的地方。
      for (final s in [
        series([pt('2024-03-01', 91)]),
        series([pt('2024-03-01', 91), pt('2024-03-01', 91)]),
        series([pt('2024-03-01', 5), pt('2025-03-01', 5)], lo: 5, hi: 5),
        series([pt('2024-03-01', 91), pt('2024-04-01', 70)]),
      ]) {
        await tester.pumpWidget(wrap(SizedBox(width: 300, child: TrendChart(series: s))));
        expect(tester.takeException(), isNull);
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('趋势:参考区间必须落在画布内', () {
    // 「参考 ≥ 90」而实测全在 90 以下 —— eGFR 的常态。若值域只让 refLow 往下撑,
    // 90 会跑到画布之上,参考带塌成零高度,虚线画在图的顶边而不是 90 处。
    test('单侧下限高于所有实测值时,下限仍在值域内', () {
      final (lo, hi) = trendYDomain([63.0, 71.0, 78.0], refLow: 90);
      expect(lo, lessThan(63));
      expect(hi, greaterThan(90), reason: '90 必须在画布内,否则虚线位置是假的');
    });

    test('单侧上限低于所有实测值时,上限仍在值域内', () {
      final (lo, hi) = trendYDomain([9.1, 9.8], refHigh: 5.2);
      expect(lo, lessThan(5.2), reason: '5.2 必须在画布内');
      expect(hi, greaterThan(9.8));
    });

    test('区间把点包在中间时照常成立', () {
      final (lo, hi) = trendYDomain([4.85], refLow: 3.1, refHigh: 8.0);
      expect(lo, lessThan(3.1));
      expect(hi, greaterThan(8.0));
    });

    test('单点无区间:跨度为 0 也不除零', () {
      final (lo, hi) = trendYDomain([5.0]);
      expect(hi - lo, greaterThan(0));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('趋势:搜索与「只看非正常项」', () {
    TrendSeriesDto s(String name, {required bool abnormal, String? panel}) =>
        TrendSeriesDto(
          name: name,
          unit: 'umol/L',
          anyAbnormal: abnormal,
          panel: panel,
          points: [pt('2024-03-01', 1)],
          selfMeasured: false,
        );

    final all = [
      s('肌酐', abnormal: false),
      s('血红蛋白', abnormal: true),
      s('Cr 血肌酐', abnormal: false),
    ];

    test('默认只列非正常项', () {
      final v = trendVisible(all, query: '', abnormalOnly: true);
      expect(v.map((e) => e.name), ['血红蛋白']);
    });

    test('关掉开关就全列', () {
      expect(trendVisible(all, query: '', abnormalOnly: false).length, 3);
    });

    // 这条是整个特性最容易写错的地方:叠加会让「搜正常项」永远搜不到。
    test('搜索时绕过「只看非正常项」—— 正常的也要找得到', () {
      final v = trendVisible(all, query: '肌酐', abnormalOnly: true);
      expect(v.map((e) => e.name), ['肌酐', 'Cr 血肌酐'],
          reason: '两条都正常,若与非正常过滤叠加就会一条都搜不到');
    });

    test('大小写无关', () {
      expect(trendVisible(all, query: 'cr', abnormalOnly: true).length, 1);
    });

    test('不做模糊匹配 —— 没查过的项目不许冒出来', () {
      expect(trendVisible(all, query: '肌钙蛋白', abnormalOnly: false), isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 分类入口(chip):产品判断是搜索框在手机上不够用,要能直接点「这类检查有哪
  // 些」。大类匹配(哪条序列属于哪个 panel)在 Rust 侧按 analyteKey 查词典算完、
  // 通过 `TrendSeriesDto.panel` 下发 —— 这里只测 UI 拿到这份结果之后怎么用,
  // **不重新猜一遍匹配**(那是 Rust 单测的事,`vault_projections.rs` 里有)。
  group('趋势:检验大类 chip', () {
    TrendSeriesDto s(String name, {String? panel, bool abnormal = false}) =>
        TrendSeriesDto(
          name: name,
          unit: 'umol/L',
          anyAbnormal: abnormal,
          panel: panel,
          points: [pt('2024-03-01', 1)],
          selfMeasured: false,
        );

    test('「其他」桶:兜底不漏项 —— 没能归一化(panel 为 null)的序列必须能'
        '被「其他」选中', () {
      // 血常规里一大类计数项(嗜酸性粒细胞、血小板分布宽度……)现实中经常没能
      // 归一化出 analyteKey,`panel` 因此是 null —— 这条序列就是那种情况的
      // 构造版本。没有「其他」兜底,它会从分类入口里彻底消失(需求原文)。
      final unmapped = s('嗜酸性粒细胞百分比', panel: null);
      expect(trendPanelMatches(unmapped, kOtherTrendPanel), isTrue);
      expect(trendPanelMatches(unmapped, null), isTrue, reason: '「全部」不筛');
      expect(trendPanelMatches(unmapped, '肾功能'), isFalse);

      final all = [unmapped, s('肌酐', panel: '肾功能')];
      final chips = trendPanelChips(all, catalog: const ['肾功能']);
      final other = chips.singleWhere((c) => c.panel == kOtherTrendPanel);
      expect(other.label, '其他');
      expect(other.count, 1);
      expect(
        trendVisible(
          all,
          query: '',
          abnormalOnly: false,
          panel: kOtherTrendPanel,
        ).map((e) => e.name),
        ['嗜酸性粒细胞百分比'],
      );
    });

    test('「全部」不筛,选中具体大类精确匹配 panel', () {
      final all = [
        s('低密度脂蛋白胆固醇', panel: '血脂'),
        s('促甲状腺激素', panel: '甲状腺功能'),
      ];
      expect(
        trendVisible(all, query: '', abnormalOnly: false, panel: null).length,
        2,
        reason: '全部 = 不筛',
      );
      expect(
        trendVisible(all, query: '', abnormalOnly: false, panel: '血脂')
            .map((e) => e.name),
        ['低密度脂蛋白胆固醇'],
      );
      expect(
        trendVisible(all, query: '', abnormalOnly: false, panel: '甲状腺功能')
            .map((e) => e.name),
        ['促甲状腺激素'],
      );
    });

    test('选中大类时「只看非正常项」让位,与搜索同一条理由', () {
      final all = [
        s('肌酐', panel: '肾功能', abnormal: false),
        s('estimated 肾小球滤过率', panel: '肾功能', abnormal: false),
      ];
      // 两条都正常;若选中大类时仍叠加 abnormalOnly,会把刚打开的大类过滤成空。
      final shown = trendVisible(
        all,
        query: '',
        abnormalOnly: true,
        panel: '肾功能',
      );
      expect(shown.length, 2, reason: '选中大类后不该再被「只看非正常项」清空');
    });

    test('大类与搜索可以叠加:先按大类筛,再按名字筛', () {
      final all = [
        s('肌酐', panel: '肾功能'),
        s('估算肾小球滤过率', panel: '肾功能'),
        s('尿酸', panel: '肾功能'),
      ];
      final shown = trendVisible(
        all,
        query: '肌酐',
        abnormalOnly: false,
        panel: '肾功能',
      );
      expect(shown.map((e) => e.name), ['肌酐']);
    });

    test('chip 目录:计数为 0 的大类不出现,「全部」恒在最前', () {
      final all = [s('肌酐', panel: '肾功能'), s('未归类指标', panel: null)];
      final chips = trendPanelChips(
        all,
        catalog: const ['血常规', '肾功能', '血脂'],
      );
      expect(chips.first.label, '全部');
      expect(chips.first.count, 2);
      // 「血常规」「血脂」在这批数据里计数为 0,不该出现。
      expect(chips.map((c) => c.label), ['全部', '肾功能', '其他']);
      expect(chips.firstWhere((c) => c.label == '肾功能').count, 1);
    });

    test('目录为空、只有未归类序列时,只剩「全部」+「其他」两颗兜底 chip', () {
      final all = [s('未归类指标A'), s('未归类指标B')];
      final chips = trendPanelChips(all, catalog: const []);
      expect(chips.map((c) => c.label), ['全部', '其他']);
      expect(chips.last.count, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('趋势:自测序列必须有文字图例', () {
    // 图上的自测点画成空心圈,但形状不能是唯一载体 —— 没有图例的形状编码等于
    // 没有编码。产品负责人真机看到图后原话:「trend 里面没有 legend,谁知道
    // 空心是自测数据呢」。
    TrendSeriesDto s({required bool self}) => TrendSeriesDto(
      name: '收缩压',
      unit: 'mmHg',
      anyAbnormal: true,
      refHigh: 135,
      panel: '生命体征',
      selfMeasured: self,
      points: [pt('2026-08-05', 138, flag: 'H')],
    );

    testWidgets('自测序列的卡上出现「家测」二字', (tester) async {
      await tester.pumpWidget(
        wrap(SeriesCard(series: s(self: true), onOpenDoc: (_) {})),
      );
      expect(find.text('家测'), findsOneWidget);
    });

    testWidgets('医院序列不出现「家测」', (tester) async {
      await tester.pumpWidget(
        wrap(SeriesCard(series: s(self: false), onOpenDoc: (_) {})),
      );
      expect(find.text('家测'), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('应急卡', () {
    final emptyCard = const EmergencyCardDto(
      allergies: [],
      activeMeds: [],
      conditions: [],
    );
    const profile = PatientProfileDto(gender: '男', age: '68岁', recordCount: 12);

    testWidgets('血型显示「未登记」,并且**没有任何输入框**', (tester) async {
      // 手填的血型会以「MedMe 显示 A 型」的权威感出现在急救现场,而它的正确性只
      // 等于用户某天晚上的记忆。这不是功能缺失,是拒绝提供 —— 谁加了输入框,红这里。
      await tester.pumpWidget(
        wrapScreen(EmergencyBigCardScreen(card: emptyCard, profile: profile)),
      );
      expect(find.text('未登记'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('空过敏史必须自己说话,不能留白', (tester) async {
      // 留白会被读成「无过敏史」,而我们只知道「已导入的这些纸上没写」。
      await tester.pumpWidget(
        wrapScreen(EmergencyBigCardScreen(card: emptyCard, profile: profile)),
      );
      expect(find.textContaining('不等于没有过敏'), findsOneWidget);
    });

    testWidgets('药物一节写「记录中出现的药物」,绝不写「在用药」', (tester) async {
      final card = EmergencyCardDto(
        allergies: [],
        activeMeds: [
          ActiveMedDto(
            name: '美托洛尔',
            dose: '25mg bid',
            until: '2021-04-09',
            documentIds: ids([7]),
          ),
        ],
        conditions: [],
      );
      await tester.pumpWidget(
        wrapScreen(EmergencyBigCardScreen(card: card, profile: profile)),
      );
      expect(find.text(kRecordedMedsTitle), findsOneWidget);
      expect(find.text('记录中出现的药物'), findsOneWidget);
      // 「在用药」「正在服用」「当前用药」一个都不许出现。
      for (final banned in ['在用药', '正在服用', '当前用药']) {
        expect(
          find.textContaining(banned),
          findsNothing,
          reason: '「$banned」暗示这是当前医嘱,而 MedSpan.status 恒为 active,推不出这件事',
        );
      }
      // 每一条都必须带最后一次出现的日期 —— 读者判断「这条还算不算数」的唯一依据。
      expect(find.textContaining('最后一次出现 2021-04-09'), findsOneWidget);
    });

    test('没有日期的药明说「记录里没有日期」,不留白', () {
      // 留白会被读成「最近」,那正好是最危险的一种误读。
      final m = ActiveMedDto(name: '二甲双胍', documentIds: ids([1]));
      expect(recordedMedTiming(m), contains('记录里没有日期'));
    });

    testWidgets('大字模式:系统字号放大 2× 不裁字、不溢出', (tester) async {
      // 007 §2.5「字号可放大,不可砍」。急救屏尤其:读它的人多半年长。
      final card = EmergencyCardDto(
        allergies: [
          AllergyItemDto(
            substance: '青霉素',
            reaction: '全身皮疹、呼吸困难',
            documentIds: ids([3]),
          ),
        ],
        activeMeds: [],
        conditions: [],
      );
      await tester.pumpWidget(
        wrapScreen(
          EmergencyBigCardScreen(card: card, profile: profile),
          textScale: 2.0,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('青霉素'), findsOneWidget);
    });

    test('器官捐献:「未登记」与「不愿意」是两件事,不许合并', () {
      // 把没填过显示成「不愿意」是替用户表态;显示成「愿意」更糟。
      expect(OrganDonation.unset.label, '未登记');
      expect(OrganDonation.no.label, isNot('未登记'));
      expect(OrganDonation.fromKey(null), OrganDonation.unset);
      expect(OrganDonation.fromKey('nonsense'), OrganDonation.unset);
      expect(OrganDonation.fromKey('yes'), OrganDonation.yes);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('五 tab 信息架构', () {
    test('tab 数 == 页面数 == 底栏项数', () {
      // 这三个数字散在两处 const 列表和一组常量里。加一个 tab 时最容易漏掉其中
      // 一处,而漏掉的表现是运行时越界或**点 A 进了 B**,不是编译错误。
      expect(HomeTab.count, 5);
      expect(HomeShell.tabScreens.length, HomeTab.count);
      expect(HomeShell.tabDestinations.length, HomeTab.count);
    });

    test('下标连续、互不重复,顺序即「使用时刻」从慢到急', () {
      const order = [
        HomeTab.overview,
        HomeTab.trends,
        HomeTab.archive,
        HomeTab.emergency,
        HomeTab.settings,
      ];
      expect(order, [0, 1, 2, 3, 4]);
      expect(order.toSet().length, HomeTab.count);
    });

    test('底栏文案就是规范 §八 那五个词', () {
      expect(
        HomeShell.tabDestinations.map((d) => d.label).toList(),
        ['概览', '趋势', '档案', '应急卡', '设置'],
      );
    });

    test('程序化跳转落在正确的 tab 上', () {
      goToArchive();
      expect(selectedTab.value, HomeTab.archive);
      goToTrends();
      expect(selectedTab.value, HomeTab.trends);
      goToEmergencyCard();
      expect(selectedTab.value, HomeTab.emergency);
      selectedTab.value = HomeTab.overview; // 复位,别污染别的测试
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('数值显示不做「美化」', () {
    test('整数不带 .0(那个 .0 是 IEEE 754 的产物,不是化验单上印的)', () {
      expect(fmtLabNumber(171), '171');
      expect(fmtLabNumber(3.86), '3.86');
      expect(fmtLabNumber(0), '0');
    });

    test('参考区间两端可缺,用 ≤ / ≥ 而不是编一个边界出来', () {
      expect(refRangeText(4, 10), '4–10');
      expect(refRangeText(null, 5.2), '≤ 5.2');
      expect(refRangeText(1.04, null), '≥ 1.04');
      expect(refRangeText(null, null), isNull);
    });
  });
}
