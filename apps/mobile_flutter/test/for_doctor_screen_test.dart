// 「给医生看」那一页的四条出口**接上了没有**(Task 9)。
//
// 摆位、顺序、逐字文案由 `test/mobile_ia_test.dart` 的「给医生看」那一组守着
// (Task 3 起);这个文件只问一件事:**点下去有没有去处**。Task 3 把四条摆好时
// 回调全是 null —— 页面看着齐全,按下去什么也不会发生,而那种「点了没反应」正是
// 这个 app 反复出过的事故形态。
//
// 为什么断言的是「回调不是 null」而不是「真的跳过去了」:点下去要建
// `QrShareScreen` / `ExportScreen` / `EmergencyCardScreen`,那三屏各自在字段
// 初始化处碰 FFI,`flutter test` 不带 Rust 原生库,当场就崩。所以整屏这一层只验
// **接线在不在**,「各自打给谁」交给下面那条纯 widget 的用例分开验。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/screens/for_doctor_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

const _empty = VisitSummaryDto(
  patient: PatientProfileDto(recordCount: 0),
  allergies: [],
  activeMeds: [],
  recentLabs: [],
  recentChanges: [],
  recentVisits: [],
  recentNotes: [],
  plainText: '',
);

Widget wrap(Widget child) => MaterialApp(
  theme: MedMe.theme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// 整屏自带 `Scaffold`,**不能**再套一层滚动(里面的 `ListView` 会拿到无穷高约束)。
Widget wrapScreen(Widget screen) =>
    MaterialApp(theme: MedMe.theme(), home: screen);

void main() {
  testWidgets('跟着滚的三条:各点各的,不串线', (tester) async {
    var exp = false, emg = false, proxy = false;
    await tester.pumpWidget(
      wrap(
        ForDoctorActions(
          onExport: () => exp = true,
          onEmergency: () => emg = true,
          onProxy: () => proxy = true,
        ),
      ),
    );
    await tester.tap(find.text('导出文件'));
    expect([exp, emg, proxy], [true, false, false], reason: '「导出文件」串线了');
    await tester.tap(find.text('急救卡'));
    expect([exp, emg, proxy], [true, true, false], reason: '「急救卡」串线了');
    await tester.tap(find.text('我是医生,替病人代拍'));
    expect([exp, emg, proxy], [true, true, true], reason: '「代拍」串线了');
  });

  testWidgets('整页四条出口全部有去处 —— 一条都不许是摆设', (tester) async {
    // Task 7 减法:「我最近的变化/过敏史/记录中出现的药物/我想问医生的」四节
    // 现在各自一张 `MedCard`、节内无图标,比原来单栏文字高不少。
    // `flutter test` 的默认画布是 800×600 逻辑像素(近似横屏平板,不是手机),
    // 这个高度下 `ListView` 的 sliver 缓冲区够不到 footer(`ForDoctorActions`),
    // `find.byType` 找到 0 个——不是接线断了,是画布不像手机。换成这套 Stage 3
    // 测试统一在用的真机尺寸(`stage3_visual_helpers.dart` 的 `pumpStage3`
    // 默认值,400×800 @ 1.0x)。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrapScreen(ForDoctorScreen(load: () async => _empty)));
    await tester.pumpAndSettle();

    // 「出码」是固定在底部的那一颗(`s4`),不在跟着滚的那一组里。Task 10 把它
    // 从 `FilledButton.icon` 换成了 `MedPrimaryButton`(brief §品牌 最后一条 +
    // 颜色面预算表:s4 的那 1 颗主按钮就是它),按类型直接找。
    final qr = tester.widget<MedPrimaryButton>(find.byType(MedPrimaryButton));
    expect(qr.onPressed, isNotNull, reason: '「出码」还是禁用态');

    final actions = tester.widget<ForDoctorActions>(
      find.byType(ForDoctorActions),
    );
    expect(actions.onExport, isNotNull, reason: '「导出文件」没接');
    expect(actions.onEmergency, isNotNull, reason: '「急救卡」没接');
    expect(actions.onProxy, isNotNull, reason: '「代拍」没接');
  });
}
