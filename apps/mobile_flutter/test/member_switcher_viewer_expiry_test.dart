// Task 11:切换器要把「被授权的只读成员」和「过期就该消失」这两条钉住——
// 同 `member_switcher_locked_test.dart` 的套路(真实 `ProfileManager` + 假的
// `switchTo`/`purgeExpired` 注入点,不碰真实 FFI)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
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
  });

  tearDown(() async => support.delete(recursive: true));

  testWidgets('viewer 行显示「只读 · 至 M月D日」,owner 行不显示', (tester) async {
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

    expect(find.text('只读 · 至 11月3日'), findsOneWidget);
    // owner 行(初始的「我」)不该带这行只读文案。
    final ownerTile = find.ancestor(of: find.text('我'), matching: find.byType(ListTile));
    expect(
      find.descendant(of: ownerTile, matching: find.textContaining('只读')),
      findsNothing,
    );
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
