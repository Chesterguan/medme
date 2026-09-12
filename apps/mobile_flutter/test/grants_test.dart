// Grants 的单测:全部用假 API + 假 Rust 桥(`flutter test` 不加载原生库,真实
// FRB 调用在这里会直接崩——同 `sync_engine_test.dart`/`account_screen_test.dart`
// 顶部同一条限制)。`redeem`/`purgeExpired` 末尾各有一段必须碰真实 Rust 原生库
// (`syncOpenProfileVault`)或 `path_provider`(`removeProfileAndReopen` 删目录)
// 的收尾,本文件不测那两段——同 `sync_engine_test.dart` 对 `enableCloud` 的处理:
// 用可注入的假实现(`afterStored`/`removeProfile`)钉住"选中了哪些、传了什么"
// 这几步可测的逻辑。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart' show ProfileLocked;
import 'package:shared_preferences/shared_preferences.dart';

/// 假 API:按路径返回预设响应,或按路径抛预设失败;记下每次调用与最后一次的
/// 请求体供断言。
class FakeApi extends ApiClient {
  FakeApi({this.responses = const {}, this.failures = const {}}) : super(base: 'http://x');

  final Map<String, Map<String, dynamic>> responses;
  final Map<String, ApiFailed> failures;
  final calls = <String>[];
  Map<String, dynamic>? lastBody;

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    lastBody = (body as Map).cast<String, dynamic>();
    final f = failures[path];
    if (f != null) throw f;
    return responses[path] ?? {'ok': true};
  }

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    final f = failures[path];
    if (f != null) throw f;
    return responses[path] ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> putJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('PUT $path');
    lastBody = (body as Map).cast<String, dynamic>();
    final f = failures[path];
    if (f != null) throw f;
    return responses[path] ?? {'ok': true};
  }

  @override
  Future<void> delete(String path, {Object? body, Map<String, String>? headers}) async {
    calls.add('DELETE $path');
    final f = failures[path];
    if (f != null) throw f;
  }
}

/// 假 Rust 桥:`wrapWithToken`/`unwrapWithToken` 是一对能真的互逆的假实现(拼接
/// token 再原样切掉),这样 redeem 测试能钉住"服务端返回的密文确实被正确解开"、
/// 而不只是钉住"调用过这个方法"。`sealTo` 同 `sync_engine_test.dart` 的
/// `FakeRust`——拼接公钥与明文,供断言用了哪把公钥。
class FakeGrantsRust implements GrantsRust {
  final wrapTokens = <String>[];
  final sealedWith = <Uint8List>[];

  @override
  Future<Uint8List> wrapWithToken(Uint8List plaintext, String token) async {
    wrapTokens.add(token);
    return Uint8List.fromList([...plaintext, ...utf8.encode('|$token')]);
  }

  @override
  Future<Uint8List> unwrapWithToken(Uint8List blob, String token) async {
    final suffix = utf8.encode('|$token');
    return Uint8List.fromList(blob.sublist(0, blob.length - suffix.length));
  }

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async {
    sealedWith.add(public);
    return Uint8List.fromList([...public, ...plaintext]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  final key = Uint8List.fromList(List.generate(32, (i) => i));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();

    support = await Directory.systemTemp.createTemp('medme-grants-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
    // C8 的复用缓存是 `Grants` 的静态字段,用例之间会串。
    Grants.clearInviteCache();
  });

  tearDown(() async => support.delete(recursive: true));

  group('inviteDoctor', () {
    test('发 viewer / 15 天 / 600 秒 的邀请,链接含 inviteId 与 token', () async {
      await AccountSession.instance.putProfileKey('prf_1', key);
      final api = FakeApi(responses: {'/v1/profiles/prf_1/invites': {'invite_id': 'inv_abc'}});
      final rust = FakeGrantsRust();
      final grants = Grants(api, AccountSession.instance, rust: rust);
      const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

      final link = await grants.inviteDoctor(p);

      expect(api.lastBody?['role'], 'viewer');
      expect(api.lastBody?['days'], 15);
      expect(api.lastBody?['invite_ttl_s'], 600);
      expect(api.lastBody?['token_hash'], isNotNull);
      expect(link.inviteId, 'inv_abc');
      expect(link.token, isNotEmpty);
      expect(rust.wrapTokens.single, link.token);
    });

    test('没有 cloudId 时拒绝,不发请求', () async {
      final api = FakeApi();
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      const p = Profile(id: 'p-1', name: '我');

      await expectLater(grants.inviteDoctor(p), throwsA(isA<StateError>()));
      expect(api.calls, isEmpty);
    });

    // ---- C8:每进一次出码屏就新建一条 invite ----
    test('C8:同一个档案连着出两次码 —— 复用同一条邀请,不在服务端多建一条', () async {
      await AccountSession.instance.putProfileKey('prf_1', key);
      final api = FakeApi(responses: {'/v1/profiles/prf_1/invites': {'invite_id': 'inv_abc'}});
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

      final first = await grants.inviteDoctor(p);
      final second = await grants.inviteDoctor(p);

      expect(second.inviteId, first.inviteId);
      expect(second.token, first.token, reason: '同一条邀请 = 同一个 token,不是新建一条一样的');
      expect(
        api.calls.where((c) => c.endsWith('/invites')).length,
        1,
        reason: '病人在诊室里退出去又进来很常见,新建出来的码和上一条没有任何区别',
      );
    });

    test('C8:换一个档案出码 —— 不复用别人的那条', () async {
      await AccountSession.instance.putProfileKey('prf_1', key);
      await AccountSession.instance.putProfileKey('prf_2', key);
      final api = FakeApi(responses: {
        '/v1/profiles/prf_1/invites': {'invite_id': 'inv_1'},
        '/v1/profiles/prf_2/invites': {'invite_id': 'inv_2'},
      });
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());

      final a = await grants.inviteDoctor(const Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner'));
      final b = await grants.inviteDoctor(const Profile(id: 'p-2', name: '爸', cloudId: 'prf_2', role: 'owner'));

      expect(a.inviteId, 'inv_1');
      expect(b.inviteId, 'inv_2');
      expect(api.calls.where((c) => c.endsWith('/invites')).length, 2);
    });

    test('C8:缓存清掉之后(相当于 App 重启)重新建一条', () async {
      await AccountSession.instance.putProfileKey('prf_1', key);
      final api = FakeApi(responses: {'/v1/profiles/prf_1/invites': {'invite_id': 'inv_abc'}});
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

      await grants.inviteDoctor(p);
      Grants.clearInviteCache();
      await grants.inviteDoctor(p);

      expect(api.calls.where((c) => c.endsWith('/invites')).length, 2);
    });
  });

  test('inviteTransfer:role owner、不带 days、ttl 15 天', () async {
    await AccountSession.instance.putProfileKey('prf_1', key);
    final api = FakeApi(responses: {'/v1/profiles/prf_1/invites': {'invite_id': 'inv_owner'}});
    final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
    const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

    final link = await grants.inviteTransfer(p);

    expect(api.lastBody?['role'], 'owner');
    expect(api.lastBody?.containsKey('days'), isFalse);
    expect(api.lastBody?['invite_ttl_s'], 15 * 86400);
    expect(link.inviteId, 'inv_owner');
  });

  group('redeem', () {
    test('解 token 包、封给自己公钥回填、建本地档案并存密钥', () async {
      final rust = FakeGrantsRust();
      const token = 'thetesttokenABCDEFGHIJKLMN';
      final wrapped = await rust.wrapWithToken(key, token);
      final api = FakeApi(responses: {
        '/v1/invites/redeem': {
          'profile_id': 'prf_9',
          'role': 'viewer',
          'expires_at': '2026-10-01T00:00:00.000Z',
          'wrapped_key_by_token': base64Encode(wrapped),
          'grant_id': 'grt_1',
        },
      });
      AccountSession.instance.publicKey = Uint8List.fromList(List.generate(32, (i) => 200 + i));
      final grants = Grants(api, AccountSession.instance, rust: rust);
      final link = GrantLink(inviteId: 'inv_1', token: token);

      final p = await grants.redeem(link, afterStored: (_) async {});

      expect(api.calls, contains('POST /v1/invites/redeem'));
      expect(api.calls, contains('PUT /v1/profiles/prf_9/grants/grt_1/key'));
      expect(await AccountSession.instance.profileKey('prf_9'), key);
      expect(
        ProfileManager.instance.profiles.any((pr) => pr.cloudId == 'prf_9' && pr.role == 'viewer'),
        isTrue,
      );
      expect(p.cloudId, 'prf_9');
      expect(p.expiresAt, DateTime.parse('2026-10-01T00:00:00.000Z'));
    });

    test('账号公钥未就绪时拒绝,不落任何本地档案', () async {
      final rust = FakeGrantsRust();
      const token = 'thetesttokenABCDEFGHIJKLMN';
      final wrapped = await rust.wrapWithToken(key, token);
      final api = FakeApi(responses: {
        '/v1/invites/redeem': {
          'profile_id': 'prf_9',
          'role': 'viewer',
          'expires_at': null,
          'wrapped_key_by_token': base64Encode(wrapped),
          'grant_id': 'grt_1',
        },
      });
      final grants = Grants(api, AccountSession.instance, rust: rust);
      final link = GrantLink(inviteId: 'inv_1', token: token);
      final before = ProfileManager.instance.profiles.length;

      await expectLater(
        grants.redeem(link, afterStored: (_) async {}),
        throwsA(isA<StateError>()),
      );
      expect(ProfileManager.instance.profiles.length, before, reason: '失败不应留下半成品档案');
    });

    test('邀请已用过/过期(410)时把失败原样抛出', () async {
      final api = FakeApi(failures: {'/v1/invites/redeem': const ApiFailed(410, 'used or expired')});
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      final link = GrantLink(inviteId: 'inv_1', token: 'thetesttokenABCDEFGHIJKLMN');

      await expectLater(
        grants.redeem(link, afterStored: (_) async {}),
        throwsA(isA<ApiFailed>().having((e) => e.status, 'status', 410)),
      );
    });

    test('token 不对(404)时把失败原样抛出', () async {
      final api = FakeApi(failures: {'/v1/invites/redeem': const ApiFailed(404, 'not found')});
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      final link = GrantLink(inviteId: 'inv_1', token: 'thetesttokenABCDEFGHIJKLMN');

      await expectLater(
        grants.redeem(link, afterStored: (_) async {}),
        throwsA(isA<ApiFailed>().having((e) => e.status, 'status', 404)),
      );
    });

    test('兑换自己发的邀请(400)时把失败原样抛出', () async {
      final api = FakeApi(failures: {'/v1/invites/redeem': const ApiFailed(400, 'cannot redeem own invite')});
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      final link = GrantLink(inviteId: 'inv_1', token: 'thetesttokenABCDEFGHIJKLMN');

      await expectLater(
        grants.redeem(link, afterStored: (_) async {}),
        throwsA(isA<ApiFailed>().having((e) => e.status, 'status', 400)),
      );
    });

    test('I2:收尾走可回退的切换——把"兑换开始前停在哪"一起传下去,开箱失败原样抛出', () async {
      final rust = FakeGrantsRust();
      const token = 'revertabletokenABCDEFGHIJK';
      final wrapped = await rust.wrapWithToken(key, token);
      final api = FakeApi(responses: {
        '/v1/invites/redeem': {
          'profile_id': 'prf_9',
          'role': 'viewer',
          'expires_at': null,
          'wrapped_key_by_token': base64Encode(wrapped),
          'grant_id': 'grt_1',
        },
      });
      AccountSession.instance.publicKey = Uint8List.fromList(List.generate(32, (i) => 200 + i));
      final startedOn = ProfileManager.instance.currentId.value;

      final switchCalls = <(String, String?)>[];
      final grants = Grants(
        api,
        AccountSession.instance,
        rust: rust,
        switchAndReopen: (id, {String? revertTo}) async {
          switchCalls.add((id, revertTo));
          // 真实世界里最常见的失败:这个云档案的密钥此刻读不出来。
          throw const ProfileLocked('prf_9');
        },
      );

      // 注意:这里**不传** afterStored,走的是真实的 `_finishRedeem`——切换是它的
      // 第一步,失败在这一步,后面的首同步/改名(都要真实 Rust 原生库)压根跑不到。
      await expectLater(
        grants.redeem(GrantLink(inviteId: 'inv_1', token: token)),
        throwsA(isA<ProfileLocked>()),
      );

      final newProfile = ProfileManager.instance.profiles.firstWhere((p) => p.cloudId == 'prf_9');
      expect(switchCalls.single.$1, newProfile.id);
      expect(
        switchCalls.single.$2,
        startedOn,
        reason: '回退目标必须是兑换开始前那个成员——create() 早就把 currentId 改成新档案了',
      );
    });

    test('本机已经有这个云档案的入口:复用它,不再建一个重复的空壳档案', () async {
      final rust = FakeGrantsRust();
      const token = 'reuseexistingtokenABCDEFGH';
      final wrapped = await rust.wrapWithToken(key, token);
      final api = FakeApi(responses: {
        '/v1/invites/redeem': {
          'profile_id': 'prf_9',
          'role': 'editor',
          'expires_at': null,
          'wrapped_key_by_token': base64Encode(wrapped),
          'grant_id': 'grt_2',
        },
      });
      AccountSession.instance.publicKey = Uint8List.fromList(List.generate(32, (i) => 200 + i));
      // 本机已经有一个指向同一个云档案的成员(比如之前用 viewer 兑换过一次)。
      final existingId = await ProfileManager.instance.create('已有的档案', userManaged: false);
      await ProfileManager.instance.markCloud(existingId!, 'prf_9', 'viewer', DateTime(2026, 1, 1));
      final before = ProfileManager.instance.profiles.length;

      final grants = Grants(api, AccountSession.instance, rust: rust);
      final link = GrantLink(inviteId: 'inv_1', token: token);
      final p = await grants.redeem(link, afterStored: (_) async {});

      expect(ProfileManager.instance.profiles.length, before, reason: '不该多出一个重复档案');
      expect(p.id, existingId, reason: '应该复用已有的本地入口');
      expect(p.role, 'editor', reason: '角色应该按新的兑换结果更新');
    });
  });

  group('grantFamilyByPhone', () {
    test('查到账号 → 封给对方公钥 → 发永久 editor 授权', () async {
      await AccountSession.instance.putProfileKey('prf_1', key);
      final theirPub = base64Encode(Uint8List.fromList(List.generate(32, (i) => 50 + i)));
      final api = FakeApi(responses: {
        '/v1/accounts/lookup': {'account_id': 'acc_family', 'public_key': theirPub},
      });
      final rust = FakeGrantsRust();
      final grants = Grants(api, AccountSession.instance, rust: rust);
      const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

      await grants.grantFamilyByPhone(p, '13800001111');

      expect(api.calls, contains('POST /v1/accounts/lookup'));
      expect(api.lastBody?['grantee_account_id'], 'acc_family');
      expect(api.lastBody?['role'], 'editor');
      expect(api.lastBody?.containsKey('days'), isFalse, reason: '家属是永久授权,不带 days');
      expect(rust.sealedWith.single, base64Decode(theirPub));
    });

    test('手机号查不到人(404)时原样抛出——existence oracle 由服务端接受', () async {
      await AccountSession.instance.putProfileKey('prf_1', key);
      final api = FakeApi(failures: {'/v1/accounts/lookup': const ApiFailed(404, 'not found')});
      final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
      const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

      await expectLater(
        grants.grantFamilyByPhone(p, '13800001111'),
        throwsA(isA<ApiFailed>().having((e) => e.status, 'status', 404)),
      );
    });
  });

  test('revoke:按 grantId 发 DELETE', () async {
    await AccountSession.instance.putProfileKey('prf_1', key);
    final api = FakeApi();
    final grants = Grants(api, AccountSession.instance, rust: FakeGrantsRust());
    const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');

    await grants.revoke(p, 'grt_5');

    expect(api.calls, contains('DELETE /v1/profiles/prf_1/grants/grt_5'));
  });

  group('purgeExpired', () {
    test('删过期的被授权档案,不动 owner 和未过期的', () async {
      final past = DateTime.now().subtract(const Duration(days: 1));
      final future = DateTime.now().add(const Duration(days: 1));
      await ProfileManager.instance.markCloud('p-1', 'prf_owner', 'owner', null); // 自己的档案,永不过期
      final expiredId = await ProfileManager.instance.create('过期的', userManaged: false);
      await ProfileManager.instance.markCloud(expiredId!, 'prf_expired', 'viewer', past);
      final freshId = await ProfileManager.instance.create('没过期的', userManaged: false);
      await ProfileManager.instance.markCloud(freshId!, 'prf_fresh', 'viewer', future);

      final removed = <String>[];
      final grants = Grants(FakeApi(), AccountSession.instance, rust: FakeGrantsRust());
      final n = await grants.purgeExpired(
        removeProfile: (id) async {
          removed.add(id);
          return true;
        },
      );

      expect(n.map((p) => p.id), [expiredId], reason: 'C11:调用方要能说出谁的授权到期了,不只是个数');
      expect(removed, [expiredId]);
    });

    test('没有过期档案时什么也不删', () async {
      final grants = Grants(FakeApi(), AccountSession.instance, rust: FakeGrantsRust());
      var called = false;
      final n = await grants.purgeExpired(removeProfile: (id) async {
        called = true;
        return true;
      });
      expect(n, isEmpty);
      expect(called, isFalse);
    });
  });
}
