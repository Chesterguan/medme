// 「病历」主页的视觉验收(mockup s1)。**只测视觉,不测行为** —— 行为归
// archive_header_test.dart / mobile_ia_test.dart 管。
//
// 减法稿 2026-09-22:主页顶部不再有品牌渐变主卡([MemberHeader] 只是一行文字,
// 不是 [HeroCard]),颜色面预算只剩 button:1。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/member_header.dart';
import 'stage3_visual_helpers.dart';

// 整屏 pump 要 FFI,测试环境没有原生库 —— 和 HomeTiles / ForDoctorActions 一样,
// 把这一屏的纯 widget 部件各自 pump(既有先例见 for_doctor_screen.dart:210 注释)。
Widget _homeBlock() => Scaffold(
  backgroundColor: MedColors.light.paper,
  body: ListView(padding: const EdgeInsets.all(MedShape.s3), children: [
    MemberHeader(name: '张建国', gender: '男', age: '61 岁', recordCount: 31,
        recentVisitDate: '2026-07-20', onSwitchMember: () {}),
    const SizedBox(height: MedShape.s2),
    HomeTiles(onAdd: () {}, onForDoctor: () {}),
    const SizedBox(height: MedShape.s2),
    PendingReviewBanner(count: 2, onTap: () {}),
    MonthHeader(label: '2026 年 8 月'),
  ]),
);

void main() {
  testWidgets('颜色面预算:没有主卡,一颗主按钮', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expectSurfaceBudget(button: 1);
    expectNoGradientAnywhere();
  });

  testWidgets('「添加」是实心药丸(MedPrimaryButton),「给医生看」是描边药丸(MedSecondaryButton)', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(find.widgetWithText(MedPrimaryButton, '添加'), findsOneWidget);
    expect(find.widgetWithText(MedSecondaryButton, '给医生看'), findsOneWidget);
  });

  testWidgets('「还没核对」是琥珀横幅', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2 份还没核对')).style!.color, MedBrand.bannerAmberInk);
    expect(tester.widget<Icon>(find.byIcon(Icons.warning_amber_outlined)).color, MedBrand.bannerAmberInk);
  });

  testWidgets('月份标题 13 号 ink3', (tester) async {
    await pumpStage3(tester, _homeBlock());
    final month = tester.widget<Text>(find.text('2026 年 8 月'));
    expect(month.style!.fontSize, 13);
    expect(month.style!.color, MedColors.light.ink3);
  });

  testWidgets('底色是实心 #F6F8FA,没有第二块颜色面', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(MedColors.light.paper, const Color(0xFFF6F8FA));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        MedColors.light.paper);
  });

  testWidgets('400×800 与 360×640 × 1.0/2.0 字号全部不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, _homeBlock());
  });

  test('主页时间线的行上没有图标(源码级)', () {
    // 整月的行现在都在一张 MedCard 里,行间 line2 分隔线,行上没有 MedIcon——
    // 这个结构在 pump 层面测不出来:不是 TimelineGroupDto 造不出来(它是个普通
    // 构造函数,`archive_header_test.dart` 已经在这么用了),而是 `_TimelineItem`
    // 是私有类,月份卡的组装又写死在 ArchiveScreen 那个绑了 FFI 的
    // FutureBuilder 里面,单独 pump 不出这一小块。改为断言源码:全文件只许剩
    // 一处 `MedIcon(`——_MismatchBanner 的警告图标(减法稿两处传色例外之一),
    // 时间线行/子文档行/还没核对卡片上的图标本任务已删光。
    final src = File('lib/screens/archive_screen.dart').readAsStringSync();
    final count = 'MedIcon('.allMatches(src).length;
    expect(count, 1, reason: '只有 _MismatchBanner 的警告图标还该有 MedIcon(,其余行上的图标本任务删掉了');
  });
}
