// 每屏视觉测试的共用工具。两件事:按两种屏幕尺寸 + 2.0 字号 pump、数品牌色面的
// 预算。写一遍,十几个屏测试共用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

/// 真机两个尺寸:大屏 400×800、小屏 360×640(brief 没给,取 Android 常见下限)。
const kStage3Sizes = [Size(400, 800), Size(360, 640)];

Future<void> pumpStage3(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(400, 800),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: MedMe.theme(),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: screen,
    ),
  ));
  await tester.pump();
}

/// 「一屏一块颜色面」的可执行形式:主卡与主按钮各至多一张/一颗,默认都是 0。
void expectSurfaceBudget({int hero = 0, int button = 0}) {
  expect(find.byType(HeroCard), findsNWidgets(hero), reason: '主卡数不对');
  expect(find.byType(MedPrimaryButton), findsNWidgets(button), reason: '主按钮数不对');
}

/// 减法稿的另一半:整棵树里一个渐变都没有(静态闸管源码,这条管渲染出来的树)。
void expectNoGradientAnywhere() {
  bool hasGradient(Decoration? d) => d is BoxDecoration && d.gradient != null;
  expect(
    find.byWidgetPredicate((w) =>
        (w is Container && hasGradient(w.decoration)) ||
        (w is DecoratedBox && hasGradient(w.decoration)) ||
        (w is Ink && hasGradient(w.decoration))),
    findsNothing,
    reason: '树里还有渐变面',
  );
}

/// 2.0 字号 × 两个尺寸,四次 pump,一次溢出都不许有。
Future<void> expectNoOverflowAtBothSizes(WidgetTester tester, Widget screen) async {
  for (final size in kStage3Sizes) {
    for (final scale in [1.0, 2.0]) {
      await pumpStage3(tester, screen, size: size, textScale: scale);
      expect(tester.takeException(), isNull,
          reason: '$size @ ${scale}x 溢出了');
    }
  }
}
