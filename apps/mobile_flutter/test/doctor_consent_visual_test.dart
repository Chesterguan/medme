// 拍前同意屏(`screens/doctor/consent_screen.dart`)的视觉护栏。
//
// 单挑这一屏来测,因为它同时是三样东西:**法务文案屏**(文案一个字都不能改,改了
// 要升 `kConsentTextVersion`)、**给病人读的屏**(常常是老人,而且他读完要签字)、
// 以及医生模式主色迁移里字阶动得最大的一屏(正文 13.5 → 15)。字号一提就可能溢出,
// 而溢出在这里意味着「病人没看到那一条就签了」。
//
// 三条断言:文案在、2× 系统字号下不溢出、强调色确实是医生模式的 `proxy` 而不是
// 个人模式的 `seal`(拿错主色 = 病人在「你自己的档案」的视觉语言下签了代拍同意)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/doctor/consent_screen.dart';
import 'package:mobile_flutter/theme.dart';

/// 同意屏很长,测试默认的 800×600 视口装不下 —— 给一个真实手机高度再加余量,
/// 否则 2× 字号那一轮会被视口本身撑爆,测出来的是视口不是布局。
void useTallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> pumpConsent(WidgetTester tester, {double textScale = 1.0}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: MedMe.theme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: ConsentScreen(onAgreed: (_) {}, onCancel: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('五条告知都在,且 1× / 2× 字号下都不溢出', (tester) async {
    useTallPhone(tester);
    for (final scale in [1.0, 2.0]) {
      await pumpConsent(tester, textScale: scale);
      // 溢出会作为异常被测试框架捕获;takeException 非空就是这一轮排版炸了。
      expect(
        tester.takeException(),
        isNull,
        reason: '系统字号 $scale× 时同意屏排版溢出 —— 病人会看不全就签字',
      );
      for (final title in ['拍什么', '做什么用', '交给谁', '在这台手机上存多久', '谁能打开']) {
        expect(find.text(title), findsOneWidget, reason: '$scale× 时「$title」不见了');
      }
    }
  });

  testWidgets('强调色是医生模式的 proxy,不是个人模式的 seal', (tester) async {
    useTallPhone(tester);
    await pumpConsent(tester);
    final icon = tester.widget<Icon>(find.byIcon(Icons.privacy_tip_outlined));
    expect(icon.color!.toARGB32(), MedColors.light.proxy.toARGB32());
    expect(icon.color!.toARGB32(), isNot(MedColors.light.seal.toARGB32()));
  });

  testWidgets('签不了字的兜底那一支也能渲染', (tester) async {
    useTallPhone(tester);
    await pumpConsent(tester);
    await tester.ensureVisible(find.text('不方便签名?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不方便签名?'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('按住\n确认'), findsOneWidget);
  });
}
