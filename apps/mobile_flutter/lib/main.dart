import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/claim_link.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart' show Profile, ProfileManager;
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/ephemeral_session.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
import 'package:mobile_flutter/screens/claim_screen.dart';
import 'package:mobile_flutter/src/rust/frb_generated.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';
import 'package:mobile_flutter/screens/first_run_consent.dart';
import 'package:mobile_flutter/screens/mode_picker_screen.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/member_switcher.dart';

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

// 后台同步触发器的接线(`sync_engine.dart` 的 `runBackgroundSync`)**不在这个文件
// 里**:概览屏顶部那行备份状态的「点这里重试」也要用它,放这儿会逼一个界面去
// import `main.dart`。本文件只负责"什么时候跑"(debounce 计时器 + 生命周期回调)。

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

/// 同意门之前到达的授权链接(家属/医生扫码进来的那条)。同 [_pendingClaim],
/// 一次性交接,取走即清空。
(GrantLink, bool)? _pendingGrant;

(GrantLink, bool)? takePendingGrant() {
  final p = _pendingGrant;
  _pendingGrant = null;
  return p;
}

void pushGrantRedeem(GrantLink link, {required bool cold}) {
  appNavigatorKey.currentState?.push(
    MaterialPageRoute(
      builder: (_) => GrantRedeemScreen(link: link, cold: cold),
    ),
  );
}

class _MedMeAppState extends State<MedMeApp> with WidgetsBindingObserver {
  /// 保险箱内容变化(`vaultRevision`)3 秒后才推——避免连续几次录入/导入各触发
  /// 一次网络请求;`triggerBackgroundSync` 自己会在没登录/当前成员没开通云同步时
  /// no-op,这里只管"什么时候跑"。
  Timer? _pushDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动:App 是被链接拉起来的,初始路由就是那条 URI。热启动走
    // didPushRouteInformation。两条路都收敛到 handleIncomingUri。
    final initial = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (initial != '/') _dispatch(initial, cold: true);
    vaultRevision.addListener(_scheduleDebouncedPush);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    vaultRevision.removeListener(_scheduleDebouncedPush);
    _pushDebounce?.cancel();
    super.dispose();
  }

  void _scheduleDebouncedPush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(seconds: 3), () => unawaited(runBackgroundSync()));
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
      // 回到前台顺手拉一次云同步(`triggerBackgroundSync` 没登录/没开通云同步
      // 时 no-op)——见 Task 15 brief:app-resume pull。
      unawaited(runBackgroundSync());
    }
  }


  /// [cold] = App 是被这条链接**拉起来的**(而不是已在运行时收到)。这个区分是
  /// 认领转化里最关键的一维:冷启动基本意味着「刚装完就来认领」。
  bool _dispatch(String raw, {bool cold = false}) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    // 授权链接(`g1.`)先试——两种深链共用同一个 `/claim/` 路径,谁认得算谁的,
    // 互不影响(见 `grant_link.dart` 顶部文档)。
    final g = GrantLink.tryParse(uri);
    if (g != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!await FirstRunConsent.hasAgreed()) {
          _pendingGrant = (g, cold);
          return;
        }
        pushGrantRedeem(g, cold: cold);
      });
      return true;
    }
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

/// [VaultBootstrap] 开箱失败时该显示的标题/正文——纯函数,不碰 UI/IO,方便在
/// 不加载 Rust 原生库的 `flutter test` 里钉住(见
/// `test/vault_bootstrap_error_text_test.dart`)。
///
/// [ProfileLocked] 是一个**已知、可操作**的状态(账号没解锁),不是"箱子坏了"——
/// 「请重启 App 再试」对它是错误建议(重启不会解锁账号),所以单独给一条不带那句
/// 建议的文案。
///
/// C4:标题原来是「需要解锁账号」—— "解锁"和"账号"都是我们自己的词。用户要做的
/// 事只有一件:输口令。正文由 [ProfileLocked] 自己说(它也改过了,见那边的注释)。
@visibleForTesting
({String title, String body}) vaultBootstrapErrorText(Object error) {
  if (error is ProfileLocked) {
    return (title: '需要你的口令', body: '$error');
  }
  return (title: '无法打开你的健康档案', body: '$error\n\n请重启 App 再试。');
}

/// [ProfileLocked] 错误屏专用的两个动作:「去登录」「切换成员」——见 Task 15
/// review C1:退出登录/换设备清过 secure storage 之后,已开通云同步的成员会
/// 变成这个状态,原来这一屏没有任何按钮,用户只能卡死在这儿。
///
/// 拆成独立 widget(而不是内联在 `VaultBootstrap.build` 里)是为了让它能在
/// `flutter test` 里单独测——`VaultBootstrap._open` 会真的调 FFI 开箱,测试
/// 没法把整个 `VaultBootstrap` 逼进错误状态,但"点了这两个按钮该发生什么"跟
/// 开箱成不成功无关,可以单独钉住(同 [vaultBootstrapErrorText] 被拆成纯函数
/// 单测的道理)。
@visibleForTesting
class ProfileLockedActions extends StatelessWidget {
  const ProfileLockedActions({
    super.key,
    required this.onDone,
    this.accountFlow,
    this.switchTo,
    this.purgeExpired,
  });

  /// 「去登录」/「切换成员」那次导航结束(用户返回)之后调——生产代码传
  /// `_VaultBootstrapState._retry`,让这一屏重跑一次开箱(登录/切换成功的话,
  /// 这次就该成功了)。
  final VoidCallback onDone;

  /// 测试注入点,默认为 null——真正用的时候现取现建真实的 [AccountFlow]。
  final AccountFlow? accountFlow;

  /// 透传给 [showMemberSwitcherSheet] 的测试注入点(同名参数),默认为 null
  /// 时用它自己的真实默认值。
  final Future<void> Function(String id)? switchTo;
  final Future<List<Profile>> Function()? purgeExpired;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: MedShape.s4),
        FilledButton(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AccountScreen(
                  flow: accountFlow ??
                      AccountFlow(
                        ApiClient.forSession(AccountSession.instance),
                        AccountSession.instance,
                      ),
                  onReadyCloudSync: runBackgroundSync,
                ),
              ),
            );
            // 登录/解锁成功时 `AccountFlow.restoreProfileKeys` 已经把这个成员
            // 锁着的密钥补回来了(见 account_flow.dart)——但这一屏自己的
            // `_open` 早就 resolve 过一次错误,不会自动感知,回来之后必须
            // 显式重试一次开箱。
            onDone();
          },
          child: const Text('去登录'),
        ),
        const SizedBox(height: MedShape.s2),
        OutlinedButton(
          onPressed: () async {
            await showMemberSwitcherSheet(context, switchTo: switchTo, purgeExpired: purgeExpired);
            onDone();
          },
          child: const Text('切换成员'),
        ),
      ],
    );
  }
}

/// 冷启动的顺序本体:**先把本机账号态读回来,再开箱**。三个副作用抽成参数,只为
/// 让这条顺序契约能在不加载 Rust 原生库的 `flutter test` 里被钉住(同
/// `vault_boot.runWipeSequence`/`switchProfileAndReopenImpl` 的套路);产品代码里
/// 唯一的调用点是 [_VaultBootstrapState._bootOpen],传的永远是真实现。
///
/// ## 为什么顺序是硬的(最终评审 C1)
///
/// `AccountSession.ensureLoaded()` 此前**在产品代码里一次都没有被调用过**——
/// `accountId`/`access`/`privateKey`/`loggedIn` 全部是进程内的内存态,冷启动后
/// 一律是 null/false,尽管它们都躺在 shared_preferences / Keychain 里。后果不是
/// "某个界面显示得不对",而是整套云功能在每次冷启动后**等于不存在**:
///
/// * `openCurrentProfileVault` 靠 `AccountSession.profileKey()` 选开箱路径
///   (见 `vault_boot.planVaultOpen`)——读不到密钥,每个已开通云同步的成员都被
///   判成 `ProfileLocked`,用户开机看到的是"需要解锁账号"的死胡同;
/// * `triggerBackgroundSync` 第一句就是 `session.loggedIn.value`——恒 false,
///   debounce push 和 app-resume pull 永远 no-op;
/// * `AccountFlow.resumeIfLoggedIn()` 看 `session.accountId == null` 就返回
///   null,账号屏永远停在"手机号登录"那一屏,哪怕昨天刚登录过。
///
/// 所以它必须在**开箱之前**、也就在任何一屏 `resumeIfLoggedIn()` 之前跑完。
///
/// ## B6:`restoreProfileKeys` 也要在启动时跑
///
/// 它原来只在「账号屏登录/解锁成功」那一刻跑过一次。于是:家人刚把一份档案授权
/// 给你、或者你在另一台手机上加了个成员 —— 这台手机要等你**下一次进账号屏重新
/// 登录**才看得见。用户的心智是"打开 App 就该是最新的",而不是"去设置里戳一下
/// 账号"。
///
/// **不 await 它**(评审 Important 3)。它第一件事是一次网络请求,而 `Net.connect`
/// 是 20 秒、`Net.idle` 是 30 秒 —— 单单一个 `GET /v1/profiles` 就能把启动画面按住
/// 约 50 秒,而且没有任何进度提示。
///
/// 这里**不再包一层 `.timeout()`**(复审新问题 4):既然没人 await 这个 Future,
/// 那个超时不改变任何行为,只留下一个没人取消的 pending Timer。真正的超时下沉到
/// `AccountFlow.restoreProfileKeys` 里那一次 `getJson` 上(见
/// `account_flow.profilesFetchBudget`),在那儿它是真的。
///
/// 排在开箱**之后**(而不是和它并发):它会 `create()`/`switchTo` 动
/// `ProfileManager.currentId`,而 `openCurrentProfileVault` 读的正是 `current` ——
/// 并发跑有一个真实的窗口会开错箱子。放在 `finally` 里是因为**开箱失败恰恰是最需要
/// 它的时候**(`ProfileLocked` = 本机缺档案密钥,而补密钥正是它干的事)。
///
/// 失败也不许挡住启动:它对网络失败本来就静默(见
/// `AccountFlow.restoreProfileKeys`),这里再包一层 `catchError`,任何没预料到的
/// 失败都不该把用户摆在一个"无法打开你的健康档案"的错误屏上。
@visibleForTesting
Future<void> runBootSequence({
  required Future<void> Function() restoreAccountSession,
  required Future<void> Function() openVault,
  required Future<void> Function() loadMode,
  required Future<void> Function() restoreProfileKeys,
}) async {
  await restoreAccountSession();
  try {
    // 开箱与读模式互不依赖,并发跑不拖慢启动。
    await Future.wait([openVault(), loadMode()]);
  } finally {
    unawaited(restoreProfileKeys().catchError((_) {}));
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
  /// 读回账号态、打开「当前成员」的保险箱(多成员见 profile_manager / vault_boot)、
  // 读「个人/医生」模式选择(`AppRoot` 据此决定先显示哪个根界面)。顺序契约见
  // [runBootSequence]。
  late Future<void> _open;

  /// `app_open` 只该报这一次启动的第一次结果——[_retry] 让 `ProfileLocked`
  /// 错误屏可以在"去登录"/"切换成员"之后重试开箱,但那不是一次新的 App 启动,
  /// 不该再报一条 `app_open`(那条事件是 DAU 基线,重试会把它污染成好几条)。
  bool _reportedAppOpen = false;

  @override
  void initState() {
    super.initState();
    _open = _bootOpen();
  }

  Future<void> _bootOpen() async {
    var ok = true;
    try {
      await runBootSequence(
        restoreAccountSession: AccountSession.instance.ensureLoaded,
        openVault: openCurrentProfileVault,
        loadMode: AppMode.instance.ensureLoaded,
        restoreProfileKeys: () async {
          // `restoreProfileKeys` 自己刻意不调 `ensureLoaded()`(见它的文档:那条
          // 路径在 widget 测试里会卡死),所以在这里先把成员表读回来 —— 不先读的话
          // 它会拿那份还没落地的内存默认值去判"本机有没有这个云成员",把已有的
          // 成员又建一遍。
          await ProfileManager.instance.ensureLoaded();
          await AccountFlow(
            ApiClient.forSession(AccountSession.instance),
            AccountSession.instance,
          ).restoreProfileKeys();
          // 它只**登记**哪些成员要跑首同步(`sync_engine.pendingFirstSync`),
          // 真正的同步在这里交给后台触发器 —— 不在启动路径上串行跑 N 个完整同步。
          unawaited(runBackgroundSync());
        },
      );
    } catch (_) {
      ok = false;
      rethrow; // 错误界面照旧显示,埋点只是搭个便车
    } finally {
      if (!_reportedAppOpen) {
        _reportedAppOpen = true;
        vaultOpenedOkThisLaunch = ok; // 首启同意页补发 app_open 时要读(见 vault_boot.dart)
        // `app_open` 发在这里而不是 `main()`:要带上模式和「箱子开没开成」。
        // **开箱失败此前是完全不可见的** —— 用户只看到一句红字,我们什么都不知道。
        await Analytics.init(); // 已在 main 里跑着,这里只是等同一个 Future
        Analytics.setContext({
          'mode': AppMode.instance.mode.value?.name ?? 'unset',
        });
        Analytics.track(AnalyticsEvent.appOpen, {'vault_ok': ok});
      }
    }
  }

  /// `ProfileLocked` 错误屏「去登录」/「切换成员」返回之后重跑一次开箱——
  /// 见 Task 15 review C1:原来这颗 `Future` 只在 `initState` 建一次,登录/
  /// 补密钥或切成员成功之后箱子其实已经能开了,但这一屏靠 `FutureBuilder`
  /// 监听同一个 `Future`,它早就 resolve(带着错误)了,不会自己刷新——用户
  /// 会被困死在这一屏里出不去。
  void _retry() {
    if (!mounted) return;
    // 语句块,不是箭头体——`setState(() => _open = _bootOpen())` 是仓库里明确
    // 禁止的写法(见 `test/known_defect_setstate_future_test.dart`):箭头体的
    // 赋值在 debug 断言判定"返回了 Future"之前就已经发生,断言抛在
    // `markNeedsBuild()` 之前,于是这次赋值没有触发任何一次重建。
    final next = _bootOpen();
    setState(() {
      _open = next;
    });
  }

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
          final error = snap.error!;
          final text = vaultBootstrapErrorText(error);
          // `ProfileLocked` 是一个**可操作**的死胡同(见 Task 15 review C1):
          // 退出登录/换设备清过 secure storage 之后,已开通云同步的成员会变成
          // 这个状态——之前这一屏没有任何按钮,用户只能卡在这儿,连"去登录把
          // 密钥补回来"都做不到,等于把 App 锁死。其它种类的开箱失败(箱子真的
          // 坏了)不给这两个按钮——它们解决不了"文件系统/数据库坏了"这件事。
          final locked = error is ProfileLocked;
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
                    //
                    // `ProfileLocked`(账号没解锁)单独一套文案——见
                    // [vaultBootstrapErrorText]:「请重启 App 再试」对这个状态是
                    // 错误建议,重启解决不了没解锁账号这件事。
                    Text(
                      text.title,
                      style: MedType.subtitle.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: MedShape.s1),
                    Text(
                      text.body,
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                    ),
                    if (locked) ProfileLockedActions(onDone: _retry),
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
          final pendingGrant = takePendingGrant();
          if (pendingGrant != null) {
            pushGrantRedeem(pendingGrant.$1, cold: pendingGrant.$2);
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

/// 底部导航壳:**三个一级 tab**(mockup,创始人拍板)。
///
/// | tab | 用户在干什么 |
/// |---|---|
/// | 病历 | 拍/添加一份,以及回头找某一张 |
/// | 趋势 | 这个病现在怎么样、吃过什么药、该查没查 |
/// | 我 | 云端、成员、口令与恢复码、设置 |
///
/// ## 四处刻意的缺席
///
/// **「给医生看」不是 tab** —— 它是「病历」首页那颗主按钮推进去的一整页。
/// ⚠️ ia-proposal §2 推荐的恰恰相反(候选 A 把它放进底栏,并写明拒绝候选 B 的
/// 理由是「老人在底栏找不到它」)。mockup 改了主意,**执行按 mockup**;
/// 那条风险在模拟器冒烟里验(Task 19)。
///
/// **「应急卡」不再是 tab**,是「给医生看」那一页里的一条。降的是位置不是质量:
/// `EmergencyBigCardScreen` 大字模式一字未动。
///
/// **「概览」整屏解散**:成员卡进「我」,化验快照与最近就诊进「趋势」,最近添加
/// 与「病历」tab 重复,三颗快捷操作各归各位。
///
/// **「趋势」保留原名**,不叫「看懂」——「病程档案」的入口位落在它里面。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// 三个 tab 的页面,顺序必须与 [HomeTab] 的常量逐一对应 —— `IndexedStack` 按
  /// 下标取,错一位就是点「趋势」进了「我」。
  ///
  /// 与 [tabDestinations] 一起公开是为了让 `test/mobile_ia_test.dart` 能钉住
  /// 「页面数 == 底栏项数 == [HomeTab.count]」。
  static const List<Widget> tabScreens = [
    ArchiveScreen(),
    TrendsScreen(),
    SettingsScreen(),
  ];

  /// 底栏三项,顺序同 [tabScreens]。
  static const List<NavigationDestination> tabDestinations = [
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: '病历',
    ),
    NavigationDestination(
      icon: Icon(Icons.show_chart_outlined),
      selectedIcon: Icon(Icons.show_chart),
      label: '趋势',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: '我',
    ),
  ];

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = HomeTab.records;

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
  /// 后者也接程序化跳转(`goToRecords()`、载入示例后的「去看看」),那是别的功能
  /// 的副作用,不是用户想去哪。混进来会把一个功能的成功记成另一个 tab 的人气,
  /// 而这条事件存在的全部意义正是「三个席位该给谁」。
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

/// 授权链接落地屏:家属/医生扫码进来,问一句「要不要加进你的 MedMe」,答应了才
/// 兑换。**未登录先走账号屏**——兑换需要账号密钥对(封回自己的公钥),没有账号
/// 无从谈起;登录/解锁完成后回到这一屏继续兑换,不用重新点一次链接。
class GrantRedeemScreen extends StatefulWidget {
  const GrantRedeemScreen({super.key, required this.link, this.cold = false, this.grants});
  final GrantLink link;

  /// App 是被这条链接拉起来的(冷启动),而不是已在运行时收到。同 `ClaimScreen`,
  /// 目前只留作将来埋点用,不影响这一屏的行为。
  final bool cold;

  /// 测试注入点,默认为 null——真正用的时候现取现建。`Grants.redeem` 末尾会碰
  /// 真实 Rust 原生库(开箱、首同步),`flutter test` 没法伪造,测试传一个整体
  /// 重写了 `redeem` 的子类进来(见 `test/grant_redeem_screen_test.dart`)。
  final Grants? grants;

  @override
  State<GrantRedeemScreen> createState() => _GrantRedeemScreenState();
}

class _GrantRedeemScreenState extends State<GrantRedeemScreen> {
  bool _busy = false;
  String? _error;
  Profile? _done;

  Future<void> _accept() async {
    if (!AccountSession.instance.loggedIn.value) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AccountScreen(
            flow: AccountFlow(
              ApiClient.forSession(AccountSession.instance),
              AccountSession.instance,
            ),
            onReadyCloudSync: runBackgroundSync,
          ),
        ),
      );
      if (!mounted || !AccountSession.instance.loggedIn.value) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final grants = widget.grants ??
          Grants(
            ApiClient.forSession(AccountSession.instance),
            AccountSession.instance,
          );
      final p = await grants.redeem(widget.link);
      if (mounted) setState(() => _done = p);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('加入档案')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _done != null ? _result(_done!) : _confirm(),
        ),
      ),
    );
  }

  Widget _confirm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 这一步只有 inviteId/token,角色(viewer/owner/editor)由服务端在兑换那
        // 一刻才揭晓(见 `redeem` 的响应)——文案不能替它先猜一个,猜错了(比如
        // 这其实是一条转移邀请)就是当场说瞎话。角色相关的措辞留到 [_result]。
        const Text(
          '要接受对方分享的病历档案吗?',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        // C5:这一屏原来只有上面那一句问话 —— 用户不知道点下去会发生什么。
        // 说得出的只有"会看到对方的病历"这一件事;**具体权限真的还不知道**
        // (见上面的注释:角色由服务端在兑换那一刻才揭晓),所以照实说"下一步
        // 告知",而不是替它猜一个。
        const Text(
          '接受之后,这份病历会出现在你的 MedMe 里;具体是只能看还是能一起录,'
          '下一步告诉你。',
          style: TextStyle(color: Colors.black54, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _accept,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('加入'),
        ),
      ],
    );
  }

  Widget _result(Profile p) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle, color: Colors.teal, size: 56),
        const SizedBox(height: 16),
        Text(_resultHeadline(p), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          _resultSubtitle(p),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('好'),
        ),
      ],
    );
  }

  /// 结果页标题——按**实际拿到的角色**说话,不是兑换前猜的那句。owner(代拍
  /// 转移)是「成为主人」,其余(viewer/editor)是普通的「加入档案」。
  String _resultHeadline(Profile p) =>
      p.role == 'owner' ? '你已成为「${p.name}」档案的主人' : '已加入「${p.name}」的档案';

  String _resultSubtitle(Profile p) {
    if (p.role == 'owner') return '这份档案现在完全归你所有,原来的账号已自动降为编辑权限。';
    final exp = p.expiresAt;
    if (p.role == 'viewer' && exp != null) return '只读,至 ${exp.month}月${exp.day}日';
    return p.role == 'editor' ? '可以一起录入,长期有效。' : '';
  }
}
