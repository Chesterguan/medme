// 病情摘要卡(`screens/doctor/proxy_summary_card.dart`)的视觉护栏。
//
// 这张卡是医生模式里唯一一处**大量渲染病人数据**的自有组件(化验表那块交给共用的
// `widgets/report_content.dart`,由 `design_tokens_test.dart` 守)。所以这里守的是
// 同一条规矩在这张卡上的落地:
//
//  1. **化验状态色与个人模式同源** —— 偏高 = `high`、偏低 = `low`、正常不上色。
//     同一份化验值在哪个模式下都必须长一样,否则「偏高」就成了两个意思。
//  2. **医生模式主色 `proxy` 一个字都不许染上去** —— 紫是「当前处在代拍模式」这个
//     信号的颜色,不是病人数据的颜色。它一旦渗进数据区,「紫 = 换了个模式」这条
//     用户刚学会的规则就开始说不准了。
//  3. 2× 系统字号下不溢出(007 §2.5「字号可放大,不可砍」)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/doctor/proxy_summary_card.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/theme.dart';

/// 一份够典型的摘要:一个「在管」的问题(带一高一正常两项化验、一在用一停用两味
/// 药)+ 一个 `warn` 的问题(带一项偏低)。四种状态一次盖全。
const sample = ProxySummaryDto(
  problems: [
    ProxyProblemDto(
      term: '2型糖尿病',
      status: '在管',
      warn: false,
      labs: [
        ProxyLabDto(
          name: '空腹血糖',
          unit: 'mmol/L',
          latestValue: 9.1,
          refHigh: 6.1,
          refLow: 3.9,
          trend: 'up',
          recentPoints: [],
        ),
        ProxyLabDto(
          name: '血红蛋白',
          unit: 'g/L',
          latestValue: 122,
          refHigh: 160,
          refLow: 120,
          trend: 'flat',
          recentPoints: [],
        ),
      ],
      meds: [
        ProxyMedDto(name: '二甲双胍', dose: '0.5g bid', active: true),
        ProxyMedDto(name: '格列美脲', dose: '2mg qd', active: false),
      ],
    ),
    ProxyProblemDto(
      term: '慢性肾脏病',
      status: '需关注',
      warn: true,
      labs: [
        ProxyLabDto(
          name: '肌酐',
          unit: 'umol/L',
          latestValue: 41,
          refHigh: 97,
          refLow: 57,
          trend: 'down',
          recentPoints: [],
        ),
      ],
      meds: [],
    ),
  ],
);

Future<void> pumpCard(WidgetTester tester, {double textScale = 1.0}) async {
  tester.view.physicalSize = const Size(390 * 3, 1600 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: MedMe.theme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: const Scaffold(
          body: SingleChildScrollView(child: ProxySummaryCard(summary: sample)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  testWidgets('化验状态色与个人模式同源:偏高 high / 偏低 low / 正常不上色', (tester) async {
    await pumpCard(tester);
    final c = MedColors.light;
    expect(colorOf(tester, '9.1mmol/L').toARGB32(), c.high.toARGB32());
    expect(colorOf(tester, '41umol/L').toARGB32(), c.low.toARGB32());
    expect(
      colorOf(tester, '122g/L').toARGB32(),
      c.ink.toARGB32(),
      reason: '正常值上色了 —— 22 项里 1–2 项异常,给正常配色会把异常淹没(规范 §二)',
    );
  });

  testWidgets('问题名牌:warn 走 critical,不 warn 中性', (tester) async {
    await pumpCard(tester);
    final c = MedColors.light;
    expect(colorOf(tester, '慢性肾脏病').toARGB32(), c.critical.toARGB32());
    expect(
      colorOf(tester, '2型糖尿病').toARGB32(),
      c.ink.toARGB32(),
      reason: '不 warn 的问题也上了色 —— 条条都染,真正报警的那条就被淹没了',
    );
  });

  testWidgets('卡上不出现医生模式主色 —— 紫是模式信号,不是数据的颜色', (tester) async {
    await pumpCard(tester);
    final banned = {
      MedColors.light.proxy.toARGB32(),
      MedColors.light.proxyInk.toARGB32(),
    };
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final col = t.style?.color?.toARGB32();
      if (col != null) {
        expect(
          banned.contains(col),
          isFalse,
          reason: '「${t.data}」染上了医生模式主色',
        );
      }
    }
  });

  testWidgets('2× 系统字号下不溢出', (tester) async {
    await pumpCard(tester, textScale: 2.0);
    expect(tester.takeException(), isNull);
    expect(find.text('病情摘要'), findsOneWidget);
  });
}
