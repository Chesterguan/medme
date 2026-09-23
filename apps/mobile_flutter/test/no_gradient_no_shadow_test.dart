// 减法稿 2026-09-22:全 lib/ 不许有渐变和阴影。层级靠字号、留白、1px 细边。
// 与 no_raw_colors_test.dart 同一手法:扫源码,不扫渲染。折线图若要一块数据可视化
// 用的渐变填充,前一行写 `// 允许:图表` 放行(与 motion_test.dart 的标注法一致)。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

final _banned = RegExp(r'\b(LinearGradient|RadialGradient|SweepGradient|BoxShadow)\s*\(|\bboxShadow\s*:');

void main() {
  test('lib/ 里没有渐变、没有阴影', () {
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
    expect(hits, isEmpty, reason: '减法稿:不许渐变、不许阴影\n${hits.join('\n')}');
  });
}
