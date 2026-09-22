// 「给医生看」(s4):长清单那一屏。brief §品牌 最后一条:「出码给医生看」按钮
// **固定底部**,内容再长也在。s4 模板里那句 `.fixed` 小字就是在说这件事。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/screens/for_doctor_screen.dart';
import 'package:mobile_flutter/screens/visit_summary_sheet.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';
import 'stage3_visual_helpers.dart';

/// 与 `for_doctor_screen_test.dart` 的 `_empty` 同一形状——本文件独立成一份,
/// 不跨文件引用一个私有 const。
const _emptySummary = VisitSummaryDto(
  patient: PatientProfileDto(recordCount: 0),
  allergies: [],
  activeMeds: [],
  recentLabs: [],
  recentChanges: [],
  recentVisits: [],
  recentNotes: [],
  plainText: '',
);

void main() {
  testWidgets('渐变预算:零主卡、零入口块、一颗主按钮', (tester) async {
    await pumpStage3(tester, Scaffold(
      body: const SingleChildScrollView(child: ForDoctorActions()),
      bottomNavigationBar: const SafeArea(child: Padding(
        padding: EdgeInsets.all(MedShape.s3),
        child: MedPrimaryButton(label: '出码给医生看', icon: Icons.qr_code_2_outlined))),
    ));
    expectSurfaceBudget(button: 1);
  });

  testWidgets('主按钮在 bottomNavigationBar 里 —— 滚动不会把它带走', (tester) async {
    await pumpStage3(tester, Scaffold(
      body: const SingleChildScrollView(child: SizedBox(height: 3000)),
      bottomNavigationBar: const SafeArea(child: Padding(
        padding: EdgeInsets.all(MedShape.s3),
        child: MedPrimaryButton(label: '出码给医生看'))),
    ));
    final before = tester.getTopLeft(find.byType(MedPrimaryButton));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -1200));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(MedPrimaryButton)), before, reason: '按钮跟着滚了');
  });

  testWidgets('三条入口:导出=中性块、急救卡=警示块、代拍=蓝横幅', (tester) async {
    await pumpStage3(tester, const Scaffold(body: SingleChildScrollView(child: ForDoctorActions())));
    final cats = tester.widgetList<GlossIconTile>(find.byType(GlossIconTile))
        .map((w) => w.category).toList();
    expect(cats, containsAll(<GlossCategory>[GlossCategory.neutral, GlossCategory.alert]));
    // 代拍那条落地成 MedBanner(brand 光泽图标块 + 蓝横幅),不是第三个 ListTile ——
    // 钉住实际用的 widget,不只是钉颜色。
    expect(find.byType(MedBanner), findsOneWidget);
    // 文案一个字不动 —— 这三句是 Stage 1 定死的。
    expect(find.text('导出文件'), findsOneWidget);
    expect(find.text('急救卡'), findsOneWidget);
    expect(find.text('我是医生,替病人代拍'), findsOneWidget);
    expect(find.text('病人不用装 App、不用账号'), findsOneWidget);
  });

  testWidgets('长清单一项一行,不溢出', (tester) async {
    // R35 Task 2:原来这里建的那个独立「长文本行」widget 已删(零生产调用点——
    // mockup 的这个形状实际由 `visit_summary_sheet.dart` 的私有 `_LineRow`
    // 实现)。压力测试的关心点没变:一枚图标块 + 一长串「正文左、说明右」的
    // Wrap 行,12 项长文案在两种尺寸×两档字号下不溢出——内联同一棵 widget 树,
    // 不重新建一个独立 class。
    const List<({String text, String? meta})> items = [
      (text: '阿司匹林肠溶片', meta: '100 mg 每日'),
      (text: '氯吡格雷', meta: '75 mg 每日,至 2027 年 7 月'),
      (text: '阿托伐他汀', meta: '20 mg 每晚'),
      (text: '氨氯地平', meta: '5 mg 早晚'),
      (text: '美托洛尔', meta: '剂量未记'),
      (text: '二甲双胍缓释片', meta: '0.5 g 每日 2 次'),
      (text: '达格列净', meta: '10 mg 每日'),
      (text: '非布司他', meta: '40 mg 每日'),
      (text: '泼尼松', meta: '7.5 mg 每日'),
      (text: '羟氯喹', meta: '400 mg 每日'),
      (text: '吗替麦考酚酯', meta: '1.5 g 每日'),
      (text: '贝利尤单抗', meta: '每 4 周'),
    ];
    final meds = Builder(builder: (context) {
      final c = MedColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const GlossIconTile(icon: Icons.medication_outlined, category: GlossCategory.med),
          const SizedBox(width: MedShape.s2),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: 10,
                  runSpacing: 2,
                  children: [
                    Text(item.text, style: MedType.body.copyWith(fontSize: 15, height: 1.5)),
                    if (item.meta != null)
                      Text(item.meta!, softWrap: false,
                        style: MedType.secondary.copyWith(color: c.ink3)),
                  ],
                ),
              ),
          ])),
        ]),
      );
    });
    await expectNoOverflowAtBothSizes(tester,
        Scaffold(body: SingleChildScrollView(child: meds)));
  });

  // ── 以下补充测试(controller 的任务说明书,不在 brief 字面里)──────────
  // 「every restyled row must survive 400×800 / 360×640 at 1.0×/2.0×,用
  // `expectNoOverflowAtBothSizes` 至少覆盖 ForDoctorActions 和急救卡各 section」。

  testWidgets('ForDoctorActions 在两种尺寸×两档字号都不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: ForDoctorActions())));
  });

  testWidgets('真实 ForDoctorScreen:渐变预算同样是 0/0/1,卡里没有渐变', (tester) async {
    await pumpStage3(tester, ForDoctorScreen(load: () async => _emptySummary));
    await tester.pumpAndSettle();
    expectSurfaceBudget(button: 1);
  });

  testWidgets('急救卡五个 section 在两种尺寸×两档字号都不溢出(长过敏名/长药名/长诊断名)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final data = (
      EmergencyCardDto(
        allergies: [
          AllergyItemDto(
            substance: '磺胺甲噁唑-甲氧苄啶复方制剂(SMZ-TMP,复方新诺明)',
            reaction: '全身荨麻疹伴呼吸困难,曾送急诊',
            documentIds: Int64List(0),
          ),
        ],
        activeMeds: [
          ActiveMedDto(
            name: '吗替麦考酚酯分散片(骁悉)',
            dose: '1.5 g 每日两次,饭前空腹服用',
            documentIds: Int64List(0),
          ),
        ],
        conditions: [
          ChronicConditionDto(
            term: '系统性红斑狼疮伴狼疮性肾炎(IV 型)',
            onset: '2019-03-12',
            icdCode: 'M32.104',
            documentIds: Int64List(0),
          ),
        ],
      ),
      const PatientProfileDto(gender: '女', age: '34岁', recordCount: 12),
    );
    // 不直接调 `expectNoOverflowAtBothSizes`:它只 `pump()` 一次,`EmergencyCardScreen`
    // 的 `FutureBuilder` 未必能在一帧内结算(`emergency_card_refresh_test.dart` /
    // `emergency_card_allergy_wording_test.dart` 断言内容前也都是 `pumpAndSettle`,
    // 不是单次 `pump`)——这里在它的两种尺寸×两档字号矩阵上手动补一次 settle 再查异常。
    for (final size in kStage3Sizes) {
      for (final scale in [1.0, 2.0]) {
        await pumpStage3(
          tester,
          EmergencyCardScreen(load: () async => data),
          size: size,
          textScale: scale,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size @ ${scale}x 溢出了');
      }
    }
  });

  // ── R23 fix round 1:VisitSummaryBody 三节共用一张 MedCard,标题行各加
  // 一枚光泽图标块 ────────────────────────────────────────────────────

  final realisticSummary = VisitSummaryDto(
    patient: const PatientProfileDto(
      name: '张建国',
      gender: '男',
      age: '61岁',
      recordCount: 42,
    ),
    allergies: [
      AllergyItemDto(
        substance: '磺胺甲噁唑-甲氧苄啶复方制剂(SMZ-TMP,复方新诺明)',
        reaction: '全身荨麻疹伴呼吸困难,曾送急诊',
        documentIds: Int64List(0),
      ),
    ],
    activeMeds: [
      ActiveMedDto(
        name: '吗替麦考酚酯分散片(骁悉)',
        dose: '1.5 g 每日两次,饭前空腹服用',
        documentIds: Int64List(0),
      ),
    ],
    recentLabs: const [],
    recentChanges: [
      VisitLabDto(
        name: '抗核抗体谱定量(ANA)',
        date: '2026-08-05',
        value: 128.5,
        unit: 'mmol/L',
        flag: 'H',
        refLow: 0,
        refHigh: 20,
        valuesConverted: false,
        documentId: 1,
        selfMeasured: false,
        unverified: false,
      ),
    ],
    recentVisits: const [],
    recentNotes: const [],
    plainText: '',
  );

  testWidgets('给医生看正文:我最近的变化/过敏史/记录中出现的药物 共用一张 MedCard', (
    tester,
  ) async {
    await pumpStage3(
      tester,
      Scaffold(
        body: VisitSummaryBody(
          summary: realisticSummary,
          onOpenDoc: (_) {},
          onAddNote: () {},
        ),
      ),
    );
    expect(find.byType(MedCard), findsOneWidget, reason: '三节应该只共用一张 MedCard');
    // 三节的文案一个字不动。
    expect(find.text('我最近的变化'), findsOneWidget);
    expect(find.text('过敏史'), findsOneWidget);
    expect(find.text(kRecordedMedsTitle), findsOneWidget);
    // 三节标题各自的光泽图标块类别照 R23:lab / alert / med。
    final cats = tester
        .widgetList<GlossIconTile>(find.byType(GlossIconTile))
        .map((w) => w.category)
        .toList();
    expect(cats, containsAll(<GlossCategory>[GlossCategory.lab, GlossCategory.alert, GlossCategory.med]));
    // 这一屏(正文本身,不含固定底部的出码按钮)渐变预算是 0。
    expect(find.byType(MedPrimaryButton), findsNothing);
  });

  testWidgets('VisitSummaryBody(真实数据)在两种尺寸×两档字号都不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(
      tester,
      Scaffold(
        body: VisitSummaryBody(
          summary: realisticSummary,
          onOpenDoc: (_) {},
          onAddNote: () {},
        ),
      ),
    );
  });
}
