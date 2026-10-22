// 真机回报(2026-10-21,675 份真实文档、11666 条化验):「关键化验」那排 chip
// 点了切不动。模拟器上 17 条序列就能复现:chip 选中态切了、往下一屏半的折线卡也
// 筛了,**可 chip 正下方那张「关键化验」快照卡(Rust 封顶 8 行,不认 chip)一动不动**
// —— 用户眼里就是没反应。修法:选了大类或在搜索时,快照卡让位,chip 正下方直接
// 就是筛出来的那批卡。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart' show PatientProfileDto;
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

const _catalog = ['血常规', '血糖', '电解质'];

TrendSeriesDto _series(int i, String? panel) => TrendSeriesDto(
  analyteKey: 'k$i',
  name: '指标$i',
  unit: 'u',
  points: [
    for (var d = 0; d < 40; d++)
      TrendPointDto(
        date: '2024-${(d % 12 + 1).toString().padLeft(2, '0')}-${(d % 28 + 1).toString().padLeft(2, '0')}',
        value: 1.0 * d,
        unit: 'u',
        flag: d.isEven ? 'H' : null,
        documentId: 1,
        unverified: false,
      ),
  ],
  refLow: 0,
  refHigh: 10,
  valuesConverted: false,
  selfMeasured: false,
  anyAbnormal: true,
  panel: panel,
);

/// 300 条序列:三个大类各 90,「其他」30。
List<TrendSeriesDto> _big() => [
  for (var i = 0; i < 300; i++)
    _series(i, i < 270 ? _catalog[i % 3] : null),
];

DiseaseProfileSource _noPackage() => DiseaseProfileSource(
  installed: () async => const [],
  view: (id) async => '{}',
  record: (kind, pkg, at) async {},
  refresh: () async {},
);

final _summary = VisitSummaryDto(
  patient: const PatientProfileDto(recordCount: 0),
  allergies: const [],
  activeMeds: const [],
  // 快照卡那一行:名字刻意不与任何序列重名,好单独找。
  recentLabs: const [
    VisitLabDto(
      name: '快照项目',
      date: '2024-05-06',
      value: 1,
      valuesConverted: false,
      documentId: 1,
      selfMeasured: false,
      unverified: false,
    ),
  ],
  recentChanges: const [],
  recentVisits: const [],
  recentNotes: const [],
  plainText: '',
);

void main() {
  testWidgets('几百条序列下点「血常规」chip:选中态切换、列表只剩该大类', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MedMe.theme(),
        home: TrendsScreen(
          load: () async => (_big(), _catalog, _summary),
          profileSource: _noPackage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('全部 300'), findsOneWidget);
    expect(find.text('血常规 90'), findsOneWidget);
    expect(find.text('快照项目'), findsOneWidget, reason: '「全部」下快照卡在');

    await tester.tap(find.text('血常规 90'));
    await tester.pumpAndSettle();

    final chip = tester.widget<MedChip>(find.widgetWithText(MedChip, '血常规 90'));
    expect(chip.selected, isTrue, reason: 'chip 选中态没切');
    // 血糖的序列(i % 3 == 1)一条都不该在树里;血常规的在。
    expect(find.text('指标1'), findsNothing);
    expect(find.text('指标0'), findsOneWidget);
    // chip 正下方必须就是筛出来的卡:快照卡让位,第一张可见的卡是「指标0」。
    expect(find.text('快照项目'), findsNothing, reason: '选了大类,快照卡该让位');
    expect(
      tester.getTopLeft(find.text('指标0')).dy - tester.getBottomLeft(find.text('血常规 90')).dy,
      lessThan(120),
      reason: 'chip 与第一张筛出来的卡之间不该再隔着别的块',
    );

    // 再点一次回到「全部」:快照卡回来。
    await tester.tap(find.text('血常规 90'));
    await tester.pumpAndSettle();
    expect(find.text('快照项目'), findsOneWidget);
  });
}
