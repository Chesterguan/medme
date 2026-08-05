// 用户视角三:**有一大堆记录的用户**。
//
// 载入示例数据(22 份真实版式的病历)之后再叠上上百条手动记录,看概览「最近的
// 关键化验」、档案列表、趋势列表在数据量上去之后有没有溢出 / 错位 / 卡顿。
//
// 「卡顿」这里用可测的口径:切到某个 tab 后首帧可用的耗时,超过阈值只 debugPrint
// 记录不硬失败(模拟器性能与真机差太多,拿它当断言会变成假信号),真正硬失败的
// 只有溢出与错位。
//
//     flutter test integration_test/journey_bulk_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

Future<void> bulkSelfMeasurements(int days) async {
  final start = DateTime(2025, 1, 1, 7, 30);
  for (var d = 0; d < days; d++) {
    final t = start.add(Duration(days: d));
    final iso = t.toUtc().toIso8601String();
    await addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'bp_systolic', value: 118.0 + (d % 50), unit: 'mmHg'),
        SelfMeasuredValueDto(
            analyteKey: 'bp_diastolic', value: 72.0 + (d % 25), unit: 'mmHg'),
      ],
      measuredAt: iso,
    );
    await addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'heart_rate', value: 58.0 + (d % 45), unit: '/min'),
      ],
      measuredAt: iso,
    );
    if (d % 3 == 0) {
      await addNote(text: '第 $d 天:今天感觉还行,血压比昨天低一点点', measuredAt: iso);
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('示例数据 + 120 天手动记录 —— 五个 tab 全过一遍', (tester) async {
    final watch = OverflowWatch('大数据量')..start();
    addTearDown(watch.stop);

    await resetEverything();

    // ① 示例数据(22 份)。走 Rust 的流式接口,与设置页那颗按钮同一条路。
    var demoLoaded = 0;
    String? demoError;
    await for (final p in loadDemoData()) {
      if (p.error != null) {
        demoError = p.error;
        break;
      }
      demoLoaded = p.succeeded.toInt();
    }
    debugPrint('[大数据量] 示例数据载入 $demoLoaded 份, error=$demoError');
    expect(demoError, isNull, reason: '载入示例数据失败:$demoError');
    expect(demoLoaded, greaterThan(0), reason: '示例数据一份都没载进来');

    // ② 再叠 120 天手动记录(240 条自测 + 40 条笔记)。
    final sw = Stopwatch()..start();
    await bulkSelfMeasurements(120);
    sw.stop();
    final total = (await patientProfile()).recordCount;
    debugPrint('[大数据量] 灌 280 条耗时 ${sw.elapsedMilliseconds}ms,'
        '库里共 $total 份');
    expect(total, greaterThan(200));

    bumpVaultRevision();
    await bootApp(tester, reset: false);

    // ③ 五个 tab 逐个进,记录首屏耗时。
    for (final (idx, label) in [
      (HomeTab.overview, '概览'),
      (HomeTab.trends, '趋势'),
      (HomeTab.archive, '档案'),
      (HomeTab.emergency, '应急卡'),
      (HomeTab.settings, '设置'),
    ]) {
      final t = Stopwatch()..start();
      selectedTab.value = idx;
      await waitFor(
        tester,
        find.descendant(of: find.byType(AppBar), matching: find.text(label)),
        timeout: const Duration(seconds: 60),
        what: '$label 首屏',
      );
      // 等到转圈消失(有的屏是异步投影)。
      final spinner = find.byType(CircularProgressIndicator);
      if (spinner.evaluate().isNotEmpty) {
        await waitGone(tester, spinner,
            timeout: const Duration(seconds: 60), what: '$label 的加载转圈');
      }
      t.stop();
      debugPrint('[大数据量] 「$label」首屏 ${t.elapsedMilliseconds}ms');
      await settle(tester, total: const Duration(seconds: 2));
    }

    // ④ 概览「最近的关键化验」不该被 200+ 条撑爆(投影自己有上限)。
    final s = await viewVisitSummary();
    debugPrint('[大数据量] recentLabs=${s.recentLabs.length} '
        'recentVisits=${s.recentVisits.length} '
        'recentNotes=${s.recentNotes.length} '
        'plainText=${s.plainText.length}字');
    expect(s.recentLabs.length, lessThan(60),
        reason: '概览「最近的关键化验」一次要画 ${s.recentLabs.length} 行');

    // ⑤ 趋势列表滚到底不崩。
    await gotoTab(tester, HomeTab.trends);
    await settle(tester, total: const Duration(seconds: 2));
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle(tester, total: const Duration(seconds: 2));

    // ⑥ 档案列表滚到底不崩。
    await gotoTab(tester, HomeTab.archive);
    await settle(tester, total: const Duration(seconds: 2));
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle(tester, total: const Duration(seconds: 2));

    // ⑦「看病带这个」在大数据量下也得开得出来。
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('看病带这个'));
    await tester.tap(find.text('看病带这个').first);
    await settle(tester, total: const Duration(seconds: 4));
    await waitFor(tester, find.text('复制全文给医生'),
        timeout: const Duration(seconds: 60));
    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await settle(tester, total: const Duration(seconds: 2));

    watch.assertClean();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
