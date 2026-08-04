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

/// 底部一级 tab 的下标。**按「使用时刻」排序,不按数据类型** —— 设计系统 v1 §八。
///
/// 概览(日常打开,看一眼我现在怎么样)→ 趋势(复诊前自己看这两年怎么变的)→
/// 档案(找某一张单子)→ 应急卡(急诊室,**别人**拿着你的手机)→ 设置(数据主权)。
///
/// 顺序不是随手排的:它按「这一刻有多着急」从慢到急,再收在设置。应急卡放在设置
/// 左边而不是塞进设置里,是因为**用它的人不是你** —— 急救人员在陌生手机上找东西,
/// 只会扫一眼底栏,不会进设置翻。
///
/// 「就诊单」刻意**不是** tab:它是诊室里那 30 秒的动作,从概览与档案两处以浮层
/// 唤起(见 `screens/visit_summary_sheet.dart`),不是一个你会常驻浏览的空间。
class HomeTab {
  HomeTab._();

  static const int overview = 0;
  static const int trends = 1;
  static const int archive = 2;
  static const int emergency = 3;
  static const int settings = 4;

  /// tab 总数。`HomeShell` 的页面列表与底栏项数都对它断言,少一个就崩在测试里,
  /// 而不是运行时 `IndexedStack` 越界。
  static const int count = 5;
}

/// 当前底部一级 tab 下标(取值见 [HomeTab])。`HomeShell` 监听它切换页面 ——
/// 让「设置」里载入示例后能自动跳回「档案」,不用用户再手点。
final ValueNotifier<int> selectedTab = ValueNotifier<int>(HomeTab.overview);

/// 跳到「档案」tab。
void goToArchive() => selectedTab.value = HomeTab.archive;

/// 跳到「趋势」tab。
void goToTrends() => selectedTab.value = HomeTab.trends;

/// 跳到「应急卡」tab。
void goToEmergencyCard() => selectedTab.value = HomeTab.emergency;
