// A3b:医生兑换完病人的二维码之后,医生模式主页原来**没有任何入口** —— 档案其实
// 已经在 `ProfileManager` 里了,但医生得切回个人模式、去家人列表里找。诊室里没人
// 会这么做,于是"病人出码授权"这条路在医生那一侧基本等于没落地。
//
// C11:过期的授权原来是**静默消失**的 —— 昨天还能看的那份病历今天不见了,屏上一个
// 字都没有,医生只会以为 App 出了问题。
//
// 三个纯函数 + 那一节本身(`PatientGrantedSection`,不碰 IO)。**整屏进不来**:
// `DoctorHomeScreen.initState` 要穿过三个单例的真实文件 I/O(今日份数、代拍病人表、
// 成员表),`pumpAndSettle` 等不到它们 —— 同
// `settings_cloud_removal_notice_test.dart` 对 `SettingsScreen` 的同一条取舍。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';

Profile _viewer(String id, String name, DateTime? expires) =>
    Profile(id: id, name: name, cloudId: 'prf_$id', role: 'viewer', expiresAt: expires);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('patientGrantedProfiles:只列病人授权给我的那些', () {
    test('只要 viewer —— owner(自己的)和 editor(和家人共管的)不算', () {
      final rows = patientGrantedProfiles([
        const Profile(id: 'p-1', name: '我'),
        const Profile(id: 'p-2', name: '我的云档案', cloudId: 'prf_own', role: 'owner'),
        const Profile(id: 'p-3', name: '老爸', cloudId: 'prf_dad', role: 'editor'),
        _viewer('p-4', '张建国', DateTime(2026, 9, 20)),
      ], now: DateTime(2026, 9, 12));
      expect(rows.map((p) => p.name), ['张建国']);
    });

    test('没有 cloudId 的 viewer 不算(不可能有,但别画一个点不开的行)', () {
      final rows = patientGrantedProfiles([
        const Profile(id: 'p-9', name: '坏数据', role: 'viewer'),
      ], now: DateTime(2026, 9, 12));
      expect(rows, isEmpty);
    });

    test('快到期的排前面 —— 这一节回答的是"这几天还能看谁的"', () {
      final rows = patientGrantedProfiles([
        _viewer('p-2', '后到期', DateTime(2026, 9, 30)),
        _viewer('p-1', '先到期', DateTime(2026, 9, 13)),
      ], now: DateTime(2026, 9, 12));
      expect(rows.map((p) => p.name), ['先到期', '后到期']);
    });

    // 评审 Minor 17:purge 包在 `catch (_) {}` 里、`removeProfileAndReopen` 也可能
    // 返回 false —— 那时这一节会显示一行副标题写着已经过去的日期、还点得进去。
    test('已经过期的不列(不依赖 purge 成没成)', () {
      final rows = patientGrantedProfiles([
        _viewer('p-1', '昨天就到期了', DateTime(2026, 9, 11)),
        _viewer('p-2', '还有效', DateTime(2026, 9, 30)),
      ], now: DateTime(2026, 9, 12));
      expect(rows.map((p) => p.name), ['还有效']);
    });
  });

  group('patientGrantedSubtitle', () {
    // Task 13 复审裁定的例外:挑人界面零角色词的硬规矩不管这一节——医生要用到期日
    // 判断该不该催病人续。这一行早就不再和 member_switcher.dart 逐字相同了(那边
    // 已经把角色词整个删掉);词从「只读」换成「只能看」,与 roleLabel('viewer') 对齐。
    test('只能看 · 至 M月D日', () {
      expect(patientGrantedSubtitle(_viewer('p', '张', DateTime(2026, 9, 20))), '只能看 · 至 9月20日');
    });

    test('没有到期日就只说「只能看」,不编一个日期', () {
      expect(patientGrantedSubtitle(_viewer('p', '张', null)), '只能看');
    });
  });

  group('expiredGrantNotice(C11)', () {
    test('没清掉任何东西:不说话', () {
      expect(expiredGrantNotice(const []), isNull);
    });

    test('一份 / 多份', () {
      expect(expiredGrantNotice([_viewer('a', '张建国', null)]), '张建国 的查看权限已到期,已移出');
      expect(
        expiredGrantNotice([_viewer('a', '张建国', null), _viewer('b', '李秀兰', null)]),
        '张建国、李秀兰 的查看权限已到期,已移出',
      );
    });
  });

  group('PatientGrantedSection:这一节的渲染与点击', () {
    // 整屏(`DoctorHomeScreen`)进不来:它的 `initState` 要穿过三个单例的真实文件
    // I/O(份数、代拍病人表、成员表),`pumpAndSettle` 等不到。所以这一节被抽成
    // 一个不碰 IO 的 widget,成员表由外面读好传进来 —— 同
    // `settings_cloud_removal_notice_test.dart` 对 `SettingsScreen` 的同一条取舍。
    Future<void> pumpSection(
      WidgetTester t,
      List<Profile> profiles, {
      void Function(Profile)? onTap,
    }) => t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PatientGrantedSection(profiles: profiles, onTap: onTap ?? (_) {}),
      ),
    ));

    testWidgets('有被授权的档案:列出姓名 + 「只能看 · 至 M月D日」', (t) async {
      await pumpSection(t, [_viewer('p-2', '张建国', DateTime(2026, 9, 20))]);
      expect(find.text('病人让我看的病历'), findsOneWidget);
      expect(find.text('张建国'), findsOneWidget);
      expect(find.text('只能看 · 至 9月20日'), findsOneWidget);
      // 内部 id 不露出来。
      expect(find.textContaining('prf_'), findsNothing);
    });

    testWidgets('没有被授权的档案:整节不画(医生模式的主角是代拍)', (t) async {
      await pumpSection(t, const []);
      expect(find.text('病人让我看的病历'), findsNothing);
    });

    testWidgets('点一行:回调拿到的是那个成员', (t) async {
      final tapped = <String>[];
      await pumpSection(
        t,
        [_viewer('p-2', '张建国', DateTime(2026, 9, 20)), _viewer('p-3', '李秀兰', DateTime(2026, 9, 25))],
        onTap: (p) => tapped.add(p.id),
      );
      await t.tap(find.byKey(const Key('granted_p-3')));
      await t.pump();
      expect(tapped, ['p-3']);
    });
  });
}
