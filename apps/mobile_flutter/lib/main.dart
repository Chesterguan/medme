import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/claim_link.dart';
import 'package:mobile_flutter/ephemeral_session.dart';
import 'package:mobile_flutter/screens/claim_screen.dart';
import 'package:mobile_flutter/src/rust/frb_generated.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';
import 'package:mobile_flutter/screens/export_screen.dart';
import 'package:mobile_flutter/screens/first_run_consent.dart';
import 'package:mobile_flutter/screens/mode_picker_screen.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
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
    MaterialPageRoute(builder: (_) => ClaimScreen(link: link, cold: cold)),
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
      await Future.wait([openCurrentProfileVault(), AppMode.instance.ensureLoaded()]);
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
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      width: 84,
                      height: 84,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const CircularProgressIndicator(color: MedMe.teal),
                ],
              ),
            ),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '无法打开你的健康档案:\n${snap.error}\n\n请重启 App 再试。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15),
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
/// 选了「个人」→ 现有 [HomeShell](三 tab);选了「医生」→ [DoctorHomeScreen]。
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
          return const Scaffold(backgroundColor: MedMe.bg, body: SizedBox.shrink());
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

/// 底部导航壳:三个一级 tab —— 健康档案 / 导出分享 / 设置。
/// 导入入口在「健康档案」页右上角「导入」按钮(不是独立 tab);导出/分享独立成一级 tab。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  // 健康档案(看 + 右上角导入)· 导出分享 · 设置。导入并进「健康档案」,
  // 导出/分享独立成 tab —— 手机端「轻」定位:采集 + 看 + 分享,搜索/趋势在桌面/查看器。
  static const _screens = [ArchiveScreen(), ExportScreen(), SettingsScreen()];

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        // 统一走 selectedTab:手点和程序化跳转(设置载入示例后)同一条路径。
        onDestinationSelected: (i) => selectedTab.value = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '健康档案',
          ),
          NavigationDestination(
            icon: Icon(Icons.ios_share_outlined),
            selectedIcon: Icon(Icons.ios_share),
            label: '导出分享',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
