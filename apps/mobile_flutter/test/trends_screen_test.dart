// 「趋势」tab 顶部三块:化验快照 / 最近就诊 / 病程档案入口。
// 整屏**不注入 `load` 时**不可 pump —— `TrendsScreen` 在字段初始化那一刻就调
// `viewTrends()` 与 `viewVisitSummary()`(FFI),`flutter test` 不带原生库会
// 直接崩(与 `test/mobile_ia_test.dart` 顶部注释同一条限制)。这三块都是
// 纯 widget;整屏顺序那一条靠注入 `load` 绕开 FFI(与 `ForDoctorScreen` 同款)。
//
// 前两块是从概览屏搬过来的(概览已在 Task 9 整屏解散)。**搬家必须先于拆房**:
// 这个文件的存在就是证明搬到了。「记录入口」原来是第四块(`RecordEntryCard`),
// Task 5 挪进了「病历」tab 的「添加」四选一,这个文件不再测它——见
// `test/sheets_visual_test.dart`。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart' show PatientProfileDto;
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// 病程档案那一块的假口子:这一屏的测试不关心它的内容,只要它别去碰 FFI 与网络
/// (卡片自己的三态由 `test/disease_profile_card_test.dart` 验)。
DiseaseProfileSource noProfilePackage() => DiseaseProfileSource(
  installed: () async => const [],
  view: (id) async => '{}',
  record: (kind, pkg, at) async {},
  refresh: () async {},
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
          profileSource: noProfilePackage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double dy(String text) => tester.getTopLeft(find.text(text)).dy;
    // ① 病程档案 → ② 关键化验 → ③ 各行 → ④ 最近就诊。「记录一下」Task 5 挪去
    //   了「添加」四选一,这一屏不再有它(顺序断言少了原来的 ⑤)。
    expect(dy('病程档案'), lessThan(dy('关键化验')));
    expect(dy('关键化验'), lessThan(dy('肌酐')));
    expect(dy('肌酐'), lessThan(dy('最近就诊')));
    // ① 病程档案入口**恒在**(mockup `s2` 的第一块)。这一屏的测试里一个病种包都
    // 没装上,所以它说的是「还没准备好」——「装上了 / 开启了」那两态在
    // `test/disease_profile_card_test.dart` 里验。
    expect(find.textContaining('还没准备好'), findsOneWidget);
    // 顶栏只有「趋势」两个字,不加成员 chip(s2)。
    expect(find.text('趋势'), findsOneWidget);
  });
}
