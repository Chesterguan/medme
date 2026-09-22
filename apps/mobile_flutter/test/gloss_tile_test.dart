// 光泽图标块是 brief §形 里的「我们的 3D 图标语言」—— 全 app 的图标底块只此一家。
// 这个测试钉住它的几何与三层光泽,免得后来有人「简化成一个纯色方块」。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';

Future<BoxDecoration> _decoOf(WidgetTester tester, Widget tile) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: tile))));
  final box = tester.widget<Container>(
    find.descendant(of: find.byType(GlossIconTile), matching: find.byType(Container)).first,
  );
  return box.decoration! as BoxDecoration;
}

void main() {
  testWidgets('44×44、圆角 12、150° 渐变、同色投影', (tester) async {
    final d = await _decoOf(tester, const GlossIconTile(icon: Icons.science_outlined, category: GlossCategory.lab));
    final size = tester.getSize(find.byType(GlossIconTile));
    expect(size, const Size(44, 44));
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusTile));

    final g = d.gradient! as LinearGradient;
    final (a, b, s) = MedBrand.tile(GlossCategory.lab);
    expect(g.colors, [a, b]);
    // 150°:CSS 的 0° 朝上、顺时针;150° ≈ 从左上偏上 → 右下偏下。
    expect(g.transform, isA<GradientRotation>());
    expect((g.transform! as GradientRotation).radians, closeTo(-30 * math.pi / 180, 1e-9));

    expect(d.boxShadow!.single.color, s);
    expect(d.boxShadow!.single.offset, const Offset(0, 5));
    expect(d.boxShadow!.single.blurRadius, 12);
  });

  testWidgets('两道内光泽:顶 rgba(255,255,255,.45)、底 rgba(0,0,0,.10)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile(icon: Icons.science_outlined))),
    ));
    // 内高光用一道 1px 的 Container 叠在顶/底 —— Flutter 没有 inset box-shadow。
    final highlights = tester.widgetList<DecoratedBox>(find.descendant(
      of: find.byType(GlossIconTile), matching: find.byType(DecoratedBox),
    )).map((w) => (w.decoration as BoxDecoration).color).toList();
    expect(highlights, containsAll(<Color>[MedBrand.glossTop, MedBrand.glossBottom]));
  });

  testWidgets('白色线图标 22px', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile(icon: Icons.science_outlined))),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, MedBrand.iconSize);
    expect(icon.color, Colors.white);
  });

  testWidgets('字母款:成员头像用品牌渐变 + 白字', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile.letter(letter: '张'))),
    ));
    expect(find.text('张'), findsOneWidget);
    expect(tester.widget<Text>(find.text('张')).style!.color, Colors.white);
    final d = await _decoOf(tester, const GlossIconTile.letter(letter: '张'));
    final (a, b, _) = MedBrand.tile(GlossCategory.brand);
    expect((d.gradient! as LinearGradient).colors, [a, b]);
  });

  testWidgets('九档类别各有各的渐变,没有两档撞色', (tester) async {
    final seen = <List<Color>>[];
    for (final cat in GlossCategory.values) {
      final (a, b, _) = MedBrand.tile(cat);
      seen.add([a, b]);
    }
    expect(seen.toSet().length, GlossCategory.values.length);
  });

  testWidgets('2.0 字号下不溢出(块是固定尺寸,图标不跟着放大)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: const Scaffold(body: Center(child: GlossIconTile.letter(letter: '张'))),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(GlossIconTile)), const Size(44, 44));
  });

  testWidgets('size 非默认值(首启场景 52/56/40):几何整体跟着缩放', (tester) async {
    final d = await _decoOf(tester, const GlossIconTile(icon: Icons.add, size: 52));
    expect(tester.getSize(find.byType(GlossIconTile)), const Size(52, 52));
    // 按实现里同样的运算顺序算(先除再乘):`a*52/b` 是 `(a*52)/b`,浮点上和
    // 实现的 `a*(52/b)` 未必位级相等,直接抄字面表达式会碰运气挂测试。
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusTile * (52 / MedBrand.iconSlot)));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile(icon: Icons.add, size: 52))),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, MedBrand.iconSize * (52 / MedBrand.iconSlot));
  });
}
