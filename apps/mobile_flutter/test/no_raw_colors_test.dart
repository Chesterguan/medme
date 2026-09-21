// 裸色值闸:屏和 widget 里不许出现任何 `Color(0x…)`,也不许用 Material 的命名色
// (白/黑/透明除外)。色板的唯一出处是 design_tokens.dart / theme.dart。
//
// 这条闸同时兑现 brief 的「不用粉彩」—— 粉彩进不来代码的路只有一条:有人手写
// 一个 Color(0xFF…)。堵住这条路,剩下的就只有令牌里那几十个经过审的值。
//
// 预检裁定 R5:只放行**恰好** `Colors.white` / `Colors.black` / `Colors.transparent`
// 这三个 —— `Colors.black54`、`Colors.white70` 这类衍生色不再豁免,一律改用
// `MedColors.scrim` / `scrimLight` / `onDarkFaint`。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const _allowedFiles = {'lib/design_tokens.dart', 'lib/theme.dart'};
const _allowedNamedColors = {'white', 'black', 'transparent'};
final _rawHex = RegExp(r'Color\(0x');
// 负向后顾 `(?<![A-Za-z])`:没有它,这条正则会命中 `MedColors.of(...)` /
// `MedColors.light` 这类调用里的「Colors.」子串 —— 那正是全 app 都要用的写法,
// 不能被这条闸自己拦下来(brief 原文的正则没有这个前置断言)。
final _namedColorToken = RegExp(r'(?<![A-Za-z])Colors\.([a-zA-Z][a-zA-Z0-9]*)');

/// 一行里只要有一个 `Colors.X` 的 X 不在允许集合里,就算违规 —— 例如
/// `Colors.black54` 的 X 是 `black54`,不是 `black`,不放行。
bool _hasDisallowedNamedColor(String line) {
  for (final m in _namedColorToken.allMatches(line)) {
    if (!_allowedNamedColors.contains(m.group(1))) return true;
  }
  return false;
}

void main() {
  test('lib 里只有令牌文件持有裸色值', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path.startsWith('lib/src/rust')) continue;   // FRB 生成物
      if (_allowedFiles.contains(f.path)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;  // 注释里可以讲历史
        if (_rawHex.hasMatch(line) || _hasDisallowedNamedColor(line)) {
          offenders.add('${f.path}:${i + 1}  ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: '裸色值:\n${offenders.join('\n')}');
  });
}
