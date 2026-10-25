// 「病历」首页时间线分档(spec 2026-10-21-timeline-tiers-design.md 稿 B):住院/急诊
// 每次一张带左色条的卡、门诊整月一张「门诊 N 次」折叠卡、顶上一排三档 chip。
//
// 合成数据(Doe, Jane 那种口径,不是真人):1 次住院(2026-03-02 → 03-08,3 份)、
// 1 次急诊、4 次门诊跨两个月、1 份独立笔记。[ArchiveTimeline] 只吃 DTO 列表,不碰
// FFI,所以这里能直接 pump。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

const _uf = 'UF Health Shands';

DocumentSummaryDto _doc(int id, String type, String date, {String? title}) =>
    DocumentSummaryDto(id: id, docType: type, docDate: '${date}T00:00:00+00:00', pageCount: 1, title: title);

TimelineGroupDto _enc(int id, String kind, String start, List<DocumentSummaryDto> docs, {String? end}) =>
    TimelineGroupDto.encounter(
      encounter: EncounterSummaryDto(
        id: id,
        kind: kind,
        provider: _uf,
        startDate: '${start}T00:00:00+00:00',
        endDate: end == null ? null : '${end}T00:00:00+00:00',
        transferred: false,
        docCount: docs.length,
      ),
      docs: docs,
    );

final _inpatient = _enc(1, 'inpatient', '2026-03-02', [
  _doc(1, 'discharge_summary', '2026-03-08'),
  _doc(2, 'lab_report', '2026-03-03'),
  _doc(3, 'clinical_note', '2026-03-02'),
], end: '2026-03-08');
final _emergency = _enc(2, 'emergency', '2026-03-15', [_doc(4, 'clinical_note', '2026-03-15')]);
final _outpatients = [
  _enc(3, 'outpatient', '2026-03-28', [_doc(5, 'lab_report', '2026-03-28')]),
  _enc(4, 'outpatient', '2026-03-21', [_doc(6, 'clinical_note', '2026-03-21')]),
  _enc(5, 'outpatient', '2026-02-10', [_doc(7, 'lab_report', '2026-02-10')]),
  _enc(6, 'outpatient', '2026-02-03', [_doc(8, 'clinical_note', '2026-02-03')]),
];
final _note = TimelineGroupDto.document(doc: _doc(9, 'note', '2026-02-01', title: '头疼两天'));

/// 日期倒序,与 `loadArchive` 的顺序一致。
List<TimelineGroupDto> _groups({bool withEmergency = true}) => [
  _outpatients[0],
  _outpatients[1],
  if (withEmergency) _emergency,
  _inpatient,
  _outpatients[2],
  _outpatients[3],
  _note,
];

Widget _wrap(List<TimelineGroupDto> groups, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(MedShape.s3),
        children: [ArchiveTimeline(groups: groups, onOpenDoc: (_) {}, onDelete: (_, _) async {})],
      ),
    ),
  ),
);

void main() {
  _docTypeChipTests();
  testWidgets('默认:住院一眼可见并带「住院 6 天 · 3 份」,门诊折叠成「门诊 N 次」,点开才见各次', (tester) async {
    await tester.pumpWidget(_wrap(_groups()));
    expect(find.text('住院 · $_uf'), findsOneWidget);
    expect(find.text('2026-03-02 → 2026-03-08 · 住院 6 天 · 3 份'), findsOneWidget);
    expect(find.text('急诊 · $_uf'), findsOneWidget);
    expect(find.text('门诊 2 次'), findsNWidgets(2), reason: '3 月、2 月各两次');
    expect(find.text('门诊 · $_uf'), findsNothing, reason: '默认折叠');
    expect(find.text('头疼两天'), findsOneWidget, reason: '独立笔记在「全部」下照常列出');

    await tester.tap(find.text('门诊 2 次').first);
    await tester.pump();
    expect(find.text('门诊 · $_uf'), findsNWidgets(2), reason: '只展开点的那个月');
  });

  testWidgets('住院卡左侧是品牌色条,急诊卡是琥珀条', (tester) async {
    await tester.pumpWidget(_wrap(_groups()));
    Color barOf(String title) {
      final container = find.ancestor(of: find.text(title), matching: find.byType(Container)).evaluate()
          .map((e) => e.widget as Container)
          .firstWhere((w) => (w.decoration as BoxDecoration?)?.border is Border &&
              ((w.decoration as BoxDecoration).border as Border).left.width == 3);
      return ((container.decoration as BoxDecoration).border as Border).left.color;
    }
    expect(barOf('住院 · $_uf'), MedColors.light.seal);
    expect(barOf('急诊 · $_uf'), MedColors.light.high);
  });

  testWidgets('筛选 chip:住院只剩住院;门诊各月默认展开;再点一次回到全部', (tester) async {
    await tester.pumpWidget(_wrap(_groups()));
    expect(find.text('全部 6'), findsOneWidget);
    expect(find.text('住院 1'), findsOneWidget);
    expect(find.text('急诊 1'), findsOneWidget);
    expect(find.text('门诊 4'), findsOneWidget);

    await tester.tap(find.text('住院 1'));
    await tester.pump();
    expect(find.text('住院 · $_uf'), findsOneWidget);
    expect(find.text('急诊 · $_uf'), findsNothing);
    expect(find.text('门诊 2 次'), findsNothing);
    expect(find.text('头疼两天'), findsNothing, reason: '独立文档不属于任何一档');
    expect(find.text('2026 年 2 月'), findsNothing, reason: '没有住院的月份不画标题');

    await tester.tap(find.text('门诊 4'));
    await tester.pump();
    expect(find.text('门诊 · $_uf'), findsNWidgets(4), reason: '筛到门诊就全展开,不用再点');
    expect(find.text('住院 · $_uf'), findsNothing);

    await tester.tap(find.text('门诊 4'));
    await tester.pump();
    expect(find.text('住院 · $_uf'), findsOneWidget);
    expect(find.text('门诊 · $_uf'), findsNothing, reason: '回到全部后门诊重新折起');
  });

  testWidgets('急诊 0 次时没有「急诊」chip', (tester) async {
    await tester.pumpWidget(_wrap(_groups(withEmergency: false)));
    expect(find.text('全部 5'), findsOneWidget);
    expect(find.textContaining('急诊'), findsNothing);
  });

  test('inpatientSummary:同日出入院记 1 天,没有出院日只写份数', () {
    EncounterSummaryDto e(String? end) => EncounterSummaryDto(
      id: 1, kind: 'inpatient', startDate: '2026-03-02T00:00:00+00:00', endDate: end,
      transferred: false, docCount: 2);
    expect(inpatientSummary(e('2026-03-02T00:00:00+00:00'), 2), '2026-03-02 → 2026-03-02 · 住院 1 天 · 2 份');
    expect(inpatientSummary(e(null), 2), '住院 · 2 份');
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:全部展开态不溢出', (tester) async {
      // 宽 393(iPhone 14 Pro),高给足 —— 时间线在 ListView 里,行只会横向溢出,
      // 高度不像「添加病历」弹层那样有上限;高给足是为了让每张卡都真的建出来、
      // 点得到,不用在两个 Scrollable(chip 行 + 列表)之间 scrollUntilVisible。
      tester.view.physicalSize = const Size(393 * 3, 4000 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(_groups(), textScale: scale));
      expect(tester.takeException(), isNull);
      // 展开住院、急诊与两个月的门诊折叠卡,再把每次门诊的子文档也展开。
      for (final (label, f) in [
        ('住院', find.text('住院 · $_uf')),
        ('急诊', find.text('急诊 · $_uf')),
        ('3 月门诊', find.text('门诊 2 次').first),
        ('2 月门诊', find.text('门诊 2 次').last),
      ]) {
        await tester.tap(f);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '点开「$label」后');
      }
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('门诊 · $_uf').at(i));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '展开第 $i 次门诊后');
      }
      expect(find.text('门诊 2 次'), findsNWidgets(2));
    });
  }
}

// ─────────────── 2026-10-23:手术 / 影像 / 病理 三颗文档类型 chip(「进程」泳道并入) ───────────────

List<TimelineGroupDto> _groupsWithDocTypes() => [
  _enc(10, 'inpatient', '2026-05-02', [
    _doc(20, 'discharge_summary', '2026-05-08'),
    // 住院里的影像,文档自己没有机构名 → 行标题用就诊的。
    _doc(21, 'imaging_report', '2026-05-03', title: 'CT Chest'),
  ], end: '2026-05-08'),
  _outpatients[0],
  TimelineGroupDto.document(doc: _doc(22, 'pathology', '2026-04-01')),
];

void _docTypeChipTests() {
  testWidgets('chip:影像 1、病理 1,没有手术;选「影像」只列那一份且带医院名', (tester) async {
    await tester.pumpWidget(_wrap(_groupsWithDocTypes()));
    expect(find.text('影像 1'), findsOneWidget);
    expect(find.text('病理 1'), findsOneWidget);
    expect(find.text('手术 1'), findsNothing);
    await tester.tap(find.text('影像 1'));
    await tester.pumpAndSettle();
    final rows = find.descendant(of: find.byType(MedCard), matching: find.byType(Text));
    expect(find.descendant(of: find.byType(MedCard), matching: find.textContaining('门诊')), findsNothing);
    expect(find.descendant(of: find.byType(MedCard), matching: find.textContaining('住院')), findsNothing);
    expect(rows, findsAtLeast(1));
    // 行标题 = document.title(checkpoint 1 F5),医院名在副标。
    expect(find.text('CT Chest'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选「病理」:独立文档没有机构名 → 只写类型,不崩', (tester) async {
    await tester.pumpWidget(_wrap(_groupsWithDocTypes()));
    await tester.tap(find.text('病理 1'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(MedCard), matching: find.text('病理')), findsAtLeast(1));
    expect(find.descendant(of: find.byType(MedCard), matching: find.textContaining('影像')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('flattenByDocType / docTypeCounts 纯函数', () {
    final g = _groupsWithDocTypes();
    expect(docTypeCounts(g), {'surgery': 0, 'imaging_report': 1, 'pathology': 1});
    final flat = flattenByDocType(g, 'imaging_report');
    expect(flat.length, 1);
    final doc = (flat.single as TimelineGroupDto_Document).doc;
    expect(doc.provider, _uf);
    expect(doc.id, 21);
  });

  for (final scale in [1.0, 1.3, 1.6]) {
    testWidgets('393 宽 字号 $scale:七颗 chip + 平铺行不溢出', (tester) async {
      tester.view.physicalSize = const Size(393 * 3, 4000 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(_wrap([..._groupsWithDocTypes(), _emergency, TimelineGroupDto.document(doc: _doc(23, 'surgery', '2026-01-01'))], textScale: scale));
      // 七颗 chip 在 393 宽里横向滚动,「影像」在屏外:先把 chip 排拖过来再点。
      await tester.dragUntilVisible(find.text('影像 1'), find.byType(ListView).at(1), const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('影像 1'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
