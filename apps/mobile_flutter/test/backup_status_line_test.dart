// 「我」tab 第一行:云端状态(Task 12 从概览搬过来,概览已在 Task 9 解散)。
//
// 为什么它值一整行常驻像素:用户输完口令、抄完恢复码之后心里那句话是"我的病历备上
// 了",而在这之前这件事在产品里一个字都没有 —— 唯一能看见同步结果的地方是账号屏里
// 那句「上次同步:推送 3 条」,既是我们的词汇,又要他先想到去戳账号。
//
// `s5`:这一行是**两段** —— 标题恒为「云端」,[backupStatus] 只给副标题那半句,
// 末尾一个 `›`。三态都测(加载中/成功/失败),外加"关掉了"和"没登录"两条。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/widgets/backup_status_line.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountSession.instance.resetForTest();
  });

  group('backupStatus(纯函数):四态', () {
    const synced = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    final now = DateTime(2026, 9, 12, 10, 0);

    test('没登录:照实说换手机找不回来,不给"重试"', () {
      final s = backupStatus(loggedIn: false, profile: synced, last: null, now: now);
      expect(s.text, '没登录,换手机找不回来');
      expect(s.canRetry, isFalse);
    });

    // fix round 1(task-2-review.md F7):这句话只在没开旧版 iCloud 同步时才真——
    // 那条入口今天收起来了(`settings_screen.dart` 的 `_showIcloudSync = false`),
    // 但 Rust 侧能力还在,入口一露出,「未登录 + iCloud 开」= 上面那句立刻变假。
    test('F7:没登录但这台手机开着旧版 iCloud 同步 → 不能说"换手机找不回来"', () {
      final s = backupStatus(loggedIn: false, profile: synced, last: null, icloudOn: true, now: now);
      expect(s.text, '没登录;同步到你自己的 iCloud');
      expect(s.canRetry, isFalse);
    });

    test('用户关掉了这个成员的云端备份', () {
      const paused = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', cloudPaused: true);
      final s = backupStatus(loggedIn: true, profile: paused, last: (at: now, ok: true), now: now);
      expect(s.text, '备份关着');
      expect(s.canRetry, isFalse);
    });

    test('还没开通成功(默认开云那条队列还没排到它/上次失败了):可点重试', () {
      const notYet = Profile(id: 'p-1', name: '我');
      final s = backupStatus(loggedIn: true, profile: notYet, last: null, now: now);
      expect(s.text, '还没开始备份');
      expect(s.canRetry, isTrue);
    });

    test('上次失败:可点重试', () {
      final s = backupStatus(
        loggedIn: true,
        profile: synced,
        last: (at: now.subtract(const Duration(minutes: 5)), ok: false),
        now: now,
      );
      expect(s.text, '上次没备份成功');
      expect(s.canRetry, isTrue);
    });

    test('I5:这台手机开着 iCloud 同步 → 说真正的原因,而不是一条点不动的「点这里重试」', () {
      const notYet = Profile(id: 'p-1', name: '我');
      final s = backupStatus(loggedIn: true, profile: notYet, last: null, icloudOn: true, now: now);
      expect(s.text, '这台手机开着 iCloud 同步,两套不能一起开');
      expect(s.canRetry, isFalse, reason: '重试一万次都是同一个结果');
    });

    test('F1:已经有 cloudId 也一样说 iCloud —— 这一笔只会在 iCloud 挡住我们时为真', () {
      final s = backupStatus(
        loggedIn: true,
        profile: synced,
        last: (at: now.subtract(const Duration(minutes: 5)), ok: false),
        icloudOn: true,
        now: now,
      );
      expect(s.text, '这台手机开着 iCloud 同步,两套不能一起开');
      expect(s.canRetry, isFalse, reason: '「点这里重试」走 enableCloud 的可续做支路,照样撞 iCloud 那道闸');
    });

    test('成功:说人话的时间,不给时间戳', () {
      String at(Duration ago) => backupStatus(
        loggedIn: true,
        profile: synced,
        last: (at: now.subtract(ago), ok: true),
        now: now,
      ).text;

      expect(at(const Duration(seconds: 20)), '已备份,刚刚');
      expect(at(const Duration(minutes: 3)), '已备份,3 分钟前');
      expect(at(const Duration(hours: 5)), '已备份,5 小时前');
      expect(at(const Duration(days: 3)), '已备份,9月9日');
    });
  });

  group('BackupStatusLine(widget)', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-backup-line-test');
    });

    tearDown(() async => support.delete(recursive: true));

    Future<void> pumpLine(
      WidgetTester t, {
      VoidCallback? openAccount,
      Future<void> Function()? retry,
    }) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: BackupStatusLine(openAccount: openAccount, retry: retry)),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('没登录:显示"未登录",点它进账号屏(不是重试)', (t) async {
      final opened = <int>[];
      await pumpLine(t, openAccount: () => opened.add(1), retry: () async => fail('没登录不该去同步'));

      expect(find.text('没登录,换手机找不回来'), findsOneWidget);
      await t.tap(find.text('没登录,换手机找不回来'));
      await t.pumpAndSettle();
      expect(opened, [1]);
    });

    testWidgets('上次失败:点一下就重试,期间显示「正在备份…」,跑完按新结果刷新', (t) async {
      SharedPreferences.setMockInitialValues({
        'last_sync_at_prf_1': DateTime.now().subtract(const Duration(minutes: 2)).toIso8601String(),
        'last_sync_ok_prf_1': false,
      });
      AccountSession.instance.loggedIn.value = true;
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_1', 'owner', null);
      });

      var ran = 0;
      await pumpLine(t, retry: () async {
        ran++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await saveLastSync(ok: true, cloudId: 'prf_1'); // 真实现里这一笔由 `SyncEngine.syncProfile` 记
      });

      expect(find.text('上次没备份成功'), findsOneWidget);

      await t.tap(find.text('上次没备份成功'));
      await t.pump();
      expect(find.text('正在备份…'), findsOneWidget, reason: '加载中那一态必须看得见,否则像"点了没反应"');

      await t.pumpAndSettle();
      expect(ran, 1);
      expect(find.text('已备份,刚刚'), findsOneWidget);
    });

    testWidgets('重试本身抛异常:不崩、不弹错误,状态照实变成"失败"', (t) async {
      SharedPreferences.setMockInitialValues({});
      AccountSession.instance.loggedIn.value = true;
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_1', 'owner', null);
      });

      await pumpLine(t, retry: () async {
        await saveLastSync(ok: false, cloudId: 'prf_1');
        throw Exception('网络抖了一下');
      });

      await t.tap(find.text('还没备份过'));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.text('上次没备份成功'), findsOneWidget);
    });

    // I6:备份状态是**按成员**的。在这之前那一笔是全局的,于是给 A 同步完之后切到
    // 从没同步过的 B,B 的那一行照样写着「已备份 · 刚刚」—— 对一个"我的病历备上了没"
    // 的问题,这是一句假话。
    testWidgets('I6:同步过 A,切到从没同步过的 B → 不说「已备份」', (t) async {
      AccountSession.instance.loggedIn.value = true;
      late String b;
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_a', 'owner', null);
        b = (await ProfileManager.instance.create('爸爸'))!;
        await ProfileManager.instance.markCloud(b, 'prf_b', 'owner', null);
        await ProfileManager.instance.switchTo('p-1');
        await saveLastSync(ok: true, cloudId: 'prf_a');
      });

      await pumpLine(t, retry: () async {});
      expect(find.text('已备份,刚刚'), findsOneWidget);

      await t.runAsync(() async => ProfileManager.instance.switchTo(b));
      await t.pumpAndSettle();

      expect(find.text('已备份,刚刚'), findsNothing, reason: 'B 从来没同步过');
      expect(find.text('还没备份过'), findsOneWidget);
    });

    // `s5`:这一行是「云端」+ 副标题 + `›`,不是一整句。`›` 是「点得进去」的唯一
    // 提示,而「云端整理」就在里面那一层 —— 漏掉它,下一层就没有入口了。
    testWidgets('整行渲染成 s5 的样子:标题「云端」+ 副标题 + 一个 ›', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: MedMe.theme(),
        home: const Scaffold(body: BackupStatusLine()),
      ));
      await t.pumpAndSettle();

      // 整个「云端」分区就这**一行**(`s5`):标题 + 副标题 + `›`,不是两条各说一半。
      // 复审 round 1:这一行下面原来还挂着一条「登录 / 注册」,同一件事说了两遍。
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('云端'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // 副标题里不许再出现「云端」两个字 —— 标题已经说过一次了。
      expect(find.textContaining('云端 ·'), findsNothing);
      expect(find.text('没登录,换手机找不回来'), findsOneWidget);
    });

    testWidgets('关掉了云端备份:说「备份关着」,点它进下一层', (t) async {
      AccountSession.instance.loggedIn.value = true;
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_1', 'owner', null);
        await ProfileManager.instance.setCloudPaused('p-1', true);
      });

      final opened = <int>[];
      await pumpLine(t, openAccount: () => opened.add(1), retry: () async => fail('关掉了就不该同步'));

      expect(find.text('备份关着'), findsOneWidget);
      await t.tap(find.text('备份关着'));
      await t.pumpAndSettle();
      expect(opened, [1]);
    });
  });
}
