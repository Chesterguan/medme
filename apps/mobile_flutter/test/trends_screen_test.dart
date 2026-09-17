// 「趋势」tab 顶部四块:化验快照 / 最近就诊 / 病程档案入口 / 记录入口。
// 整屏**不注入 `load` 时**不可 pump —— `TrendsScreen` 在字段初始化那一刻就调
// `viewTrends()` 与 `viewVisitSummary()`(FFI),`flutter test` 不带原生库会
// 直接崩(与 `test/overview_quick_actions_test.dart` 同一条限制)。这四块都是
// 纯 widget;整屏顺序那一条靠注入 `load` 绕开 FFI(与 `ForDoctorScreen` 同款)。
//
// 前两块是从 `overview_screen.dart` 搬过来的(概览在 Task 9 整屏解散)。**搬家
// 必须先于拆房**:这个文件的存在就是证明搬到了。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart' show PatientProfileDto;
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  // ── 从概览搬过来的两块(Task 9 会删掉原屋) ────────────────────────────────
  group('化验快照 / 最近就诊 已经搬进「趋势」', () {
    final labs = [
      VisitLabDto(
        name: '肌酐',
        date: '2025-11-05',
        value: 96,
        unit: 'umol/L',
        flag: 'H',
        valuesConverted: false,
        documentId: 7,
        selfMeasured: false,
        unverified: false,
      ),
    ];
    final visits = [
      VisitRecordDto(
        title: '化验 · 协和',
        kind: 'lab',
        date: '2025-11-05',
        documentIds: Int64List.fromList([7]),
      ),
    ];

    testWidgets('化验快照:数值与标记照原样显示,点得开那一份', (tester) async {
      useNarrowPhone(tester);
      var opened = 0;
      await tester.pumpWidget(
        wrap(KeyLabsSnapshot(labs: labs, onOpenDoc: (id) => opened = id)),
      );
      expect(find.text('肌酐'), findsOneWidget);
      expect(find.text('偏高'), findsOneWidget, reason: '化验单说的,照搬');
      await tester.tap(find.text('肌酐'));
      expect(opened, 7);
    });

    testWidgets('最近就诊:标题、份数、点进一份', (tester) async {
      useNarrowPhone(tester);
      var opened = 0;
      await tester.pumpWidget(
        wrap(
          RecentVisitsCard(
            visits: visits,
            total: 12,
            onOpenDoc: (id) => opened = id,
          ),
        ),
      );
      expect(find.text('化验 · 协和'), findsOneWidget);
      expect(find.text('全部 12 份'), findsOneWidget);
      await tester.tap(find.text('化验 · 协和'));
      expect(opened, 7);
    });

    test('标题里已有日期就不在右边重复一遍(原样搬来的纯函数)', () {
      expect(
        visitCardShowsDate(title: '化验 · 协和 · 2025-11-05', date: '2025-11-05'),
        isFalse,
      );
      expect(visitCardShowsDate(title: '化验 · 协和', date: '2025-11-05'), isTrue);
      expect(visitCardShowsDate(title: '化验 · 协和', date: ''), isFalse);
    });

    testWidgets('两块空态都不报错、不撒谎', (tester) async {
      useNarrowPhone(tester);
      await tester.pumpWidget(
        wrap(
          Column(
            children: [
              KeyLabsSnapshot(labs: const [], onOpenDoc: (_) {}),
              RecentVisitsCard(visits: const [], total: 0, onOpenDoc: (_) {}),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('一切正常'), findsNothing, reason: '没数据不等于正常');
    });
  });

  testWidgets('看懂横幅:占位,不假装已经有内容', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const UnderstandBanner()));
    expect(find.text('看懂'), findsOneWidget);
    expect(find.textContaining('还在做'), findsOneWidget);
    // s2 里这条横幅引用的是某份报告「提示」一栏的原文 —— 没有真内容时,
    // 一个像结论的字都不许摆出来。
    for (final claim in ['提示:', '建议', '考虑']) {
      expect(find.textContaining(claim), findsNothing);
    }
  });

  testWidgets('病程档案入口:说清楚以后放什么,不假装已经有了', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const DiseaseFileEntryCard()));
    expect(find.text('病程档案'), findsOneWidget);
    // 不许宣称已经能用 —— 内容由另一条线做。
    for (final claim in ['活动度', '该查没查', '查看详情']) {
      expect(find.textContaining(claim), findsNothing);
    }
    expect(find.textContaining('还在做'), findsOneWidget);
  });

  testWidgets('记录一下:点得动', (tester) async {
    useNarrowPhone(tester);
    var tapped = false;
    await tester.pumpWidget(wrap(RecordEntryCard(onTap: () => tapped = true)));
    expect(find.text('记录一下'), findsOneWidget);
    await tester.tap(find.text('记录一下'));
    expect(tapped, isTrue);
  });

  testWidgets('2× 字号不溢出', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(
      wrap(
        const Column(children: [DiseaseFileEntryCard(), RecordEntryCard()]),
        textScale: 2.0,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // ── 整屏:s2 的顺序是固定的 ─────────────────────────────────────────────────
  testWidgets('整屏按 s2 自上而下摆;病程档案没内容时不占位', (tester) async {
    // 注入 `load` 就一次 FFI 都不碰,整屏 pump 得起来(与 `ForDoctorScreen.load`
    // 同一手法)。视口拉高是为了让 `ListView` 一次把六块都布局出来,
    // 好按 y 坐标比顺序 —— 顺序只能整屏验,逐块 pump 验不到。
    tester.view.physicalSize = const Size(360 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final summary = VisitSummaryDto(
      patient: const PatientProfileDto(recordCount: 12),
      allergies: const [],
      activeMeds: const [],
      recentLabs: [
        VisitLabDto(
          name: '肌酐',
          date: '2025-11-05',
          value: 96,
          unit: 'umol/L',
          flag: 'H',
          valuesConverted: false,
          documentId: 7,
          selfMeasured: false,
          unverified: false,
        ),
      ],
      recentChanges: const [],
      recentVisits: [
        VisitRecordDto(
          title: '化验 · 协和',
          kind: 'lab',
          date: '2025-11-05',
          documentIds: Int64List.fromList([7]),
        ),
      ],
      recentNotes: const [],
      plainText: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: MedMe.theme(),
        home: TrendsScreen(
          load: () async => (const <TrendSeriesDto>[], const <String>[], summary),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double dy(String text) => tester.getTopLeft(find.text(text)).dy;
    // ② 关键化验 → ③ 各行 → ④ 看懂 → ⑤ 最近就诊 → ⑥ 记录一下。
    expect(dy('关键化验'), lessThan(dy('肌酐')));
    expect(dy('肌酐'), lessThan(dy('看懂')));
    expect(dy('看懂'), lessThan(dy('最近就诊')));
    expect(dy('最近就诊'), lessThan(dy('记录一下')));
    // ① 病程档案:内容由另一条线做。**没有档案就不摆入口** —— 一个点了只会
    // 说「还在做」的条,不该占住这一屏的第一眼。
    expect(find.text('病程档案'), findsNothing);
    // 顶栏只有「趋势」两个字,不加成员 chip(s2)。
    expect(find.text('趋势'), findsOneWidget);
  });
}
