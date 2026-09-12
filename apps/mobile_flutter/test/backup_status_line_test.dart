// UX 第二轮:概览屏顶部那一行备份状态。
//
// 为什么它值一整行常驻像素:用户输完口令、抄完恢复码之后心里那句话是"我的病历备上
// 了",而在这之前这件事在产品里一个字都没有 —— 唯一能看见同步结果的地方是账号屏里
// 那句「上次同步:推送 3 条」,既是我们的词汇,又要他先想到去戳账号。
//
// 三态都测(加载中/成功/失败),外加"关掉了"和"没登录"两条。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
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

    test('没登录:照实说病历只在这台手机上,不给"重试"', () {
      final s = backupStatus(loggedIn: false, profile: synced, last: null, now: now);
      expect(s.text, '未登录 · 病历只在这台手机上');
      expect(s.canRetry, isFalse);
    });

    test('用户关掉了这个成员的云同步', () {
      const paused = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', cloudPaused: true);
      final s = backupStatus(loggedIn: true, profile: paused, last: (at: now, ok: true), now: now);
      expect(s.text, '云同步已关闭');
      expect(s.canRetry, isFalse);
    });

    test('还没开通成功(默认开云那条队列还没排到它/上次失败了):可点重试', () {
      const notYet = Profile(id: 'p-1', name: '我');
      final s = backupStatus(loggedIn: true, profile: notYet, last: null, now: now);
      expect(s.text, '还没开始备份 · 点这里重试');
      expect(s.canRetry, isTrue);
    });

    test('上次失败:可点重试', () {
      final s = backupStatus(
        loggedIn: true,
        profile: synced,
        last: (at: now.subtract(const Duration(minutes: 5)), ok: false),
        now: now,
      );
      expect(s.text, '上次备份失败 · 点这里重试');
      expect(s.canRetry, isTrue);
    });

    test('成功:说人话的时间,不给时间戳', () {
      String at(Duration ago) => backupStatus(
        loggedIn: true,
        profile: synced,
        last: (at: now.subtract(ago), ok: true),
        now: now,
      ).text;

      expect(at(const Duration(seconds: 20)), '已备份 · 刚刚');
      expect(at(const Duration(minutes: 3)), '已备份 · 3 分钟前');
      expect(at(const Duration(hours: 5)), '已备份 · 5 小时前');
      expect(at(const Duration(days: 3)), '已备份 · 9月9日');
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

      expect(find.text('未登录 · 病历只在这台手机上'), findsOneWidget);
      await t.tap(find.text('未登录 · 病历只在这台手机上'));
      await t.pumpAndSettle();
      expect(opened, [1]);
    });

    testWidgets('上次失败:点一下就重试,期间显示「正在备份…」,跑完按新结果刷新', (t) async {
      SharedPreferences.setMockInitialValues({
        'last_sync_at': DateTime.now().subtract(const Duration(minutes: 2)).toIso8601String(),
        'last_sync_ok': false,
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
        await saveLastSync(ok: true); // 真实现里这一笔由 `SyncEngine.syncProfile` 记
      });

      expect(find.text('上次备份失败 · 点这里重试'), findsOneWidget);

      await t.tap(find.text('上次备份失败 · 点这里重试'));
      await t.pump();
      expect(find.text('正在备份…'), findsOneWidget, reason: '加载中那一态必须看得见,否则像"点了没反应"');

      await t.pumpAndSettle();
      expect(ran, 1);
      expect(find.text('已备份 · 刚刚'), findsOneWidget);
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
        await saveLastSync(ok: false);
        throw Exception('网络抖了一下');
      });

      await t.tap(find.text('还没备份过 · 点这里立刻备份'));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.text('上次备份失败 · 点这里重试'), findsOneWidget);
    });

    testWidgets('关掉了云同步:说"已关闭",点它进账号屏', (t) async {
      AccountSession.instance.loggedIn.value = true;
      await t.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_1', 'owner', null);
        await ProfileManager.instance.setCloudPaused('p-1', true);
      });

      final opened = <int>[];
      await pumpLine(t, openAccount: () => opened.add(1), retry: () async => fail('关掉了就不该同步'));

      expect(find.text('云同步已关闭'), findsOneWidget);
      await t.tap(find.text('云同步已关闭'));
      await t.pumpAndSettle();
      expect(opened, [1]);
    });
  });
}
