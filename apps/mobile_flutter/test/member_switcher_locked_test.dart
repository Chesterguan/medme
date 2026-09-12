// review round 2 新发现:`switchProfileAndReopen` 现在会在开箱失败(最常见是
// `ProfileLocked`)时把 `currentId` 退回原成员并 rethrow,但没有任何调用点接住
// 这个异常给用户看——`showMemberSwitcherSheet` 现在接住 `ProfileLocked`、弹一条
// SnackBar。这里钉住这条 UI 契约:锁定成员点不过去,SnackBar 带着消息,
// `currentId` 停在原成员上。
//
// `showMemberSwitcherSheet` 接受一个 `switchTo` 注入点(默认是真实的
// `switchProfileAndReopen`,内部调 FRB,`flutter test` 里直接调用会崩)。这里传入
// 一个包了假 `reopen` 的 `switchProfileAndReopenImpl`——复用真实的"失败就回退"
// 逻辑,只把会碰原生库的开箱动作换成假的,所以这条测试验的是真代码路径,不是
// 一份重写的模拟。
//
// ⚠️ **`ProfileManager` 的真实文件 IO 必须包在 `tester.runAsync()` 里**(round 2
// 修复轮的教训——第一版没包,`flutter test` 直接卡死,连 `--timeout` 都救不了,
// 因为 `testWidgets` 的测试体跑在一个"假时钟"zone 里,真实的 `dart:io` 完成回调
// 进不来;`setUp()`/`tearDown()` 不在这个 zone 里,不受影响)。规则很简单:
// **`testWidgets` 回调体内,任何一次触达 `ProfileManager`(`create`/`switchTo`/
// `markCloud`/...)的调用都要么在 `setUp()` 里,要么包一层 `runAsync`**——包括由
// `tester.tap()` 间接触发的(所以点击"已锁定成员"那一下本身也要包进去)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/widgets/member_switcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-member-switcher-locked-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() async => support.delete(recursive: true));

  testWidgets('点一个锁定的云档案成员:SnackBar 显示解锁提示,currentId 停在原成员', (tester) async {
    final pm = ProfileManager.instance;
    late String originalId;
    late String lockedId;
    // 单例 `_loaded` 一旦为 true 不会重新读盘——每个 test 用 factoryReset() 拉回
    // 干净状态(同 `member_switcher_shared_state_test.dart` 的套路)。这几步都是
    // 真实文件 IO,必须包进 `runAsync`。
    await tester.runAsync(() async {
      await pm.ensureLoaded();
      await pm.factoryReset();
      originalId = pm.currentId.value;
      lockedId = (await pm.create('已锁定成员'))!;
      await pm.switchTo(originalId); // 确认此刻停在"原成员"上,再打开切换器
    });

    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showMemberSwitcherSheet(
                    ctx,
                    switchTo: (id) => switchProfileAndReopenImpl(
                      id,
                      reopen: () async {
                        if (pm.currentId.value == lockedId) {
                          throw const ProfileLocked('prf_locked');
                        }
                      },
                    ),
                  ),
                  child: const Text('打开切换器'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开切换器'));
    await tester.pumpAndSettle();
    expect(find.text('已锁定成员'), findsOneWidget);

    // 点这一下会触发 `switchProfileAndReopenImpl` 里两次真实的 `ProfileManager.switchTo`
    // (先切去锁定成员、失败后切回原成员)+ 抛出 + `member_switcher` 捕获后弹
    // SnackBar——这一整条链都是真实异步,`tap()` 本身不等它跑完就返回,所以要在
    // `runAsync` 里额外让出几个真实事件循环节拍,这条链才能真正跑到底
    // (单独一次 `pump()` 不够——之前试过,SnackBar 断言会因为链没跑完而落空)。
    await tester.runAsync(() async {
      await tester.tap(find.text('已锁定成员'));
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle(); // 让 SnackBar 的入场动画走完

    expect(find.textContaining('需要你的口令'), findsOneWidget, reason: 'ProfileLocked 的消息应该出现在 SnackBar 里');
    expect(pm.currentId.value, originalId, reason: '锁定失败之后必须还停在原成员上,不能停在锁定成员上');
  });

  testWidgets('点一个正常成员:不弹 SnackBar,currentId 换过去', (tester) async {
    final pm = ProfileManager.instance;
    late String newId;
    await tester.runAsync(() async {
      await pm.ensureLoaded();
      await pm.factoryReset();
      newId = (await pm.create('张三'))!;
      await pm.switchTo(pm.profiles.first.id); // 先切回另一个成员,确保下面这次点击是真的切换
    });

    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showMemberSwitcherSheet(
                    ctx,
                    switchTo: (id) => switchProfileAndReopenImpl(id, reopen: () async {}),
                  ),
                  child: const Text('打开切换器'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('打开切换器'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('张三'));
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    expect(pm.currentId.value, newId);
    expect(find.textContaining('需要你的口令'), findsNothing);
  });
}
