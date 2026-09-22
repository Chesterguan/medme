// 病历本条(brief §形「病历本条」,减法稿 2026-09-22)。它是「病程档案」在趋势页的
// 入口:白卡一行 —— 30px 真 logo + 标题 + 说明 + 一行数字 + `›`。原来的白卡 + 34px
// 渐变书脊、右列大数,以及它们各自的令牌(`MedBrand.spine*`)都随这次减法删掉了。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';

void main() {
  const strip = RecordBookStrip(
    title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
    bigNumberCaption: '活动度(化验可算部分)', bigNumber: '0 / 18',
  );

  testWidgets('是一张 MedCard,整树没有渐变', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    expect(find.byType(MedCard), findsOneWidget);
    final decorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration)
        .whereType<BoxDecoration>();
    for (final d in decorations) {
      expect(d.gradient, isNull);
    }
  });

  testWidgets('默认 logo 30px;logo: null 时不画', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    expect(tester.widget<BrandLogo>(find.byType(BrandLogo)).size, BrandLogo.topBar);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: RecordBookStrip(
        title: '病程档案', subtitle: '还没准备好', logo: null))));
    expect(find.byType(BrandLogo), findsNothing);
  });

  testWidgets('标题/说明/数字行三段文字都在,数字 MedType.value ink 色', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    expect(find.text('病程档案 · 狼疮'), findsOneWidget);
    expect(find.text('2 项该复查 · 复诊 8 月 12 日'), findsOneWidget);
    expect(find.text('活动度(化验可算部分)'), findsOneWidget);
    final number = tester.widget<Text>(find.text('0 / 18'));
    expect(number.style!.fontSize, MedType.value.fontSize);
    expect(number.style!.fontWeight, MedType.value.fontWeight);
    expect(number.style!.color, MedColors.light.ink);
  });

  testWidgets('onTap 传了才有 ›,tap 会触发它', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    expect(find.byIcon(Icons.chevron_right), findsNothing);

    var tapped = false;
    final tappable = RecordBookStrip(
      title: '病程档案 · 狼疮', subtitle: '2 项该复查', onTap: () => tapped = true,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: tappable)));
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.byType(RecordBookStrip));
    expect(tapped, isTrue);
  });

  testWidgets('360×640 @2× 字号,长标题不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: RecordBookStrip(
          title: '病程档案 · 系统性红斑狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
          bigNumberCaption: '活动度(化验可算部分)', bigNumber: '0 / 18')),
    )));
    expect(tester.takeException(), isNull);
    // R21 回归钉子:标题退回一行省略号(而不是抛异常)也算破 —— 光看
    // `takeException` 抓不到。
    final title = tester.widget<Text>(find.text('病程档案 · 系统性红斑狼疮'));
    expect(title.maxLines, 2);
  });
}
