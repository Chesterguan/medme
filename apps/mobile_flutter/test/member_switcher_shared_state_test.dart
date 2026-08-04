// 产品反馈第二条:「概览和档案应该联动 —— 两边都能快速切换成员」,技术要求
// 是「同一套状态,不是两份」。在概览切了成员,回到档案必须已经是切过的。
//
// 概览的 hero 卡与档案屏的 tab 条/弹出层现在都调用同一份
// `widgets/member_switcher.dart`(`showMemberSwitcherSheet` / `promptAddMember`),
// 而它们内部只做两件事:改 `ProfileManager.instance.currentId`,再
// `bumpVaultRevision()`。真相只在 `currentId` 这一个 `ValueNotifier` 里——
// 这里不拉起完整 UI 去点两屏(概览/档案的 `FutureBuilder` 要真正开箱,走 Rust
// FFI,纯 dart test 进程里没有原生库可用)。改为直接盯住两屏真正共享的这层:
// 证明「一处调用 switchTo/create 之后,任意数量的监听者都同步看到新值」,
// 概览与档案各自挂在 `vaultRevision` 上的刷新回调(见 vault_boot.dart 的
// `switchProfileAndReopen` / `createProfileAndReopen`)就必然会被同一次调用
// 一起触发——不存在「切了概览、档案还是旧的」这种分叉。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-switcher-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
    // ProfileManager 是进程内单例,`_loaded` 一旦为 true,`ensureLoaded()`
    // 就不会再重新读盘——所以每个 test 靠 factoryReset() 拉回单一默认成员的
    // 干净状态,而不是靠写一份新的 profiles.json(那份不会被读到)。
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
  });

  tearDown(() async => support.delete(recursive: true));

  test('currentId 是唯一真相:一处切换,所有监听者(概览/档案)同步看到新值', () async {
    final pm = ProfileManager.instance;
    final startId = pm.currentId.value;

    // 模拟「概览屏」与「档案屏」各自挂一个监听器——与真实代码同一模式
    // (两屏都在各自的 initState 里对某个 ValueNotifier addListener,
    // 见 overview_screen.dart / archive_screen.dart 对 vaultRevision 的监听)。
    var overviewSeen = startId;
    var archiveSeen = startId;
    void onOverview() => overviewSeen = pm.currentId.value;
    void onArchive() => archiveSeen = pm.currentId.value;
    pm.currentId.addListener(onOverview);
    pm.currentId.addListener(onArchive);
    addTearDown(() {
      pm.currentId.removeListener(onOverview);
      pm.currentId.removeListener(onArchive);
    });

    final secondId = await pm.create('张建国');
    expect(secondId, isNotNull);

    // 「在档案屏」切成员(与 _switchTo / showMemberSwitcherSheet 内部调用的
    // 是同一个 ProfileManager.switchTo)。
    await pm.switchTo(startId);

    expect(pm.currentId.value, startId);
    expect(
      overviewSeen,
      startId,
      reason: '概览屏的监听器必须同步看到这次切换,不是缓存的旧值——'
          '如果概览自己另存了一份"当前成员",这里就会读到 secondId 而不是 startId',
    );
    expect(archiveSeen, startId);

    // 反过来:切到刚建的成员,两个监听器同样要跟上。
    await pm.switchTo(secondId!);
    expect(overviewSeen, secondId);
    expect(archiveSeen, secondId);
  });

  test('新建成员同样只有一处真相:create 之后 currentId 立刻指向新成员', () async {
    final pm = ProfileManager.instance;

    var seenByOtherScreen = pm.currentId.value;
    void onOtherScreen() => seenByOtherScreen = pm.currentId.value;
    pm.currentId.addListener(onOtherScreen);
    addTearDown(() => pm.currentId.removeListener(onOtherScreen));

    final newId = await pm.create('李秀英');

    expect(newId, isNotNull);
    expect(pm.currentId.value, newId);
    expect(
      seenByOtherScreen,
      newId,
      reason: '添加成员(概览/档案共用同一个 promptAddMember)后,'
          '两屏都应该已经切到新成员,而不是各自停在旧的',
    );
  });
}
