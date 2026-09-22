// 「病历」主页的视觉验收(mockup s1)。**只测视觉,不测行为** —— 行为归
// archive_header_test.dart / mobile_ia_test.dart 管。
//
// 这一屏是唯一同时有主卡和主按钮的屏,所以颜色面预算 hero:1 button:1。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
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
  testWidgets('颜色面预算:一张主卡、一颗主按钮', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expectSurfaceBudget(hero: 1, button: 1);
  });

  testWidgets('「添加」是实心药丸(MedPrimaryButton),「给医生看」是描边药丸(MedSecondaryButton)', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(find.widgetWithText(MedPrimaryButton, '添加'), findsOneWidget);
    expect(find.widgetWithText(MedSecondaryButton, '给医生看'), findsOneWidget);
  });

  testWidgets('「还没核对」是琥珀横幅', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2 份还没核对')).style!.color, MedBrand.bannerAmberInk);
    expect(tester.widget<Icon>(find.byIcon(Icons.warning_amber_outlined)).color, MedBrand.bannerAmberInk);
  });

  testWidgets('月份标题 15 号 ink2,「找一找」14·500 seal', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2026 年 8 月')).style!.fontSize, 15);
    expect(tester.widget<Text>(find.text('2026 年 8 月')).style!.color, MedColors.light.ink2);
    final search = tester.widget<Text>(find.text('找一找'));
    expect(search.style!.fontSize, 14);
    expect(search.style!.color, MedColors.light.seal);
  });

  testWidgets('底色是实心 #F6F8FA,没有第二块颜色面', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(MedColors.light.paper, const Color(0xFFF6F8FA));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        MedColors.light.paper);
  });

  testWidgets('400×800 与 360×640 × 1.0/2.0 字号全部不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, _homeBlock());
  });
}
