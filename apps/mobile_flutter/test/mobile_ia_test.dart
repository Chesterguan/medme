// 三 tab 信息架构 + 三块新界面的看门测试。
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

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/emergency_contact.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/screens/for_doctor_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';
import 'package:mobile_flutter/screens/visit_summary_sheet.dart';
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

TrendPointDto pt(String? date, double v, {String? flag, bool unverified = false}) =>
    TrendPointDto(date: date, value: v, flag: flag, documentId: 1, unverified: unverified);

TrendSeriesDto series(List<TrendPointDto> points, {double? lo, double? hi}) =>
    TrendSeriesDto(
      name: '肌酐',
      unit: 'umol/L',
      refLow: lo,
      refHigh: hi,
      valuesConverted: false,
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

    testWidgets('flag = N 的行:没有状态词、没有 pill、数值 ink、无 4px 左边框', (tester) async {
      // 上面那条纯函数断言的用户可见兑现——「明确正常」和「没有标记」必须给出同一个
      // 结果,否则一份血常规里 1–2 项真正的异常会被二十个 N 淹没。减法稿
      // 2026-09-22:「正常」什么都不画——不上色、不给状态词、不给 pill。
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
      expect(find.text('正常'), findsNothing);
      expect(find.text('偏高'), findsNothing);
      expect(find.text('偏低'), findsNothing);
      expect(find.text('210'), findsOneWidget);
      expect(find.text('10^9/L'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('210')).style?.color,
        MedColors.light.ink,
        reason: '减法稿:正常数值用 ink,不再上色',
      );
      final hasLeftBar = tester
          .widgetList<Container>(find.descendant(
              of: find.byType(LabLine), matching: find.byType(Container)))
          .any((w) {
            final d = w.decoration;
            return d is BoxDecoration && d.border is Border && (d.border! as Border).left.width == 4;
          });
      expect(hasLeftBar, isFalse, reason: '减法稿:无色条');
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

    // 云抽取图片档:本机拿不到原文逐字比对的那些值。规矩是**保留 + 标记**
    // (spec §4),不是丢弃 —— 丢掉的话用户连"有这么个数"都不知道,更无从核对。
    testWidgets('unverified 的行:照常显示数值,多一枚「需核对」', (tester) async {
      await tester.pumpWidget(
        wrap(
          const LabLine(
            name: '肌酐',
            value: 1.2,
            unit: 'mg/dL',
            refLow: 0.6,
            refHigh: 1.3,
            unverified: true,
          ),
        ),
      );
      expect(find.text('需核对'), findsOneWidget);
      expect(find.text('1.2'), findsOneWidget, reason: '标记归标记,值照常显示');
      expect(find.text('mg/dL'), findsOneWidget, reason: '标记归标记,单位照常显示');
      // 用 R4 的中性 check 配色(MedPill.check),不借 high/low/critical —— 那三套是
      // 化验状态专用,借来会被读成一档临床结论;也不借主色 seal —— 那是「点这里去
      // 做什么」的强调色,这枚 chip 说的是「App 没能替你核对」,不是一个动作。
      final chip = tester.widget<MedPill>(find.byType(MedPill));
      expect(chip.background, MedBrand.checkWash);
      expect(chip.foreground, MedBrand.checkInk);
    });

    testWidgets('核对过的行:没有这枚 chip', (tester) async {
      await tester.pumpWidget(
        wrap(
          const LabLine(name: '肌酐', value: 1.2, unit: 'mg/dL', refLow: 0.6, refHigh: 1.3),
        ),
      );
      expect(find.text('需核对'), findsNothing);
    });

    testWidgets('既偏高又需核对:两枚 chip 并排,各说各的', (tester) async {
      await tester.pumpWidget(
        wrap(const LabLine(name: '肌酐', value: 2.0, flag: 'H', unverified: true)),
      );
      expect(find.text('偏高'), findsOneWidget, reason: '化验单说的');
      expect(find.text('需核对'), findsOneWidget, reason: 'MedMe 说的');
    });

    test('认不出的标记不吞掉,原样成为 unknown', () {
      // 某些医院印「HH」(危急高)、「危」、「*」。我们读到了就得显示,
      // 悄悄当成正常比显示得难看危险得多。
      expect(labStatusOf('HH'), LabStatus.unknown);
      expect(labStatusOf('危'), LabStatus.unknown);
      expect(labStatusOf('*'), LabStatus.unknown);
    });

    testWidgets('值远超参考区间但 flag 为空 → 仍按「正常」处理,不按 high/low 上色', (tester) async {
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
      expect(find.text('99.9'), findsOneWidget);
      expect(find.text('10^9/L'), findsOneWidget);
      // 数值墨色是减法稿的正常档 ink,不是 high —— 没有从参考区间反推出一个
      // 临床结论。
      final valueText = tester.widget<Text>(find.text('99.9'));
      expect(valueText.style?.color, MedColors.light.ink);
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
  // ───────────────────────────────────────────────────────────────────────────
  // ───────────────────────────────────────────────────────────────────────────
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

    testWidgets('空过敏史说「未识别」,并且绝不说「没有过敏」', (tester) async {
      // 留白会被读成「无过敏史」,而我们只知道「已导入的这些纸上没写」。
      //
      // 断言钉的是**产品定的语义**,不是某一版措辞:app 永远不能宣称病人没有
      // 过敏 —— 几乎没有人做过完整的过敏原检测,病历上「否认过敏」也只是没查
      // 出来。所以这里查两件事:说了「未识别」,以及**整屏没有任何一处**出现
      // 「没有过敏」「无过敏」。后一条是这条测试真正的价值:换文案时改错了
      // 方向(写成「未发现过敏,应无过敏史」这类)会在这里当场被拦下。
      await tester.pumpWidget(
        wrapScreen(EmergencyBigCardScreen(card: emptyCard, profile: profile)),
      );
      expect(find.textContaining('未识别'), findsWidgets);
      for (final claim in ['没有过敏', '无过敏', '不存在过敏']) {
        expect(
          find.textContaining(claim),
          findsNothing,
          reason: '应急卡不能宣称「$claim」—— 我们只知道记录里没读到,不知道病人有没有',
        );
      }
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

    testWidgets('降级之后大字模式一字未动:深色、高对比、没有输入框', (tester) async {
      // ia-proposal §7 决定 3:降的是位置不是质量。这条测试存在的唯一理由是
      // 「顺手」—— 把一屏从 tab 降成 push 进来的一页时,最容易发生的事是有人
      // 觉得「既然不常用了」就顺便简化它。
      await tester.pumpWidget(
        wrapScreen(EmergencyBigCardScreen(card: emptyCard, profile: profile)),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('未登记'), findsOneWidget);
      // 它不再是底栏的一项(底栏四个:病历 / 现在 / 用药 / 我)。
      expect(
        HomeShell.tabDestinations.map((d) => d.label),
        isNot(contains('急救卡')),
      );
      expect(HomeShell.tabDestinations.length, 4);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('四 tab 信息架构(2026-10-23:病历 / 现在 / 用药 / 我)', () {
    test('tab 数 == 页面数 == 底栏项数', () {
      // 这三个数字散在两处 const 列表和一组常量里。加一个 tab 时最容易漏掉其中
      // 一处,而漏掉的表现是运行时越界或**点 A 进了 B**,不是编译错误。
      expect(HomeTab.count, 4);
      expect(HomeShell.tabScreens.length, HomeTab.count);
      expect(HomeShell.tabDestinations.length, HomeTab.count);
    });

    test('下标连续、互不重复', () {
      const order = [HomeTab.records, HomeTab.now, HomeTab.meds, HomeTab.me];
      expect(order, [0, 1, 2, 3]);
      expect(order.toSet().length, HomeTab.count);
    });

    test('底栏文案就是 spec 那四个词', () {
      expect(
        HomeShell.tabDestinations.map((d) => d.label).toList(),
        ['病历', '现在', '用药', '我'],
      );
    });

    test('冷启动落在「病历」', () {
      expect(HomeTab.records, 0);
    });

    test('「给医生看」**不在**底栏 —— 它是从「病历」推进去的一整页', () {
      // mockup。这条断言存在的理由:ia-proposal §2 推荐的是把它放进底栏,
      // 谁照着那份提案改回去,红的应该是这里,而不是到了真机上才发现两处打架。
      expect(
        HomeShell.tabDestinations.map((d) => d.label),
        isNot(contains('给医生看')),
      );
      expect(
        HomeShell.tabDestinations.map((d) => d.label),
        isNot(contains('急救卡')),
      );
    });

    test('程序化跳转落在正确的 tab 上', () {
      goToNow();
      expect(selectedTab.value, HomeTab.now);
      goToMeds();
      expect(selectedTab.value, HomeTab.meds);
      expect(medsFilterFamily.value, isNull);
      goToMeds(family: 'cardio');
      expect(medsFilterFamily.value, 'cardio');
      medsFilterFamily.value = null;
      goToMe();
      expect(selectedTab.value, HomeTab.me);
      goToRecords();
      expect(selectedTab.value, HomeTab.records);
    });

    test('埋点枚举与 tab 一一对应 —— 少一个就会把 A 的人气记成 B', () {
      expect(AnalyticsTab.values.length, HomeTab.count);
      expect(AnalyticsTab.of(HomeTab.records), AnalyticsTab.records);
      expect(AnalyticsTab.of(HomeTab.now), AnalyticsTab.now);
      expect(AnalyticsTab.of(HomeTab.meds), AnalyticsTab.meds);
      expect(AnalyticsTab.of(HomeTab.me), AnalyticsTab.me);
      expect(AnalyticsTab.of(4), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('「给医生看」那一页', () {
    // 不注入 `load` 时整屏在字段初始化那一刻就走 FFI,`flutter test` 不带原生库 ——
    // 注入一份空摘要就能把整屏 pump 起来(与 `EmergencyCardScreen.load` 同一手法)。
    const empty = VisitSummaryDto(
      patient: PatientProfileDto(recordCount: 0),
      allergies: [],
      activeMeds: [],
      recentLabs: [],
      recentChanges: [],
      recentVisits: [],
      recentNotes: [],
      plainText: '',
    );

    testWidgets('整页立得住 —— 摘要主体本身是 ListView,不能再嵌进一层滚动里', (t) async {
      // 这条钉的是**组合方式**:`VisitSummaryBody` 返回的是 `ListView`,把它放进
      // 另一个 `ListView` 的 children 会拿到无穷高约束当场炸(见 `wrapScreen` 的
      // 文档)。所以正文占 `Expanded`,「出码」那一颗固定在它下面,另外三条经
      // `footer` 接进正文自己的滚动流 —— 与浮层那边同一个形状。
      await t.pumpWidget(
        wrapScreen(ForDoctorScreen(load: () async => empty)),
      );
      await t.pumpAndSettle();
      expect(find.text('给医生看'), findsOneWidget);
      expect(find.text('出码给医生看'), findsOneWidget);
    });

    testWidgets('跟着滚的三条逐字照 mockup s4,顺序也照它', (t) async {
      await t.pumpWidget(wrap(const ForDoctorActions()));
      // 断言**顺序**,不是「都在」—— 三条换个位置照样能逐条 findsOneWidget。Task 10
      // 把第三条换成了 mockup `s4` 的蓝横幅(`MedBanner`,不再是 `ListTile`)——
      // 按**纵向位置**比顺序,不再假设三条都是同一个 widget 类型。
      final labels = ['导出文件', '急救卡', '我是医生,替病人代拍'];
      final dys = labels.map((l) => t.getTopLeft(find.text(l)).dy).toList();
      for (var i = 1; i < dys.length; i++) {
        expect(dys[i - 1], lessThan(dys[i]), reason: '「${labels[i - 1]}」应排在「${labels[i]}」前面');
      }
      // 代拍入口全 App 只有这一句话(Task 15 让医生端主按钮也用它)。
      expect(find.text('病人不用装 App、不用账号'), findsOneWidget);
      // 出码不在这一组里 —— 它是固定在底部的那一颗(`s4`)。
      expect(find.text('出码给医生看'), findsNothing);
    });

    testWidgets('正文不重复画「给医生看」—— AppBar 已经写着这个名字了', (t) async {
      await t.pumpWidget(wrapScreen(ForDoctorScreen(load: () async => empty)));
      await t.pumpAndSettle();
      // 只出现一次(AppBar 那一处)——`showHeading: false` 时正文不该再画一遍,
      // 同屏两个自己的名字。
      expect(find.text('给医生看'), findsOneWidget);
      // 不带自己标题栏的调用方(`showHeading` 默认值 `true`)则要自己画一遍抬头。
      await t.pumpWidget(
        wrapScreen(
          Scaffold(
            body: VisitSummaryBody(
              summary: empty,
              onOpenDoc: (_) {},
              onAddNote: () {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('给医生看'), findsOneWidget);
    });

    testWidgets('360×640 上 ×1 / ×2 / ×3 字号都不溢出 —— 老人是主要用户', (t) async {
      // 固定区一旦不止一颗按钮,大字号下会把正文挤没:四条一起钉死时
      // ×2.0 只剩 34% 的正文高度,×3.0 直接 `RenderFlex overflowed`。
      // 现在只有「出码」钉在底部,另外三条跟着滚。
      t.view.physicalSize = const Size(360, 640);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0, 3.0]) {
        await t.pumpWidget(
          wrapScreen(
            ForDoctorScreen(load: () async => empty),
            textScale: scale,
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: '×$scale 字号下溢出了');
        expect(find.text('出码给医生看'), findsOneWidget);
      }
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
