// 用户视角五:**多成员用户**(一家人共用一台手机)。
//
// 覆盖:新增、切换、删除;**删掉当前正在看的那个成员**会怎样;成员名极长 /
// 含 emoji / 纯空格 / 同名。
//
// 这一屏最贵的 bug 是「把家人的病历当自己的给医生看」—— 所以每次切换之后都
// 核一遍「现在开着的到底是谁的箱子」,而不是只看 UI 高亮。
//
//     flutter test integration_test/journey_members_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';

import 'harness.dart';

const kLongName = '张建国张建国张建国张建国张建国张建国张建国张建国张建国张建国'
    '张建国张建国张建国张建国张建国张建国张建国张建国张建国张建国';
const kEmojiName = '👵🏻奶奶🩺';

Future<void> addBpFor(double sys) => addSelfMeasurement(
      values: [
        SelfMeasuredValueDto(
            analyteKey: 'bp_systolic', value: sys, unit: 'mmHg'),
        SelfMeasuredValueDto(
            analyteKey: 'bp_diastolic', value: 80, unit: 'mmHg'),
      ],
      measuredAt: DateTime.now().toUtc().toIso8601String(),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('新增 / 切换 / 每人一箱互不串味', (tester) async {
    final watch = OverflowWatch('多成员')..start();
    addTearDown(watch.stop);

    await resetEverything();
    final pm = ProfileManager.instance;

    // 默认成员先存一条 111。
    await addBpFor(111);
    final rootId = pm.currentId.value;

    // 新建「妈妈」并存一条 122。
    final momId = await createProfileAndReopen('妈妈');
    expect(momId, isNotNull);
    expect((await patientProfile()).recordCount, 0,
        reason: '新成员的箱子不是空的 —— 串味了');
    await addBpFor(122);

    // 新建「爸爸」并存两条。
    final dadId = await createProfileAndReopen('爸爸');
    await addBpFor(133);
    await addBpFor(144);
    expect((await patientProfile()).recordCount, 2);

    // 切回去逐个核对。
    await switchProfileAndReopen(rootId);
    expect((await patientProfile()).recordCount, 1, reason: '切回默认成员数据对不上');
    await switchProfileAndReopen(momId!);
    expect((await patientProfile()).recordCount, 1);
    await switchProfileAndReopen(dadId!);
    expect((await patientProfile()).recordCount, 2);

    // UI:档案屏顶部的成员 tab 条应当列全。
    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.archive);
    await waitFor(tester, find.text('妈妈'));
    expect(find.text('爸爸'), findsWidgets);

    watch.assertClean();
  });

  testWidgets('删掉当前正在看的成员 —— 自动切到剩下的第一个,不留空壳', (tester) async {
    await resetEverything();
    final pm = ProfileManager.instance;

    final rootId = pm.currentId.value;
    await addBpFor(111);
    final momId = (await createProfileAndReopen('妈妈'))!;
    await addBpFor(122);

    expect(pm.currentId.value, momId, reason: '新建成员后没切过去');

    // 删的正是「当前正在看的」那个。
    final removed = await removeProfileAndReopen(momId);
    expect(removed, isTrue);
    expect(pm.currentId.value, rootId, reason: '删掉当前成员后没有自动切到剩下的第一个');
    expect(pm.byId(momId), isNull);
    // 关键:此刻开着的箱子必须是 root 的,而不是一个已经被删掉的目录。
    expect((await patientProfile()).recordCount, 1,
        reason: '删掉当前成员后,开着的还是那个已删目录的箱子');

    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.archive);
    await settle(tester, total: const Duration(seconds: 2));
    expect(find.text('妈妈'), findsNothing, reason: '删掉的成员还在 tab 条上');
  });

  testWidgets('删到只剩一个时不给删(该走「清空所有数据」)', (tester) async {
    await resetEverything();
    final pm = ProfileManager.instance;
    expect(pm.profiles.length, 1);
    expect(pm.canRemove(pm.currentId.value), isFalse);
    final removed = await removeProfileAndReopen(pm.currentId.value);
    expect(removed, isFalse, reason: '把最后一个成员删掉了 —— 保险箱变成无人状态');
    expect(pm.profiles.length, 1);
  });

  testWidgets('极端成员名:纯空格 / 极长 / emoji / 同名', (tester) async {
    final watch = OverflowWatch('极端成员名')..start();
    addTearDown(watch.stop);

    await resetEverything();
    final pm = ProfileManager.instance;
    final before = pm.profiles.length;

    // ① 纯空格 —— 不该建出一个看不见名字的成员。
    final blank = await pm.create('     ');
    expect(blank, isNull, reason: '纯空格建出了成员');
    expect(pm.profiles.length, before);

    // ② 极长名字。
    final longId = await createProfileAndReopen(kLongName);
    expect(longId, isNotNull);

    // ③ emoji 名字。
    await createProfileAndReopen(kEmojiName);

    // ④ 同名不去重(家里有两个「张伟」很正常)。
    await createProfileAndReopen('张伟');
    await createProfileAndReopen('张伟');
    expect(pm.profiles.where((p) => p.name == '张伟').length, 2);

    // 屏上不该被挤爆:档案屏的成员 tab 条 + 设置的保险箱卡都过一遍。
    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.archive);
    await settle(tester, total: const Duration(seconds: 2));

    await gotoTab(tester, HomeTab.settings);
    await waitFor(
      tester,
      find.descendant(of: find.byType(AppBar), matching: find.text('设置')),
    );
    // 五个成员 + 一个 40 字的名字会把保险箱卡撑得很高,「示例数据」那一节被顶到
    // 屏外 —— `ListView` 不构建屏外的子项,所以要翻下去才找得到。
    expect(await scrollToFind(tester, find.text('清空所有数据 · 重置保险箱')), isTrue,
        reason: '五个成员之后,设置屏翻到底也找不到「清空所有数据」');
    await settle(tester);

    // 概览的身份卡拿的是 `displayName`,极长名字不该把卡撑破。
    await gotoTab(tester, HomeTab.overview);
    await settle(tester, total: const Duration(seconds: 2));

    watch.assertClean();
  });

  testWidgets('成员切换器弹层:列出全部成员、点了真的换箱子', (tester) async {
    await resetEverything();
    await addBpFor(111);
    await createProfileAndReopen('二姨');
    await addBpFor(122);
    await addBpFor(133);

    await bootApp(tester, reset: false);
    await gotoTab(tester, HomeTab.overview);
    await waitFor(tester, find.byType(IdentityHeroCard));

    // 身份卡整卡可点 → 弹成员切换器。
    await tester.tap(find.byType(IdentityHeroCard));
    await settle(tester, total: const Duration(seconds: 2));

    await waitFor(tester, find.text('切换成员'), what: '成员切换弹层');
    expect(find.text('二姨'), findsWidgets);
    expect(find.text(ProfileManager.defaultMemberName), findsWidgets);

    // 切回默认成员,箱子必须真的换回去。
    await tester.tap(find.text(ProfileManager.defaultMemberName).last);
    await settle(tester, total: const Duration(seconds: 3));
    expect((await patientProfile()).recordCount, 1,
        reason: '切换器里点了成员,开着的箱子没换');
  });
}
