// 「病历」主页的视觉验收(mockup s1)。**只测视觉,不测行为** —— 行为归
// archive_header_test.dart / mobile_ia_test.dart 管。
//
// 这一屏是唯一同时有主卡和主入口块的屏,所以渐变预算 hero:1 entry:1。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';
import 'stage3_visual_helpers.dart';

// 整屏 pump 要 FFI,测试环境没有原生库 —— 和 HomeTiles / ForDoctorActions 一样,
// 把这一屏的纯 widget 部件各自 pump(既有先例见 for_doctor_screen.dart:210 注释)。
Widget _homeBlock() => Scaffold(
  backgroundColor: MedColors.light.paper,
  body: ListView(padding: const EdgeInsets.all(MedShape.s3), children: [
    IdentityHeroCard(name: '张建国', gender: '男', age: '61 岁', recordCount: 31,
        recentVisitDate: '2026-07-20', onSwitchMember: () {}),
    const SizedBox(height: MedShape.s2),
    HomeTiles(onAdd: () {}, onForDoctor: () {}),
    const SizedBox(height: MedShape.s2),
    PendingReviewBanner(count: 2, onTap: () {}),
    MonthHeader(label: '2026 年 8 月', onSearch: () {}),
  ]),
);

void main() {
  testWidgets('渐变预算:一张主卡、一个主入口块、零个主按钮', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expectGradientBudget(hero: 1, entry: 1);
    expectNoGradientInsideCards();
  });

  testWidgets('「添加」是渐变入口块,「给医生看」是白块 + 门诊光泽图标', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(find.descendant(of: find.byType(PrimaryEntryTile), matching: find.text('添加')),
        findsOneWidget);
    expect(find.descendant(of: find.byType(HomeTiles), matching: find.byType(GlossIconTile)),
        findsOneWidget);
    expect(tester.widgetList<GlossIconTile>(find.descendant(
      of: find.byType(HomeTiles), matching: find.byType(GlossIconTile))).single.category,
      GlossCategory.clinic);
  });

  testWidgets('「还没核对」是琥珀横幅 + 用药图标块', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2 份还没核对')).style!.color, MedBrand.bannerAmberInk);
    expect(tester.widgetList<GlossIconTile>(find.descendant(
      of: find.byType(PendingReviewBanner), matching: find.byType(GlossIconTile))).single.category,
      GlossCategory.med);
  });

  testWidgets('月份标题 15 号 ink2,「找一找」14·500 seal', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2026 年 8 月')).style!.fontSize, 15);
    expect(tester.widget<Text>(find.text('2026 年 8 月')).style!.color, MedColors.light.ink2);
    final search = tester.widget<Text>(find.text('找一找'));
    expect(search.style!.fontSize, 14);
    expect(search.style!.color, MedColors.light.seal);
  });

  testWidgets('底色是实心 #F6F8FA,没有第二个渐变面', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        const Color(0xFFF6F8FA));
    expect(find.byType(BrandGradientBox), findsNWidgets(2));  // 主卡 + 主入口块
  });

  testWidgets('400×800 与 360×640 × 1.0/2.0 字号全部不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, _homeBlock());
  });
}
