// 每屏视觉测试的共用工具。三件事:按两种屏幕尺寸 + 2.0 字号 pump、数品牌渐变的
// 预算、确认卡里没有渐变。写一遍,十几个屏测试共用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

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

/// brief §品牌「一屏只一处品牌渐变」的可执行形式。默认三个都是 0 —— 调用方只写
/// 它这一屏真正有的那几个,写漏了测试就红。
void expectGradientBudget({int hero = 0, int entry = 0, int button = 0}) {
  expect(find.byType(HeroCard), findsNWidgets(hero), reason: '主卡数不对');
  expect(find.byType(PrimaryEntryTile), findsNWidgets(entry), reason: '主入口块数不对');
  expect(find.byType(MedPrimaryButton), findsNWidgets(button), reason: '主按钮数不对');
}

/// brief §形「卡无边框」+「渐变只给主卡/主入口块/主按钮」的另一半:
/// **任何一张 MedCard 里都不许有品牌渐变。**
void expectNoGradientInsideCards() {
  expect(
    find.descendant(of: find.byType(MedCard), matching: find.byType(BrandGradientBox)),
    findsNothing,
    reason: '卡里出现了品牌渐变 —— 卡只能是白底 + 阴影',
  );
  expect(
    find.descendant(of: find.byType(Card), matching: find.byType(BrandGradientBox)),
    findsNothing,
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
