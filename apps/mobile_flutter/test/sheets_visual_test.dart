// 三张 sheet 与首启屏。s6 的选项行是 paper 底的圆角块(第一条是 #DDEDF8),
// s17 / s16 各有一颗主按钮,s16 的场景中央是 104px 的真 logo。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/import_flow.dart';
import 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart';
import 'package:mobile_flutter/screens/first_run_consent.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('s6 选项行:paper 底圆角 16,第一条是蓝底', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Column(children: [
      MedSheetOption(icon: Icons.photo_camera_outlined,
          label: '拍照', note: '可以连拍几张', highlighted: true),
      MedSheetOption(icon: Icons.image_outlined, label: '从相册选'),
    ])));
    final decos = tester.widgetList<Container>(find.descendant(
      of: find.byType(MedSheetOption), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .where((d) => d.borderRadius == BorderRadius.circular(MedShape.radiusBanner)).toList();
    expect(decos.map((d) => d.color), [MedBrand.bannerBlue, MedColors.light.paper]);
    expect(find.byType(MedIcon), findsNWidgets(2));

    // Task 16 budget-table audit:s6 那一行(0/0/0)之前只拿两颗手摆的
    // MedSheetOption 断言过颜色,没有在真正的 AddSheetBody 上钉过预算——补上
    // (真 widget 下面第 55 行的溢出矩阵已经在用同一个)。
    await pumpStage3(tester, const Scaffold(body: AddSheetBody()));
    expectSurfaceBudget();
    expectNoGradientAnywhere();
  });

  testWidgets('AddSheetBody 有四项,第四项「记录一下」点了 pop(ImportChoice.record)', (
    tester,
  ) async {
    // Task 5:「记录一下」从「趋势」页的 `RecordEntryCard` 搬来,成为这个四选一
    // 的第四项。走真实的 `showModalBottomSheet`(而不是直接 pump `AddSheetBody`
    // 本身)才测得到 `_SheetTile.onTap` 真的 `pop` 出了选中的 `ImportChoice`——
    // `AddSheetBody` 自己不碰 `Navigator`,见它的类文档。
    ImportChoice? popped;
    await pumpStage3(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            key: const Key('open_add_sheet'),
            onPressed: () async {
              // `isScrollControlled: true` 跟 [showImportSheet] 的真实配置一致——
              // 四项内容比默认 bottom sheet 的 9/16 高度上限高,不加这个,400×800
              // 这个尺寸就先溢出了(踩过,见 `showImportSheet` 旁边的注释)。
              popped = await showModalBottomSheet<ImportChoice>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const AddSheetBody(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_add_sheet')));
    await tester.pumpAndSettle();

    expect(find.byType(MedSheetOption), findsNWidgets(4));
    expect(find.text('记录一下'), findsOneWidget);
    expect(find.text('自己量的血压、体重,或者想记一句话'), findsOneWidget);

    await tester.tap(find.text('记录一下'));
    await tester.pumpAndSettle();
    expect(popped, ImportChoice.record);
  });

  testWidgets('s17:一颗主按钮 + 一颗次按钮,标题 19·600', (tester) async {
    await pumpStage3(tester, const Scaffold(body: CloudExtractAskBody()));
    expectSurfaceBudget(button: 1);
    expectNoGradientAnywhere();
    expect(find.byType(MedSecondaryButton), findsOneWidget);
  });

  testWidgets('s16:场景中央 104px 真 logo,微微左旋,一颗主按钮', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: FirstRunScene())));
    expect(tester.getSize(find.byType(BrandLogo)), const Size(104, 104));
    expect(find.byType(Transform), findsWidgets);          // rotate(-6deg)

    // fix round 2(R30):「同意并开始使用」迁到 MedPrimaryButton 之后,s16 的
    // 颜色面预算是 1(禁用态用 ink2 字 + line2 底,不占这个数)。
    await pumpStage3(tester, FirstRunConsentScreen(onAgreed: () {}));
    expectSurfaceBudget(button: 1);
    expectNoGradientAnywhere();
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
