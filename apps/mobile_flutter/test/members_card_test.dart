// 「我」tab 的「这台手机上的病历」卡(`s5`,Task 12)。
//
// 只 pump 这张卡,不 pump `SettingsScreen` —— 那一屏 `initState` 里直接调 FFI
// (`icloudStatus` / `patientProfile`),`flutter test` 不带原生库(同
// `test/overview_quick_actions_test.dart` 顶部那条教训)。
//
// 钉住的是一条会在界面上说错话的规矩:**挑人的列表上只有名字和份数,一个角色词、
// 一颗删除图标都不许有**。「主人 / 家属 / 能改 / 只能看」写在这里,用户读到的是
// 「家里谁是谁」,而那不是那个字段的意思 —— 授权级别只在某个成员自己的页面里说
// (`s10`,`MemberDetailScreen`)。删除成员的入口也在 `s10`(Task 13 fix round 1
// 挪过去的)——这张卡上原来那颗小图标(Task 12 的临时方案,两个 `TODO(Task 13)`
// 早已作废)已经撤掉,`onRemove` 参数一并从 `MembersCard` 上删掉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/theme.dart';

const _members = [
  Profile(id: 'p-1', name: '张建国', cloudId: 'prf_1', role: 'owner'),
  Profile(id: 'p-2', name: '王淑芬', cloudId: 'prf_2', role: 'editor'),
];

Future<void> pumpCard(
  WidgetTester t, {
  List<Profile> members = _members,
  void Function(Profile)? onOpen,
  VoidCallback? onAdd,
}) => t.pumpWidget(MaterialApp(
      theme: MedMe.theme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MembersCard(
            members: members,
            countOf: (id) => id == 'p-1' ? 31 : 8,
            onOpen: onOpen ?? (_) {},
            onAdd: onAdd ?? () {},
          ),
        ),
      ),
    ));

void main() {
  testWidgets('s5:一人一行 —— 名字 + N 份,最后一行「添加成员」', (t) async {
    await pumpCard(t);

    expect(find.text('张建国'), findsOneWidget);
    expect(find.text('王淑芬'), findsOneWidget);
    expect(find.text('31 份'), findsOneWidget);
    expect(find.text('8 份'), findsOneWidget);
    expect(find.text('添加成员'), findsOneWidget);
  });

  testWidgets('一个角色词都没有(角色只在成员自己的页面里说)', (t) async {
    await pumpCard(t);

    for (final w in ['主人', '家属', '家人', '能改', '只能看', '只读', 'owner', 'editor', 'viewer']) {
      expect(find.textContaining(w), findsNothing, reason: '「$w」不许出现在挑人的列表上');
    }
  });

  testWidgets('点一行 → 交出那个成员;点「添加成员」→ 走新建那条路', (t) async {
    final opened = <String>[];
    var added = 0;
    await pumpCard(t, onOpen: (m) => opened.add(m.id), onAdd: () => added++);

    await t.tap(find.text('王淑芬'));
    await t.pump();
    expect(opened, ['p-2']);

    await t.tap(find.text('添加成员'));
    await t.pump();
    expect(added, 1);
  });

  // Task 13 fix round 1:删除成员的入口挪到 `MemberDetailScreen`(`s10`)的
  // 「删除这个成员」,不管一个成员还是两个,这张卡上都不该再有删除图标。
  testWidgets('不管几个成员,都没有删除图标(那颗撤掉了,入口在 s10)', (t) async {
    await pumpCard(t, members: const [Profile(id: 'p-1', name: '张建国')]);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    await pumpCard(t);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('份数还没数出来:显示「—」,不编一个数', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: MedMe.theme(),
      home: Scaffold(
        body: MembersCard(
          members: _members,
          countOf: (_) => null,
          onOpen: (_) {},
          onAdd: () {},
        ),
      ),
    ));

    expect(find.text('—'), findsNWidgets(2));
  });
}
