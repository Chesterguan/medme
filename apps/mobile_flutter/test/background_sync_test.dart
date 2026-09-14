// `triggerBackgroundSync`(debounced push / app-resume pull 共用的 no-op 判断 +
// 静默失败)的单测——这条逻辑是从 `main.dart` 的 `State` 里抽出来的顶层函数,
// 就是为了让它能在这里不启动真实 Rust/Flutter 绑定的情况下被钉住。
import 'dart:async';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
  });

  test('没登录:no-op,不调 sync', () async {
    AccountSession.instance.loggedIn.value = false;
    var called = false;
    await triggerBackgroundSync(
      session: AccountSession.instance,
      currentProfile: () => const Profile(id: 'p-1', name: 'x', cloudId: 'prf_1'),
      sync: (p) async {
        called = true;
        return SyncReport();
      },
    );
    expect(called, isFalse);
  });

  test('已登录,但当前成员没有 cloudId:no-op,不调 sync', () async {
    AccountSession.instance.loggedIn.value = true;
    var called = false;
    await triggerBackgroundSync(
      session: AccountSession.instance,
      currentProfile: () => const Profile(id: 'p-1', name: 'x'),
      sync: (p) async {
        called = true;
        return SyncReport();
      },
    );
    expect(called, isFalse);
  });

  test('已登录 + 有 cloudId:调用 sync,并传对了这个档案', () async {
    AccountSession.instance.loggedIn.value = true;
    const profile = Profile(id: 'p-1', name: 'x', cloudId: 'prf_1', role: 'owner');
    Profile? got;
    await triggerBackgroundSync(
      session: AccountSession.instance,
      currentProfile: () => profile,
      sync: (p) async {
        got = p;
        return SyncReport();
      },
    );
    expect(got, same(profile));
  });

  test('sync 抛异常:静默吞掉,不往外抛(后台触发器不该打断用户)', () async {
    AccountSession.instance.loggedIn.value = true;
    await expectLater(
      triggerBackgroundSync(
        session: AccountSession.instance,
        currentProfile: () => const Profile(id: 'p-1', name: 'x', cloudId: 'prf_1'),
        sync: (p) async => throw Exception('network boom'),
      ),
      completes,
    );
  });

  // ---- fix round 1 (Task 15 review) I2:重叠触发合并,不并发跑两轮 ----

  test('两次几乎同时触发:合并成"一次在跑 + 一次补跑",不会两轮同时在跑', () async {
    AccountSession.instance.loggedIn.value = true;
    const profile = Profile(id: 'p-1', name: 'x', cloudId: 'prf_1');
    var callCount = 0;
    var concurrent = 0;
    var maxConcurrent = 0;
    final completers = <Completer<void>>[];

    Future<SyncReport> fakeSync(Profile p) async {
      callCount++;
      concurrent++;
      if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      final c = Completer<void>();
      completers.add(c);
      await c.future;
      concurrent--;
      return SyncReport();
    }

    // 第一次触发:进了 sync(),卡在它自己的 completer 上,还没跑完。
    final first = triggerBackgroundSync(session: AccountSession.instance, currentProfile: () => profile, sync: fakeSync);
    await Future<void>.delayed(Duration.zero); // 让第一次真正跑进 sync() 里
    expect(callCount, 1);

    // 第二次几乎同时触发——此刻第一次还没完成,应该只设置"补跑"标记、立刻
    // 返回,而不是新起一轮(那样就会跟第一轮并发)。
    final second = triggerBackgroundSync(session: AccountSession.instance, currentProfile: () => profile, sync: fakeSync);
    await second;
    expect(callCount, 1, reason: '第二次触发时第一次还没完成,不该立刻起第二轮');

    // 放第一轮完成:按合并设计,跑完之后应该自动补跑一轮(因为期间来过第二次
    // 触发),而不是让第二次触发的调用自己单独起一轮。
    completers[0].complete();
    await Future<void>.delayed(Duration.zero); // 让"补跑"那一轮真正调用到 sync()
    expect(callCount, 2, reason: '第一轮跑完后应该自动补跑一轮,合并第二次触发');

    completers[1].complete();
    await first;

    expect(maxConcurrent, 1, reason: '任何时刻只有一轮在跑,两次触发不会并发执行');
  });
}
