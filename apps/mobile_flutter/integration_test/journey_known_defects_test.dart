// 已知缺陷的**钉子**。这些用例**故意不修产品代码**(本轮任务约束:发现 bug 只
// 报告不修),而是把「现在到底是什么行为」钉下来,修好之后这些断言会红,那正是
// 提醒改这份文件的时候。
//
// 每条都标了:复现路径 / 现象 / 我判断的严重度。
//
//     flutter test integration_test/journey_known_defects_test.dart -d emulator-5554

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
  // 现象:`bumpVaultRevision()` 触发应急卡屏的
  //       `setState(() => _future = _load())`(emergency_card_screen.dart:58),
  //       箭头函数把 `Future` 当成了 setState 的返回值。debug 构建里
  //       `State.setState` 的断言在 **`markNeedsBuild()` 之前**抛出 ——
  //       于是 `_future` 换成了新的,却**没有任何一次重建被调度**。
  //       五个 tab 全在 `IndexedStack` 里、且 `tabScreens` 是 `const` 列表,
  //       切 tab 也不会让它重建(`identical(newWidget, oldWidget)` 直接跳过)。
  //       结果:**应急卡一直显示冷启动那一刻的内容,直到 App 重启。**
  // 影响面:release 构建里断言被剥掉,`markNeedsBuild()` 照常执行 → 正常;
  //       **debug / profile 构建必现**,而团队自己装的正是带 `.dev` 后缀的
  //       debug 包(commit e89516c)。
  // 严重度:**中**(终端用户拿到的 release 包不受影响;但内部验收看到的应急卡
  //       是过期的,而应急卡恰恰是「别人拿着你的手机」那一屏)。
  // 对照:概览 / 趋势 / 档案三屏都为这件事写了语句块 + 注释,只有应急卡漏了。
  testWidgets('BUG-1 应急卡的 setState 传了个 Future —— 存完不重建,内容停在冷启动那一刻', (
    tester,
  ) async {
    await bootApp(tester);
    final before = knownDefectHits;

    // 先把应急卡打开过一次(其实不必 —— IndexedStack 冷启动就把它挂上了)。
    await gotoTab(tester, HomeTab.emergency);
    await waitFor(tester, find.text('过敏史'));
    expect(find.textContaining('已导入的病历里没有读到诊断名'), findsOneWidget);

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

    // **这就是 bug**:存一条就报一次。
    expect(
      knownDefectHits, greaterThan(before),
      reason: 'BUG-1 已经修好了 —— 请把这条用例和 harness.dart 的 kKnownDefects '
          '一起删掉,并把下面那条「不重建」的断言反过来写。',
    );
  });

  // BUG-1 的**用户可见后果**:载入示例数据(里面有过敏史、用药、诊断)之后,
  // 应急卡那一屏一个字都不变 —— 它根本没被重建。这一条是上面那条断言的兑现,
  // 也是「为什么这不只是一条控制台噪音」的证据。
  testWidgets('BUG-1 后果:导入之后应急卡不刷新,还停在空态', (tester) async {
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

    // 数据层确实有过敏史了。
    final card = await viewEmergencyCard();
    debugPrint('[BUG-1] 数据层:过敏 ${card.allergies.length} 条,'
        '用药 ${card.activeMeds.length} 条,诊断 ${card.conditions.length} 条');
    expect(
      card.allergies.length + card.activeMeds.length + card.conditions.length,
      greaterThan(0),
      reason: '示例数据里应当抽得出过敏史/用药/诊断,否则这条用例证明不了什么',
    );

    // 切到应急卡 —— 屏上却还是空态。
    await gotoTab(tester, HomeTab.emergency);
    await settle(tester, total: const Duration(seconds: 3));
    expect(
      find.textContaining('已导入的病历里没有找到过敏记录'),
      findsOneWidget,
      reason: 'BUG-1 已经修好了 —— 应急卡现在会随保险箱变更刷新,请删掉这条用例。',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  // ── BUG-3 ────────────────────────────────────────────────────────────────
  //
  // 复现:设置 →「清空所有数据 · 重置保险箱」→ 确认 → 回概览 →「记录」→ 填
  //       128/82 → 保存。
  // 现象:弹层不关,红字「保存失败:AnyhowException(io: No such file or
  //       directory (os error 2))」。**清空之后到重启之前,一条都存不进去**
  //       (手动录入、导入、载入示例都一样,它们最后都要往这个箱子里写)。
  // 根因:`vault_boot.dart` 的 `wipeAllData()` 顺序是
  //         ② `openCurrentProfileVault()`   → 开在 `<docs>/profiles/p-1/vault`
  //         ③ `resetVault()`                → 干净清掉活跃那处
  //         ⑤ `rmDir('<docs>/profiles')`    → **把刚开着的那个目录整个删掉**
  //       第 ⑤ 步的注释说它删的是「所有子成员数据」,但恢复出厂之后 root 成员
  //       自己也住在 `profiles/p-1/` 里(`localBaseOf` 对所有成员一视同仁,
  //       `ProfileManager` 的文档明说「成员一律平等,路径规则只有一条」)——
  //       所以 `profiles/` 不是「子成员目录」,而是**全部**成员目录,含当前这个。
  //       删完没有重开:`_confirmAndResetVault` 只 `bumpVaultRevision()`。
  // 为什么读还正常:`patientProfile()` 等读路径走已打开的连接/内存态,
  //       所以「清空成功」这个反馈是真的,坏掉的是**之后的写**。
  // 严重度:**高**(release / debug 都中;数据不丢,但功能整块失效,而用户此刻
  //       正处在「我刚清空,准备重新开始录」的状态,最可能马上就要写)。
  testWidgets('BUG-3 清空所有数据之后写不进任何东西(vault 目录被自己删掉了)', (tester) async {
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

    // 读还是好的 —— 所以用户看到的是「已清空」,以为一切正常。
    expect((await patientProfile()).recordCount, 0, reason: '清空本身没生效');

    // 现在往里写一条 —— 走真实 UI。
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

    // **这就是 bug**:弹层没关,屏上是一条保存失败的红字。
    expect(
      find.textContaining('保存失败'),
      findsOneWidget,
      reason: 'BUG-3 已经修好了(清空之后还能写)—— 请删掉这条用例,'
          '并把 harness.dart `resetEverything` 里那句补开的 openCurrentProfileVault 也去掉。',
    );
    final err = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.contains('保存失败'), orElse: () => '');
    debugPrint('[BUG-3] 保存失败文案:$err');
    expect(err, contains('No such file or directory'),
        reason: '失败原因变了,BUG-3 的根因描述需要重新核对:$err');
    expect((await patientProfile()).recordCount, 0, reason: '这条其实没存进去');
  }, timeout: const Timeout(Duration(minutes: 5)));

  // ── BUG-4 ────────────────────────────────────────────────────────────────
  //
  // 复现:概览 →「看病带这个」→「我想问医生的」右侧的「加一条」→ 写一句 → 保存。
  // 现象:笔记确实存进去了,但**浮层一个字都不变** —— 用户看着自己刚写的东西
  //       没出现,自然会再写一遍。关掉浮层重开才看得到。
  // 根因:`visit_summary_sheet.dart:98` 的
  //       `setState(() => _future = viewVisitSummary())` —— 与 BUG-1 同一个
  //       写法(箭头函数返回 `Future`),debug 断言在 `markNeedsBuild()` 之前抛。
  //       而且这一处是在 `async` 方法里、被 `VoidCallback` 调用,异常直接逃成
  //       **未捕获的 zone 错误**(BUG-1 那处被 `notifyListeners` 的 try/catch
  //       接住,只是打印)。
  // 讽刺的是这个方法自己的文档写着:「存完刷新这一屏的数据,不需要用户自己关掉
  //       浮层再重开」。
  // 影响面:与 BUG-1 一样,release 里断言被剥掉 → 正常;debug / profile 必现。
  // 严重度:**中**(同 BUG-1)。
  //
  // ⚠️ **这一条钉不进集成测试,原因在测试框架而不在产品。** BUG-1 那处抛在
  // `ChangeNotifier.notifyListeners` 的 try/catch 里,只走 `FlutterError.onError`,
  // 用例还能继续跑完再断言;BUG-4 这处抛在一个 `async` 方法里、由 `VoidCallback`
  // 调起,异常逃成**未捕获的 zone 错误** —— `flutter_test` 收到它就直接把用例的
  // completer 以错误完成,**测试体当场终止**,`tester.takeException()` 那行根本
  // 执行不到。手工试过:用例必红,而且会把 `LiveTestWidgetsFlutterBinding.postTest`
  // 的 `_pendingFrame == null` 一起带塌,污染同文件后面的用例。
  //
  // 所以 BUG-4 改由一条**源码级**回归测试钉住,两个站点一起:
  //     apps/mobile_flutter/test/known_defect_setstate_future_test.dart
  // 那条用 `flutter test` 就能跑,不需要设备,修好之后会立刻变红。

  // ── BUG-2 ────────────────────────────────────────────────────────────────
  //
  // 复现:存一条正常范围内的家测血压(如 128/82),看概览「最近的关键化验」;
  //       或导入任意一张带参考区间的化验单,看任何一个正常项。
  // 现象:每一行数值左边都挂着一个灰色 pill,上面印着一个字母 **「N」**。
  // 根因:Rust 侧 `flag` 的取值域是 `"H" | "L" | "N" | null`
  //       (`packages/parser/src/labs.rs:110` 的文档、:934 的实现;自测值走
  //       `aggregate.rs:458` 同一套),而 Dart 侧 `labStatusOf`
  //       (`lib/widgets/lab_status.dart`)只认 H/↑/L/↓,`"N"` 落进了
  //       `LabStatus.unknown` —— 那一档的语义是「化验单上印了个我们不认识的
  //       记号,原样透出」,于是内部编码被当成印刷体显示给了用户。
  // 违反:同一个文件自己的注释:「正常不上色(一份血常规 22 项只有 1–2 项异常,
  //       给正常配色会把异常淹没)」。现在 22 项里 20 项都挂着「N」,真正的
  //       「偏高」被淹在一片 N 里;而「HH」「危」这种真正读不懂的记号,和例行
  //       正常值长得一模一样。
  // 严重度:**中高**(不丢数据,但每一行都受影响,且直接损害这一屏的核心判读;
  //       面向的是看不懂英文缩写的中老年用户)。
  // 测试盲点:`test/mobile_ia_test.dart` 测了 'HH' 和 '危' 落进 unknown,
  //       **就是没测 'N'**。
  testWidgets('BUG-2 正常值被打上灰色「N」pill —— Rust 的 flag 契约含 N,Dart 没认', (
    tester,
  ) async {
    // 纯函数层先钉一道:这是根因所在。
    expect(
      labStatusOf('N'),
      LabStatus.unknown,
      reason: 'BUG-2 已经修好了(labStatusOf 现在认得 N)—— 请把这条用例改成 '
          'expect(labStatusOf("N"), isNull) 并删掉下面的 UI 断言。',
    );

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

    // 128 / 82 都在家测参考区间(≤135 / ≤85)之内 —— 完全正常。
    // 期望的正确行为是**没有 pill**;实际每行挂一个印着「N」的 pill。
    final pills = find.text('N');
    debugPrint('[BUG-2] 屏上「N」pill 数量 = ${pills.evaluate().length}');
    expect(
      pills,
      findsWidgets,
      reason: 'BUG-2 已经修好了 —— 正常值不再挂 N pill,请删掉这条用例。',
    );
  });
}
