// 缺陷钉子:「载入示例数据」后那条带「去看看」的 SnackBar 挂了 7 分钟不走。
//
// 真机实测:华为 MHA-L29 / Android 8.0,16:08 弹出,16:15 还在。期间切 tab、
// 横划、开关弹层、走完「清空所有数据」二次确认都无效。它挡住底部约 200px 且
// **吃掉那块区域的点击**(SnackBar 的 Dismissible 默认 `HitTestBehavior.opaque`),
// 「清空所有数据」按钮正好在它下面,连点三次没反应 —— 用户会判成 App 卡死。
//
// 根因**不是** IndexedStack / TickerMode(下面 A 组用对照实验排除了),而是
// Flutter 3.37 的 #173084 改了 `SnackBar` 的默认值:`persist = persist ?? action != null`,
// 于是任何带 action 的 SnackBar 永不自动消失。详见 `lib/widgets/app_snack_bar.dart`。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

const _msg = '已载入 22 份示例病历(在「张建国(示例)」里)';

/// 复刻 `main.dart` 里 `HomeShell` 的骨架:外层 `Scaffold` + `IndexedStack`(五个
/// 子屏,每个子屏自己也是 `Scaffold`)+ `NavigationBar`,主题用真实的
/// `MedMe.theme()`(它配了 `snackBarTheme`,`behavior: floating`)。
///
/// 不引真实的五个屏 —— 它们都要 Rust FFI,而这条缺陷与 FFI 无关。
class _ShellHarness extends StatefulWidget {
  const _ShellHarness({required this.make});

  /// 点「载入示例数据」时要弹的那条。
  final SnackBar Function() make;

  @override
  State<_ShellHarness> createState() => _ShellHarnessState();
}

class _ShellHarnessState extends State<_ShellHarness> {
  /// 复现路径从「设置」tab(下标 4)出发,与真机一致。
  int _index = 4;

  static const _labels = ['概览', '趋势', '档案', '应急卡', '设置'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < 5; i++)
            Scaffold(
              body: Center(
                child: i == 4
                    ? Builder(
                        builder: (inner) => ElevatedButton(
                          onPressed: () => ScaffoldMessenger.of(
                            inner,
                          ).showSnackBar(widget.make()),
                          child: const Text('载入示例数据'),
                        ),
                      )
                    : Text('tab $i'),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final l in _labels)
            NavigationDestination(icon: const Icon(Icons.circle), label: l),
        ],
      ),
    );
  }
}

Widget _app(SnackBar Function() make) =>
    MaterialApp(theme: MedMe.theme(), home: _ShellHarness(make: make));

/// 小步推进 [seconds] 秒。
///
/// **不能用 `pump(Duration(seconds: 10))` 一步跳过去**:那颗 4 秒关灯计时器是在
/// 「入场动画播完之后的那一帧 `ScaffoldMessengerState.build`」里才被创建的,一次性
/// 大步长会跳过创建时机;而 `pumpAndSettle` 只推有帧回调的动画,不推一个纯 `Timer`。
/// 这一条本身踩过一次(第一版探针四个用例全红,包括对照组),留在这里当路标。
Future<void> _advance(WidgetTester tester, {int seconds = 6}) async {
  for (var i = 0; i < seconds * 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('SnackBar 必须自己消失(载入示例数据卡死案)', () {
    testWidgets('对照组:不带 action 的提示,4 秒后消失 —— ticker 是活的', (tester) async {
      await tester.pumpWidget(_app(() => appSnackBar(content: const Text(_msg))));
      await tester.tap(find.text('载入示例数据'));
      await tester.pump();
      expect(find.text(_msg), findsOneWidget);

      await _advance(tester);
      expect(
        find.text(_msg),
        findsNothing,
        reason: '这一条红了说明 ticker/计时器整体被冻住,那才轮得到 TickerMode 的怀疑',
      );
    });

    testWidgets('缺陷本体:带「去看看」action 的提示,也必须自己消失', (tester) async {
      await tester.pumpWidget(
        _app(
          () => appSnackBar(
            content: const Text(_msg),
            action: SnackBarAction(label: '去看看', onPressed: () {}),
          ),
        ),
      );
      await tester.tap(find.text('载入示例数据'));
      await tester.pump();
      expect(find.text(_msg), findsOneWidget);

      // 真机上挂了 7 分钟。这里推 10 分钟,余量足够。
      for (var i = 0; i < 100; i++) {
        await _advance(tester);
      }
      expect(
        find.text(_msg),
        findsNothing,
        reason:
            '带 action 的 SnackBar 又变回「永不消失」了 —— 检查 appSnackBar 的 '
            'persist: false 是不是被去掉了(Flutter #173084)',
      );
    });

    testWidgets('切 tab 之后依然会自己消失(IndexedStack 不背这口锅)', (tester) async {
      await tester.pumpWidget(
        _app(
          () => appSnackBar(
            content: const Text(_msg),
            action: SnackBarAction(label: '去看看', onPressed: () {}),
          ),
        ),
      );
      await tester.tap(find.text('载入示例数据'));
      await tester.pump();
      await tester.tap(find.text('概览')); // 切到别的 tab,像真机上那样
      await tester.pump(const Duration(milliseconds: 100));

      await _advance(tester);
      expect(find.text(_msg), findsNothing);
    });

    testWidgets(
      '带 action 的提示到点会兑现 closed(import_flow 的「用普通相机」靠 await 它)',
      (tester) async {
        // `_offerPlainCamera` 是 `await controller.closed == action`:提示永不关闭
        // 就等于那次导入**永远卡在这一句**上,比横条不走更严重。
        SnackBarClosedReason? reason;
        late ScaffoldMessengerState messenger;
        await tester.pumpWidget(
          MaterialApp(
            theme: MedMe.theme(),
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  messenger = ScaffoldMessenger.of(c);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        final controller = messenger.showSnackBar(
          appSnackBar(
            content: const Text('没有拍到照片。'),
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(label: '用普通相机', onPressed: () {}),
          ),
        );
        unawaited(controller.closed.then((r) => reason = r));

        await _advance(tester, seconds: 12);
        expect(
          reason,
          SnackBarClosedReason.timeout,
          reason: 'closed 没兑现 = 导入流程会永远挂在 await 上',
        );
      },
    );
  });

  group('根因守卫:SnackBar 只能从 appSnackBar 造', () {
    test('lib/ 里没有裸的 SnackBar(...) 构造', () {
      // 为什么是源码扫描而不是行为断言:根因是「框架默认值变了、无声无息」,
      // 只修好现有的两处并不能拦住下一处 —— 只要有人再写一次裸 `SnackBar(`,
      // 同样的 7 分钟会在别的地方重演。这条把入口收成一个。
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: '测试要在包根目录跑');

      final offenders = <String>[];
      final bare = RegExp(r'\bSnackBar\(');
      for (final f in lib.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('widgets/app_snack_bar.dart')) continue; // 唯一的口
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          // `\b` 天然排除 showSnackBar / hideCurrentSnackBar / removeCurrentSnackBar,
          // `\(` 排除 SnackBarAction / SnackBarBehavior / SnackBarClosedReason。
          if (bare.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '这些地方直接 new 了 SnackBar,会重新继承 Flutter 的 persist 默认值'
            '(带 action 就永不消失)。改用 lib/widgets/app_snack_bar.dart 的 '
            'appSnackBar(...)。',
      );
    });
  });
}
