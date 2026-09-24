// 「病历」首页成员一行下面那两颗药丸、「还没核对」横幅、月份标题(`s1`)。
//
// 整屏 `ArchiveScreen` 在字段初始化处碰 FFI,`flutter test` 不带原生库,**不可
// pump 整屏** —— 这里 pump 的是从那一屏里拆出来的三个纯 widget。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

/// 最小可用的独立文档时间线项,只填 `byMonth` 分段要看的 `docDate`——同一份
/// `_doc` 写法见 `test/doc_display_title_test.dart`。
TimelineGroupDto _doc(String? docDate) => TimelineGroupDto.document(
  doc: DocumentSummaryDto(id: 1, docType: 'lab_report', docDate: docDate, pageCount: 1),
);

/// 最小可用的自测周,只填 `byMonth` 分段要看的 `weekStart`/`weekEnd`。
TimelineGroupDto _selfWeek(String weekStart, String weekEnd) => TimelineGroupDto.selfWeek(
  weekStart: weekStart,
  weekEnd: weekEnd,
  docs: const [],
  summary: const [],
);

/// 开关病程档案写下的动作日志:`doc_type == 'profile_event'`,日期 = 记的那天。
TimelineGroupDto _profileEvent(String docDate) => TimelineGroupDto.document(
  doc: DocumentSummaryDto(id: 9, docType: 'profile_event', docDate: docDate, pageCount: 1),
);

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

  test('byMonth:空列表 → 空', () {
    expect(byMonth([]), isEmpty);
  });

  test('byMonth:一条 → 一段一条', () {
    final g = _doc('2026-08-12');
    expect(byMonth([g]), [[g]]);
  });

  test('byMonth:两条同月 → 一段两条', () {
    final a = _doc('2026-08-12'), b = _doc('2026-08-01');
    expect(byMonth([a, b]), [[a, b]]);
  });

  test('byMonth:两条跨月 → 两段', () {
    final a = _doc('2026-08-12'), b = _doc('2026-07-20');
    expect(byMonth([a, b]), [[a], [b]]);
  });

  test('byMonth:自测周按 weekStart 分月——跨月的周归周一所在月,不归 weekEnd 那个月', () {
    // 周一(weekStart)7 月 27 日、周日(weekEnd)已经跨到 8 月 2 日。
    final week = _selfWeek('2026-07-27', '2026-08-02');
    final aug = _doc('2026-08-12');
    // 若误按 weekEnd 分月,这条周会跟 8 月的 `aug` 并成一段;归 weekStart 才各自一段。
    expect(byMonth([aug, week]), [[aug], [week]]);
  });

  test('timelineGroups:动作日志(profile_event)不进时间线,别的原样保留', () {
    final event = _profileEvent('2026-09-23');
    final lab = _doc('2026-05-04');
    final week = _selfWeek('2026-04-27', '2026-05-03');
    expect(timelineGroups([event, lab, week]), [lab, week]);
    expect(timelineGroups([]), isEmpty);
  });

  test('recentVisitDate:跳过自测周,取最新一条非自测周的日期', () {
    final week = _selfWeek('2026-09-21', '2026-09-27');
    final lab = _doc('2026-09-10');
    expect(recentVisitDate([week, lab]), '2026-09-10');
  });

  test('recentVisitDate:只有自测周、或空列表 → null(成员头显示「暂无」)', () {
    expect(recentVisitDate([_selfWeek('2026-09-21', '2026-09-27')]), isNull);
    expect(recentVisitDate([]), isNull);
  });

  test('F-B 回归:开启档案当天,「最近就诊」不会变成今天', () {
    final groups = timelineGroups([_profileEvent('2026-09-23'), _doc('2026-09-10')]);
    expect(recentVisitDate(groups), '2026-09-10');
  });
}
