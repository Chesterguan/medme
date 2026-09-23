// 减法稿 2026-09-22:全 lib/ 不许有渐变、阴影、非零 elevation。层级靠字号、留白、
// 1px 细边。与 no_raw_colors_test.dart 同一手法:扫源码,不扫渲染。折线图若要一块
// 数据可视化用的渐变填充,前一行写 `// 允许:图表` 放行(与 motion_test.dart 的
// 标注法一致)。
//
// `_banned` 具体禁的东西:`LinearGradient`/`RadialGradient`/`SweepGradient`/
// `BoxShadow`/`Shadow` 构造调用;`boxShadow:`/`shadows:` 属性;底层画布渐变
// `ui.Gradient.*`;以及任何非零的 `...elevation:`(`elevation: 0`/
// `scrolledUnderElevation: 0` 放行——Material 组件默认就带这个参数,0 就是
// 「没有」,终审裁定只挡非零值)。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// 最后一支 `elevation` 分支里 `\s*` 特意挪进了零宽断言内部
// (`:(?!\s*0(\.0)?\b)` 而不是 `:\s*(?!0(\.0)?\b)`)——外面留一个可回溯的
// `\s*` 时,引擎在断言失败后会把它缩到 0 宽,从冒号正后方(此时后面还跟着一个
// 空格,不是 `0`)重新断言,断言反而通过,`elevation: 0,` 就被错放成「非零」。
// 断言写在零宽结构内部就不会被外面的量词借道。
final _banned = RegExp(r'\b(LinearGradient|RadialGradient|SweepGradient|BoxShadow|Shadow)\s*\(|\b(boxShadow|shadows)\s*:|\bui\.Gradient\.|\b[A-Za-z]*[eE]levation\s*:(?!\s*0(\.0)?\b)');

void main() {
  test('lib/ 里没有渐变、没有阴影、没有非零 elevation', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//')) continue;
        if (!_banned.hasMatch(l)) continue;
        if (i > 0 && lines[i - 1].contains('// 允许:图表')) continue;
        hits.add('${f.path}:${i + 1}: ${l.trim()}');
      }
    }
    expect(hits, isEmpty, reason: '减法稿:不许渐变、不许阴影、不许非零 elevation\n${hits.join('\n')}');
  });

  group('闸本身的自测——确认 `_banned` 拦对东西、放对东西', () {
    test('elevation: 2, —— 拦', () {
      expect(_banned.hasMatch('elevation: 2,'), isTrue);
    });
    test('elevation: 0, —— 放行', () {
      expect(_banned.hasMatch('elevation: 0,'), isFalse);
    });
    test('shadows: [Shadow()] —— 拦', () {
      expect(_banned.hasMatch('shadows: [Shadow()]'), isTrue);
    });
    test('ui.Gradient.linear( —— 拦', () {
      expect(_banned.hasMatch('ui.Gradient.linear('), isTrue);
    });
  });
}
