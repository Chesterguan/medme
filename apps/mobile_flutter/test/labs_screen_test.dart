// 「化验」tab(修订 2 验收 2–4):按报告 / 按指标 / 指标折线页。合成数据。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/lab_detail_screen.dart';
import 'package:mobile_flutter/screens/labs_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';

final _today = DateTime(2026, 10, 22);

TrendSeriesDto _series(String name, String key, String? panel, List<(String, double, int)> pts, {double? lo, double? hi}) => TrendSeriesDto(
  name: name,
  analyteKey: key,
  panel: panel,
  unit: 'u',
  refLow: lo,
  refHigh: hi,
  valuesConverted: false,
  anyAbnormal: false,
  points: [for (final (d, v, id) in pts) TrendPointDto(date: d, value: v, unit: 'u', documentId: id, unverified: false)],
  selfMeasured: false,
);

List<TrendSeriesDto> _allSeries() => [
  _series('肌酐', 'creatinine', '肾功能', [('2025-01-01', 90, 1), ('2026-10-01', 112, 2)], lo: 44, hi: 133),
  _series('ALT', 'alt', '肝功能', [('2026-09-15', 30, 2)], lo: 0, hi: 40),
  _series('血红蛋白', 'hgb', '血常规', [('2026-09-15', 130, 2)]),
  _series('乳酸脱氢酶', 'ldh', null, [('2024-01-01', 200, 3)]),
];

List<LabReportDto> _reports() => [
  LabReportDto(
    documentId: 2,
    date: '2026-10-01',
    time: '08:15',
    panels: const ['肾功能', '血常规'],
    title: '肾功能、血常规',
    abnormalCount: 1,
    items: const [
      LabReportItemDto(name: '肌酐', analyteKey: 'creatinine', value: '1.4', unit: 'mg/dL', reference: '0.6-1.2', flag: 'H', unverified: false),
      LabReportItemDto(name: '血红蛋白', analyteKey: 'hgb', value: '13.5', unit: 'g/dL', reference: '13-17', flag: null, unverified: false),
      LabReportItemDto(name: 'HIV抗体', analyteKey: 'hiv_ab', value: 'Nonreactive', unit: null, reference: null, flag: null, unverified: false),
    ],
  ),
  LabReportDto(documentId: 1, date: '2025-01-01', time: null, panels: const ['肾功能'], title: '肾功能', abnormalCount: 0, items: const [
    LabReportItemDto(name: '肌酐', analyteKey: 'creatinine', value: '0.9', unit: 'mg/dL', reference: '0.6-1.2', flag: null, unverified: false),
  ]),
];

Widget _wrap(Widget child, {double scale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(size: const Size(393, 852), textScaler: TextScaler.linear(scale)),
    child: child,
  ),
);

Future<void> _pump(WidgetTester t, {double scale = 1.0}) async {
  t.view.physicalSize = const Size(393 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(_wrap(
    LabsScreen(key: UniqueKey(), today: _today, load: () async => (_reports(), _allSeries(), {'creatinine', 'alt'})),
    scale: scale,
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('按报告:一天一行,面板名 + 日期 · 时间 · 项数 + 异常徽标;区间外折进「更早的报告」;点开是表', (t) async {
    await _pump(t);
    expect(find.text('肾功能、血常规'), findsOneWidget);
    expect(find.text('2026-10-01 · 08:15 · 3 项'), findsOneWidget);
    expect(find.text('1 项异常'), findsOneWidget);
    expect(find.text('2025-01-01 · 1 项'), findsNothing, reason: '默认 1 年,2025 的单折起来');
    expect(find.text('更早的报告 · 1 份'), findsOneWidget);
    await t.tap(find.text('更早的报告 · 1 份'));
    await t.pumpAndSettle();
    expect(find.text('2025-01-01 · 1 项'), findsOneWidget);
    // 顶部区间切「全部」:没有「更早」折叠。
    await t.tap(find.byKey(const ValueKey('range:all')));
    await t.pumpAndSettle();
    expect(find.text('更早的报告 · 1 份'), findsNothing);
    expect(find.text('2025-01-01 · 1 项'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('range:oneYear')));
    await t.pumpAndSettle();
    await t.tap(find.text('2026-10-01 · 08:15 · 3 项'));
    await t.pumpAndSettle();
    expect(find.byType(LabReportScreen), findsOneWidget);
    expect(find.text('1.4 mg/dL↑'), findsOneWidget);
    expect(find.text('参考 0.6-1.2'), findsOneWidget);
    expect(find.text('Nonreactive'), findsOneWidget);
    expect(find.text('查看原件'), findsOneWidget);
    // 认得出的行点开 → 折线页。
    await t.tap(find.text('1.4 mg/dL↑'));
    await t.pumpAndSettle();
    expect(find.byType(LabDetailScreen), findsOneWidget);
    expect(find.byType(LabLineChart), findsOneWidget);
  });

  testWidgets('按指标:关键 / 其他(折叠)/ 更早(折叠)三层;chip;只看异常;搜索;每行有迷你折线', (t) async {
    await _pump(t);
    await t.tap(find.text('按指标'));
    await t.pumpAndSettle();
    expect(find.text('全部 4'), findsOneWidget);
    expect(find.text('肝肾 2'), findsOneWidget);
    expect(find.text('其他 1'), findsOneWidget);
    expect(find.text('关键指标 · 2'), findsOneWidget);
    expect(find.byType(LabTrendRow), findsNWidgets(2), reason: '关键指标 2 项展开;其他 / 更早折着');
    expect(find.descendant(of: find.byType(LabTrendRow), matching: find.byType(CustomPaint)), findsAtLeast(2));
    expect(find.text('其他指标 · 还有 1 项'), findsOneWidget);
    expect(find.text('更早的 1 项(超过1 年没有结果)'), findsOneWidget);
    await t.tap(find.text('其他指标 · 还有 1 项'));
    await t.pumpAndSettle();
    expect(find.text('血红蛋白'), findsOneWidget);
    // 只看异常:合成数据没有 flag → 全空。
    await t.tap(find.byType(Switch).first);
    await t.pumpAndSettle();
    expect(find.text('没有偏高 / 偏低的指标。'), findsOneWidget);
    await t.tap(find.byType(Switch).first);
    await t.pumpAndSettle();
    await t.tap(find.text('肝肾 2'));
    await t.pumpAndSettle();
    expect(find.byType(LabTrendRow), findsNWidgets(2));
    expect(find.text('肌酐'), findsOneWidget);
    expect(find.text('ALT'), findsOneWidget);
    expect(find.text('其他指标 · 还有 1 项'), findsNothing);
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '肌酐');
    await t.pumpAndSettle();
    expect(find.byType(LabTrendRow), findsOneWidget);
  });

  testWidgets('指标折线页:默认 1 年(四档可切)、高 ≥120 的折线、参考带说明、切「全部」后每个点可点回原件', (t) async {
    final opened = <int>[];
    await t.pumpWidget(_wrap(LabDetailScreen(series: _allSeries().first, onOpenDoc: opened.add)));
    await t.pumpAndSettle();
    expect(find.text('半年'), findsOneWidget);
    final chart = t.widget<LabLineChart>(find.byType(LabLineChart));
    expect(chart.height, greaterThanOrEqualTo(120));
    expect(find.text('参考范围 44–133(灰带)'), findsOneWidget);
    // 默认 1 年:2025-01-01 那次不在范围里。
    expect(find.text('2025-01-01'), findsNothing);
    expect(find.text('1 次'), findsOneWidget);
    await t.tap(find.text('全部'));
    await t.pumpAndSettle();
    expect(find.text('2025-01-01'), findsOneWidget);
    await t.tap(find.text('2025-01-01'));
    expect(opened, [1]);
    await t.tap(find.text('2026-10-01'));
    expect(opened, [1, 2]);
  });

  testWidgets('ⓘ 按钮弹出参考区间的出处', (t) async {
    await _pump(t);
    await t.tap(find.byIcon(Icons.info_outline));
    await t.pumpAndSettle();
    expect(find.text('参考区间的出处'), findsOneWidget);
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:两种视图与报告页不溢出', (t) async {
      await _pump(t, scale: scale);
      expect(t.takeException(), isNull);
      await t.tap(find.text('按指标'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('按报告'));
      await t.pumpAndSettle();
      await t.tap(find.text('2026-10-01 · 08:15 · 3 项'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }

  test('MedCard 还是那张卡(占位,防止导入被当未用)', () {
    expect(MedCard, isNotNull);
  });
}
