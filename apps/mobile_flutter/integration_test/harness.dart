// 集成测试公共脚手架。
//
// ## 为什么不是 Patrol
//
// 仓库里原有的四个 `integration_test/*.dart` 用的是 `patrolTest`,而 `patrol`
// 的原生自动化需要 `android/app/src/androidTest/` 那一套 instrumentation 脚手架
// —— 本仓库没有(`patrol bootstrap` 会改 gradle 配置,属于动构建产物)。而且
// `patrolTest` 在 `flutter test integration_test/... -d <device>` 下会直接崩在
// 绑定初始化:
//
//     Binding is already initialized to IntegrationTestWidgetsFlutterBinding
//     package:patrol/src/binding.dart  new PatrolBinding.ensureInitialized
//
// 所以这批测试改走 `integration_test` 官方路径:
//
//     flutter test integration_test/<file>.dart -d emulator-5554
//
// 代价是拿不到原生弹窗(系统权限框/相机/文件选择器)的控制权 —— 这批用例本来
// 也刻意不触发那些流程(会拉起系统 UI,在 CI 上必挂)。
//
// ## 三条这里踩过的坑,别再踩
//
// 1. **`pumpAndSettle` 会超时。** 这个 app 的加载态是 `CircularProgressIndicator`,
//    它永远在动 → 永远有下一帧 → `pumpAndSettle` 等到天荒地老。用 [waitFor]:
//    定时 pump 并轮询 finder。
// 2. **RenderFlex 溢出抓不到。** 溢出走 `FlutterError.reportError`,不是抛异常,
//    `tester.takeException()` 是空的。用 [OverflowWatch] 挂 `FlutterError.onError`。
// 3. **真实病历箱是进程级单例且落盘。** 每个用例之间必须 [resetEverything],
//    否则上一个用例灌的 60 条血压会污染下一个用例的空态断言。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/main.dart' as app;
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/frb_generated.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';

bool _rustReady = false;

/// Rust 侧是进程级单例,`RustLib.init()` 调第二次会抛。
Future<void> ensureRust() async {
  if (_rustReady) return;
  await RustLib.init();
  _rustReady = true;
}

/// 把设备恢复成「刚装完 App、同意过、选了个人模式、病历箱空」的状态。
///
/// 同意门走 `SharedPreferences.setMockInitialValues`(进程内内存实现),模式与
/// 病历箱走真实落盘 —— 后两者没有 mock 层,而它们正是这批用例要测的东西。
Future<void> resetEverything() async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'consent_agreed_v1': true,
    'analytics_consent_asked': true,
    'analytics_enabled': false,
  });
  await ensureRust();
  await AppMode.instance.chooseMode(AppModeKind.personal);
  await wipeAllData();
  // `wipeAllData()` 自己就保证「清完之后进程里开着一个真实存在的空箱子」
  // (顺序契约见 `vault_boot.dart` 的 `runWipeSequence`)。这里**不再补一次
  // `openCurrentProfileVault()`** —— 那一句原本是在绕开 BUG-3,而 BUG-3 已修。
  // 补回去会把这条契约重新藏起来:真机上清空之后写不进东西,测试里却看不见。
  selectedTab.value = HomeTab.records;
}

/// 起 App 并等到底栏出现(即已过同意门与开箱)。
Future<void> bootApp(WidgetTester tester, {bool reset = true}) async {
  if (reset) await resetEverything();
  installKnownDefectFilter();
  addTearDown(removeKnownDefectFilter);
  await tester.pumpWidget(const app.MedMeApp());
  await waitFor(tester, find.byType(NavigationBar));
  await settle(tester);
}

/// 轮询式等待:每 100ms pump 一帧,直到 [finder] 命中或超时。
///
/// 替代 `pumpAndSettle` —— 见文件头第 1 条。
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 40),
  String? what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('等待超时($timeout):${what ?? finder.toString()}');
}

/// 等到 [finder] 消失。
Future<void> waitGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String? what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('等待消失超时($timeout):${what ?? finder.toString()}');
}

/// 固定帧数的「安定」——不等到无帧可调度(那永远等不到),只把当前这一批
/// 动画/异步跑完。
Future<void> settle(
  WidgetTester tester, {
  Duration total = const Duration(milliseconds: 1200),
}) async {
  final step = const Duration(milliseconds: 60);
  for (var i = 0; i < total.inMilliseconds ~/ step.inMilliseconds; i++) {
    await tester.pump(step);
  }
}

/// 切到某个一级 tab(直接写 `selectedTab`,与手点同一条路径 —— 见 `HomeShell`)。
///
/// **先把推上去的二级页收回来**:Stage 1 之后「给医生看」「急救卡」「关于」
/// 「导出文件」都是 `push` 进去的整页,而 `selectedTab` 只换底栏那一层 ——
/// 不先 pop,后面的断言会对着盖在上面的那一页查底下那一屏,红得驴唇不对马嘴。
/// 真人点底栏时手指也够不到被盖住的底栏,这一步就是把那件事补上。
Future<void> gotoTab(WidgetTester tester, int tab) async {
  await popToShell(tester);
  selectedTab.value = tab;
  await settle(tester);
}

/// 把 `push` 上去的二级页全部收回来,回到底栏那一层。
///
/// **不能用 `find.byType(NavigationBar)` 判断「回来了没有」** —— 被盖住的那条
/// 路由仍然留在 widget 树里(`maintainState`),底栏一直找得到。只有问导航器
/// 自己 `canPop()` 才是真的。
Future<void> popToShell(WidgetTester tester) async {
  final navFinder = find.byType(Navigator);
  if (navFinder.evaluate().isEmpty) return;
  final nav = tester.state<NavigatorState>(navFinder.first);
  for (var i = 0; i < 8 && nav.canPop(); i++) {
    nav.pop();
    await settle(tester);
  }
}

/// 在当前屏的第一个可滚动区域里往下翻,直到 [finder] 命中(或翻到底)。
///
/// `ListView` 只构建可视区附近的子项,所以「屏下面那一节」在 widget 树里**根本
/// 不存在**,`find` 找不到不代表它没渲染 —— 这是 finder 超时最常见的假警报。
Future<bool> scrollToFind(
  WidgetTester tester,
  Finder finder, {
  int maxSwipes = 15,
}) async {
  for (var i = 0; i < maxSwipes; i++) {
    if (finder.evaluate().isNotEmpty) return true;
    final list = find.byType(Scrollable);
    if (list.evaluate().isEmpty) return false;
    await tester.drag(list.first, const Offset(0, -400), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 120));
  }
  return finder.evaluate().isNotEmpty;
}

/// 与 [scrollToFind] 相反:**往回翻**,直到 [finder] 命中(或翻到顶)。
///
/// 为什么不能只靠 [scrollToTop]:那是固定次数的「翻几下」,灌了 280 条之后
/// 「病历」列表几千像素长,十二下翻不回去 —— 于是 hero 卡下面那两颗方块仍然
/// 不在可视区,`find` 找不到,报出来的却是「等待超时」这种看不出所以然的话。
Future<bool> scrollUpToFind(
  WidgetTester tester,
  Finder finder, {
  int maxSwipes = 60,
}) async {
  for (var i = 0; i < maxSwipes; i++) {
    if (finder.evaluate().isNotEmpty) return true;
    final list = find.byType(Scrollable);
    if (list.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 120));
      continue;
    }
    await tester.drag(list.first, const Offset(0, 600), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
  }
  return finder.evaluate().isNotEmpty;
}

/// 把当前屏的第一个可滚动区域拉回顶部。
///
/// tab 是保活的:上一段测试把「病历」滚到底之后,切走再切回来它**还停在底部**,
/// 于是 hero 卡下面那两颗方块(`添加` / `给医生看`)不在可视区、`ListView` 也就
/// 没构建它们,`find` 直接找不到。这不是 bug,是没滚回去。
Future<void> scrollToTop(WidgetTester tester, {int swipes = 12}) async {
  for (var i = 0; i < swipes; i++) {
    // **每一轮都重新判一次**:浮层关闭动画期间可能一个 `Scrollable` 都没有,
    // 而 `find.byType(...).first` 在那一刻求值会直接 `Bad state: No element`。
    final list = find.byType(Scrollable);
    if (list.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 120));
      continue;
    }
    await tester.drag(list.first, const Offset(0, 500), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 80));
  }
  await settle(tester);
}

/// 点底栏上的某个 tab(走真实手势,验证底栏本身)。
Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  ));
  await settle(tester);
}

/// 收集 `FlutterError.onError` 上报的错误(RenderFlex 溢出走这条路,**不是**
/// 抛异常,所以 `tester.takeException()` 抓不到)。
///
/// **只吞溢出,别的一律往上转发。**
///
/// 溢出要吞:这批用例要的是「跑完一整轮字号 × 三个 tab,再一次性报出全部溢出
/// 点」,而不是撞上第一个就停 —— 断言在 [assertClean] 里显式做。
///
/// 别的绝不能吞。第一版把**所有** `FlutterError` 都收进列表不转发,结果是:测试
/// 里真的抛了个异步异常,`flutter_test` 的 `handleUncaughtError` 发现自己的
/// `_pendingExceptionDetails` 是空的,直接断言失败并把整个 run 卡死 ——
///
///     Failed assertion: '_pendingExceptionDetails != null': A test overrode
///     FlutterError.onError but either failed to return it to its original
///     state, or had unexpected additional errors that it could not handle.
///
/// 表现是「测试跑到一半不动了」,而真正的错误一个字都看不到。
class OverflowWatch {
  OverflowWatch(this.label);

  final String label;
  final List<String> hits = [];
  FlutterExceptionHandler? _prev;
  bool _on = false;

  void start() {
    if (_on) return;
    _prev = FlutterError.onError;
    FlutterError.onError = (details) {
      final s = details.exceptionAsString();
      if (s.contains('overflowed by')) {
        // 光有「溢出了 31 像素」定位不到任何东西。`details` 的完整诊断里带着
        // 出事的 `RenderFlex` 本身、它的约束、以及 debug 构建下 widget 的创建
        // 位置(文件 + 行号)—— 那才是能直接去改的信息。
        final full = details
            .toDiagnosticsNode()
            .toStringDeep(minLevel: DiagnosticLevel.info);
        hits.add('[$label] $s\n${_trim(full)}');
        return;
      }
      _prev?.call(details); // 真错误照常让 flutter_test 判失败
    };
    _on = true;
  }

  /// 诊断树很长,只留能定位的那几行。
  static String _trim(String full) {
    final keep = full
        .split('\n')
        .where((l) =>
            l.contains('RenderFlex') ||
            l.contains('creator:') ||
            l.contains('overflowed') ||
            l.contains('constraints:') ||
            l.contains('.dart:'))
        .take(14);
    return keep.map((l) => '      ${l.trim()}').join('\n');
  }

  void stop() {
    if (!_on) return;
    FlutterError.onError = _prev;
    _on = false;
  }

  /// 收到的溢出(去重后)。
  Set<String> get overflows => {...hits};

  void assertClean() {
    // ⚠️ **先摘钩子再断言。** `fail()` 抛的 `TestFailure` 会被 `flutter_test`
    // 拿去走 `FlutterError.reportError`;钩子还挂着的话它会被这里吞掉,于是
    // `handleUncaughtError` 断言 `_pendingExceptionDetails != null` 失败,
    // 真正的溢出清单一个字都看不到(踩过一次)。
    stop();
    if (hits.isEmpty) return;
    final buf = StringBuffer('[$label] 捕获 ${overflows.length} 处 RenderFlex 溢出:\n');
    for (final h in overflows) {
      buf.writeln('  · $h');
    }
    fail(buf.toString());
  }
}

/// ── 曾经的「已知缺陷挡板」,现在是一道守卫 ────────────────────────────
///
/// 这里原本挡着 BUG-1(`emergency_card_screen.dart` 的
/// `setState(() => _future = _load())` —— 箭头体,返回的是一个 `Future`)。全部
/// tab 由 `IndexedStack` 一次性挂载,那个监听器从冷启动第一帧就活着,于是
/// **任何一次 `bumpVaultRevision()`(录一条、导入、清空、载入示例)都会踩到它**,
/// 不挡就会把每一条「存了东西之后再断言」的用例都染红。
///
/// BUG-1 与 BUG-4 都已修(两屏各自改成语句块 setState),所以名单**清空了**,
/// 这段代码的角色随之反转:它不再吞任何东西,而是**数**这类签名还出不出现。
/// [assertNoKnownDefects] 一旦非零就说明它回来了 —— 挡板变守卫,签名一条都不删,
/// 因为「这类异常曾经在这里发生过」正是要守住的知识。
const kKnownDefects = <String>[
  'setState() callback argument returned a Future',
];

int knownDefectHits = 0;
final knownDefectSeen = <String>[];
FlutterExceptionHandler? _knownDefectPrev;

/// 安装守卫(`bootApp` 自动调)。
///
/// ⚠️ **只看「框架内部报上来的」那一路,绝不碰测试框架自己的失败上报。**
/// `ChangeNotifier.notifyListeners` 会把监听器抛的异常包成
/// `FlutterErrorDetails(library: 'widgets library')` 交给 `FlutterError.onError`
/// —— BUG-1 当初走的就是这条。
///
/// 但 `flutter_test` 判定用例失败时**也**走 `FlutterError.reportError`,只是
/// `library` 是 `'Flutter test framework'`。第一版没区分,把它也吞了,于是
/// `handleUncaughtError` 发现 `_pendingExceptionDetails` 还是 null,直接断言炸
/// 并把整个 run 卡死 —— 真正的错误一个字看不到。按 `library` 分流。
///
/// 现在**只记不吞**:记完照样往下传,该红的用例照红。
void installKnownDefectFilter() {
  if (_knownDefectPrev != null) return;
  knownDefectHits = 0;
  knownDefectSeen.clear();
  _knownDefectPrev = FlutterError.onError;
  FlutterError.onError = (details) {
    final s = details.exceptionAsString();
    if (details.library != 'Flutter test framework') {
      for (final sig in kKnownDefects) {
        if (s.contains(sig)) {
          knownDefectHits++;
          knownDefectSeen.add(sig);
          debugPrint('[已修缺陷复发 #$knownDefectHits] $sig');
        }
      }
    }
    _knownDefectPrev?.call(details);
  };
}

void removeKnownDefectFilter() {
  if (_knownDefectPrev == null) return;
  FlutterError.onError = _knownDefectPrev;
  _knownDefectPrev = null;
}

/// 本条用例跑下来,没有一条已修缺陷的签名再出现过。
void assertNoKnownDefects() {
  expect(
    knownDefectHits,
    0,
    reason: '已修缺陷复发:${knownDefectSeen.toSet().join('、')}\n'
        '见 `vault_boot.dart` / 两屏 `_refresh()` 的注释,以及 '
        '`test/known_defect_setstate_future_test.dart`。',
  );
}

/// 在指定系统字号倍数下跑一段操作。用 `TestPlatformDispatcher` 的
/// `textScaleFactorTestValue` —— 与 `adb shell settings put system font_scale`
/// 等效,但可在用例内精确控制、可复现。
Future<void> withTextScale(
  WidgetTester tester,
  double scale,
  Future<void> Function() body,
) async {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  await tester.pump();
  try {
    await body();
  } finally {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump();
  }
}

/// 当前成员名(调试输出用)。
String get currentMemberName => ProfileManager.instance.current.name;

/// 三个一级 tab 的标签,顺序同 `HomeTab`。
const tabLabels = ['病历', '趋势', '我'];

/// 「病历」→ hero 卡下面那颗白底方块「给医生看」→ 整页(`s4`)。
///
/// 这颗方块是「给医生看」**全 App 唯一的入口**(它不是 tab,见
/// `global-constraints.md` 的 mockup 决定)。
Future<void> gotoForDoctor(WidgetTester tester) async {
  await gotoTab(tester, HomeTab.records);
  if (!await scrollUpToFind(tester, find.text('给医生看'))) {
    throw TestFailure('「病历」首页翻回顶部也找不到那颗「给医生看」方块');
  }
  await tester.tap(find.text('给医生看').first);
  await settle(tester, total: const Duration(seconds: 3));
  await waitFor(
    tester,
    find.descendant(of: find.byType(AppBar), matching: find.text('给医生看')),
    timeout: const Duration(seconds: 60),
    what: '「给医生看」整页',
  );
  // 正文是异步投影(`viewVisitSummary` 走 FFI),等它画出来再让调用方断言。
  await waitFor(tester, find.text('我想问医生的'),
      timeout: const Duration(seconds: 60), what: '「给医生看」正文');
}

/// 「急救卡」在 Stage 1 已从底栏撤下 —— 现在它是「给医生看」那一页里**跟着正文
/// 一起滚**的第二行(`ForDoctorActions`),所以要先进那一页再往下翻。
Future<void> gotoEmergencyCard(WidgetTester tester) async {
  await gotoForDoctor(tester);
  final found = await scrollToFind(tester, find.text('急救卡'));
  if (!found) throw TestFailure('「给医生看」那一页里翻不到「急救卡」这一行');
  await tester.tap(find.text('急救卡').last);
  await settle(tester, total: const Duration(seconds: 3));
  // 等顶栏,**不要等「过敏史」** —— 空过敏史那一节的标题是「过敏史(未识别)」
  // (产品拍板:app 永远不能宣称「没有过敏」),`find.text` 是精确匹配,等不到。
  await waitFor(
    tester,
    find.descendant(of: find.byType(AppBar), matching: find.text('急救卡')),
    timeout: const Duration(seconds: 60),
    what: '急救卡整屏',
  );
}

/// 「病历」→「添加」→「记录一下」→ 录入弹层(`s9`)。
///
/// 这颗入口原来是「趋势」页自己的 `RecordEntryCard`,Task 5 挪进了「病历」tab
/// 「添加」三选一变四选一的第四项(`import_flow.dart` 的 `AddSheetBody`)——
/// 自己量的数和医院的数走同一个添加入口。
Future<void> openRecordSheet(WidgetTester tester) async {
  await gotoTab(tester, HomeTab.records);
  if (!await scrollUpToFind(tester, find.text('添加'))) {
    throw TestFailure('「病历」翻回顶部也找不到「添加」');
  }
  await tester.tap(find.text('添加').first);
  await settle(tester, total: const Duration(seconds: 2));
  await waitFor(tester, find.text('记录一下'), what: '「添加」弹层里的「记录一下」');
  await tester.tap(find.text('记录一下').last);
  await settle(tester, total: const Duration(seconds: 2));
  await waitFor(tester, find.text('保存'), what: '录入弹层的「保存」按钮');
}

/// 「我」→「关于 / 隐私政策」那一层。
///
/// Task 17 之后「载入示例数据」与「删掉全部 · 清空所有数据」都住在这一页,
/// 不再在「我」的首屏平铺(`s5`:首屏只留一行「关于 / 隐私政策 ›」)。
Future<void> gotoAbout(WidgetTester tester) async {
  await gotoTab(tester, HomeTab.me);
  final row = find.text('关于 / 隐私政策');
  // 成员多起来之后(名单卡按人长高)这一行会被顶到屏外,`ListView` 压根不构建它。
  // 先翻到它,再 `ensureVisible` 把它挪进 viewport —— 只 `find` 到不等于点得到,
  // 贴着下边缘的那一下会落在底栏上。
  if (!await scrollToFind(tester, row)) {
    throw TestFailure('「我」里翻不到「关于 / 隐私政策」');
  }
  await tester.ensureVisible(row);
  await settle(tester);
  await tester.tap(row);
  await settle(tester, total: const Duration(seconds: 2));
  await waitFor(
    tester,
    find.descendant(of: find.byType(AppBar), matching: find.text('关于')),
    what: '「我 → 关于」',
  );
}
