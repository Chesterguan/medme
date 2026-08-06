import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/claim_link.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/ephemeral_session.dart';
import 'package:mobile_flutter/screens/claim_screen.dart';
import 'package:mobile_flutter/src/rust/frb_generated.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';
import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/screens/first_run_consent.dart';
import 'package:mobile_flutter/screens/mode_picker_screen.dart';
import 'package:mobile_flutter/screens/overview_screen.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // 清医生代拍临时会话的崩溃残留(上次进程被杀/崩溃时没机会走 `ephemeral_wipe`)。
  // 不依赖是否曾开过会话,不阻塞启动。
  unawaited(EphemeralSession.sweep());
  // 行为分析:**不 await** —— 它绝不能挡在启动路径上。没配 Key 时整个不启动。
  // `app_open` 不在这里发:它要带上模式、库存、开箱成功与否,那些得等开箱完
  // (见 `VaultBootstrap`)。init 会缓存自己的 Future,那边直接 await 同一个。
  unawaited(Analytics.init());
  runApp(const MedMeApp());
}

/// 深链投递需要一个跨界面可用的导航器 —— 认领链接可能在任何界面(甚至冷启动)到达。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class MedMeApp extends StatefulWidget {
  const MedMeApp({super.key});
  @override
  State<MedMeApp> createState() => _MedMeAppState();
}

/// 同意门之前到达的认领链接。**不是缓存,是一次性交接**:取走即清空。
(ClaimLink, bool)? _pendingClaim;

/// 取走待处理的认领链接(取过就没了)。
(ClaimLink, bool)? takePendingClaim() {
  final p = _pendingClaim;
  _pendingClaim = null;
  return p;
}

void pushClaimScreen(ClaimLink link, {required bool cold}) {
  appNavigatorKey.currentState?.push(
    MaterialPageRoute(
      builder: (_) => ClaimScreen(link: link, cold: cold),
    ),
  );
}

class _MedMeAppState extends State<MedMeApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动:App 是被链接拉起来的,初始路由就是那条 URI。热启动走
    // didPushRouteInformation。两条路都收敛到 handleIncomingUri。
    final initial = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (initial != '/') _dispatch(initial, cold: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App 已在运行时,系统把链接送到这里(自定义 scheme / 将来的 Universal Links)。
  @override
  Future<bool> didPushRouteInformation(RouteInformation info) async {
    return _dispatch(info.uri.toString());
  }

  /// 回到前台时跑一次代拍材料的 12 小时清理。
  ///
  /// 没有后台定时器是刻意的(app 不在前台时不该跑),所以「到时间自动删」能兑现的
  /// 最早时机就是这里。只靠 `ensureLoaded` 不够 —— 医生早上代拍完把手机揣兜里,
  /// 一整天不再进那个流程,材料就一直在。而这句承诺印在病人签字的同意书上。
  ///
  /// 个人模式下没有代拍病人,`_purgeExpired` 扫一眼空目录就返回,代价可以忽略。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ProxyPatientManager.instance.ensureLoaded());
    }
  }

  /// [cold] = App 是被这条链接**拉起来的**(而不是已在运行时收到)。这个区分是
  /// 认领转化里最关键的一维:冷启动基本意味着「刚装完就来认领」。
  bool _dispatch(String raw, {bool cold = false}) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final link = ClaimLink.tryParse(uri);
    if (link == null) return false;
    // 保险箱可能还没打开完(冷启动),推迟到下一帧再导航。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // ⚠️ **没同意过就先别推。** 冷启动时认领屏会被推到告知页**上面** —— 那等于
      // 病人在没看过任何告知、没同意过任何条款的情况下,第一屏就是「存进我的档案」,
      // 存完才可能看到告知页。而认领恰恰是最典型的首次使用(装完 App 第一件事)。
      // 首启告知门是合规要求不是引导流程,不能被一条深链绕过去。
      // 存着,等 `_AppRootState` 过了同意门再补推(见 [takePendingClaim])。
      if (!await FirstRunConsent.hasAgreed()) {
        _pendingClaim = (link, cold);
        return;
      }
      pushClaimScreen(link, cold: cold);
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MedMe 医我',
      navigatorKey: appNavigatorKey,
      theme: MedMe.theme(),
      debugShowCheckedModeBanner: false,
      // 面向简体中文用户:强制中文本地化,日历选择器/所有 Material 弹窗都显示中文。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const VaultBootstrap(),
    );
  }
}

/// 启动引导:先在真实沙盒目录打开保险箱(FFI `open_vault`),再进主界面。
/// 打开是可韧性的(损坏的派生 db 会从 log 重建);目录取自 path_provider。
/// iCloud 已接入(见 `vault_boot` / `icloud_bridge`):容器可解析且用户在设置里开启
/// 同步时,真相存进 iCloud 容器,否则用本机沙盒。打开失败给人性化提示而非白屏。
class VaultBootstrap extends StatefulWidget {
  const VaultBootstrap({super.key});
  @override
  State<VaultBootstrap> createState() => _VaultBootstrapState();
}

class _VaultBootstrapState extends State<VaultBootstrap> {
  // 打开「当前成员」的保险箱(多成员见 profile_manager / vault_boot),同时把
  // 「个人/医生」模式选择读出来(`AppRoot` 据此决定先显示哪个根界面)。两者互不
  // 依赖,并发跑不拖慢启动。IIFE 包一层是因为 `Future.wait` 本身返回
  // `Future<List<void>>`,与这里声明的 `Future<void>` 字段类型不兼容。
  final Future<void> _open = (() async {
    var ok = true;
    try {
      await Future.wait([
        openCurrentProfileVault(),
        AppMode.instance.ensureLoaded(),
      ]);
    } catch (_) {
      ok = false;
      rethrow; // 错误界面照旧显示,埋点只是搭个便车
    } finally {
      vaultOpenedOkThisLaunch = ok; // 首启同意页补发 app_open 时要读(见 vault_boot.dart)
      // `app_open` 发在这里而不是 `main()`:要带上模式和「箱子开没开成」。
      // **开箱失败此前是完全不可见的** —— 用户只看到一句红字,我们什么都不知道。
      await Analytics.init(); // 已在 main 里跑着,这里只是等同一个 Future
      Analytics.setContext({
        'mode': AppMode.instance.mode.value?.name ?? 'unset',
      });
      Analytics.track(AnalyticsEvent.appOpen, {'vault_ok': ok});
    }
  })();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _open,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    // 圆角取卡片这一档(20),与进到主界面后满屏的卡一致 ——
                    // 启动图是用户看到的第一个圆角,不该和后面对不上。
                    borderRadius: BorderRadius.circular(MedShape.radiusCard),
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      width: 84,
                      height: 84,
                    ),
                  ),
                  const SizedBox(height: MedShape.s4),
                  const CircularProgressIndicator(),
                ],
              ),
            ),
          );
        }
        if (snap.hasError) {
          final c = MedColors.of(context);
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(MedShape.s5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_off_outlined, size: 40, color: c.ink3),
                    const SizedBox(height: MedShape.s3),
                    // 文案一字未改,只是把标题和技术细节分成两档字级 ——
                    // 原先四行挤在同一个 15px 里,最要紧的那句读不出来。
                    // ⚠️ 这里**不加**任何「你的记录没有丢」之类的安慰:箱子都没
                    // 打开,我们并不知道里面怎么样,不能替它打包票。
                    Text(
                      '无法打开你的健康档案',
                      style: MedType.subtitle.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: MedShape.s1),
                    Text(
                      '${snap.error}\n\n请重启 App 再试。',
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const AppRoot();
      },
    );
  }
}

/// 应用根:按 [AppMode] 决定显示哪个界面——还没选过模式 → 「你是?」选择屏;
/// 选了「个人」→ [HomeShell](五 tab);选了「医生」→ [DoctorHomeScreen]。
/// 用 `ValueListenableBuilder` 监听同一个 notifier:设置页「切换模式」写入新值后,
/// 这里自动重建换到另一个根界面,不需要任何显式导航(调用方只需在切换后把导航栈
/// popUntil 回第一层,见 `settings_screen.dart`)。
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  /// 首启告知与同意 —— **挡在一切之前**。带「医」字的 App 在用户交出任何病历之前
  /// 必须先把「是什么/不是什么/数据去哪」说清楚,这是合规要求不是引导流程。
  late final Future<bool> _agreed = FirstRunConsent.hasAgreed();
  bool _justAgreed = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _agreed,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // 一次 SharedPreferences 读,瞬时;上一屏的 loading 还没撤,不闪。
          // 底色不再指定 —— 主题的 scaffoldBackgroundColor 已经是 `paper`。
          return const Scaffold(body: SizedBox.shrink());
        }
        if (!(snap.data ?? false) && !_justAgreed) {
          return FirstRunConsentScreen(
            onAgreed: () => setState(() => _justAgreed = true),
          );
        }
        // 同意门已过。若有一条认领链接在门外等着(冷启动时链接比同意门先到),
        // 现在补推 —— 病人不用回去重点一次链接,那条链接他多半已经关掉了。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final pending = takePendingClaim();
          if (pending != null) {
            pushClaimScreen(pending.$1, cold: pending.$2);
          }
        });
        return _modeRoot();
      },
    );
  }

  Widget _modeRoot() {
    return ValueListenableBuilder<AppModeKind?>(
      valueListenable: AppMode.instance.mode,
      builder: (context, mode, _) {
        return switch (mode) {
          null => const ModePickerScreen(),
          AppModeKind.personal => const HomeShell(),
          AppModeKind.doctor => const DoctorHomeScreen(),
        };
      },
    );
  }
}

/// 底部导航壳:**五个一级 tab,按「使用时刻」划分**(设计系统 §八)。
///
/// | tab | 使用时刻 |
/// |---|---|
/// | 概览 | 日常打开,看一眼「我现在怎么样」 |
/// | 趋势 | 复诊前自己看「这两年怎么变的」 |
/// | 档案 | 找某一张单子 |
/// | 应急卡 | 急诊室,**别人**拿着你的手机 |
/// | 设置 | 数据主权 |
///
/// 划分依据是**时刻**不是数据类型。旧的三 tab(健康档案 / 导出分享 / 设置)是按
/// 功能分的,于是「我现在怎么样」和「这两年怎么变的」被一起压进了「健康档案」,
/// 而它们是两个完全不同的时刻 —— 一个是每天早上三十秒,一个是复诊前坐下来看十分钟。
///
/// ## 两处刻意的缺席
///
/// **「看病带这个」不是 tab。**(原名「就诊单」,2026-08-05 改名,见
/// `screens/visit_summary_sheet.dart` 顶部文档)它是诊室里那 30 秒的动作,从
/// 概览与档案的顶栏两处以浮层唤起。做成 tab 就是给一个一年用十次的动作一个
/// 常驻席位,而把它挤掉的会是应急卡。
///
/// **「导出·分享」不再是 tab,收进了设置。** 它承载的是 E2E 加密分享与可打印导出:
/// 重、正式、要联网、低频。它和「看病带这个」不是一回事(那个是本地的、离线的、
/// 一页纸),所以不能并进去;而它的心智恰好就是设置这个 tab 的定义 ——「数据
/// 主权:我的数据往哪去」,和备份、清空是同一件事的三个方向。
/// 诊室现场那条最高频的路没有变长:「看病带这个」浮层底部直接有「医生要看原件 ·
/// 出示二维码」。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// 五个 tab 的页面,顺序必须与 [HomeTab] 的常量逐一对应 —— `IndexedStack` 按
  /// 下标取,错一位就是点「应急卡」进了「设置」。
  ///
  /// 与 [tabDestinations] 一起公开是为了让 `test/home_shell_test.dart` 能钉住
  /// 「页面数 == 底栏项数 == [HomeTab.count]」。这三个数字散在两处 const 列表和
  /// 一组常量里,加一个 tab 时最容易漏掉的就是其中一处,而漏掉的表现是**运行时
  /// 越界或错位**,不是编译错误。
  static const List<Widget> tabScreens = [
    OverviewScreen(),
    TrendsScreen(),
    ArchiveScreen(),
    EmergencyCardScreen(),
    SettingsScreen(),
  ];

  /// 底栏五项,顺序同 [tabScreens]。
  static const List<NavigationDestination> tabDestinations = [
    NavigationDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: '概览',
    ),
    NavigationDestination(
      icon: Icon(Icons.show_chart_outlined),
      selectedIcon: Icon(Icons.show_chart),
      label: '趋势',
    ),
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: '档案',
    ),
    // 应急卡用 Material 的 `emergency`(那个六角星医疗符号),不用心形或十字 ——
    // 心形在健康 app 里普遍是「收藏」,十字是「新增」。
    NavigationDestination(
      icon: Icon(Icons.emergency_outlined),
      selectedIcon: Icon(Icons.emergency),
      label: '应急卡',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '设置',
    ),
  ];

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = HomeTab.overview;

  @override
  void initState() {
    super.initState();
    // 别的屏(如设置载入示例后)可程序化切 tab。
    selectedTab.addListener(_onTabRequested);
  }

  @override
  void dispose() {
    selectedTab.removeListener(_onTabRequested);
    super.dispose();
  }

  void _onTabRequested() {
    if (mounted && selectedTab.value != _index) {
      setState(() => _index = selectedTab.value);
    }
  }

  /// 底栏被**手点**。埋点只挂在这里,**不挂 [_onTabRequested]** ——
  /// 后者也接程序化跳转(`goToArchive()`、载入示例后的「去看看」),那是别的功能
  /// 的副作用,不是用户想去哪。混进来会把一个功能的成功记成另一个 tab 的人气,
  /// 而这条事件存在的全部意义正是「五个席位该给谁」。
  void _onTabTapped(int i) {
    final tab = AnalyticsTab.of(i);
    // 认不出来就不报(不猜),但 tab 照切 —— 埋点绝不影响功能。
    if (tab != null) {
      Analytics.track(AnalyticsEvent.homeTabSelected, {'tab': tab.name});
    }
    selectedTab.value = i;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: HomeShell.tabScreens),
      // 底栏与内容之间一道 `line`。原先靠 elevation:3 的投影分层 —— 规范 §四
      // 「层次靠边框不靠阴影,阴影只有一档」,那一档已经花在卡片上了。
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: MedColors.of(context).line)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          // 统一走 selectedTab:手点和程序化跳转(设置载入示例后)同一条路径。
          onDestinationSelected: _onTabTapped,
          destinations: HomeShell.tabDestinations,
        ),
      ),
    );
  }
}
