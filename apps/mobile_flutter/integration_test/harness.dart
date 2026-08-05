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
// 3. **真实保险箱是进程级单例且落盘。** 每个用例之间必须 [resetEverything],
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

/// 把设备恢复成「刚装完 App、同意过、选了个人模式、保险箱空」的状态。
///
/// 同意门走 `SharedPreferences.setMockInitialValues`(进程内内存实现),模式与
/// 保险箱走真实落盘 —— 后两者没有 mock 层,而它们正是这批用例要测的东西。
Future<void> resetEverything() async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'consent_agreed_v1': true,
    'analytics_consent_asked': true,
    'analytics_enabled': false,
  });
  await ensureRust();
  await AppMode.instance.chooseMode(AppModeKind.personal);
  await wipeAllData();
  // ⚠️ **这一句是在绕开 BUG-3,不是常规收尾。**
  //
  // `wipeAllData()` 的最后一步是 `rmDir('<docs>/profiles')` —— 而它前面第 2 步
  // 刚刚 `openCurrentProfileVault()` 把进程级 vault 开在 `<docs>/profiles/p-1/vault`。
  // 于是清空结束时,进程里开着的那个箱子的目录已经被删掉了,后续任何写入都是
  // `io: No such file or directory (os error 2)`。
  //
  // App 里 `_confirmAndResetVault` 清完只 `bumpVaultRevision()`,**没有重开**,
  // 所以真机上清空之后到重启之前一条都存不进去。见
  // `journey_known_defects_test.dart` 的 BUG-3。
  //
  // 测试里补开一次,免得每条用例都被这个缺陷带塌;BUG-3 由它自己的用例钉住。
  await openCurrentProfileVault();
  selectedTab.value = HomeTab.overview;
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
Future<void> gotoTab(WidgetTester tester, int tab) async {
  selectedTab.value = tab;
  await settle(tester);
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

/// 把当前屏的第一个可滚动区域拉回顶部。
///
/// tab 是保活的:上一段测试把概览滚到底之后,切走再切回来它**还停在底部**,
/// 于是「看病带这个」那条 banner 不在可视区、`ListView` 也就没构建它,`find`
/// 直接找不到。这不是 bug,是没滚回去。
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
/// 溢出要吞:这批用例要的是「跑完一整轮字号 × 五个 tab,再一次性报出全部溢出
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

/// ── 已知缺陷的全局挡板 ──────────────────────────────────────────────
///
/// **BUG-1(未修,只报告)**:`emergency_card_screen.dart:58` 的
/// `setState(() => _future = _load())` 是箭头函数,返回的是一个 `Future` ——
/// 概览/趋势/档案三屏都为这件事专门写成语句块并留了注释,只有应急卡漏了。
/// 五个 tab 全部由 `IndexedStack` 一次性挂载,所以这个监听器从冷启动第一帧就活着:
/// **任何一次 `bumpVaultRevision()`(录一条、导入、清空、载入示例)都会踩到它。**
///
/// 后果见 `journey_known_defects_test.dart` 里那条专门的用例。这里之所以要挡:
/// 不挡的话它会把每一条「存了东西之后再断言」的用例都染红,真正想测的东西反而
/// 看不见。**挡住 ≠ 修好** —— 每次命中都会打印出来。
const kKnownDefects = <String>[
  'setState() callback argument returned a Future',
];

int knownDefectHits = 0;
FlutterExceptionHandler? _knownDefectPrev;

/// 安装已知缺陷挡板(`bootApp` 自动调)。
///
/// ⚠️ **只挡「框架内部报上来的」那一路,绝不挡测试框架自己的失败上报。**
/// `ChangeNotifier.notifyListeners` 会把监听器抛的异常包成
/// `FlutterErrorDetails(library: 'widgets library')` 交给 `FlutterError.onError`
/// —— BUG-1 走的是这条,挡掉它才不会污染每一条用例。
///
/// 但 `flutter_test` 判定用例失败时**也**走 `FlutterError.reportError`,只是
/// `library` 是 `'Flutter test framework'`。第一版没区分,把它也吞了,于是
/// `handleUncaughtError` 发现 `_pendingExceptionDetails` 还是 null,直接断言炸
/// 并把整个 run 卡死 —— 真正的错误一个字看不到。按 `library` 分流。
void installKnownDefectFilter() {
  if (_knownDefectPrev != null) return;
  _knownDefectPrev = FlutterError.onError;
  FlutterError.onError = (details) {
    final s = details.exceptionAsString();
    final fromTestFramework = details.library == 'Flutter test framework';
    if (!fromTestFramework) {
      for (final sig in kKnownDefects) {
        if (s.contains(sig)) {
          knownDefectHits++;
          debugPrint(
              '[已知缺陷 #$knownDefectHits] $sig(见 harness.dart kKnownDefects)');
          return;
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

/// 五个一级 tab 的标签,顺序同 `HomeTab`。
const tabLabels = ['概览', '趋势', '档案', '应急卡', '设置'];
