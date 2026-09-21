// 化验行(brief §形:「左 4px 色条 + 偏高/偏低标签 + 彩色数值,单位小字可折到
// 数值下一行」)。色条与 pill **同时**编码状态:色盲用户读 pill,正常视力扫色条。
//
// 预检裁定 R2:`LabStatus` 不新增 normal/critical 枚举值——「正常」是
// `labStatusOf` 返回的 `null`,这里按 `null` 断言颜色,不引用不存在的枚举成员。
// 危急档暂无数据来源,只保留 token、不做行为,这里不测(design_tokens_test.dart
// 已经把 token 本身钉住了)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';

void main() {
  testWidgets('左色条:偏高 #E07A25、偏低 #1F6FD2、(null=正常) #2F8F5B', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) { ctx = c; return const SizedBox(); })));
    expect(labStripeColor(ctx, LabStatus.high), MedBrand.barHigh);
    expect(labStripeColor(ctx, LabStatus.low), MedBrand.barLow);
    expect(labStripeColor(ctx, null), MedBrand.barNormal);
  });

  testWidgets('数值色用 brief 的档位文字色;(null=正常) 用 normalInk', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) { ctx = c; return const SizedBox(); })));
    expect(labStatusColor(ctx, LabStatus.high), const Color(0xFFC25E18));
    expect(labStatusColor(ctx, LabStatus.low), const Color(0xFF1F5FB8));
    expect(labStatusColor(ctx, null), MedBrand.normalInk);
  });

  testWidgets('左色条宽 4px(brief 说 4,旧代码是 3)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LabLine(
      name: '肌酐', value: 112, unit: 'μmol/L', flag: 'H', meta: '参考 57–97'))));
    final border = (tester.widget<Container>(find.descendant(
      of: find.byType(LabLine), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration).border! as Border;
    expect(border.left.width, 4);
    expect(border.left.color, MedBrand.barHigh);
  });

  testWidgets('偏高 pill 用 #9A4A12 压 #FDE3CC —— 不是数值那档橙', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LabLine(
      name: '肌酐', value: 112, unit: 'μmol/L', flag: 'H'))));
    expect(tester.widget<Text>(find.text('偏高')).style!.color, MedBrand.pillHighInk);
  });

  testWidgets('小屏 2.0 字号:单位折到数值下一行,不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: SingleChildScrollView(child: LabLine(
        name: '估算肾小球滤过率', value: 63, unit: 'ml/min/1.73m²', flag: 'L',
        meta: '参考 >90'))),
    )));
    expect(tester.takeException(), isNull);
  });
}
