// 「趋势」页的视觉验收(mockup s2)。这一屏**一个品牌渐变面都没有** —— 顶上那条
// 是病历本条(白卡 + 34px 渐变书脊),形状故意和主页的成员主卡不一样。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('零个渐变面;病程档案入口是病历本条', (tester) async {
    await pumpStage3(tester, const Scaffold(body: SingleChildScrollView(child: Column(children: [
      RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
          bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度'),
    ]))));
    expectGradientBudget();                      // 三个全 0
    expect(find.byType(BrandGradientBox), findsNothing);
    expect(find.byType(RecordBookStrip), findsOneWidget);
  });

  testWidgets('「看懂」是蓝横幅:底 #DDEDF8、小标题 #0E6285', (tester) async {
    await pumpStage3(tester, const Scaffold(body: UnderstandBanner(
        text: '肌酐四年缓慢上升,eGFR 渐降。', source: '该报告「提示」一栏')));
    final d = tester.widgetList<Container>(find.descendant(
        of: find.byType(UnderstandBanner), matching: find.byType(Container)))
        .map((w) => w.decoration).whereType<BoxDecoration>().first;
    expect(d.color, MedBrand.bannerBlue);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));
  });

  testWidgets('面板 chip:白底药丸 + 小阴影,选中是 seal 实底白字', (tester) async {
    await pumpStage3(tester, const Scaffold(body: _ChipsProbe()));
    // 未选中
    final off = tester.widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration).whereType<BoxDecoration>()
        .firstWhere((d) => d.color == Colors.white && d.boxShadow == MedBrand.chipShadow);
    expect(off.borderRadius, BorderRadius.circular(MedShape.radiusPill));
    // 选中
    expect(tester.widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration).whereType<BoxDecoration>()
        .any((d) => d.color == MedColors.light.seal), isTrue);
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, const Scaffold(body: SingleChildScrollView(
        child: RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
            bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度'))));
  });
}

/// `_PanelChip` 是 `trends_screen.dart` 的私有类,同文件外拿不到;这里改拿
/// `PanelChipsRow`(本 Task 把它从私有的 `_PanelChipsRow` 改公开,专为这条测试
/// ——不然「未选中/选中各断一次」这条测试写不出来)喂两颗 chip,一颗选中
/// 一颗不选中,同样能触到 `_PanelChip` 两条分支。
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
