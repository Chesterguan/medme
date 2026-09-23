// 「我」(s5)与「成员页」(s10)+ 成员切换器 + 备份状态行(Task 11)。四屏一个品牌
// 渐变面都没有 —— 成员头像那几个小圆是 `MedAvatar`(line2 圆底 + ink2 首字),
// 不是 hero。
//
// `_SettingsRow`/`_SettingsGroup`/`_SectionLabel` 是 settings_screen.dart 的私有
// 类——Dart 的隐私按文件分,测试文件跨文件引用不到,也不该为了测试把它们改公开
// (brief 原话)。凡是本该探 `_SettingsRow` 的断言,改成探 `MembersCard`(公开、
// 结构等价:leading `MedAvatar` + 标题 + 尾部说明,同一套 token)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/member_detail_screen.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/backup_status_line.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';
import 'package:mobile_flutter/widgets/member_switcher.dart';
import 'stage3_visual_helpers.dart';

/// 照抄 `test/members_card_test.dart` 现成的假 Profile 构造。
const _members = [
  Profile(id: 'p-1', name: '张建国', cloudId: 'prf_1', role: 'owner'),
  Profile(id: 'p-2', name: '王淑芬', cloudId: 'prf_2', role: 'editor'),
];

int? _countOf(String id) => id == 'p-1' ? 31 : 8;

void main() {
  testWidgets('成员头像是 MedAvatar,不是 Flutter 的 CircleAvatar', (tester) async {
    await pumpStage3(tester, Scaffold(body: MembersCard(
        members: _members, countOf: _countOf, onOpen: (_) {}, onAdd: () {})));
    expect(find.byType(CircleAvatar), findsNothing, reason: '自绘的 MedAvatar,不借 Flutter 这个类');
    expect(find.byType(Card), findsNothing, reason: '外壳应换成 MedCard');
    expect(find.byType(MedAvatar), findsWidgets);
  });

  testWidgets('零个颜色面', (tester) async {
    await pumpStage3(tester, Scaffold(body: MembersCard(
        members: const [], countOf: (_) => 0, onOpen: (_) {}, onAdd: () {})));
    expectSurfaceBudget();
    expectNoGradientAnywhere();
  });

  // `_RowProbe` 探不到私有的 `_SettingsRow`(见文件头注释)——改探 `MembersCard`
  // 的「添加成员」(标题)与「N 份」(尾部说明),两者与 `_SettingsRow` 共用同一套
  // `MedType.body`(16·400)/`MedType.secondary.copyWith(color: c.ink3)` token。
  testWidgets('设置行样式:标题 16·400、右侧说明 13 ink3', (tester) async {
    await pumpStage3(tester, Scaffold(body: MembersCard(
        members: _members, countOf: _countOf, onOpen: (_) {}, onAdd: () {})));
    final title = tester.widget<Text>(find.text('添加成员'));
    expect(title.style!.fontSize, 16);
    expect(title.style!.fontWeight, anyOf(FontWeight.w400, isNull));

    final trailing = tester.widget<Text>(find.text('31 份'));
    expect(trailing.style!.fontSize, 13);
    expect(trailing.style!.color, MedColors.light.ink3);
  });

  testWidgets('两个尺寸 × 两档字号不溢出(空态)', (tester) async {
    await expectNoOverflowAtBothSizes(tester, Scaffold(body: MembersCard(
        members: const [], countOf: (_) => 0, onOpen: (_) {}, onAdd: () {})));
  });

  testWidgets('两个尺寸 × 两档字号不溢出(两个成员)', (tester) async {
    await expectNoOverflowAtBothSizes(tester, Scaffold(body: MembersCard(
        members: _members, countOf: _countOf, onOpen: (_) {}, onAdd: () {})));
  });

  group('成员页(s10):三组卡换 MedCard', () {
    const local = Profile(id: 'p-1', name: '张建国');

    testWidgets('本地成员(无云端授权):没有 Card/CircleAvatar 残留,零个颜色面,不溢出', (tester) async {
      await expectNoOverflowAtBothSizes(
        tester,
        Scaffold(body: MemberDetailScreen(member: local)),
      );

      await pumpStage3(tester, Scaffold(body: MemberDetailScreen(member: local)));
      // 本地成员:没有「谁能看」那组卡,只剩「还没开通云端备份」占位卡 +
      // 「改名字/删除这个成员」卡,共两张。
      expect(find.byType(MedCard), findsNWidgets(2));
      expect(find.byType(Card), findsNothing);
      expect(find.byType(CircleAvatar), findsNothing);
      expectSurfaceBudget();
      expectNoGradientAnywhere();
    });

    testWidgets('「删除这个成员」标题色是 critical', (tester) async {
      await pumpStage3(tester, Scaffold(body: MemberDetailScreen(member: local)));
      final title = tester.widget<Text>(find.text('删除这个成员'));
      expect(title.style!.color, MedColors.light.critical);
    });
  });

  group('成员切换器:头像换 MedAvatar', () {
    setUp(() async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
    });

    testWidgets('不再是 CircleAvatar,而是 MedAvatar', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: MedMe.theme(),
        home: Builder(builder: (context) {
          ctx = context;
          return Scaffold(body: Center(child: ElevatedButton(
            onPressed: () => showMemberSwitcherSheet(
              ctx,
              switchTo: (_) async {},
              purgeExpired: () async => const [],
            ),
            child: const Text('打开切换器'),
          )));
        }),
      ));
      await tester.tap(find.text('打开切换器'));
      await tester.pumpAndSettle();

      expect(find.byType(CircleAvatar), findsNothing);
      expect(find.byType(MedAvatar), findsWidgets);
    });
  });

  // memory `test-all-three-states`:改 UI 状态必须验加载中/成功/失败三态,只验一条
  // 会连环出 bug。这里钉的是 Task 11 新引入的那一半(MedBanner 的蓝/琥珀二态 +
  // lab 图标类别)——四态文案本身(没登录/关着/失败/成功)早已在
  // `test/backup_status_line_test.dart` 覆盖,这里不重复。
  group('BackupStatusLine 换 MedBanner:蓝/琥珀', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountSession.instance.resetForTest();
    });

    testWidgets('没登录(默认态):蓝色横幅,云图标', (tester) async {
      await pumpStage3(tester, const Scaffold(body: BackupStatusLine()));
      final banner = tester.widget<MedBanner>(find.byType(MedBanner));
      expect(banner.amber, isFalse);
      expect(banner.icon, Icons.cloud_outlined);
      expect(banner.title, '云端');
    });

    testWidgets('已备份成功:蓝色横幅(成功态)', (tester) async {
      SharedPreferences.setMockInitialValues({
        'last_sync_at_prf_1': DateTime.now().toIso8601String(),
        'last_sync_ok_prf_1': true,
      });
      AccountSession.instance.loggedIn.value = true;
      await tester.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_1', 'owner', null);
      });

      await pumpStage3(tester, const Scaffold(body: BackupStatusLine()));
      await tester.pumpAndSettle();
      final banner = tester.widget<MedBanner>(find.byType(MedBanner));
      expect(banner.amber, isFalse);
    });

    testWidgets('上次没备份成功:琥珀横幅(失败态)', (tester) async {
      SharedPreferences.setMockInitialValues({
        'last_sync_at_prf_1':
            DateTime.now().subtract(const Duration(minutes: 2)).toIso8601String(),
        'last_sync_ok_prf_1': false,
      });
      AccountSession.instance.loggedIn.value = true;
      await tester.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
        await ProfileManager.instance.markCloud('p-1', 'prf_1', 'owner', null);
      });

      await pumpStage3(tester, const Scaffold(body: BackupStatusLine()));
      await tester.pumpAndSettle();
      final banner = tester.widget<MedBanner>(find.byType(MedBanner));
      expect(banner.amber, isTrue);
    });

    testWidgets('正在备份中(加载态):副标题「正在备份…」,横幅仍是 MedBanner', (tester) async {
      AccountSession.instance.loggedIn.value = true;
      await tester.runAsync(() async {
        await ProfileManager.instance.ensureLoaded();
        await ProfileManager.instance.factoryReset();
      });

      await pumpStage3(tester, Scaffold(body: BackupStatusLine(retry: () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      })));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MedBanner));
      await tester.pump();

      expect(find.text('正在备份…'), findsOneWidget, reason: '加载中必须看得见,否则像"点了没反应"');
      expect(find.byType(MedBanner), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
