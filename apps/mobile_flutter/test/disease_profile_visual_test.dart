// 「病程档案」(s3)。页头带真 logo(brief §品牌 四处摆位之一),提醒是琥珀横幅,
// 活动度与用药走化验行(4px 左色条),病程是时间轴。零个品牌渐变面。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';
import 'stage3_visual_helpers.dart';

// golden fixture:同 `test/profile_sections_test.dart` 那份(Task 20 合成 SLE
// 语料),这里只用它给控制者要求的溢出矩阵喂真实数据——status_card/score_card/
// reminders 这三节被 Task 12 动过颜色/形状(barColor 色条、琥珀横幅),而
// `profile_sections_test.dart` 的 golden 溢出测试只钉 400×800,不钉 360×640
// (那份测试跨很多个 Task,不属于本 Task 的 Files 清单,不在这里改它)。
final _goldenFile = File(
  '../../packages/profile/testdata/golden_profile_view.json',
);
final _goldenSections = (jsonDecode(_goldenFile.readAsStringSync())
        as Map<String, dynamic>)['sections'] as List;

Map<String, dynamic> _goldenSection(String kind) => (_goldenSections
        .map((s) => (s as Map).cast<String, dynamic>())
        .firstWhere((s) => s['kind'] == kind))
    .cast<String, dynamic>();

void main() {
  testWidgets('页头带 30px 真 logo', (tester) async {
    await pumpStage3(tester, Scaffold(appBar: AppBar(
      title: const Row(children: [
        BrandLogo(size: BrandLogo.topBar), SizedBox(width: 10), Text('病程档案 · 狼疮'),
      ]))));
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.getSize(find.byType(BrandLogo)), const Size(30, 30));
  });

  testWidgets('section 头就是一枚 MedIcon —— 不再是 sealWash 方块', (tester) async {
    await pumpStage3(tester, const Scaffold(body: MedIcon(Icons.timeline_outlined)));
    expect(find.byType(MedIcon), findsOneWidget);
    expect(tester.getSize(find.byType(MedIcon)), const Size(44, 44));
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
    await pumpStage3(tester, const Scaffold(body: MedCard(child: MedIcon(Icons.science_outlined))));
    expectSurfaceBudget();
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: _TimelineProbe())));
  });

  // R26 fix round 1:`_ReminderRow` 有琥珀底,但漏了 mockup `.banner` 的签名元素
  // ——44×44 `MedIcon`,原来还是一颗 18px 小图标。这里精确定位到那一条
  // 琥珀底 `Container`(靠 `MedBrand.bannerAmber` 找,不靠 icon——section
  // 头本身也是同一个铃铛图标,两枚图标光看 icon 分不开,只有靠「是不是长在
  // 琥珀底容器里面」才分得开),确认里面**只有一枚** `MedIcon`;标题字色是
  // `MedBrand.bannerAmberInk`(跟 `MedBanner.title` 同一处理)。
  testWidgets('提醒行:琥珀底里是一枚 44px MedIcon,标题走横幅字色', (tester) async {
    await pumpStage3(tester, Scaffold(body: ProfileSectionView({
      'kind': 'reminders', 'title': '待补 / 逾期',
      'body': {'items': [
        {'id': 'mmf_cbc', 'text': '血常规', 'state': 'overdue', 'overdue_days': 12,
         'basis': 'label', 'source': 'L1'},
      ]},
    })));
    final amberBox = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      return d is BoxDecoration && d.color == MedBrand.bannerAmber;
    });
    expect(amberBox, findsOneWidget);
    final tileFinder = find.descendant(of: amberBox, matching: find.byType(MedIcon));
    expect(tileFinder, findsOneWidget);
    final label = tester.widget<Text>(
      find.descendant(of: amberBox, matching: find.text('血常规')),
    );
    expect(label.style?.color, MedBrand.bannerAmberInk);
  });

  // 控制者裁定的溢出矩阵不只管时间轴——`_ItemRow` 新加的 `barColor`(现行方案/
  // 活动度)与 `_ReminderRow` 新加的琥珀底(提醒)都是这个 Task 改的形状,同样要
  // 在 360×640 × 2.0 字号下不溢出。golden fixture 里这三节本来就带着长药名/长
  // 出处/长 reason,是最接近真机的压力数据。
  testWidgets('现行方案/活动度/提醒三节(golden)两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            ProfileSectionView(_goldenSection('status_card')),
            ProfileSectionView(_goldenSection('score_card')),
            ProfileSectionView(_goldenSection('reminders')),
          ]),
        ),
      ),
    );
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
