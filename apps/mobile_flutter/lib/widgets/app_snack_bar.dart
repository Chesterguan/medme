import 'package:flutter/material.dart';

/// SnackBar 默认停留时长。与 Flutter 私有的 `_snackBarDisplayDuration` 一致 ——
/// 那颗常量是 private,拿不到,只能对齐字面量。
const Duration kAppSnackDuration = Duration(milliseconds: 4000);

/// **全 App 唯一的 SnackBar 构造口。不要在别处直接 `SnackBar(...)`。**
/// (`test/snack_bar_persist_test.dart` 会扫 `lib/` 钉住这一条。)
///
/// ## 为什么必须有这么一层
///
/// Flutter 在 3.37 的 [#173084](https://github.com/flutter/flutter/pull/173084)
/// 里改了 [SnackBar] 的默认行为,构造函数末尾多了一句:
///
/// ```dart
/// persist = persist ?? action != null;
/// ```
///
/// 而 `ScaffoldMessengerState.build` 里那颗到点关灯的计时器,回调第一句是:
///
/// ```dart
/// if (snackBar.persist) { return; }
/// ```
///
/// 两句合起来:**任何带 `action:` 的 SnackBar,默认永远不会自己消失。** 没有报错、
/// 没有 lint、没有 assert,`duration` 照传不误但根本不被使用 —— 唯一的表现是那条
/// 横条一直挂在屏幕底部。
///
/// 这不是理论。真机(华为 MHA-L29 / Android 8.0)上「设置 → 载入示例数据」完成后
/// 那条带「去看看」的提示挂了 7 分钟没走,而它:
///
/// * **挡住底部约 200px 且吃掉点击** —— `SnackBar` 的 `Dismissible` 默认
///   `HitTestBehavior.opaque`,盖住的「清空所有数据」按钮连点三次没反应;
/// * **横划划不掉** —— 默认 `DismissDirection.down`,只有向下划才算数;
/// * 切 tab、开关弹层、走完对话框都不影响它(计时器压根没被启用,与 ticker 无关)。
///
/// 用户会把这判成「App 卡死了」。我们自己也判成过。
///
/// ## 为什么统一 `persist: false`,而不是逐处判断
///
/// 上游那条 PR 的本意是照顾读屏用户(4 秒不够摸到 action)。但在本 App 里,一条
/// 永不消失、且吃掉底部 200px 点击的横条,危害大于「可能错过一次 action」——
/// 我们所有 SnackBar 上的 action 都只是捷径(如「去看看」= 自己切到档案 tab),
/// 没有任何一个是唯一入口。所以这里一律恢复「到点自己走」。
///
/// 要一条真正常驻的提示,请用别的东西(`MaterialBanner` / 页内提示),不要指望
/// 把 `persist` 打开 —— 那样又会盖住底部操作区。
SnackBar appSnackBar({
  required Widget content,
  SnackBarAction? action,
  Duration duration = kAppSnackDuration,
  SnackBarBehavior? behavior,
}) {
  return SnackBar(
    content: content,
    action: action,
    duration: duration,
    behavior: behavior,
    // ⚠️ 这一行就是这个文件存在的全部理由。见上面的长注释。
    persist: false,
  );
}
