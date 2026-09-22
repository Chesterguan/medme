// 「病历」首页成员一行下面那两颗药丸、「还没核对」横幅、月份标题(`s1`)。
//
// 整屏 `ArchiveScreen` 在字段初始化处碰 FFI,`flutter test` 不带原生库,**不可
// pump 整屏** —— 这里 pump 的是从那一屏里拆出来的三个纯 widget。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320 * 3, 568 * 3); // iPhone SE
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('两颗药丸:等宽、都点得动', (tester) async {
    useNarrowPhone(tester);
    var add = false, doc = false;
    await tester.pumpWidget(
      wrap(HomeTiles(onAdd: () => add = true, onForDoctor: () => doc = true)),
    );
    expect(find.widgetWithText(MedPrimaryButton, '添加'), findsOneWidget);
    expect(find.widgetWithText(MedSecondaryButton, '给医生看'), findsOneWidget);
    // 等宽 —— 它们是一对并列的动作,不是一主一次。
    final w1 = tester.getSize(find.byType(MedPrimaryButton)).width;
    final w2 = tester.getSize(find.byType(MedSecondaryButton)).width;
    expect((w1 - w2).abs() < 1.0, isTrue, reason: '两颗必须等宽');
    await tester.tap(find.byType(MedPrimaryButton));
    await tester.tap(find.byType(MedSecondaryButton));
    expect([add, doc], [true, true]);
  });

  testWidgets('SE + 2× 字号:「给医生看」四个字不裁 —— 它是那一页唯一的入口', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const HomeTiles(), textScale: 2.0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('给医生看'), findsOneWidget);
  });

  testWidgets('还没核对横幅:逐字两句,0 份时整条不画', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const PendingReviewBanner(count: 2)));
    expect(find.text('2 份还没核对'), findsOneWidget);
    expect(find.text('扫描件,识别出的字有几处不确定'), findsOneWidget);
    // 旧写法的痕迹:每行一个「待确认 · 点开核对并确认」,一处都不许留。
    expect(find.textContaining('待确认'), findsNothing);

    await tester.pumpWidget(wrap(const PendingReviewBanner(count: 0)));
    expect(find.textContaining('还没核对'), findsNothing, reason: '没有要核对的就整条不画');
  });

  testWidgets('还没核对横幅:给了 onTap 才画 ›,点一下能碰到回调', (tester) async {
    useNarrowPhone(tester);
    var tapped = false;
    await tester.pumpWidget(
      wrap(PendingReviewBanner(count: 2, onTap: () => tapped = true)),
    );
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.byType(PendingReviewBanner));
    expect(tapped, isTrue, reason: '档案屏用它把还没核对那一段滚动进可视区域');

    // 没有去处就别给箭头——不画一个点不动的 ›(archive_screen.dart 里
    // PendingReviewBanner 类文档的约定)。
    await tester.pumpWidget(wrap(const PendingReviewBanner(count: 2)));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  test('monthLabel:按月分组的那一行字;没日期的不许归进某个月', () {
    expect(monthLabel('2026-08-12'), '2026 年 8 月');
    // 不补零 —— `s1` 写的是「2026 年 7 月」。
    expect(monthLabel('2026-07-20'), '2026 年 7 月');
    // 没识别到日期的那几份自成一段:塞进上一个月就是拿一个我们并不知道的
    // 日期说话(`fmtDate` 对空/坏日期返回 '' 是同一条约定)。
    expect(monthLabel(null), '没有日期');
    expect(monthLabel(''), '没有日期');
    expect(monthLabel('不是日期'), '没有日期');
  });
}
