// 新设备/重新登录会把用户本机主动删掉的云成员重新建回来:`removeProfileAndReopen`
// 删的只是本机的行/目录/密钥——owner 授权服务端没有 DELETE 端点删不掉,换机后
// `AccountFlow.restoreProfileKeys` 走 `GET /v1/profiles` 一样会看到这个档案,
// 于是自动建回一个"云端档案 xxxxxx"。
//
// 修复:本机记一份删除黑名单(`AccountSession.deletedCloudProfileIds`,
// shared_preferences 键 `deleted_cloud_profiles`)——
//   * `vault_boot.removeProfileAndReopenImpl` 删云成员时记一笔;
//   * `restoreProfileKeys` 见到黑名单里的 cloudId 整条跳过(密钥不补、成员不建);
//   * `Grants.redeem` 兑换到同一个 cloudId 时清掉这一笔(重新合法领回)。
//
// 三段都用假 API/假 Rust 桥,不碰真实 FRB(同仓库其它测试的一贯限制)。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 API:`/v1/profiles` 固定返回预设的一份云档案列表;其它路径按需要单独处理。
class _FakeApi extends ApiClient {
  _FakeApi({this.profiles = const [], this.redeemResponse}) : super(base: 'http://x');
  final List<Map<String, dynamic>> profiles;
  final Map<String, dynamic>? redeemResponse;
  final calls = <String>[];

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    if (path == '/v1/profiles') return profiles;
    return const <dynamic>[];
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    if (path == '/v1/invites/redeem') return redeemResponse!;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> putJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('PUT $path');
    return {'ok': true};
  }
}

/// 恒等透传的假加密/假 Rust 桥——同 `account_screen_test.dart`/`grants_test.dart`
/// 的套路,不追求真实密码学正确性,只钉住"传对了什么"。
class _FakeCrypto implements SyncCrypto {
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
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async => Uint8List.fromList([...public, ...plaintext]);
  @override
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob) async => blob;
}

class _FakeGrantsRust implements GrantsRust {
  @override
  Future<Uint8List> wrapWithToken(Uint8List plaintext, String token) async => plaintext;
  @override
  Future<Uint8List> unwrapWithToken(Uint8List blob, String token) async => blob;
  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async => Uint8List.fromList([...public, ...plaintext]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();

    support = await Directory.systemTemp.createTemp('medme-tombstone-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
  });

  tearDown(() async => support.delete(recursive: true));

  test('删云成员 → 重新登录/解锁不会把它建回来', () async {
    final pm = ProfileManager.instance;
    final memberId = await pm.create('云端张三');
    expect(memberId, isNotNull);
    await pm.markCloud(memberId!, 'prf_del', 'owner', null);
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    await AccountSession.instance.putProfileKey('prf_del', key);

    // 用户在设置里删掉这个成员。
    final ok = await removeProfileAndReopenImpl(memberId, reopen: () async {}, releaseIfOpen: (_) async {});
    expect(ok, isTrue);
    expect(pm.byId(memberId), isNull);
    expect(await AccountSession.instance.deletedCloudProfileIds(), contains('prf_del'));

    // 换机/重新登录:服务端 `/v1/profiles` 还挂着这个云档案(owner 授权删不掉)。
    await AccountSession.instance.save(accountId: 'acc_1', access: 'a', refresh: 'r', privateKey: Uint8List(32));
    final api = _FakeApi(profiles: [
      {'profile_id': 'prf_del', 'role': 'owner', 'wrapped_profile_key': 'AA==', 'expires_at': null},
    ]);
    final flow = AccountFlow(api, AccountSession.instance, crypto: _FakeCrypto(), reopenCurrentProfileVault: () async {});

    await flow.restoreProfileKeys();

    expect(
      pm.profiles.any((p) => p.cloudId == 'prf_del'),
      isFalse,
      reason: '本机主动删过的云成员不该被"补齐密钥"这条逻辑重新建回来',
    );
    expect(await AccountSession.instance.profileKey('prf_del'), isNull, reason: '密钥也不该被补回来');
  });

  test('之后兑换到同一个 cloudId:清掉黑名单,成员正常建起来', () async {
    await AccountSession.instance.tombstoneCloudProfile('prf_del');
    AccountSession.instance.publicKey = Uint8List.fromList(List.generate(32, (i) => 200 + i));
    final api = _FakeApi(redeemResponse: {
      'profile_id': 'prf_del',
      'role': 'viewer',
      'expires_at': null,
      'wrapped_key_by_token': 'AA==',
      'grant_id': 'grt_1',
    });
    final grants = Grants(api, AccountSession.instance, rust: _FakeGrantsRust());
    final link = GrantLink(inviteId: 'inv_1', token: 'thetesttokenABCDEFGHIJKLMN');

    await grants.redeem(link, afterStored: (_) async {});

    expect(
      await AccountSession.instance.deletedCloudProfileIds(),
      isNot(contains('prf_del')),
      reason: '重新合法领回之后,黑名单不该再挡着它',
    );
    expect(ProfileManager.instance.profiles.any((p) => p.cloudId == 'prf_del'), isTrue);
  });

  test('删纯本地成员(没有 cloudId):黑名单不多一条', () async {
    final pm = ProfileManager.instance;
    final localOnlyId = await pm.create('本地李四');
    expect(localOnlyId, isNotNull);

    final ok = await removeProfileAndReopenImpl(localOnlyId!, reopen: () async {}, releaseIfOpen: (_) async {});

    expect(ok, isTrue);
    expect(await AccountSession.instance.deletedCloudProfileIds(), isEmpty);
  });
}
