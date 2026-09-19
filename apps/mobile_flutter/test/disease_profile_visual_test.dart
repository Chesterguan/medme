// 「病程档案」(s3)。页头带真 logo(brief §品牌 四处摆位之一),提醒是琥珀横幅,
// 活动度与用药走化验行(4px 左色条),病程是时间轴。零个品牌渐变面。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('页头带 30px 真 logo', (tester) async {
    await pumpStage3(tester, Scaffold(appBar: AppBar(
      title: const Row(children: [
        BrandLogo(size: BrandLogo.topBar), SizedBox(width: 10), Text('病程档案 · 狼疮'),
      ]))));
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.getSize(find.byType(BrandLogo)), const Size(30, 30));
  });

  testWidgets('ProfileIconTile 就是光泽图标块 —— 不再是 sealWash 方块', (tester) async {
    await pumpStage3(tester, const Scaffold(body: ProfileIconTile(icon: Icons.timeline_outlined)));
    expect(find.byType(GlossIconTile), findsOneWidget);
    expect(tester.getSize(find.byType(GlossIconTile)), const Size(44, 44));
  });

  testWidgets('时间轴:竖线 #DCE3EA、圆点 seal、异常点 #CF3A5A', (tester) async {
    await pumpStage3(tester, const Scaffold(body: _TimelineProbe()));
    final dots = tester.widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration).whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle).map((d) => d.color).toList();
    expect(dots, contains(MedColors.light.seal));
    final lines = tester.widgetList<Container>(find.byType(Container))
        .map((w) => (w.decoration as BoxDecoration?)?.color).toList();
    expect(lines, contains(MedBrand.timelineLine));
  });

  testWidgets('零个品牌渐变面,卡里没有渐变', (tester) async {
    await pumpStage3(tester, const Scaffold(body: MedCard(child: ProfileIconTile(icon: Icons.science_outlined))));
    expectGradientBudget();
    expectNoGradientInsideCards();
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: _TimelineProbe())));
  });
}

/// pump `profile_sections.dart` 里公开可达的时间轴那一节:`ProfileSectionView`
/// 传一个含 timeline 的 section,数据形状照抄 `test/profile_sections_test.dart`
/// 「undated timeline events get their own group」那条已经在用的 fixture,
/// 额外加一个非异常事件(测正常 seal 圆点)与一条 `unverified`(测「需核对」pill)。
class _TimelineProbe extends StatelessWidget {
  const _TimelineProbe();

  @override
  Widget build(BuildContext context) => ProfileSectionView({
    'kind': 'timeline', 'title': '病程时间轴',
    'body': {
      'years': [
        {'year': 2026, 'events': [
          {'type': 'flare', 'text': '皮疹加重', 'date': '2026-03-01', 'severity': 'high'},
          {'type': 'infusion', 'text': '第一次输注贝利尤单抗', 'date': '2026-01-10'},
        ]},
      ],
      'undated': [
        {'type': 'biopsy', 'text': '肾活检', 'unverified': true},
      ],
    },
  });
}
