// 「趋势」页的视觉验收(mockup s2)。这一屏**一个品牌颜色面都没有** —— 顶上那条
// 是病历本条(白卡一行),形状故意和主页的成员主卡不一样。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('零个颜色面;病程档案入口是病历本条', (tester) async {
    await pumpStage3(tester, const Scaffold(body: SingleChildScrollView(child: Column(children: [
      RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
          bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度'),
    ]))));
    expectSurfaceBudget();                      // 两个全 0
    expect(find.byType(RecordBookStrip), findsOneWidget);
  });

  testWidgets('面板 chip:白底描边,选中 seal 描边 + sealInk 字', (tester) async {
    await pumpStage3(tester, const Scaffold(body: _ChipsProbe()));
    final boxes = tester.widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration).whereType<BoxDecoration>()
        .where((d) => d.borderRadius == BorderRadius.circular(MedShape.radiusPill))
        .toList();
    // 未选中(「肾功能 1」)
    final off = boxes.firstWhere((d) => d.border!.top.color == MedColors.light.line);
    expect(off.boxShadow, isNull);
    // 选中(「全部 3」)
    final on = boxes.firstWhere((d) => d.border!.top.color == MedColors.light.seal);
    expect(on.boxShadow, isNull);
    expect(tester.widget<Text>(find.text('全部 3')).style!.color, MedColors.light.sealInk);
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, const Scaffold(body: SingleChildScrollView(
        child: RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
            bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度'))));
  });

  // ── Fix round 1(controller ruling R19,Important #2):trends_visual_test.dart
  // 原来一次都没 pump 过真的 `SeriesCard`,漏掉了这一屏计划要求覆盖的那一行的
  // 几何形状。补上:长名称/长单位这组真实会溢出的数据(见 R19 的复现用例)。
  TrendSeriesDto longNameSeries() => TrendSeriesDto(
    name: '抗核抗体谱定量(ANA)',
    unit: 'mmol/L',
    valuesConverted: false,
    anyAbnormal: true,
    points: const [
      TrendPointDto(
        date: '2026-08-05', value: 128.5, unit: 'mmol/L', flag: 'H',
        documentId: 1, unverified: false,
      ),
    ],
    selfMeasured: false,
  );

  testWidgets('趋势行(SeriesCard):长名称 + 长单位,两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, Scaffold(body: SingleChildScrollView(
        child: SeriesCard(series: longNameSeries(), onOpenDoc: (_) {}))));
  });

  testWidgets('趋势行:78×24 小折线占位;点开 ▾ 原地展开 82px、底 #F7FAFC', (tester) async {
    await pumpStage3(tester, Scaffold(body: SingleChildScrollView(
        child: SeriesCard(series: longNameSeries(), onOpenDoc: (_) {}))));

    final spark = find.byWidgetPredicate((w) => w is SizedBox && w.width == 78 && w.height == 24);
    expect(spark, findsOneWidget);
    expect(tester.getSize(spark), const Size(78, 24));

    Finder expandArea() => find.byWidgetPredicate((w) =>
        w is Container && (w.decoration as BoxDecoration?)?.color == MedBrand.expandedChartBg);
    expect(expandArea(), findsNothing, reason: '默认收起,不占位');

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();

    expect(expandArea(), findsOneWidget, reason: '点开之后原地展开一块占位区');
    expect(tester.getSize(expandArea()).height, 82);
  });
}

/// `MedChip`(原 `trends_screen.dart` 私有的 `_PanelChip`,Task 10 提到
/// `widgets/med_card.dart` 改公开共用,R8)今天已经可以直接拿到,但这里仍然
/// 经 `PanelChipsRow`(本 Task 把它从私有的 `_PanelChipsRow` 改公开)喂两颗
/// chip,一颗选中一颗不选中——顺带把「选中态/未选中态」在 `PanelChipsRow`
/// 这一层的接线也验了,不只是验 `MedChip` 自己。
class _ChipsProbe extends StatelessWidget {
  const _ChipsProbe();

  @override
  Widget build(BuildContext context) => PanelChipsRow(
    chips: const [
      TrendPanelChipData(panel: null, label: '全部', count: 3),
      TrendPanelChipData(panel: 'x', label: '肾功能', count: 1),
    ],
    selectedPanel: null,
    onSelectPanel: (_) {},
  );
}
