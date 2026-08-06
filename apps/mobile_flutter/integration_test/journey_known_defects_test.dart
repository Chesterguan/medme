// 曾经的**四条缺陷钉子**,现在是四条**回归守卫**。
//
// 这个文件原本记录的是「现在到底是什么行为」—— 那一轮的任务约束是发现 bug 只报告
// 不修,所以断言写的是缺陷本身。四条都修好之后,断言全部翻了过来:现在它们断言的
// 是**正确行为**,任何一条退化都会让这里红。
//
// 每条都保留了原来的复现路径、根因与严重度 —— 那些是这个文件真正的价值,判据可以
// 翻面,「为什么会这样」不该被删掉。
//
//     flutter test integration_test/journey_known_defects_test.dart -d <device>
//
// ⚠️ **修复那一轮这个文件没有被执行过。** 当时没有可用设备(模拟器已由产品负责人
// 关闭,唯一的真机是他本人的日常机,装着他自己的病历,不能碰),所以这批集成测试
// 只做到「编译与静态检查通过」。四条缺陷各自的红→绿证据来自 `test/` 下不需要设备
// 的那几条:
//
//   · BUG-1 → `test/emergency_card_refresh_test.dart`
//   · BUG-2 → `test/mobile_ia_test.dart`(化验状态那一组)
//   · BUG-3 → `test/wipe_all_data_test.dart`
//   · BUG-4 → `test/visit_summary_sheet_test.dart`(「存完笔记要当场刷新」那一组)
//   · 两处写法本身 → `test/known_defect_setstate_future_test.dart`

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ── BUG-1 ────────────────────────────────────────────────────────────────
  //
  // 复现:冷启动 → 概览 →「记录」→ 存任意一条(或导入、清空、载入示例)。
  // 曾经的现象:`bumpVaultRevision()` 触发应急卡屏的
  //       `setState(() => _future = _load())`(箭头体,把 `Future` 当成了 setState
  //       的返回值)。debug 构建里 `State.setState` 的断言在 **`markNeedsBuild()`
  //       之前**抛出 —— 于是 `_future` 换成了新的,却**没有任何一次重建被调度**。
  //       五个 tab 全在 `IndexedStack` 里、且 `tabScreens` 是 `const` 列表,切 tab
  //       也不会让它重建(`identical(newWidget, oldWidget)` 直接跳过)。结果:
  //       **应急卡一直显示冷启动那一刻的内容,直到 App 重启。**
  // 影响面:release 构建里断言被剥掉 → 正常;**debug / profile 必现**,而团队自己
  //       装的正是带 `.dev` 后缀的 debug 包。
  // 修法:`_onVaultChanged` → `_refresh()`,语句块 setState(与概览 / 趋势 / 档案
  //       三屏同一形状)。
  testWidgets('BUG-1 存一条之后,刷新路径上不再有「setState 收到 Future」这类异常', (
    tester,
  ) async {
    await bootApp(tester);

    await gotoTab(tester, HomeTab.emergency);
    await waitFor(tester, find.text('过敏史'));

    // 回概览存一条 —— 走真实 UI。
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('记录'));
    await tester.tap(find.text('记录').first);
    await settle(tester);
    await waitFor(tester, find.text('保存'));
    await tester.enterText(find.byType(TextField).at(0), '128');
    await tester.enterText(find.byType(TextField).at(1), '82');
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await waitGone(tester, find.text('保存'));
    await settle(tester, total: const Duration(seconds: 3));

    expect((await patientProfile()).recordCount, 1, reason: '记录本身没存上');
    assertNoKnownDefects();
  });

  // BUG-1 的**用户可见后果**:载入示例数据(里面有过敏史、用药、诊断)之后,应急卡
  // 那一屏必须跟着变。这一条是上面那条的兑现,也是「为什么这不只是一条控制台噪音」。
  testWidgets('BUG-1 后果:导入之后应急卡当场刷新,不再停在空态', (tester) async {
    await bootApp(tester);

    // 应急卡先看一眼:空态。
    await gotoTab(tester, HomeTab.emergency);
    await waitFor(tester, find.text('过敏史'));
    expect(find.textContaining('已导入的病历里没有找到过敏记录'), findsOneWidget);

    // 灌示例数据(22 份真实版式的病历,里面有过敏史/用药/诊断)。
    var loaded = 0;
    String? err;
    await for (final p in loadDemoData()) {
      if (p.error != null) {
        err = p.error;
        break;
      }
      loaded = p.succeeded.toInt();
    }
    debugPrint('[BUG-1] 示例数据载入 $loaded 份 err=$err');
    expect(err, isNull);
    expect(loaded, greaterThan(0));

    // 与设置页那颗按钮同一条通知路径。
    bumpVaultRevision();
    await settle(tester, total: const Duration(seconds: 4));

    // 数据层确实有东西了。
    final card = await viewEmergencyCard();
    debugPrint('[BUG-1] 数据层:过敏 ${card.allergies.length} 条,'
        '用药 ${card.activeMeds.length} 条,诊断 ${card.conditions.length} 条');
    expect(
      card.allergies.length + card.activeMeds.length + card.conditions.length,
      greaterThan(0),
      reason: '示例数据里应当抽得出过敏史/用药/诊断,否则这条用例证明不了什么',
    );

    // 切到应急卡 —— 屏上必须已经跟着变了。
    await gotoTab(tester, HomeTab.emergency);
    await settle(tester, total: const Duration(seconds: 3));
    expect(
      find.textContaining('已导入的病历里没有找到过敏记录'),
      findsNothing,
      reason: 'BUG-1 复发:应急卡没有随保险箱变更刷新,还停在冷启动那一刻的空态',
    );
    assertNoKnownDefects();
  }, timeout: const Timeout(Duration(minutes: 10)));

  // ── BUG-3 ────────────────────────────────────────────────────────────────
  //
  // 复现:设置 →「清空所有数据 · 重置保险箱」→ 确认 → 回概览 →「记录」→ 填
  //       128/82 → 保存。
  // 曾经的现象:弹层不关,红字「保存失败:AnyhowException(io: No such file or
  //       directory (os error 2))」。**清空之后到重启之前,一条都存不进去**
  //       (手动录入、导入、载入示例都一样,它们最后都要往这个箱子里写)。
  // 根因:`wipeAllData()` 的顺序是「开箱 → 清箱 → 删目录」,而删掉的
  //       `<docs>/profiles` 里就包含刚开好的那个箱子 —— 恢复出厂之后 root 成员
  //       自己也住在 `profiles/p-1/`(`localBaseOf` 对所有成员一视同仁)。旧注释
  //       写的「删所有**子**成员数据」是错的:`profiles/` 是**全部**成员目录。
  // 为什么读还正常:读路径走已打开的连接/内存态,所以「清空成功」这个反馈是真的,
  //       坏掉的是**之后的写**。
  // 严重度:**高**(release / debug 都中)。
  // 修法:确立顺序契约 —— 先松手(`resetVault`)、再删盘、**最后**开箱。见
  //       `vault_boot.dart` 的 `runWipeSequence`。
  testWidgets('BUG-3 清空所有数据之后,立刻还写得进去', (tester) async {
    await bootApp(tester);

    // 先证明清空之前写得进去。
    await addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'bp_systolic', value: 130, unit: 'mmHg'),
        SelfMeasuredValueDto(
            analyteKey: 'bp_diastolic', value: 84, unit: 'mmHg'),
      ],
      measuredAt: DateTime.now().toUtc().toIso8601String(),
    );
    bumpVaultRevision();
    expect((await patientProfile()).recordCount, 1);

    // 走**真实 UI**清空:设置 → 清空 → 确认。
    await gotoTab(tester, HomeTab.settings);
    await waitFor(tester, find.text('清空所有数据 · 重置保险箱'));
    await tester.tap(find.text('清空所有数据 · 重置保险箱'));
    await settle(tester, total: const Duration(seconds: 2));
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await settle(tester, total: const Duration(seconds: 6));

    expect((await patientProfile()).recordCount, 0, reason: '清空本身没生效');

    // 现在往里写一条 —— 走真实 UI。这就是用户清空之后做的第一件事。
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('记录'));
    await tester.tap(find.text('记录').first);
    await settle(tester);
    await waitFor(tester, find.text('保存'));
    await tester.enterText(find.byType(TextField).at(0), '128');
    await tester.enterText(find.byType(TextField).at(1), '82');
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settle(tester, total: const Duration(seconds: 5));

    expect(
      find.textContaining('保存失败'),
      findsNothing,
      reason: 'BUG-3 复发:清空之后写不进去了 —— 多半是又有人把 `rm` 排到了开箱后面,'
          '见 `vault_boot.dart` `runWipeSequence` 的顺序契约',
    );
    expect(
      (await patientProfile()).recordCount,
      1,
      reason: '清空之后的第一条记录必须真的落库',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  // ── BUG-4 ────────────────────────────────────────────────────────────────
  //
  // 复现:概览 →「看病带这个」→「我想问医生的」右侧的「加一条」→ 写一句 → 保存。
  // 曾经的现象:笔记确实存进去了,但**浮层一个字都不变** —— 用户看着自己刚写的
  //       东西没出现,自然会再写一遍。关掉浮层重开才看得到。
  // 根因:`visit_summary_sheet.dart` 的 `setState(() => _future = viewVisitSummary())`
  //       —— 与 BUG-1 同一个写法。而且这一处是在 `async` 方法里、被 `VoidCallback`
  //       调用,异常直接逃成**未捕获的 zone 错误**(BUG-1 那处被 `notifyListeners`
  //       的 try/catch 接住,只是打印)。讽刺的是这个方法自己的文档写着:「存完刷新
  //       这一屏的数据,不需要用户自己关掉浮层再重开」。
  //
  // ⚠️ **这一条仍然不在这个文件里驱动**,原因和当初一样在成本而不在缺陷:它要走完整
  // 的「加一条 → 录入弹层 → 保存」链路(两层浮层 + FFI 落库),在集成测试里噪音大。
  // 修好之后的行为由 `test/visit_summary_sheet_test.dart` 的「存完笔记要当场刷新」
  // 那一组钉住 —— 那里把数据源与「加一条」都注入成假的,`flutter test` 就能跑,不需要
  // 设备,断言的是「存完真的重新拉了一次、新笔记出现在屏上、放弃时不白拉」。
  //
  // 写法本身(两个站点都不许再出现箭头体 setState)由
  // `test/known_defect_setstate_future_test.dart` 从源码层守着。

  // ── BUG-2 ────────────────────────────────────────────────────────────────
  //
  // 复现:存一条正常范围内的家测血压(如 128/82),看概览「最近的关键化验」;
  //       或导入任意一张带参考区间的化验单,看任何一个正常项。
  // 曾经的现象:每一行数值左边都挂着一个灰色 pill,上面印着一个字母 **「N」**。
  // 根因:Rust 侧 `flag` 的取值域是 `"H" | "L" | "N" | null`
  //       (`packages/parser/src/labs.rs` 的文档与实现;自测值走 `aggregate.rs`
  //       同一套),而 Dart 侧 `labStatusOf` 只认 H/↑/L/↓,`"N"` 落进了
  //       `LabStatus.unknown` —— 那一档的语义是「化验单上印了个我们不认识的记号,
  //       原样透出」,于是内部编码被当成印刷体显示给了用户。
  // 违反:同一个文件自己的注释:「正常不上色(一份血常规 22 项只有 1–2 项异常,
  //       给正常配色会把异常淹没)」。而「HH」「危」这种真正读不懂的记号,和例行
  //       正常值长得一模一样 —— 这才是危险的地方。
  // 修法:`'N' => null`(与「没有标记」同样什么都不画)。为什么不给它一个新档,
  //       见 `lib/widgets/lab_status.dart` 里 `labStatusOf` 的文档。
  testWidgets('BUG-2 正常值不再挂灰色「N」pill', (tester) async {
    // 纯函数层先钉一道:这是根因所在。
    expect(labStatusOf('N'), isNull, reason: 'BUG-2 复发:`N` 又落回 unknown 了');

    await bootApp(tester);
    await addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'bp_systolic', value: 128, unit: 'mmHg'),
        SelfMeasuredValueDto(
            analyteKey: 'bp_diastolic', value: 82, unit: 'mmHg'),
      ],
      measuredAt: DateTime.now().toUtc().toIso8601String(),
    );
    bumpVaultRevision();

    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.text('收缩压'));

    // 128 / 82 都在家测参考区间(≤135 / ≤85)之内 —— 完全正常,不该有任何 pill。
    expect(
      find.text('N'),
      findsNothing,
      reason: 'BUG-2 复发:一个内部编码又被当成印刷体印给用户了',
    );
    expect(find.text('偏高'), findsNothing);
    expect(find.text('偏低'), findsNothing);
  });
}
