// 长文本行(brief §形:「长文本行(诊断、用药、检查):图标块 + 全宽一项一行,
// 不用两栏」)。两栏会把长句从中间切断 —— `s4` 故意放了 12 种药、6 个诊断来看这件事。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/long_text_row.dart';

void main() {
  const row = LongTextRow(
    category: GlossCategory.med, icon: Icons.medication_outlined,
    items: [
      (text: '氯吡格雷', meta: '75 mg 每日,至 2027 年 7 月'),
      (text: '二甲双胍缓释片', meta: '0.5 g 每日 2 次'),
    ],
  );

  testWidgets('一个图标块 + 每项各占一行', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: row)));
    expect(find.byType(GlossIconTile), findsOneWidget);
    expect(tester.widget<GlossIconTile>(find.byType(GlossIconTile)).category, GlossCategory.med);
    // 两项的 y 不同 = 各占一行(不是两栏并排)。
    expect(tester.getTopLeft(find.text('氯吡格雷')).dy,
        lessThan(tester.getTopLeft(find.text('二甲双胍缓释片')).dy));
  });

  testWidgets('正文左、说明右,说明不换行、正文可换行', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: row)));
    final meta = tester.widget<Text>(find.text('75 mg 每日,至 2027 年 7 月'));
    expect(meta.style!.fontSize, 13);
    expect(meta.style!.color, MedColors.light.ink3);
    expect(meta.softWrap, isFalse);                 // mockup `white-space:nowrap`
    expect(tester.widget<Text>(find.text('氯吡格雷')).style!.fontSize, 15);
  });

  testWidgets('小屏 2.0 字号不溢出 —— 说明挤不下时折到下一行', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: SingleChildScrollView(child: row)),
    )));
    expect(tester.takeException(), isNull);
  });
}
