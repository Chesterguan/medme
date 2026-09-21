import 'package:flutter/foundation.dart';

/// 病历箱内容变更的全局信号。导入、清空、载入示例后调用 [bumpVaultRevision]，
/// 监听者(尤其「病历」屏)据此重新加载。
///
/// 为什么需要:底部三 tab 用 `IndexedStack` 承载,切走的屏会**保活**(state 不销毁),
/// 所以在「我 → 关于」里清空、或在导入后,「病历」屏的 `initState` 不会
/// 再跑一次 → 切回去还是旧数据,用户以为没生效。让档案屏监听这个信号即可自动刷新。
final ValueNotifier<int> vaultRevision = ValueNotifier<int>(0);

/// 病历箱内容变了(导入/清空/载入示例),通知所有监听屏重载。
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
