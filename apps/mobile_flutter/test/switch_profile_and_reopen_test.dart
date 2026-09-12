// 钉住 `switchProfileAndReopen` 的回退契约(review round 2, 新 Important 发现):
// 目标成员开箱失败(最常见是 `ProfileLocked`——云档案 cloudId 有但本机没密钥)时,
// `ProfileManager.currentId` 必须退回切换前的那个成员,不能停在"UI 好像切过去了,
// 其实那个成员的箱子根本没开成"的不一致状态——那样接下来任何一次写入都会把新
// 成员的东西写进旧成员的保险箱。
//
// `switchProfileAndReopenImpl` 把真正开箱的动作(`reopen`)抽成参数,所以这里能用
// 一个假的 `reopen` 钉住"失败就回退"这条契约,不需要加载 Rust 原生库
// (`openCurrentProfileVault` 本身调 FRB,`flutter test` 里直接调用会崩——同
// `wipe_all_data_test.dart` 顶部同一条限制,这里复用它抽参数的同一个套路)。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-switch-reopen-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    // ProfileManager 是进程内单例,`_loaded` 一旦为 true 就不会再重新读盘——
    // 每个 test 用 factoryReset() 拉回干净状态,而不是写一份不会被读到的
    // profiles.json(同 `member_switcher_shared_state_test.dart` 的套路)。
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
  });

  tearDown(() async => support.delete(recursive: true));

  test('目标成员开箱失败(如 ProfileLocked):currentId 退回原成员,异常原样抛出', () async {
    final pm = ProfileManager.instance;
    final originalId = pm.currentId.value;
    final lockedId = (await pm.create('张建国'))!;
    await pm.switchTo(originalId); // 确认此刻真的停在"原成员"上

    var reopenCalls = 0;
    Future<void> reopen() async {
      reopenCalls++;
      if (pm.currentId.value == lockedId) {
        throw const ProfileLocked('prf_x');
      }
    }

    await expectLater(
      switchProfileAndReopenImpl(lockedId, reopen: reopen),
      throwsA(isA<ProfileLocked>()),
    );

    expect(
      pm.currentId.value,
      originalId,
      reason: '开箱失败后必须退回原成员,不能停在"看起来切过去了"的锁定成员上',
    );
    expect(reopenCalls, 2, reason: '先试目标成员失败一次,再重开原成员一次(回退)');
  });

  test('回退本身也失败(原成员这会儿也开不了):不掩盖原始异常,原样抛出', () async {
    final pm = ProfileManager.instance;
    final originalId = pm.currentId.value;
    final lockedId = (await pm.create('张建国'))!;
    await pm.switchTo(originalId);

    Future<void> reopen() async => throw const ProfileLocked('always-fails');

    await expectLater(
      switchProfileAndReopenImpl(lockedId, reopen: reopen),
      throwsA(isA<ProfileLocked>()),
      reason: '回退尝试也失败时,吞掉回退失败、rethrow 第一次的原始异常',
    );
  });

  test('开箱成功:正常切换,不触发任何回退', () async {
    final pm = ProfileManager.instance;
    final newId = (await pm.create('李秀英'))!;
    await pm.switchTo(pm.profiles.first.id); // 先切回另一个成员

    var reopenCalls = 0;
    Future<void> reopen() async => reopenCalls++;

    await switchProfileAndReopenImpl(newId, reopen: reopen);

    expect(pm.currentId.value, newId);
    expect(reopenCalls, 1);
  });
}
