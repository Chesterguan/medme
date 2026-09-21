// Task 11:切换器要把「被授权的只读成员」和「过期就该消失」这两条钉住——
// 同 `member_switcher_locked_test.dart` 的套路(真实 `ProfileManager` + 假的
// `switchTo`/`purgeExpired` 注入点,不碰真实 FFI)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/sync_engine.dart' show pendingFirstSync, resetPendingFirstSyncForTest;
import 'package:mobile_flutter/widgets/member_switcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-switcher-viewer-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
    resetPendingFirstSyncForTest();
  });

  tearDown(() async {
    resetPendingFirstSyncForTest();
    await support.delete(recursive: true);
  });

  /// 切换器的标准壳子:一颗按钮打开它,两个注入点都给假实现。
  Future<void> pumpSwitcher(
    WidgetTester tester, {
    Future<List<Profile>> Function()? purgeExpired,
    Future<void> Function(String id)? switchTo,
  }) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showMemberSwitcherSheet(
                ctx,
                switchTo: switchTo ?? (_) async {},
                purgeExpired: purgeExpired ?? () async => const <Profile>[],
              ),
              child: const Text('打开切换器'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.text('打开切换器'));
    await tester.pumpAndSettle();
  }

  // ---- 评审 Important 4:C11 的提示原来只落在医生模式 ----
  group('C11 在个人模式:过期被清掉也要说一句', () {
    /// 关掉底部弹窗(点一下它外面的遮罩)—— SnackBar 只有在弹窗收起之后才说得出口。
    Future<void> dismissSheet(WidgetTester tester) async {
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
    }

    testWidgets('清掉了一份:弹窗收起后 SnackBar **可见**地说「X 的查看权限已到期,已移出」', (tester) async {
      await pumpSwitcher(
        tester,
        purgeExpired: () async => const [
          Profile(id: 'p-9', name: '李秀兰', cloudId: 'prf_gone', role: 'viewer'),
        ],
      );
      // 第一轮把这句话弹在**打开弹窗之前** —— SnackBar 从底部升起,而底部弹窗整块
      // 盖在它上面,那 4 秒里用户一个字都看不见。所以这里用 `hitTestable()`:
      // `findsOneWidget` 对"在树里但被盖住"是过得去的,而那正是当时的 bug。
      expect(find.text('李秀兰 的查看权限已到期,已移出').hitTestable(), findsNothing,
          reason: '弹窗还开着,此刻不该(也盖不住地)显示');

      await dismissSheet(tester);
      expect(find.text('李秀兰 的查看权限已到期,已移出').hitTestable(), findsOneWidget);
    });

    testWidgets('什么都没清掉:不说话(不骚扰每一次打开切换器)', (tester) async {
      await pumpSwitcher(tester);
      await dismissSheet(tester);
      expect(find.textContaining('已到期'), findsNothing);
    });

    testWidgets('清理本身失败:吞掉,切换器照常打开、也不乱说一句到期', (tester) async {
      await pumpSwitcher(tester, purgeExpired: () async => throw Exception('purge boom'));
      expect(find.text('切换成员'), findsOneWidget);
      await dismissSheet(tester);
      expect(find.textContaining('已到期'), findsNothing);
      expect(find.textContaining('purge boom'), findsNothing);
    });
  });

  // ---- 评审 Important 2 的可见出口 ----
  group('正在恢复的成员:列表里说得出"还没好"、点一下能重试', () {
    testWidgets('在 pendingFirstSync 里的成员:副标题是「正在恢复…点这里重试」', (tester) async {
      final pm = ProfileManager.instance;
      late String id;
      await tester.runAsync(() async {
        id = (await pm.create(ProfileManager.restoringPlaceholderName, userManaged: false))!;
        await pm.markCloud(id, 'prf_restoring', 'owner', null);
        await pm.switchTo(pm.profiles.first.id);
      });
      pendingFirstSync.add(id);

      await pumpSwitcher(tester);

      expect(find.text('正在恢复…点这里重试'), findsOneWidget);
    });

    testWidgets('点它 = 切过去(切换会 bumpVaultRevision,后台触发器随即排空队列)', (tester) async {
      final pm = ProfileManager.instance;
      late String id;
      await tester.runAsync(() async {
        id = (await pm.create(ProfileManager.restoringPlaceholderName, userManaged: false))!;
        await pm.markCloud(id, 'prf_restoring', 'owner', null);
        await pm.switchTo(pm.profiles.first.id);
      });
      pendingFirstSync.add(id);
      final switched = <String>[];

      await pumpSwitcher(tester, switchTo: (x) async => switched.add(x));
      await tester.tap(find.text('正在恢复…点这里重试'));
      await tester.pumpAndSettle();

      expect(switched, [id]);
    });

    testWidgets('首同步成功之后(不在队列里了):不再说「正在恢复」', (tester) async {
      final pm = ProfileManager.instance;
      await tester.runAsync(() async {
        final id = (await pm.create('张建国', userManaged: false))!;
        await pm.markCloud(id, 'prf_done', 'owner', null);
        await pm.switchTo(pm.profiles.first.id);
      });

      await pumpSwitcher(tester);

      expect(find.textContaining('正在恢复'), findsNothing);
      expect(find.text('张建国'), findsOneWidget);
    });
  });

  // Task 13:挑人的界面上不出现任何亲属/角色词——授权级别只在某个成员自己的
  // 页面里说(`s10`,Stage 2)。这条原来钉的是「viewer 行显示只读 · 至 M月D日」,
  // 现在反过来钉「不显示」,同 `test/member_no_role_words_test.dart` 的规矩。
  testWidgets('viewer 成员不写「只读」——挑人的界面只有名字', (tester) async {
    final pm = ProfileManager.instance;
    late String viewerId;
    await tester.runAsync(() async {
      viewerId = (await pm.create('张医生的病人', userManaged: false))!;
      await pm.markCloud(viewerId, 'prf_1', 'viewer', DateTime(2026, 11, 3));
      await pm.switchTo(pm.profiles.first.id);
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
                    switchTo: (_) async {},
                    purgeExpired: () async => const <Profile>[],
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

    expect(find.text('张医生的病人'), findsOneWidget);
    expect(find.textContaining('只读'), findsNothing, reason: '挑人的界面不写角色词');
    expect(find.textContaining('11月3日'), findsNothing, reason: '到期日也挪到成员自己的页面里说');
  });

  testWidgets('打开切换器时先跑一次过期清理', (tester) async {
    var purgeCalls = 0;
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
                    purgeExpired: () async {
                      purgeCalls++;
                      return const <Profile>[];
                    },
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

    expect(purgeCalls, 1);
  });

  testWidgets('清理抛错也不该挡住打开切换器——家务事不是开关', (tester) async {
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
                    purgeExpired: () async => throw Exception('purge boom'),
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

    // 清理失败没有阻止 sheet 打开——「切换成员」这个标题出现在 sheet 里。
    expect(find.text('切换成员'), findsOneWidget);
  });
}
