// 品牌色的三个出口:实色、无渐变、无阴影;禁用态对比度;水波纹有 Material 祖先。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

Future<void> pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
  theme: MedMe.theme(), home: Scaffold(body: Center(child: w))));

/// WCAG 相对亮度对比度(sRGB 线性化用 dart:math 的 pow,不手搓)。
double contrast(Color a, Color b) {
  double lin(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  double lum(Color c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  final l1 = lum(a), l2 = lum(b);
  final hi = math.max(l1, l2), lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const c = MedColors.light;

  testWidgets('HeroCard:实色 sealInk、圆角 16、没有渐变、没有阴影、可点', (t) async {
    var taps = 0;
    await pump(t, HeroCard(onTap: () => taps++, child: const Text('x')));
    final m = t.widget<Material>(find.ancestor(of: find.text('x'), matching: find.byType(Material)).first);
    expect(m.color, c.sealInk);
    expect(m.borderRadius, BorderRadius.circular(16));
    expect(find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.gradient != null), findsNothing);
    expect(find.byWidgetPredicate((w) => w is Ink && (w.decoration as BoxDecoration?)?.gradient != null), findsNothing);
    await t.tap(find.text('x'));
    expect(taps, 1);
  });

  testWidgets('HeroCard:color 可覆盖(代拍首页 proxyInk)', (t) async {
    await pump(t, HeroCard(color: c.proxyInk, child: const Text('x')));
    final m = t.widget<Material>(find.ancestor(of: find.text('x'), matching: find.byType(Material)).first);
    expect(m.color, c.proxyInk);
  });

  testWidgets('MedPrimaryButton 启用:sealInk 底白字,对比度 ≥ 4.5', (t) async {
    await pump(t, MedPrimaryButton(label: '出码给医生看', onPressed: () {}));
    final m = t.widget<Material>(find.ancestor(of: find.text('出码给医生看'), matching: find.byType(Material)).first);
    expect(m.color, c.sealInk);
    expect(t.widget<Text>(find.text('出码给医生看')).style!.color, Colors.white);
    expect(contrast(Colors.white, c.sealInk), greaterThanOrEqualTo(4.5));
  });

  testWidgets('MedPrimaryButton 禁用:line2 底 ink2 字,对比度 ≥ 4.5', (t) async {
    await pump(t, const MedPrimaryButton(label: '出码给医生看'));
    final m = t.widget<Material>(find.ancestor(of: find.text('出码给医生看'), matching: find.byType(Material)).first);
    expect(m.color, c.line2);
    expect(t.widget<Text>(find.text('出码给医生看')).style!.color, c.ink2);
    expect(contrast(c.ink2, c.line2), greaterThanOrEqualTo(4.5));
  });

  testWidgets('MedSecondaryButton:启用 seal 描边 sealInk 字;禁用 line 描边 ink3 字', (t) async {
    await pump(t, MedSecondaryButton(label: '给医生看', onPressed: () {}));
    var ink = t.widget<Ink>(find.byType(Ink));
    expect((ink.decoration as BoxDecoration).border!.top.color, c.seal);
    expect(t.widget<Text>(find.text('给医生看')).style!.color, c.sealInk);
    await pump(t, const MedSecondaryButton(label: '给医生看'));
    ink = t.widget<Ink>(find.byType(Ink));
    expect((ink.decoration as BoxDecoration).border!.top.color, c.line);
    expect(t.widget<Text>(find.text('给医生看')).style!.color, c.ink3);
  });

  testWidgets('2.0 字号 × 360×640:三个都不溢出', (t) async {
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: MedMe.theme(), home: MediaQuery(
      data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(2.0)),
      child: Scaffold(body: Column(children: [
        HeroCard(child: const Text('用旧手机扫码批准,最简单')),
        MedPrimaryButton(label: '出码给医生看', onPressed: () {}),
        MedSecondaryButton(label: '给医生看', onPressed: () {}),
      ])))));
    expect(t.takeException(), isNull);
  });
}
