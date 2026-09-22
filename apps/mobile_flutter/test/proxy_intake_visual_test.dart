// Task 16 sweep(Task 13b carry-forward):代拍「还没核对」列表页
// (`proxy_intake_flow.dart` 的 `PendingListStep`)的两颗按钮。
//
// **没有按 carry-forward 字面意思换成 MedSecondaryButton/MedPrimaryButton——
// 这两个 token 组件写死蓝色(`MedBrand.gradientColors`/`c.seal`/`c.sealInk`,
// 没有颜色参数),而代拍模式全程是紫色 `c.proxy`:文件头部类文档写明『紫是
// 代拍专属……两个模式一眼可辨是安全设计,不是装饰』——防的是拍错病人的单子/
// 在错模式下动手。同一个文件里 `_CaptureStep`(891 行一带)、以及
// consent_screen.dart / doctor_share_result_dialog.dart / doctor_home_screen.dart /
// proxy_document_detail.dart 另外四处主按钮,全部维持裸
// `FilledButton.styleFrom(backgroundColor: c.proxy)`——`lib/screens/doctor/`
// 整个目录没有一处用 MedPrimaryButton/MedSecondaryButton,而这五处全部是
// Stage 3 期间(Task 12/13/13b)已经过审、原样保留的代拍配色。换成蓝会破坏
// 这条一直保持一致的安全区分。`global-constraints.md` 的品牌渐变预算表
// (九屏/十五行)也没有任何一行是代拍屏——预算表本来就只管个人模式。
//
// 这个测试只钉两件没有争议的事:①「添加」/「生成取件码,交给病人」原样是
// OutlinedButton/FilledButton,颜色/标签/回调都不变;②两个尺寸×两档字号不
// 溢出。`_PendingListStep` 改名成 `PendingListStep`(纯移动,只去掉一个
// 下划线,零逻辑变化)才能在这个文件里直接 new 它——它本来就是一个只吃
// 数据 + 回调的 StatelessWidget。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/doctor/proxy_intake_flow.dart'
    show PendingListStep;

import 'stage3_visual_helpers.dart';

/// 空清单(`docs.isEmpty`)就够测按钮/预算/溢出——列表行本身的视觉是
/// `_PendingRow`(与 `archive_screen.dart` 同一套语言),不在这个文件里重复断言。
Widget _harness() => PendingListStep(
  groups: const [],
  summary: null,
  confirmedMap: const {},
  patientName: '张三',
  mismatch: const {},
  busy: false,
  progress: null,
  onCaptureMore: () {},
  onDeliver: () {},
  onOpenDocument: (_) {},
);

void main() {
  testWidgets('还没核对列表:零品牌渐变(代拍紫不进个人模式的预算表)', (tester) async {
    await pumpStage3(tester, _harness());

    expectSurfaceBudget();
    expect(find.widgetWithText(OutlinedButton, '添加'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, '生成取件码,交给病人'),
      findsOneWidget,
    );
  });

  testWidgets('两个尺寸 × 两档字号,底部按钮栏不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, _harness());
  });
}
