// 源码级守卫:**`setState(() => …)` 的箭头体不许返回 `Future`。**
//
// ## 为什么是扫源码,而不是渲染断言
//
// 这个写法的后果只在 debug 断言开着时才出现,而它出现的方式恰好让测试难抓:
//
//   · 应急卡那处抛在 `ChangeNotifier.notifyListeners` 的 try/catch 里 → 只走
//     `FlutterError.onError`,`tester.takeException()` 接不到;
//   · 「看病带这个」那处抛在一个 `async` 方法里、由 `VoidCallback` 调起 →
//     **未捕获的 zone 错误** → `flutter_test` 收到就把用例的 completer 以错误
//     完成,测试体当场终止,后面的断言一行都执行不到。
//
// 两处各自的**行为**回归已经分别由 `test/emergency_card_refresh_test.dart` 与
// `test/visit_summary_sheet_test.dart`(「存完笔记要当场刷新」那一组)钉住 —— 那两条
// 断言的是「屏上真的变了」。这条不同:它守的是**写法本身**,判据与根因是同一个东西,
// 不依赖任何运行时行为,也因此能拦住**任何一处新出现的**同款写法,包括还没有人为它
// 写过行为测试的那些屏。
//
// ## 名单是空的 —— 这条现在是纯粹的守卫
//
// [kKnownBadSites] 曾经列着两处「已知有问题、那一轮只报告不修」的站点。两处都修好
// 之后名单清空,这条用例的角色随之反转:任何**新**出现的站点都会让它红。
//
// 那两处当时的后果(相同):`State.setState` 先执行回调(赋值**已经发生**),再在
// 断言里发现返回了 `Future` 并抛出 —— 抛在 `markNeedsBuild()` **之前**。于是
// `_future` 换成了新的,却没有任何一次重建被调度。
//   · 应急卡:五个 tab 全在 `IndexedStack` 里、`tabScreens` 是 `const` 列表,
//     切 tab 也不会让它重建 → 内容停在冷启动那一刻,直到 App 重启;
//   · 「看病带这个」:点「加一条」存完笔记,浮层一个字不变 —— 而这个方法自己的
//     文档写着「存完刷新这一屏的数据,不需要用户自己关掉浮层再重开」。
// release 构建里断言被剥掉,`markNeedsBuild()` 照常执行 → 不受影响;
// **debug / profile 必现**,而团队自己装的正是带 `.dev` 后缀的 debug 包。
//
// 正确写法(概览/趋势/档案三屏一直是这么写的,现在应急卡与「看病带这个」也是):
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
/// **空的,而且应该一直是空的。** 这里曾经有两行:
///
///     'screens/emergency_card_screen.dart': 'setState(() => _future = _load())',
///     'screens/visit_summary_sheet.dart':   'setState(() => _future = viewVisitSummary())',
///
/// 两处都已改成语句块 `_refresh()`。留着这个常量而不是把它删掉,是为了让「暂时容忍
/// 某一处」有一个明确的、要写理由的落点 —— 而不是给这条用例加 `skip`。
const kKnownBadSites = <String, String>{};

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

  test('setState 的箭头体不许返回 Future —— 全仓一处都不许有', () {
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

    // ① 名单里的站点(现在一个都没有)确实还在 —— 少了说明有人修好了却没更新名单。
    for (final entry in kKnownBadSites.entries) {
      expect(
        found.containsKey(entry.key),
        isTrue,
        reason: '「${entry.key}」的 setState-返回-Future 已经修好了(或文件挪了位置),'
            '请把它从 kKnownBadSites 里删掉。\n当前扫到的站点:$found',
      );
    }

    // ② 名单之外一处都不许有。名单是空的,所以这一条等于「全仓干净」。
    final extras = found.keys.where((k) => !kKnownBadSites.containsKey(k));
    expect(
      extras,
      isEmpty,
      reason: '出现了 setState-返回-Future 的写法 —— 它会让那一屏静默不重建\n'
          '(赋值发生了,断言在 markNeedsBuild() 之前抛,于是没有任何一次重建被调度;\n'
          ' release 里断言被剥掉看不出来,debug/profile 必现):\n'
          '${extras.map((k) => '  · $k: ${found[k]}').join('\n')}\n'
          '改成语句块:final next = _load(); setState(() { _future = next; }); await next;',
    );
  });
}
