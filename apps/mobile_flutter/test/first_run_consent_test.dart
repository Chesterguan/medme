// 首启同意屏(`screens/first_run_consent.dart`)的滚动门槛回归测试。
//
// 真机(华为 Mate 9,1080×1920)实测发现:声明没有整段露在首屏,最后一条和
// 协议链接都在折线之下,但「同意并开始使用」在首屏就可点 —— 用户能在没看过
// 声明末尾、没点开过任何协议链接的情况下同意。模拟器默认视口(1080×2400)看不出
// 这个问题,所以这里用真机同款的矮屏视口复现它。
//
// 四条断言对应验收标准:内容超一屏未滚到底时同意不可点;滚到底后可点;内容不足
// 一屏时同意直接可点(这条最容易漏 —— 漏了就是大屏手机 / 平板上永远点不了的
// 按钮);「不同意」任何时候都可点,不受这道门槛限制。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/first_run_consent.dart';
import 'package:mobile_flutter/theme.dart';

/// 华为 Mate 9 同款的矮屏视口(逻辑分辨率约 360×640)—— 复现内容溢出首屏的场景。
void useShortPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// 大屏手机 / 平板同款的高视口 —— 复现「内容本来就不到一屏」的场景。
void useTallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2600 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> pumpScreen(WidgetTester tester, {double textScale = 1.0}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: MedMe.theme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: FirstRunConsentScreen(onAgreed: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FilledButton _agreeButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.widgetWithText(FilledButton, '同意并开始使用'),
);

TextButton _declineButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.widgetWithText(TextButton, '不同意'));

/// WCAG 相对亮度 / 对比度 —— 与 `MedColors` 系列令牌对比度校验用的是同一套公式,
/// 独立算一遍而不是引用实现,免得实现算错了测试还跟着算错。
double _relLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _relLuminance(a) + 0.05;
  final lb = _relLuminance(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

void main() {
  testWidgets('矮屏未滚到底时,「同意」不可点,「不同意」仍可点', (tester) async {
    useShortPhone(tester);
    await pumpScreen(tester);

    expect(_agreeButton(tester).onPressed, isNull, reason: '没看到声明末尾就不该能同意');
    expect(
      _declineButton(tester).onPressed,
      isNotNull,
      reason: '拒绝不需要读完,任何时候都能点',
    );
  });

  testWidgets('矮屏滚到底后,「同意」变为可点', (tester) async {
    useShortPhone(tester);
    await pumpScreen(tester);
    expect(_agreeButton(tester).onPressed, isNull);

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(_agreeButton(tester).onPressed, isNotNull, reason: '滚到底之后应该能同意');
  });

  testWidgets('内容不到一屏(大屏 / 平板)时,「同意」不需要滚动就能点', (tester) async {
    useTallPhone(tester);
    await pumpScreen(tester);

    expect(
      _agreeButton(tester).onPressed,
      isNotNull,
      reason: '内容本来就没超过一屏时不该逼用户滚一个滚不动的条,否则按钮永远点不了',
    );
  });

  testWidgets('系统字号放大到 2× 时,矮屏门槛照样成立且不溢出', (tester) async {
    useShortPhone(tester);
    await pumpScreen(tester, textScale: 2.0);

    expect(tester.takeException(), isNull, reason: '2× 字号下排版不该溢出');
    expect(_agreeButton(tester).onPressed, isNull, reason: '2× 字号下内容更长,更不该一开始就能同意');

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(_agreeButton(tester).onPressed, isNotNull, reason: '2× 字号下滚到底也该能同意');
  });

  testWidgets('标题的「几件事」与实际条目数一致', (tester) async {
    useTallPhone(tester);
    await pumpScreen(tester);
    expect(find.text('开始之前,有三件事'), findsOneWidget);
  });

  testWidgets('禁用态的按钮文字对比度不低于 WCAG AA 的 4.5:1', (tester) async {
    useShortPhone(tester);
    await pumpScreen(tester);

    final style = _agreeButton(tester).style!;
    final bg = style.backgroundColor!.resolve({WidgetState.disabled})!;
    final fg = style.foregroundColor!.resolve({WidgetState.disabled})!;
    expect(
      _contrast(fg, bg),
      greaterThanOrEqualTo(4.5),
      reason: '禁用态可能要撑到用户读完才解除,不是一闪而过,必须扛得住被盯着看',
    );
  });

  // ── Stage 1:四条声明不许再说「不上传 / 只在这台手机上 / 没有账号」 ──────────
  //
  // 本版默认开云备份,并在第一次导入时征询「云端整理」(脱敏后的病历画面会送
  // 境内云端模型)。ux-audit §4 第 1-5 条:这几句话已经是对外不实陈述,而且
  // 印在 App Store 可见的位置上。
  //
  // 按钮不采 mockup `s16` 的「开始使用」:s16 把滚动到底的显式同意门换成了
  // 「用了就是同意」,那是合规机制的改动,本 Task 没有做(需要创始人另外拍板)。
  // 滚动门保留,按钮因此把「同意」这个动作明说出来,不靠旁白暗示。
  group('首启声明与当前数据流一致', () {
    const banned = [
      '只存在这台手机上',
      '没有账号,不需要注册',
      '我们那里本来就没有',
      '不会上传',
      '只在这台手机上',
      '只保存在你自己的设备上',
      '用了就是同意',
    ];

    testWidgets('整屏找不到任何一句过时声明', (tester) async {
      useTallPhone(tester);
      await pumpScreen(tester);
      for (final s in banned) {
        expect(find.textContaining(s), findsNothing, reason: '「$s」已不成立');
      }
    });

    testWidgets('云端整理这件事必须在同意之前说出来', (tester) async {
      useTallPhone(tester);
      await pumpScreen(tester);
      expect(find.textContaining('云端'), findsWidgets);
    });

    testWidgets('三条就是 s16 那三句', (tester) async {
      useTallPhone(tester);
      await pumpScreen(tester);
      for (final t in [
        '拍一下单子变成表和趋势',
        '看病时一页给医生',
        '加密存在手机,登录后云端备份,我们打不开',
      ]) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('同意并开始使用'), findsOneWidget);
    });
  });
}
