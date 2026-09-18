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
