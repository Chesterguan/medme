// 品牌渐变的看门测试。brief §品牌:「一屏只一处品牌渐变」——「一处」按计划的收口
// 指一个渐变**卡面**;主入口块和主按钮是控件,各自独立限一个(见计划「已知分歧 1」)。
//
// 能这样断言的前提是:**渐变只从 BrandGradientBox 出去**。所以这里先钉住这一点,
// 屏测试才有得数。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';

void main() {
  testWidgets('渐变 135°、三段、0/.5/1', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: HeroCard(child: Text('x')),
    )));
    // R13:渐变面改用 Ink(不是 Container)画,水波纹才叠得上去——见
    // brand_gradient.dart 里 BrandGradientBox.build() 的注释。
    final box = tester.widget<Ink>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Ink)).first);
    final g = (box.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(g.colors, MedBrand.gradientColors);
    expect(g.stops, MedBrand.gradientStops);
    expect(g.begin, Alignment.topLeft);    // 135° = 左上 → 右下
    expect(g.end, Alignment.bottomRight);
  });

  testWidgets('HeroCard:圆角 22、主卡阴影、右上一团光晕', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HeroCard(child: Text('x')))));
    final box = tester.widget<Ink>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Ink)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusHero));
    expect(d.boxShadow, MedBrand.heroShadow);
    // 光晕:一个用 heroGlow 起色的 RadialGradient,对齐右上。
    final glow = tester.widgetList<Container>(find.descendant(
      of: find.byType(HeroCard), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .firstWhere((d) => d.gradient is RadialGradient);
    expect((glow.gradient! as RadialGradient).colors.first, MedBrand.heroGlow);
  });

  testWidgets('PrimaryEntryTile:圆角 18、入口块阴影、白图标 34', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: PrimaryEntryTile(icon: Icons.add_a_photo_outlined, label: '添加'))));
    final box = tester.widget<Ink>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Ink)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusEntry));
    expect(d.boxShadow, MedBrand.entryShadow);
    expect(tester.widget<Icon>(find.byType(Icon)).size, 34);
    expect(tester.widget<Icon>(find.byType(Icon)).color, Colors.white);
  });

  testWidgets('MedPrimaryButton:药丸、按钮阴影、17·w500 白字', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: MedPrimaryButton(label: '出码给医生看', icon: Icons.qr_code_2_outlined))));
    final box = tester.widget<Ink>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Ink)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusPill));
    expect(d.boxShadow, MedBrand.buttonShadow);
    final t = tester.widget<Text>(find.text('出码给医生看'));
    expect(t.style!.fontSize, 17);
    expect(t.style!.fontWeight, FontWeight.w500);
    expect(t.style!.color, Colors.white);
  });

  testWidgets('MedSecondaryButton:白底 + 1.5px seal 描边 + sealInk 字,无阴影', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: MedSecondaryButton(label: '先不出'))));
    expect(find.byType(BrandGradientBox), findsNothing);  // 次按钮不许有渐变
    final d = tester.widget<Ink>(find.descendant(
      of: find.byType(MedSecondaryButton), matching: find.byType(Ink)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.border!.top.color, MedColors.light.seal);
    expect(d.border!.top.width, 1.5);
    expect(d.boxShadow, anyOf(isNull, isEmpty));
    expect(tester.widget<Text>(find.text('先不出')).style!.color, MedColors.light.sealInk);
  });

  // R13(review fix round 1):BrandGradientBox 与 MedSecondaryButton 原来把
  // InkWell 的子内容画成不透明 Container,水波纹被盖在下面,画了也看不见
  // (Flutter `Ink` 类文档原话)。改成 Ink 之后,水波纹能叠上去的前提是
  // 「InkWell 的直接/间接子内容里有 Ink,不是 Container」——这两个测试把这条
  // 钉成断言,回归了会红,不会又悄悄变回不可见的水波纹。
  group('R13:水波纹画在 Ink 上,不会被不透明底色盖住', () {
    testWidgets('BrandGradientBox 系(以 HeroCard 为例):InkWell 的子内容是 Ink', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: HeroCard(onTap: () {}, child: const Text('x')),
      )));
      expect(
        find.descendant(of: find.byType(InkWell), matching: find.byType(Ink)),
        findsOneWidget,
      );
      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.splashColor, Colors.white.withValues(alpha: 0.08));
      expect(inkWell.highlightColor, Colors.white.withValues(alpha: 0.04));
    });

    testWidgets('MedSecondaryButton:InkWell 的子内容是 Ink', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: MedSecondaryButton(label: '先不出', onPressed: () {}),
      )));
      expect(
        find.descendant(of: find.byType(InkWell), matching: find.byType(Ink)),
        findsOneWidget,
      );
    });
  });

  testWidgets('2.0 字号、360×640 下按钮不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: Center(child: MedPrimaryButton(label: '出码给医生看'))),
    )));
    expect(tester.takeException(), isNull);
  });
}
