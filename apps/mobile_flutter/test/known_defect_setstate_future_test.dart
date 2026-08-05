// 源码级回归钉:**`setState(() => …)` 的箭头体不许返回 `Future`。**
//
// ## 为什么是扫源码,而不是渲染断言
//
// 这个写法的后果只在 debug 断言开着时才出现,而它出现的方式恰好让测试抓不住:
//
//   · `emergency_card_screen.dart:58` 抛在 `ChangeNotifier.notifyListeners` 的
//     try/catch 里 → 只走 `FlutterError.onError`,能抓,已由
//     `integration_test/journey_known_defects_test.dart` 的 BUG-1 钉住;
//   · `visit_summary_sheet.dart:98` 抛在一个 `async` 方法里、由 `VoidCallback`
//     调起 → **未捕获的 zone 错误** → `flutter_test` 收到就把用例的 completer
//     以错误完成,测试体当场终止,`tester.takeException()` 那行执行不到,还会把
//     `LiveTestWidgetsFlutterBinding.postTest` 的 `_pendingFrame == null` 一起
//     带塌、污染同文件后面的用例。
//
// 也就是说:**驱动它就等于让用例必红**,可它又确实是个必须被记住的缺陷。所以
// 改成扫源码 —— 判据和根因是同一个东西(写法本身),不依赖任何运行时行为。
//
// ## 这条测试现在是「记录现状」,不是「守住现状」
//
// 下面的 [kKnownBadSites] 列的是**已知有问题、本轮只报告不修**的两处。
// 修好其中任何一处,这条用例会红 —— 那正是提醒:把修好的那一行从名单里删掉。
// 名单空了之后,这条用例就退化成一条纯粹的守卫(任何新出现的站点都会红)。
//
// 后果(两处相同):`State.setState` 先执行回调(赋值**已经发生**),再在断言里
// 发现返回了 `Future` 并抛出 —— 抛在 `markNeedsBuild()` **之前**。于是
// `_future` 换成了新的,却没有任何一次重建被调度。
//   · 应急卡:五个 tab 全在 `IndexedStack` 里、`tabScreens` 是 `const` 列表,
//     切 tab 也不会让它重建 → 内容停在冷启动那一刻,直到 App 重启;
//   · 「看病带这个」:点「加一条」存完笔记,浮层一个字不变 —— 而这个方法自己的
//     文档写着「存完刷新这一屏的数据,不需要用户自己关掉浮层再重开」。
// release 构建里断言被剥掉,`markNeedsBuild()` 照常执行 → 不受影响;
// **debug / profile 必现**,而团队自己装的正是带 `.dev` 后缀的 debug 包。
//
// 正确写法(概览/趋势/档案三屏都是这么写的,还各自留了注释):
//
//     Future<void> _refresh() async {
//       final next = _load();
//       setState(() { _future = next; });   // 语句块,不是箭头
//       await next;
//     }

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 已知有问题的站点:`相对 lib/ 的路径` → `那一行的原文片段`。
///
/// **修好一处就从这里删一行。**
const kKnownBadSites = <String, String>{
  'screens/emergency_card_screen.dart':
      'setState(() => _future = _load())',
  'screens/visit_summary_sheet.dart':
      'setState(() => _future = viewVisitSummary())',
};

/// `setState(() => <赋值>);` —— 贪婪吃到行尾那个 `)`,不能用 `[^)]*`:
/// 右边本来就常带括号(`_load()`),截断之后判据全歪。
final _arrowSetState = RegExp(r'setState\(\(\)\s*=>\s*(.+)\)\s*;');

/// 明显是同步取值的写法,出现即排除。列的是**这个仓库里实际有的**几种,
/// 不试图穷举 Dart —— 宁可漏报也不要把一堆 `setState(() => _busy = false)`
/// 染红,那样这条测试很快就会被人加 `skip` 关掉。
const _syncSuffixes = ['.toString()', '.trim()', '.value'];

/// 判定「这个赋值右边像不像一个 Future」:是一次函数调用,且不是上面那些
/// 同步写法、也不是字符串字面量。
bool _looksLikeFuture(String assignment) {
  final eq = assignment.indexOf('=');
  if (eq < 0) return false;
  final rhs = assignment.substring(eq + 1).trim();
  if (rhs.isEmpty) return false;
  if (rhs.startsWith("'") || rhs.startsWith('"')) return false;
  if (_syncSuffixes.any(rhs.contains)) return false;
  return RegExp(r'\w+\s*\(').hasMatch(rhs); // 有函数调用
}

void main() {
  final libDir = Directory('lib');

  test('setState 的箭头体不许返回 Future —— 已知两处,修好即改名单', () {
    expect(libDir.existsSync(), isTrue,
        reason: '这条测试要从仓库根的 apps/mobile_flutter 目录跑');

    final found = <String, String>{};
    for (final f in libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // 生成代码不看(frb_generated 之类)。
      if (f.path.contains('/src/rust/')) continue;
      final rel = f.path.replaceFirst(RegExp(r'^lib/'), '');
      for (final line in f.readAsLinesSync()) {
        final m = _arrowSetState.firstMatch(line);
        if (m == null) continue;
        final body = m.group(1)!;
        if (!body.contains('=')) continue;
        if (!_looksLikeFuture(body)) continue;
        found[rel] = line.trim();
      }
    }

    // ① 已知的两处都还在 —— 少了说明修好了,来改这份名单。
    for (final entry in kKnownBadSites.entries) {
      expect(
        found.containsKey(entry.key),
        isTrue,
        reason: '「${entry.key}」的 setState-返回-Future 已经修好了(或文件挪了位置)。\n'
            '请把它从 kKnownBadSites 里删掉;两处都删干净之后,这条用例就变成一条'
            '纯粹的守卫。\n当前扫到的站点:$found',
      );
      expect(found[entry.key], contains('setState(() => _future ='),
          reason: '「${entry.key}」那一行变了,请重新核对:${found[entry.key]}');
    }

    // ② 没有**新增**的站点。
    final extras = found.keys.where((k) => !kKnownBadSites.containsKey(k));
    expect(
      extras,
      isEmpty,
      reason: '新出现了 setState-返回-Future 的写法(它会让那一屏静默不重建):\n'
          '${extras.map((k) => '  · $k: ${found[k]}').join('\n')}',
    );
  });
}
