// 化验行(减法稿 2026-09-22):无左色条;右列 = 数值 + 状态词 + 细刻度条;正常不上色不加字。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

Future<void> pump(WidgetTester t, Widget w, {Size size = const Size(400, 800), double scale = 1.0}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: MedMe.theme(), home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: Material(child: w)))));
}

// `BoxDecoration.border` 静态类型是 `BoxBorder?`——`.left` 只在它的子类 `Border`
// 上(`BorderDirectional` 用 start/end),所以要先 `is Border` 窄化,不能直接
// `?.left`(与 `document_detail_visual_test.dart` 已有的同一处写法一致)。
bool _hasLeftBar(WidgetTester t) => t.widgetList<Container>(find.byType(Container)).any((w) {
  final d = w.decoration;
  return d is BoxDecoration && d.border is Border && (d.border! as Border).left.width == 4;
});

void main() {
  const c = MedColors.light;

  testWidgets('偏高:数值 high、「偏高」上色无底、无左色条、圆点 high', (t) async {
    await pump(t, const LabLine(name: '尿素', value: 8.2, unit: 'mmol/L', flag: 'H', refLow: 3.1, refHigh: 8));
    expect(t.widget<Text>(find.text('8.2')).style!.color, c.high);
    expect(t.widget<Text>(find.text('偏高')).style!.color, c.high);
    expect(find.byType(MedPill), findsNothing);
    expect(_hasLeftBar(t), isFalse);
    expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.high);
  });

  testWidgets('偏低:数值 low、「偏低」low、圆点 low', (t) async {
    await pump(t, const LabLine(name: '估算肾小球滤过率', value: 63, unit: 'ml/min/1.73m2', flag: 'L', refLow: 90));
    expect(t.widget<Text>(find.text('63')).style!.color, c.low);
    expect(t.widget<Text>(find.text('偏低')).style!.color, c.low);
    expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.low);
  });

  testWidgets('正常(N / 无标记):数值 ink、没有任何状态词、圆点 ink3', (t) async {
    for (final flag in ['N', null]) {
      await pump(t, LabLine(name: '心率', value: 70, unit: '/min', flag: flag, refLow: 60, refHigh: 100));
      expect(t.widget<Text>(find.text('70')).style!.color, c.ink);
      expect(find.text('正常'), findsNothing);
      expect(find.text('偏高'), findsNothing);
      expect(find.text('偏低'), findsNothing);
      expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.ink3);
    }
  });

  testWidgets('没有参考区间:不画刻度条', (t) async {
    await pump(t, const LabLine(name: '血糖', value: 6.3, unit: 'mmol/L'));
    expect(find.byType(LabRangeBar), findsNothing);
  });

  testWidgets('认不出的标记:原样成「看一眼」chip,数值不上色,圆点 ink3', (t) async {
    await pump(t, const LabLine(name: '钾', value: 5.9, flag: 'HH', refLow: 3.5, refHigh: 5.3));
    expect(find.widgetWithText(MedPill, 'HH'), findsOneWidget);
    expect(t.widget<Text>(find.text('5.9')).style!.color, c.ink);
    expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.ink3);
  });

  testWidgets('需核对 chip 仍在名字前', (t) async {
    await pump(t, const LabLine(name: '钾', value: 5.9, unverified: true));
    expect(find.widgetWithText(MedPill, '需核对'), findsOneWidget);
  });

  testWidgets('360×640 @2×:长名 + 长单位 + 偏低 + 参考区间,不溢出', (t) async {
    await pump(t, const LabLine(name: '抗核抗体谱定量(ANA)', value: 63, unit: 'ml/min/1.73m2',
        flag: 'L', refLow: 90, meta: '2026-02-14', unverified: true, onTap: null),
      size: const Size(360, 640), scale: 2.0);
    expect(t.takeException(), isNull);
  });

  testWidgets('360×640 @2×:meta + 参考区间连在一起时,数值不在破折号处被夹断', (t) async {
    const fullText = '2026-02-14 · 参考 3.1–8';
    await pump(t, const LabLine(name: '肌酐', value: 95, meta: '2026-02-14', refLow: 3.1, refHigh: 8),
      size: const Size(360, 640), scale: 2.0);
    // 这一行曾经塞在名字那个窄 Expanded 里(360dp 上约 114dp 宽)。实测过:
    // 日期+分隔号+参考区间这一整句在 360dp@2× 下本来就超过一行能装的宽度,
    // 挪到整宽之后仍会在「· 」处折成两行——这是正常换行,不是本条要盯的问题。
    // 真正的缺陷是旧代码把它挤进窄列后连「参考 3.1–8」自己都装不下,在破折号
    // 处被夹断成「参考 3.1–」/「8」两行,孤零零的「8」读起来像另一个值。
    // 所以这里不断言「整句不换行」(测过是假的),断言更精确的那件事:量出
    // 「3.1–8」这个子串的包围盒,必须只有一个 top——它完整地待在同一行里,
    // 不管上面那句整体折不折行。用真实的 RenderParagraph(不是另起一个
    // TextPainter 重算一遍布局,那样可能和实际渲染对不上)。
    final rp = t.renderObject<RenderParagraph>(find.text(fullText));
    final rangeStart = fullText.indexOf('3.1');
    final boxes = rp.getBoxesForSelection(
      TextSelection(baseOffset: rangeStart, extentOffset: fullText.length));
    expect(boxes.map((b) => b.top).toSet(), hasLength(1),
      reason: '参考区间的数值不许在破折号处被夹断成两行');
  });

  group('labRangeFractions(纯函数,与折线图同一个值域)', () {
    test('≥ 90 而实测 63:点在带子左外侧', () {
      final f = labRangeFractions(value: 63, refLow: 90);
      expect(f.bandTo, 1.0);
      expect(f.markerAt, lessThan(f.bandFrom));
    });
    test('≤ 1.7 而实测 1.95:点在带子右外侧', () {
      final f = labRangeFractions(value: 1.95, refHigh: 1.7);
      expect(f.bandFrom, 0.0);
      expect(f.markerAt, greaterThan(f.bandTo));
    });
    test('70 落在 60–100 里:点在带子里', () {
      final f = labRangeFractions(value: 70, refLow: 60, refHigh: 100);
      expect(f.markerAt, inExclusiveRange(f.bandFrom, f.bandTo));
    });
    test('全部在 [0,1] 里', () {
      final f = labRangeFractions(value: 1000, refLow: 0, refHigh: 1);
      for (final v in [f.bandFrom, f.bandTo, f.markerAt]) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
    test('refLow > refHigh(参考区间倒挂,单据印刷错误):不画负宽,bandTo ≥ bandFrom', () {
      final f = labRangeFractions(value: 5, refLow: 10, refHigh: 2);
      expect(f.bandTo, greaterThanOrEqualTo(f.bandFrom));
    });
  });
}
