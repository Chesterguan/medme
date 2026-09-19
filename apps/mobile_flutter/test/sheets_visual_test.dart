// 三张 sheet 与首启屏。s6 的选项行是 #F1F4F8 底的圆角块(第一条是 #DDEDF8),
// s17 / s16 各有一颗渐变主按钮,s16 的场景中央是 104px 的真 logo。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/import_flow.dart';
import 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart';
import 'package:mobile_flutter/screens/first_run_consent.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('s6 选项行:paper 底圆角 16,第一条是蓝底', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Column(children: [
      MedSheetOption(icon: Icons.photo_camera_outlined, category: GlossCategory.brand,
          label: '拍照', note: '可以连拍几张', highlighted: true),
      MedSheetOption(icon: Icons.image_outlined, category: GlossCategory.lab, label: '从相册选'),
    ])));
    final decos = tester.widgetList<Container>(find.descendant(
      of: find.byType(MedSheetOption), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .where((d) => d.borderRadius == BorderRadius.circular(MedShape.radiusBanner)).toList();
    expect(decos.map((d) => d.color), [MedBrand.bannerBlue, MedColors.light.paper]);
    expect(find.byType(GlossIconTile), findsNWidgets(2));
  });

  testWidgets('s17:一颗渐变主按钮 + 一颗次按钮,标题 19·600', (tester) async {
    await pumpStage3(tester, const Scaffold(body: CloudExtractAskBody()));
    expectGradientBudget(button: 1);
    expect(find.byType(MedSecondaryButton), findsOneWidget);
  });

  testWidgets('s16:场景中央 104px 真 logo,微微左旋,一颗渐变主按钮', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: FirstRunScene())));
    expect(tester.getSize(find.byType(BrandLogo)), const Size(104, 104));
    expect(find.byType(Transform), findsWidgets);          // rotate(-6deg)
    expect(find.byType(GlossIconTile), findsNWidgets(3));  // 三个飘着的小块

    // fix round 2(R30):「同意并开始使用」迁到 MedPrimaryButton 之后,s16 的
    // 渐变预算是 1(禁用态用 ink2 字 + line2 底,不画渐变,不占这个数)。
    await pumpStage3(tester, FirstRunConsentScreen(onAgreed: () {}));
    expectGradientBudget(button: 1);
  });

  testWidgets('三张 sheet 在两个尺寸 × 两档字号下不溢出', (tester) async {
    // fix round 1(task-14-review Important):原来只 pump 了 CloudExtractAskBody
    // 一家,s6(AddSheetBody)与 s16(FirstRunConsentScreen)一次都没在这个
    // 矩阵里跑过。补齐,用真文案。
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: CloudExtractAskBody())));
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: AddSheetBody())));
    await expectNoOverflowAtBothSizes(tester, FirstRunConsentScreen(onAgreed: () {}));
  });
}
