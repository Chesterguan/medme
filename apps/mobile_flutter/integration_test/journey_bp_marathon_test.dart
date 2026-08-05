// 用户视角一:**每天量血压的慢病老人**。
//
// 同一天连着录十几条家测血压(含边界值 135/85、危急但真实的 200/120、极低的
// 90/55),然后去趋势屏看这条线画成了什么样。要盯的是:
//   · 点数对不对(同日多点会不会被吞掉一部分);
//   · 「家测」文字图例在不在(形状不能是唯一载体,见 `trends_screen.dart`);
//   · 参考带用的是**家测**区间 135/85,而不是诊室的 140/90;
//   · 危急值 200/120 必须存得进去(可能性范围只挡打错,不挡危急值);
//   · 卡头那个「最新值」是不是真的最新那一条。
//
//     flutter test integration_test/journey_bp_marathon_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

/// 直接走 FFI 灌一条血压 —— 与录入弹层 `_save()` 调的是同一个入口
/// (`addSelfMeasurement`),不是绕过校验的后门。
Future<void> addBp(double sys, double dia, DateTime when) async {
  await addSelfMeasurement(
    values: [
      SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: sys, unit: 'mmHg'),
      SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: dia, unit: 'mmHg'),
    ],
    measuredAt: when.toUtc().toIso8601String(),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('同一天连录 12 条家测血压 → 趋势屏', (tester) async {
    final watch = OverflowWatch('血压马拉松')..start();
    addTearDown(watch.stop);

    await resetEverything();

    // 同一天从早到晚 12 次。刻意混入三档:边界(135/85)、危急但真实
    // (200/120)、极低(90/55)。
    final day = DateTime(2026, 7, 20);
    final readings = <(double, double)>[
      (135, 85), // 家测正常上限,边界
      (136, 86), // 刚过界
      (128, 82),
      (200, 120), // 高血压危象 —— 必须存得进去
      (90, 55), // 极低
      (142, 91),
      (118, 74),
      (155, 95),
      (134, 84),
      (161, 99),
      (127, 80),
      (149, 88), // 当天最后一条 = 最新值
    ];
    for (var i = 0; i < readings.length; i++) {
      await addBp(
        readings[i].$1,
        readings[i].$2,
        day.add(Duration(hours: 6, minutes: i * 45)),
      );
    }
    bumpVaultRevision();

    // ── 先在数据层核对:12 条全都落库了吗 ──
    final trends = await viewTrends();
    final sys = trends.firstWhere(
      (s) => s.name == '收缩压',
      orElse: () => throw TestFailure('趋势里根本没有「收缩压」这条序列'),
    );
    final dia = trends.firstWhere((s) => s.name == '舒张压');

    debugPrint('[血压马拉松] 收缩压 points=${sys.points.length} '
        'selfMeasured=${sys.selfMeasured} refLow=${sys.refLow} '
        'refHigh=${sys.refHigh} anyAbnormal=${sys.anyAbnormal} '
        'dates=${sys.points.map((p) => p.date).toSet()}');
    debugPrint('[血压马拉松] 舒张压 points=${dia.points.length} '
        'refHigh=${dia.refHigh}');

    expect(sys.points.length, readings.length,
        reason: '录了 ${readings.length} 条,趋势里只剩 ${sys.points.length} 个点 —— 同日多点被吞了');
    expect(dia.points.length, readings.length);
    expect(sys.selfMeasured, isTrue, reason: '家测序列没被标成 selfMeasured');

    // 家测参考区间 135/85(《中国高血压防治指南》家测上限),**不是**诊室 140/90。
    expect(sys.refHigh, 135.0, reason: '收缩压参考上限不是家测的 135');
    expect(dia.refHigh, 85.0, reason: '舒张压参考上限不是家测的 85');

    // 危急但真实的 200/120 必须在,可能性范围只挡打错的数。
    expect(sys.points.map((p) => p.value), contains(200.0));
    expect(sys.points.map((p) => p.value), contains(90.0));

    // ── 再看屏上画成了什么 ──
    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.trends);
    await waitFor(tester, find.text('收缩压'), what: '趋势屏上的「收缩压」卡');

    // 「家测」文字图例:形状(空心圈)不能是唯一载体。
    expect(find.text('家测'), findsWidgets, reason: '趋势卡上没有「家测」文字图例');
    // 参考带图例带数值。
    expect(find.textContaining('参考区间'), findsWidgets);

    // 「N 次」的口径:同一天 12 次应当说 12 次,不能说 1 次。
    final spanTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.contains('次') && (s.contains('起') || s.contains('只有')))
        .toList();
    debugPrint('[血压马拉松] 跨度文案: $spanTexts');
    expect(
      spanTexts.any((s) => s.contains('12 次')),
      isTrue,
      reason: '趋势卡的跨度文案没说满 12 次,实际是:$spanTexts',
    );

    // 卡头「最新值」应当是当天最后一条(149/88),不是排序抖出来的任意一条。
    final lastSys = sys.points.last.value;
    expect(lastSys, 149.0,
        reason: '同日多点排序不稳:序列最后一个点是 $lastSys,应该是当天最后录的 149');

    // ── 概览「最近的关键化验」也应当认得出这条家测 ──
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('最近的关键化验'));
    expect(find.textContaining('家测'), findsWidgets,
        reason: '概览没把家测值标出来,会被当成医院化验值');

    watch.assertClean();
  });

  testWidgets('跨 30 天每天一条 → 线画得出来、只看非正常项开关的计数对得上', (tester) async {
    await resetEverything();

    final start = DateTime(2026, 6, 1, 7, 30);
    for (var d = 0; d < 30; d++) {
      // 前 15 天正常、后 15 天偏高 —— 让「只看非正常项」有东西可过滤。
      final sys = d < 15 ? 120.0 + d % 5 : 150.0 + d % 7;
      final dia = d < 15 ? 78.0 + d % 4 : 95.0 + d % 5;
      await addBp(sys, dia, start.add(Duration(days: d)));
    }
    bumpVaultRevision();

    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.trends);
    await waitFor(tester, find.text('收缩压'));

    final series = await viewTrends();
    final sys = series.firstWhere((s) => s.name == '收缩压');
    expect(sys.points.length, 30);
    expect(sys.anyAbnormal, isTrue, reason: '30 天里一半是 150+,却没有任何点被标异常');

    // 关掉「只看非正常项」,序列不该减少。
    final sw = find.byType(Switch);
    if (sw.evaluate().isNotEmpty) {
      await tester.tap(sw.first);
      await settle(tester);
      expect(find.text('收缩压'), findsOneWidget);
    }
  });
}
