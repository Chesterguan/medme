// 最终评审 C1:`AccountSession.ensureLoaded()` 在产品代码里一次都没被调用过,
// 于是每次冷启动后整套云功能等于不存在——token/私钥/档案密钥都还在本机存储里,
// 但内存态是空的,`loggedIn` 恒 false。
//
// 这个文件钉三件事(都是"冷启动之后"的下游后果,而不是"某个函数被调过"):
//   1. 顺序:账号态必须在**开箱之前**读回来(`openCurrentProfileVault` 靠
//      `AccountSession.profileKey()` 选 keyed/unkeyed/locked 分支);
//   2. 恢复:save() → 内存清空(模拟进程重启)→ 走一遍启动序列 → 账号又在了;
//   3. 两个靠它的下游路径真的活了:`AccountFlow.resumeIfLoggedIn()` 能落到正确的
//      阶段,`triggerBackgroundSync` 真的会跑一次同步。
//
// `openVault`/`loadMode` 用假实现(真的那两个要 Rust 原生库 + path_provider,
// `flutter test` 一调就崩)——同 `wipe_all_data_test.dart`/
// `switch_profile_and_reopen_test.dart` 抽参数的同一个套路。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/vault_boot.dart' show ProfileLocked;
import 'package:shared_preferences/shared_preferences.dart';

/// 只回 `/v1/account/keys`(有密钥)和 `/v1/profiles`(空列表)的假 API——
/// `resumeIfLoggedIn()` 要的就这两个。
class _FakeApi extends ApiClient {
  _FakeApi() : super(base: 'http://x');
  final calls = <String>[];

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    if (path == '/v1/account/keys') {
      return {
        'public_key': 'AA==',
        'wrapped_priv_pw': 'AA==',
        'wrapped_priv_rc': 'AA==',
        'kdf_salt': 'AA==',
        'kdf_params': {'m_kib': 8, 't': 1, 'p': 1},
      };
    }
    return const <dynamic>[];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
  });

  test('顺序:账号态先读回来,才轮到开箱(开箱要靠它选 keyed/locked 分支)', () async {
    final order = <String>[];
    await runBootSequence(
      restoreAccountSession: () async => order.add('session'),
      openVault: () async => order.add('vault'),
      loadMode: () async => order.add('mode'),
      restoreProfileKeys: () async => order.add('keys'),
    );
    expect(order.first, 'session', reason: '开箱读不到档案密钥 = 每个云成员都被判成 ProfileLocked');
    expect(order, containsAll(['vault', 'mode']));
  });

  test('开箱失败时照样抛出去(错误屏还得照显示),但账号态已经读回来了', () async {
    await AccountSession.instance.save(accountId: 'acc_1', access: 'a', refresh: 'r');
    AccountSession.instance.resetForTest();

    await expectLater(
      runBootSequence(
        restoreAccountSession: AccountSession.instance.ensureLoaded,
        openVault: () async => throw StateError('boom'),
        loadMode: () async {},
        restoreProfileKeys: () async {},
      ),
      throwsA(isA<StateError>()),
    );
    expect(AccountSession.instance.accountId, 'acc_1');
  });

  test('冷启动:save → 内存清空 → 启动序列 → 登录态/私钥/档案密钥都回来了', () async {
    await AccountSession.instance.save(
      accountId: 'acc_1',
      access: 'access-1',
      refresh: 'refresh-1',
      publicKey: Uint8List.fromList([1, 2, 3]),
      privateKey: Uint8List.fromList([4, 5, 6]),
      loginMethod: 'otp',
    );
    await AccountSession.instance.putProfileKey('prf_1', Uint8List.fromList(List.generate(32, (i) => i)));

    // 模拟进程重启:内存态全清,底层存储不动。
    AccountSession.instance.resetForTest();
    expect(AccountSession.instance.loggedIn.value, isFalse, reason: '这就是 bug 发生时 App 全程的状态');

    await runBootSequence(
      restoreAccountSession: AccountSession.instance.ensureLoaded,
      openVault: () async {},
      loadMode: () async {},
      restoreProfileKeys: () async {},
    );

    expect(AccountSession.instance.accountId, 'acc_1');
    expect(AccountSession.instance.access, 'access-1');
    expect(AccountSession.instance.refresh, 'refresh-1', reason: '没有它,401 自动刷新也无从下手');
    expect(AccountSession.instance.privateKey, Uint8List.fromList([4, 5, 6]));
    expect(AccountSession.instance.loggedIn.value, isTrue);
    expect(await AccountSession.instance.profileKey('prf_1'), isNotNull);
  });

  test('冷启动后 resumeIfLoggedIn() 能落到正确阶段(之前恒返回 null)', () async {
    await AccountSession.instance.save(
      accountId: 'acc_1',
      access: 'access-1',
      refresh: 'refresh-1',
      privateKey: Uint8List.fromList([4, 5, 6]),
    );
    AccountSession.instance.resetForTest();

    final api = _FakeApi();
    final flow = AccountFlow(api, AccountSession.instance, reopenCurrentProfileVault: () async {});

    expect(await flow.resumeIfLoggedIn(), isNull, reason: 'ensureLoaded 之前:账号态是空的,什么都恢复不了');
    expect(api.calls, isEmpty);

    await runBootSequence(
      restoreAccountSession: AccountSession.instance.ensureLoaded,
      openVault: () async {},
      loadMode: () async {},
      restoreProfileKeys: () async {},
    );

    expect(await flow.resumeIfLoggedIn(), LoginOutcome.ready, reason: '本机有私钥 + 服务端有密钥 → 直接就绪');
    expect(api.calls, contains('GET /v1/account/keys'));
  });

  // ---- B6:新授权/新成员要在**启动时**出现,不必等用户去账号屏重新登录一次 ----
  test('B6:启动序列会跑一次 restoreProfileKeys,而且排在账号态与开箱之后', () async {
    final order = <String>[];
    await runBootSequence(
      restoreAccountSession: () async => order.add('session'),
      openVault: () async => order.add('vault'),
      loadMode: () async => order.add('mode'),
      restoreProfileKeys: () async => order.add('keys'),
    );
    // 它是 unawaited 的,所以 `runBootSequence` 返回时可能还没跑 —— 给它一拍。
    await Future<void>.delayed(Duration.zero);
    expect(order, contains('keys'));
    expect(
      order.indexOf('session') < order.indexOf('keys'),
      isTrue,
      reason: '它要用 session.privateKey 解档案密钥,读回来之前跑就是白跑',
    );
    expect(
      order.indexOf('vault') < order.indexOf('keys'),
      isTrue,
      reason: '它会 create()/switchTo 动 currentId,而开箱读的正是 current —— '
          '并发跑有一个真实的窗口会开错箱子(评审 Important 3)',
    );
  });

  // 评审 Important 3:`Net.connect` 20s + `Net.idle` 30s —— 单单一个
  // `GET /v1/profiles` 就能把启动画面按住约 50 秒。
  test('Important 3:restoreProfileKeys 再慢也不拖住启动(不 await)', () async {
    var finished = false;
    final slow = Completer<void>();

    await runBootSequence(
      restoreAccountSession: () async {},
      openVault: () async {},
      loadMode: () async {},
      restoreProfileKeys: () => slow.future, // 永远不完成 = 最坏的慢网
    ).then((_) => finished = true);

    expect(finished, isTrue, reason: '启动必须已经走完,哪怕补齐那一步还吊着');
    slow.complete();
  });

  test('B6:restoreProfileKeys 失败不许挡住启动(否则断网就进不去 App)', () async {
    var opened = false;
    await runBootSequence(
      restoreAccountSession: () async {},
      openVault: () async => opened = true,
      loadMode: () async {},
      restoreProfileKeys: () async => throw StateError('补密钥炸了'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(opened, isTrue, reason: '"顺手补齐"不是启动的前提');
  });

  test('Important 3:开箱失败也要跑补齐 —— ProfileLocked 恰恰是最需要它的时候', () async {
    var restored = false;
    await expectLater(
      runBootSequence(
        restoreAccountSession: () async {},
        openVault: () async => throw const ProfileLocked('prf_1'),
        loadMode: () async {},
        restoreProfileKeys: () async => restored = true,
      ),
      throwsA(isA<ProfileLocked>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(restored, isTrue, reason: 'ProfileLocked = 本机缺档案密钥,而补密钥正是它干的事');
  });

  test('冷启动后后台同步触发器真的会跑(之前 loggedIn 恒 false,永远 no-op)', () async {
    await AccountSession.instance.save(accountId: 'acc_1', access: 'access-1', refresh: 'refresh-1');
    AccountSession.instance.resetForTest();
    const cloudProfile = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

    var runs = 0;
    Future<SyncReport> fakeSync(Profile p) async {
      runs++;
      return SyncReport();
    }

    await triggerBackgroundSync(
      session: AccountSession.instance,
      currentProfile: () => cloudProfile,
      sync: fakeSync,
    );
    expect(runs, 0, reason: 'ensureLoaded 之前:loggedIn 是 false,触发器直接 no-op');

    await runBootSequence(
      restoreAccountSession: AccountSession.instance.ensureLoaded,
      openVault: () async {},
      loadMode: () async {},
      restoreProfileKeys: () async {},
    );

    await triggerBackgroundSync(
      session: AccountSession.instance,
      currentProfile: () => cloudProfile,
      sync: fakeSync,
    );
    expect(runs, 1);
  });
}
