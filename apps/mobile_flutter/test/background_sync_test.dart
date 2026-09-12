// `triggerBackgroundSync`(debounced push / app-resume pull 共用的 no-op 判断 +
// 静默失败)的单测——这条逻辑是从 `main.dart` 的 `State` 里抽出来的顶层函数,
// 就是为了让它能在这里不启动真实 Rust/Flutter 绑定的情况下被钉住。
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
}
