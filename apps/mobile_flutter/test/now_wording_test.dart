// 「现在」「用药」措辞闸(2026-10-23 spec §8、§11.2 验收 12):这两页与它们的行组件只说日期、
// 次数、原文,不下结论。扫源码的**非注释行**;「活动度」是包里的评分名(包给的 JSON 才会出现),
// 这里禁的是「活动期」这类状态词。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _files = [
  'lib/screens/now_screen.dart',
  'lib/screens/now_model.dart',
  'lib/screens/meds_screen.dart',
  'lib/screens/meds_model.dart',
  'lib/widgets/lab_trend_row.dart',
  'lib/evidence_open.dart',
  // 不扫 profile_sections.dart:那是包段的渲染器,「活动期 / 稳定期」是包的复诊节律
  //(ADR 0011 决定 8)给的状态名,措辞归包管,不归这两页。
];

const _banned = ['活动期', '已解决', '既往', '在吃', '已停', '开始吃', '当前用药', '在用药', '正在服用'];

void main() {
  test('「现在」「用药」相关源码不出现结论性措辞', () {
    final hits = <String>[];
    for (final f in _files) {
      final lines = File(f).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trim();
        if (l.startsWith('//')) continue;
        for (final w in _banned) {
          if (l.contains(w)) hits.add('$f:${i + 1}: $w');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
