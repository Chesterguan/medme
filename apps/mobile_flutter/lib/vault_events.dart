import 'package:flutter/foundation.dart';

/// 保险箱内容变更的全局信号。导入、清空、载入示例后调用 [bumpVaultRevision]，
/// 监听者(尤其「健康档案」屏)据此重新加载。
///
/// 为什么需要:底部三 tab 用 `IndexedStack` 承载,切走的屏会**保活**(state 不销毁),
/// 所以在「设置」里清空、或在「导入导出」里导入后,「健康档案」屏的 `initState` 不会
/// 再跑一次 → 切回去还是旧数据,用户以为没生效。让档案屏监听这个信号即可自动刷新。
final ValueNotifier<int> vaultRevision = ValueNotifier<int>(0);

/// 保险箱内容变了(导入/清空/载入示例),通知所有监听屏重载。
void bumpVaultRevision() => vaultRevision.value++;

/// 底部一级 tab 的下标。**三个**(mockup,创始人拍板):
///
/// | tab | 用户在干什么 |
/// |---|---|
/// | 病历 | 拍/添加一份,以及回头找某一张 |
/// | 趋势 | 这个病现在怎么样、吃过什么药、该查没查 |
/// | 我 | 云端、成员、口令与恢复码、设置 |
///
/// **「给医生看」不是 tab** —— 它是「病历」首页那颗主按钮推进去的一整页
/// (`screens/for_doctor_screen.dart`)。急救大字模式在那一页里。
/// ⚠️ ia-proposal §2 推荐的是把它放进底栏(候选 A);mockup 改了主意。
/// 两处打架时**以 mockup 为准**,理由见计划的 Global Constraints。
class HomeTab {
  HomeTab._();

  static const int records = 0;
  static const int trends = 1;
  static const int me = 2;

  /// tab 总数。`HomeShell` 的页面列表与底栏项数都对它断言,少一个就崩在测试里,
  /// 而不是运行时 `IndexedStack` 越界。
  static const int count = 3;
}

/// 当前底部一级 tab 下标(取值见 [HomeTab])。`HomeShell` 监听它切换页面。
final ValueNotifier<int> selectedTab = ValueNotifier<int>(HomeTab.records);

/// 跳到「病历」tab。
void goToRecords() => selectedTab.value = HomeTab.records;

/// 跳到「趋势」tab。
void goToTrends() => selectedTab.value = HomeTab.trends;

/// 跳到「我」tab。
void goToMe() => selectedTab.value = HomeTab.me;

// ── 过渡期 shim ─────────────────────────────────────────────────────────────
//
// `overview_screen.dart` 还要活到 Task 9(它的「最近的关键化验」「最近就诊」得先
// 搬进「趋势」才能拆,见 Task 8),在那之前这两个旧名字仍有调用方
// (`overview_screen.dart:569,650` 和 `:248`)。直接删会让**本次提交的
// `flutter analyze` 当场就红** —— 而每个 Task 的「Expected: PASS」指的是那一刻
// 整仓的 analyze + test,不是只有新写的那个测试文件。
//
// `goToTrends` 不在此列:「趋势」仍然是一个 tab,那个函数照旧是真的。
//
// 两个 shim 在 Task 9 随概览一起删。

@Deprecated('Stage 1: 用 goToRecords();概览删掉后本 shim 一并删(Task 9)')
void goToArchive() => goToRecords();

/// 急救已经搬进「给医生看」那一页,底栏没有它的位置了 —— 这个 shim **只是让
/// 注定要删的概览还能编译**,落点是权宜的,不代表产品意图。Task 9 删。
@Deprecated('Stage 1: 急救在「给医生看」页里;概览删掉后本 shim 一并删(Task 9)')
void goToEmergencyCard() => goToRecords();
