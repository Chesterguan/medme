// 遗留 4(评审 Minor 13):`AccountFlow.restoreProfileKeys` 的重入守卫。
//
// 为什么这是真的会发生:启动序列那一次是 `unawaited` 的(评审 Important 3 的修法),
// 于是「启动补齐还在跑、用户已经点进账号屏登录」这两条路会真的重叠。而它们各自
// `new` 一个 `AccountFlow`(`main.dart` 的 `_bootOpen` 一个、`VaultBootstrap` 的
// 「去登录」按钮一个)—— 所以守卫必须是**静态**的,实例字段挡不住真正会撞的那一对。
//
// 并发两次的后果不是"多一次请求":两边都看到"本机没有这个 cloudId",于是各
// `create()` 一个成员,同一个云档案在本机变成两个。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 只回一个云档案,并数 `GET /v1/profiles` 被调了几次。真的 delay 一下 —— 纯微任务
/// 链会在第一个 `await` 之前就跑完,那样两次调用压根不会重叠,测不出东西。
class _CountingApi extends ApiClient {
  _CountingApi() : super(base: 'http://x');
  int profileGets = 0;

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    if (path == '/v1/profiles') {
      profileGets++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return [
        {'profile_id': 'prf_1', 'wrapped_profile_key': 'AAAA', 'role': 'owner'},
      ];
    }
    return const [];
  }
}

class _PassthroughCrypto implements SyncCrypto {
  @override
  Future<(Uint8List, Uint8List)> accountKeysNew() async => (Uint8List(32), Uint8List(32));
  @override
  Future<Uint8List> wrapPrivate(Uint8List s, String pw, Uint8List salt, int m, int t, int p) async => Uint8List(40);
  @override
  Future<Uint8List> unwrapPrivatePw(Uint8List b, String pw, Uint8List salt, int m, int t, int p) async => Uint8List(32);
  @override
  Future<String> recoveryCodeNew() async => 'CODE';
  @override
  Future<Uint8List> wrapPrivateRc(Uint8List s, String code) async => Uint8List(40);
  @override
  Future<Uint8List> unwrapPrivateRc(Uint8List b, String code) async => Uint8List(32);
  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async => plaintext;
  @override
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob) async => blob;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-restore-guard-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
    AccountFlow.resetRestoreGuardForTest();
    resetPendingFirstSyncForTest();
    resetPendingCloudEnableForTest();
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
    AccountSession.instance.accountId = 'acc_1';
    AccountSession.instance.access = 'tok';
    AccountSession.instance.publicKey = Uint8List(32);
    AccountSession.instance.privateKey = Uint8List(32);
    AccountSession.instance.loggedIn.value = true;
  });

  tearDown(() async => support.delete(recursive: true));

  AccountFlow flow(ApiClient api) => AccountFlow(
        api,
        AccountSession.instance,
        crypto: _PassthroughCrypto(),
        reopenCurrentProfileVault: () async {},
        removeProfile: (_) async => false,
      );

  test('并发两次(两个 AccountFlow 实例)只 adopt 一次:一个成员、一次请求', () async {
    final api = _CountingApi();
    await Future.wait([flow(api).restoreProfileKeys(), flow(api).restoreProfileKeys()]);

    expect(api.profileGets, 1, reason: '后来者应该等前一次的 future,不是自己再跑一遍');
    expect(
      ProfileManager.instance.profiles.where((p) => p.cloudId == 'prf_1').length,
      1,
      reason: '同一个云档案在本机只能有一个成员',
    );
  });

  test('前一次跑完之后,再调一次照常跑(守卫不是"只跑一次"的闸)', () async {
    final api = _CountingApi();
    await flow(api).restoreProfileKeys();
    await flow(api).restoreProfileKeys();

    expect(api.profileGets, 2);
    expect(ProfileManager.instance.profiles.where((p) => p.cloudId == 'prf_1').length, 1);
  });

  // ---- UX 第二轮:有账号默认开云 —— `restoreProfileKeys` 是"本机密钥就绪"的唯一
  // 汇流处(注册完 / 口令解锁完 / 每次启动补齐都经过它),所以登记只挂那一处。----

  test('补齐完:还没上云的成员全部进"默认开云"队列', () async {
    final api = _CountingApi();
    await ProfileManager.instance.create('爸爸');
    await flow(api).restoreProfileKeys();

    final ids = ProfileManager.instance.profiles.where((p) => p.cloudId == null).map((p) => p.id).toSet();
    expect(ids, isNotEmpty);
    expect(pendingCloudEnable, containsAll(ids));
  });

  test('用户关过的成员不进队列(不许下次启动又替他打开)', () async {
    final api = _CountingApi();
    final id = (await ProfileManager.instance.create('爸爸'))!;
    await ProfileManager.instance.setCloudPaused(id, true);

    await flow(api).restoreProfileKeys();

    expect(pendingCloudEnable, isNot(contains(id)));
  });

  test('已经上云的成员不进队列', () async {
    final api = _CountingApi();
    await flow(api).restoreProfileKeys(); // 领回 prf_1,建出那个成员
    final adopted = ProfileManager.instance.profiles.firstWhere((p) => p.cloudId == 'prf_1');
    expect(pendingCloudEnable, isNot(contains(adopted.id)));
  });
}
