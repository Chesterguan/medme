// 把埋点目录钉在代码上。
//
// 半年后没人记得 `share_qr_degraded` 当初想回答什么问题 —— 到那时后台里躺着一堆
// 事件名,数据分析无从下手。文档能救,但文档会烂。所以这里**双向**校验
// `docs/analytics-catalog.md` 与 `AnalyticsEvent` 枚举:
//
//   代码里加了事件、文档里没写  → 红(会有采了却没人知道用途的事件)
//   文档里写了、代码里没有      → 红(会去后台找一个根本不存在的事件)
//
// 顺带这份目录还是工信部双清单和隐私政策的底稿,烂掉的代价不只是分析不便。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/analytics.dart';

/// 目录在仓库根的 docs/ 下;`flutter test` 的工作目录是 package 根。
final _catalog = File('../../docs/analytics-catalog.md');

/// 只认第四节「事件全集」里的表格行,形如:`| `event_name` | … |`。
/// 会话上下文和分桶那几节的表格第一列也是反引号包的标识符,但那些是**属性名**,
/// 不是事件名 —— 所以必须按小节切,不能全文扫。
Set<String> _eventsInCatalog(String md) {
  final start = md.indexOf('## 四、');
  final end = md.indexOf('## 五、');
  expect(start, greaterThan(-1), reason: '目录里找不到「## 四、」事件全集小节');
  expect(end, greaterThan(start), reason: '目录里找不到「## 五、」——第四节没有结尾');
  final section = md.substring(start, end);
  final re = RegExp(r'^\|\s*`([a-z][a-z0-9_]*)`\s*\|', multiLine: true);
  return re.allMatches(section).map((m) => m.group(1)!).toSet();
}

void main() {
  test('目录文件存在', () {
    expect(
      _catalog.existsSync(),
      isTrue,
      reason: '找不到 ${_catalog.path} —— 埋点目录是双清单和隐私政策的底稿,不能没有',
    );
  });

  test('每个事件都在目录里有一行(否则采了也没人知道它想回答什么)', () {
    final documented = _eventsInCatalog(_catalog.readAsStringSync());
    final missing = AnalyticsEvent.values
        .map((e) => e.name)
        .where((n) => !documented.contains(n))
        .toList();
    expect(
      missing,
      isEmpty,
      reason:
          '这些事件在代码里有、在 docs/analytics-catalog.md 第四节没有:$missing\n'
          '加事件时必须同时写下它回答哪个决定 —— 写不出来就说明不该加。',
    );
  });

  test('目录里没有已经不存在的事件(否则会去后台找一个不存在的名字)', () {
    final documented = _eventsInCatalog(_catalog.readAsStringSync());
    final known = AnalyticsEvent.values.map((e) => e.name).toSet();
    final stale = documented.where((n) => !known.contains(n)).toList();
    expect(
      stale,
      isEmpty,
      reason: '这些事件写在目录里但代码里没有(删了没同步?):$stale',
    );
  });

  test('目录里没漏掉「不采什么」那一节 —— 隐私政策直接引它', () {
    final md = _catalog.readAsStringSync();
    for (final must in ['录屏', r'$geoip_disable', 'ADR 0009']) {
      expect(
        md.contains(must),
        isTrue,
        reason: '目录里应当保留「$must」这条 —— 隐私政策与双清单以它为准',
      );
    }
  });
}
