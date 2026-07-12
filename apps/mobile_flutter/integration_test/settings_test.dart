import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:mobile_flutter/main.dart' as app;
import 'package:mobile_flutter/src/rust/frb_generated.dart';

// 「设置」屏集成测试(Patrol)。用户跑:
//   patrol test -t integration_test/settings_test.dart
//
// 覆盖:切到设置 tab 后,示例数据/清空/关于 三个分组都渲染出来;点「清空所有
// 数据 · 重置保险箱」弹出二次确认对话框(且能取消,不误删)。真正跑一次
// FFI 清空留给人工在真机/模拟器上验证——这里只验证 UI 流程不会漏掉确认这一步
// (对应过的反馈:载入示例后清空无法用,首要是要看到确认弹窗且能操作)。

void main() {
  patrolTest('设置屏:分组可见,清空按钮弹二次确认', ($) async {
    await RustLib.init();
    await $.pumpWidgetAndSettle(const app.MedMeApp());

    await $('设置').tap();
    await $.pumpAndSettle();

    // 三个功能分组的标题行都在。
    expect($('载入示例数据(张建国)'), findsOneWidget);
    expect($('清空所有数据 · 重置保险箱'), findsOneWidget);
    expect($('关于'), findsOneWidget);

    // 点清空 → 弹出二次确认,不直接执行。
    await $('清空所有数据 · 重置保险箱').tap();
    await $.pumpAndSettle();
    expect($('清空保险箱?'), findsOneWidget);
    expect($('确定清空全部记录?示例数据和已导入的病历都会被删除,此操作不可撤销。'), findsOneWidget);

    // 取消:对话框消失,不触发清空。
    await $('取消').tap();
    await $.pumpAndSettle();
    expect($('清空保险箱?'), findsNothing);
  });
}
