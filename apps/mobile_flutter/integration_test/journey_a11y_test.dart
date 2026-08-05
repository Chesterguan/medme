// 用户视角七 + 八:**无障碍用户 / 旋转 / 中断**。
//
// ## 为什么不用 `adb shell settings put system font_scale`
//
// 用了 —— 但那条路只能拿截图肉眼看。这一条用例走的是
// `TestPlatformDispatcher.textScaleFactorTestValue`,效果与系统字号一致,但
// **可复现、可断言**:字号 × 视口 × 五个 tab 组合着扫,一次跑完把全部溢出点
// 报出来。
//
// ⚠️ RenderFlex 溢出走 `FlutterError.reportError`,`tester.takeException()`
// **抓不到** —— 靠 `OverflowWatch` 挂 `FlutterError.onError`(见 harness)。
//
//     flutter test integration_test/journey_a11y_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

/// 有内容的库比空库更容易挤爆(空态是几行居中文字,有数据才有 pill / 数值 /
/// 日期挤在同一行)。所以这批用例先灌一点真实形状的数据。
Future<void> seed() async {
  final base = DateTime(2026, 5, 1, 8);
  for (var d = 0; d < 6; d++) {
    final iso = base.add(Duration(days: d * 5)).toUtc().toIso8601String();
    await addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'bp_systolic', value: 138.0 + d, unit: 'mmHg'),
        SelfMeasuredValueDto(
            analyteKey: 'bp_diastolic', value: 88.0 + d, unit: 'mmHg'),
      ],
      measuredAt: iso,
    );
    await addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'body_temperature', value: 36.8, unit: 'Cel'),
      ],
      measuredAt: iso,
    );
  }
  await addNote(
    text: '想问医生:这个降压药能不能减量?最近早上起来有点晕,量出来低压总在 88 上下。',
    measuredAt: base.toUtc().toIso8601String(),
  );
  bumpVaultRevision();
}

/// 把五个 tab 都翻一遍(顺带滚一屏,让屏下的内容也参与布局)。
Future<void> sweepTabs(WidgetTester tester) async {
  for (final (idx, label) in [
    (HomeTab.overview, '概览'),
    (HomeTab.trends, '趋势'),
    (HomeTab.archive, '档案'),
    (HomeTab.emergency, '应急卡'),
    (HomeTab.settings, '设置'),
  ]) {
    selectedTab.value = idx;
    await waitFor(
      tester,
      find.descendant(of: find.byType(AppBar), matching: find.text(label)),
      timeout: const Duration(seconds: 40),
      what: '$label(字号扫描)',
    );
    await settle(tester, total: const Duration(seconds: 2));
    for (var i = 0; i < 6; i++) {
      final list = find.byType(ListView);
      if (list.evaluate().isEmpty) break;
      await tester.drag(list.first, const Offset(0, -500), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final scale in [1.0, 1.3, 1.5, 2.0]) {
    testWidgets('系统字号 ×$scale:五个 tab + 看病带这个,全程无 RenderFlex 溢出', (
      tester,
    ) async {
      await resetEverything();
      await seed();

      final watch = OverflowWatch('字号 ×$scale')..start();
      addTearDown(watch.stop);

      await bootApp(tester, reset: false);
      await withTextScale(tester, scale, () async {
        await sweepTabs(tester);

        // 「看病带这个」浮层单独过一遍 —— 它是一屏里信息最密的地方。
        // 概览刚被 `sweepTabs` 滚到了底,banner 不在可视区、`ListView` 也就
        // 没构建它 —— 先滚回顶部。
        selectedTab.value = HomeTab.overview;
        await settle(tester, total: const Duration(seconds: 2));
        await scrollToTop(tester);
        await waitFor(tester, find.text('看病带这个'));
        await tester.tap(find.text('看病带这个').first);
        await settle(tester, total: const Duration(seconds: 3));
        await waitFor(tester, find.text('复制全文给医生'),
            timeout: const Duration(seconds: 40));
        for (var i = 0; i < 6; i++) {
          final sheetList = find.byType(ListView);
          if (sheetList.evaluate().isEmpty) break;
          await tester.drag(sheetList.last, const Offset(0, -400),
              warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await settle(tester, total: const Duration(seconds: 2));
        // 用药那一节默认折叠,展开后再看一次。
        final meds = find.textContaining('记录里的用药');
        if (meds.evaluate().isNotEmpty) {
          await tester.tap(meds.first, warnIfMissed: false);
          await settle(tester, total: const Duration(seconds: 2));
        }
        await tester.tapAt(const Offset(10, 10));
        await settle(tester, total: const Duration(seconds: 2));

        // 录入弹层也过一遍(六个 chip 一排,最容易在大字号下换行/挤爆)。
        await scrollToTop(tester);
        await waitFor(tester, find.text('记录'));
        await tester.tap(find.text('记录').first);
        await settle(tester, total: const Duration(seconds: 2));
        await waitFor(tester, find.text('保存'));
        await tester.tapAt(const Offset(10, 10));
        await settle(tester, total: const Duration(seconds: 2));
      });

      watch.stop();
      if (watch.overflows.isNotEmpty) {
        debugPrint('[字号 ×$scale] 溢出 ${watch.overflows.length} 处:');
        for (final o in watch.overflows) {
          debugPrint('   $o');
        }
      }

      if (scale >= 2.0) {
        // ── BUG-5(未修,只报告)──
        // 复现:系统字号拉到最大(`adb shell settings put system font_scale 2.0`,
        //       或系统设置里「字体大小」最右)→ 概览 →「记录」。
        // 现象:弹层底部「测量时间」那一行**横向溢出 31px**,右边的
        //       「2026-08-05 14:23」被裁掉一截,黄黑条纹压在上面。
        // 位置:`manual_entry_sheet.dart:701` 的 `_WhenRow`。那个 `Row` 是
        //       [图标][「测量时间」][Spacer][日期时间][箭头],**两个 `Text` 都
        //       没有 `Flexible`/`Expanded`**,字号翻倍之后它们各自变宽,
        //       `Spacer` 挤没了也不够,只能溢出。
        // 违反:`007 §2.5` 的「字号可放大,不可砍」。同一个文件里
        //       `QuickActions` 专门用 `Wrap` 而不是 `GridView` 就是为这条;
        //       `_MemberTabs` 也按 `textScaler` 算了高度。这一行漏了。
        // 修法参考(不在本轮做):把日期那个 `Text` 包 `Flexible` +
        //       `overflow: TextOverflow.ellipsis`,或者放不下时改成上下两行
        //       ——`lab_status.dart` 的 `LabLine` 已经有「实测宽度决定并排还是
        //       两行」的现成做法。
        // 严重度:**中**(只在最大字号出现,不丢数据;但受影响的正好是需要放大
        //       字号的那批用户,而这一行是他们核对/修改测量时间的唯一入口)。
        expect(
          watch.overflows.length,
          1,
          reason: '字号 ×2.0 下的溢出数量变了(原本只有 BUG-5 那一处):\n'
              '${watch.overflows.join('\n')}',
        );
        expect(
          watch.overflows.first,
          contains('manual_entry_sheet.dart:701'),
          reason: 'BUG-5 已经修好了(或换了位置)—— 请更新这段判断。\n'
              '${watch.overflows.first}',
        );
      } else {
        watch.assertClean();
      }
    }, timeout: const Timeout(Duration(minutes: 12)));
  }

  testWidgets('横屏 / 窄屏 / 超窄屏:布局不挤爆', (tester) async {
    await resetEverything();
    await seed();

    final watch = OverflowWatch('视口扫描')..start();
    addTearDown(watch.stop);

    await bootApp(tester, reset: false);

    // 1080×2400 @3x = 360×800 dp(常见国产机),横屏 800×360;
    // 320dp 是安卓生态实际还在跑的最窄一档。
    final viewports = <(String, Size)>[
      ('横屏 800×360', const Size(2400, 1080)),
      ('窄屏 360×640', const Size(1080, 1920)),
      ('超窄 320×640', const Size(960, 1920)),
    ];
    for (final (name, px) in viewports) {
      tester.view.physicalSize = px;
      tester.view.devicePixelRatio = 3.0;
      await tester.pump();
      await settle(tester, total: const Duration(seconds: 2));
      debugPrint('[视口扫描] $name');
      await sweepTabs(tester);
    }
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    watch.assertClean();
  }, timeout: const Timeout(Duration(minutes: 12)));

  testWidgets('后台切回 / 内存压力信号:不丢状态、不崩', (tester) async {
    await resetEverything();
    await seed();

    final watch = OverflowWatch('生命周期')..start();
    addTearDown(watch.stop);

    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.trends);
    await waitFor(tester, find.text('收缩压'));

    // inactive → resumed,来回三轮。
    //
    // ⚠️ **这里刻意不发 `paused`。** `LiveTestWidgetsFlutterBinding` 的
    // `tester.pump()` 等的是设备上真实的一帧;进程一进 `paused`,引擎就不再产
    // 帧,那个 `await` 永远回不来 —— 用例挂死,不是产品的问题(实测过一次:
    // 05:18 起跑,到 17:23 被 runner 判 did not complete)。
    //
    // 真正的「切后台再切回来」用 adb 手工验过(`input keyevent HOME` →
    // `am start`),App 回到前台后 tab、数据、滚动位置都在,见测试报告。
    // 这里能自动化验的是:生命周期回调本身不会把屏搞没。
    for (var i = 0; i < 3; i++) {
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 100));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester, total: const Duration(seconds: 2));
    }

    // 回来还得停在趋势,数据还在。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('趋势')),
      findsOneWidget,
      reason: '后台切回后 tab 变了',
    );
    expect(find.text('收缩压'), findsWidgets, reason: '后台切回后趋势数据没了');

    // 内存压力信号(等价 `adb shell am send-trim-memory`)。
    tester.binding.handleMemoryPressure();
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text('收缩压'), findsWidgets, reason: '收到内存压力信号后屏空了');

    watch.assertClean();
  });
}
