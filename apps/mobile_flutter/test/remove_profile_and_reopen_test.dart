// 钉住 `removeProfileAndReopenImpl` 的密钥清理契约(Task 16 review 修复第一轮
// item 5):被移除的成员如果开通过云同步,连同它的档案密钥(`pk_<cloudId>`)
// 一起从 secure storage 清掉;被移除的是纯本地成员(没有 cloudId)时,不该碰
// secure storage 里任何东西——尤其不能因为"这个成员没有 cloudId"就误删了别的
// 成员的密钥。
//
// `removeProfileAndReopenImpl` 把真正重开箱的动作(`reopen`)抽成参数,同
// `switchProfileAndReopenImpl`(见 `switch_profile_and_reopen_test.dart`)的
// 套路——这样能用一个假的 `reopen` 钉住密钥清理这条契约,不需要加载 Rust 原生库
// (`openCurrentProfileVault` 本身调 FRB,`flutter test` 里直接调用会崩)。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-remove-reopen-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
  });

  tearDown(() async => support.delete(recursive: true));

  Future<void> noopReopen() async {}

  test('移除已开通云同步的成员:连同它的 pk_<cloudId> 一起从 secure storage 清掉', () async {
    final pm = ProfileManager.instance;
    final survivorId = pm.currentId.value; // factoryReset 后仅有的默认成员
    final memberId = await pm.create('云端张三');
    expect(memberId, isNotNull);
    await pm.markCloud(memberId!, 'prf_cloud_1', 'owner', null);
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    await AccountSession.instance.putProfileKey('prf_cloud_1', key);
    expect(await AccountSession.instance.profileKey('prf_cloud_1'), isNotNull);

    final ok = await removeProfileAndReopenImpl(memberId, reopen: noopReopen);

    expect(ok, isTrue);
    expect(pm.byId(memberId), isNull, reason: '成员表里这个成员应该真的没了');
    expect(
      await AccountSession.instance.profileKey('prf_cloud_1'),
      isNull,
      reason: '云档案的密钥必须随成员一起清掉,不能留在 Keychain 里当作还有效的敏感材料',
    );
    expect(pm.byId(survivorId), isNotNull, reason: '幸存成员不该被连坐');
  });

  test('移除纯本地成员(没有 cloudId):不碰 secure storage,别的成员的密钥原样还在', () async {
    final pm = ProfileManager.instance;
    final localOnlyId = await pm.create('本地李四'); // 从没 markCloud 过,没有 cloudId
    expect(localOnlyId, isNotNull);
    final cloudSurvivorId = await pm.create('云端王五');
    expect(cloudSurvivorId, isNotNull);
    await pm.markCloud(cloudSurvivorId!, 'prf_cloud_2', 'owner', null);
    final key = Uint8List.fromList(List.generate(32, (i) => 100 + i));
    await AccountSession.instance.putProfileKey('prf_cloud_2', key);

    final ok = await removeProfileAndReopenImpl(localOnlyId!, reopen: noopReopen);

    expect(ok, isTrue);
    expect(pm.byId(localOnlyId), isNull);
    expect(
      await AccountSession.instance.profileKey('prf_cloud_2'),
      key,
      reason: '被删的是纯本地成员——没有 cloudId 可清,更不该误删别的成员的密钥',
    );
  });

  test('删到只剩一个:canRemove 拒绝,reopen 不该被调用,更不碰密钥', () async {
    final pm = ProfileManager.instance;
    final onlyId = pm.currentId.value;
    await pm.markCloud(onlyId, 'prf_cloud_3', 'owner', null);
    await AccountSession.instance.putProfileKey('prf_cloud_3', Uint8List(32));

    var reopenCalls = 0;
    final ok = await removeProfileAndReopenImpl(onlyId, reopen: () async => reopenCalls++);

    expect(ok, isFalse);
    expect(reopenCalls, 0);
    expect(await AccountSession.instance.profileKey('prf_cloud_3'), isNotNull, reason: '被拒绝的删除不许动任何密钥');
  });
}
