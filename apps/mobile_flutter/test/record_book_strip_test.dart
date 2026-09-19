// 病历本条(brief §形「病历本条」)。它是「病程档案」在趋势页的入口,形状**故意**
// 和主页的成员主卡不一样 —— 一个是渐变卡面,一个是白卡 + 渐变书脊。所以这里同时
// 断言:它不是 HeroCard,也不含 BrandGradientBox。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';

void main() {
  const strip = RecordBookStrip(
    title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
    bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度',
  );

  testWidgets('白底、圆角 18、标准卡阴影 —— 不是渐变卡面', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    expect(find.byType(BrandGradientBox), findsNothing);
    final d = tester.widget<Container>(find.descendant(
        of: find.byType(RecordBookStrip), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusEntry));
    expect(d.boxShadow, MedBrand.cardShadow);
    expect(d.border, isNull);   // brief §形:卡无边框
  });

  testWidgets('左 34px 书脊,180° 两段渐变', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    final spine = find.byKey(const ValueKey('record-book-spine'));
    expect(tester.getSize(spine).width, MedBrand.spineWidth);
    final g = (tester.widget<DecoratedBox>(spine).decoration as BoxDecoration).gradient!
        as LinearGradient;
    expect(g.colors, MedBrand.spineColors);
    expect(g.begin, Alignment.topCenter);   // 180° = 上 → 下
    expect(g.end, Alignment.bottomCenter);
  });

  // R1(预检裁定):brief 原 `_StripePainter` 把 `spineStripe` 的 alpha 又乘了
  // 0.6,裁定明确不许这样做 —— 横纹颜色必须是 `MedBrand.spineStripe` 原值。
  // brief 给的测试文件里没有任何一条断言横纹本身(只断言了书脊渐变),所以这条
  // 是本 Task 新增的,用 flutter_test 内建的 `paints` 记录画布调用来钉住
  // 「颜色不被再乘」与「2px 实 / 9px 周期」这两件事,不靠新依赖。
  testWidgets('横纹:2px 实/9px 周期,颜色是 spineStripe 原值(不乘 0.6)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    final stripeCanvas = find.descendant(
      of: find.byKey(const ValueKey('record-book-spine')),
      matching: find.byType(CustomPaint),
    );
    expect(
      stripeCanvas,
      paints
        ..rect(
          rect: Rect.fromLTWH(0, 0, MedBrand.spineWidth, MedBrand.spineStripeOn),
          color: MedBrand.spineStripe,
        )
        ..rect(
          rect: Rect.fromLTWH(0, MedBrand.spineStripePeriod, MedBrand.spineWidth,
              MedBrand.spineStripeOn),
          color: MedBrand.spineStripe,
        ),
    );
  });

  testWidgets('右列大数 22·600 seal 色 + 小字说明', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    final big = tester.widget<Text>(find.text('4'));
    expect(big.style!.fontSize, 22);
    expect(big.style!.fontWeight, FontWeight.w600);
    expect(big.style!.color, MedColors.light.seal);
    expect(find.text('/18'), findsOneWidget);
    expect(find.text('化验可算活动度'), findsOneWidget);
  });

  // Fix round 1 / 控制者裁定 R15:大数列曾经包了一层 `Flexible(fit: FlexFit.loose)`
  // 来防溢出(见本文件先前版本 / 报告 deviation 3)。reviewer 用 scratch widget test
  // 验出这层包装本身就是 bug:`Flexible` 让大数列变成 flex 子项,`RenderFlex` 先按
  // flex 比例把可用空间在标题的 `Expanded` 和它之间**对半分**、各封顶 50%,大数列
  // 即使自己比封顶窄也不退回多余空间——于是它不再贴右边,`brief §形「右列大数」`
  // 的形状就破了。已去掉那层 `Flexible`(大数列恢复成 brief 原稿的普通非 flex 子
  // 项),这条测试把「贴右边」钉成断言,回归就会红。
  //
  // 用不含 `bigNumberSuffix`/`bigNumberCaption` 的最小 strip——否则「靠右贴边」的
  // 其实是后缀 `/18`,`find.text('4')` 断言就找错了对象。宽度用
  // `tester.view.physicalSize` 定死(和上面「太长时省略」那条同一手法),不用
  // `SizedBox(width:360)` 包一层——`Scaffold`/`MaterialApp.home` 给 body 的是紧约束,
  // 直接包 `SizedBox` 会被那层紧约束吃掉,量出来的还是整个视口宽度而不是 360。
  testWidgets('大数靠右贴边(fix round 1:去掉会打破贴边的 Flexible)', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const minimal = RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查', bigNumber: '4');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: minimal)));
    final rightEdge = tester.getTopRight(find.byType(RecordBookStrip)).dx;
    expect(
      tester.getTopRight(find.text('4')).dx,
      closeTo(rightEdge - RecordBookStrip.bigNumberEndPadding, 0.5),
    );
  });

  testWidgets('标题副标太长时省略,不撑破布局', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: strip),
    )));
    expect(tester.takeException(), isNull);
  });
}
