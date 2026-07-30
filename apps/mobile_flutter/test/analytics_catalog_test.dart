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

/// 每个事件行的「属性」列 —— 按**位置**取(每行第二个单元格),不按表头文字取。
///
/// 为什么不能按表头:「分析自身」那张表表头只写了「事件 | 触发点 | 回答什么」,漏了
/// 「属性」两个字,但数据行(`analytics_opt_out`)照样多出一格「无」,位置和其余
/// 六张表完全一致。按表头找列名在这张表上会直接找不到,所以统一按第二格取,
/// 这份文档里所有表(不管表头怎么写)第二格永远是属性说明。
///
/// 属性列的写法不统一,已知形态:
///   `vault_ok`                                          —— 单个
///   `source`, `count_bucket`                            —— 逗号分隔多个
///   无                                                    —— 空(不带属性)
///   `choice`(**interrupted**=… / **retry**=…), `progress_bucket`
///   `entry`(cold/warm)
///   `reason`(gone/network/failed/unknown)
/// 括号里是**取值说明**,不是属性名(尤其 `choice`(恒为 `fallback`) 这种,括号里
/// 还嵌着一个反引号包住的取值 `fallback` —— 必须先整体剔除圆括号,再抽反引号词,
/// 否则会把取值误当成属性名)。
Map<String, Set<String>> _propsInCatalog(String md) {
  final start = md.indexOf('## 四、');
  final end = md.indexOf('## 五、');
  final section = md.substring(start, end);
  final rowRe = RegExp(r'^\|\s*`([a-z][a-z0-9_]*)`\s*\|([^|]*)\|', multiLine: true);
  final propNameRe = RegExp(r'`([a-z][a-z0-9_]*)`');
  final result = <String, Set<String>>{};
  for (final row in rowRe.allMatches(section)) {
    final event = row.group(1)!;
    final cell = row.group(2)!;
    // 先剔除圆括号里的取值说明,剩下的反引号词才是属性名。
    final withoutValueNotes = cell.replaceAll(RegExp(r'\([^()]*\)'), '');
    result[event] = propNameRe
        .allMatches(withoutValueNotes)
        .map((m) => m.group(1)!)
        .toSet();
  }
  return result;
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

  test('每个事件的属性与 AnalyticsEvent.props 逐字对钉(否则属性漂了 CI 不会红)', () {
    final documented = _propsInCatalog(_catalog.readAsStringSync());
    final mismatches = <String>[];
    for (final e in AnalyticsEvent.values) {
      final fromDoc = documented[e.name];
      // 事件名本身缺失已经由上一个测试盯着,这里没有对应行就不重复报错。
      if (fromDoc == null) continue;
      final missingInDoc = e.props.difference(fromDoc);
      final staleInDoc = fromDoc.difference(e.props);
      if (missingInDoc.isEmpty && staleInDoc.isEmpty) continue;
      final parts = <String>[];
      if (missingInDoc.isNotEmpty) {
        parts.add(
          '代码里声明了但目录没写 $missingInDoc —— 补 docs/analytics-catalog.md '
          '第四节这一行的「属性」列',
        );
      }
      if (staleInDoc.isNotEmpty) {
        parts.add(
          '目录写了但代码里没声明 $staleInDoc —— 要么调用点确实会发这个键、'
          '把它加进 AnalyticsEvent.${e.name} 的 props,要么目录这条是漂的,删掉',
        );
      }
      mismatches.add('${e.name}: ${parts.join('; ')}');
    }
    expect(
      mismatches,
      isEmpty,
      reason: '事件属性与目录第四节「属性」列对不上:\n${mismatches.join('\n')}',
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
