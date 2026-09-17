// 「我」tab 的「这台手机上的病历」卡(`s5`,Task 12)。
//
// 只 pump 这张卡,不 pump `SettingsScreen` —— 那一屏 `initState` 里直接调 FFI
// (`icloudStatus` / `patientProfile`),`flutter test` 不带原生库(同
// `test/overview_quick_actions_test.dart` 顶部那条教训)。
//
// 钉住的是一条会在界面上说错话的规矩:**挑人的列表上只有名字和份数,一个角色词
// 都不许有**。「主人 / 家属 / 能改 / 只能看」写在这里,用户读到的是「家里谁是谁」,
// 而那不是那个字段的意思 —— 授权级别只在某个成员自己的页面里说(`s10`,Task 13)。
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
  void Function(Profile)? onRemove,
}) => t.pumpWidget(MaterialApp(
      theme: MedMe.theme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MembersCard(
            members: members,
            countOf: (id) => id == 'p-1' ? 31 : 8,
            onOpen: onOpen ?? (_) {},
            onAdd: onAdd ?? () {},
            onRemove: onRemove ?? (_) {},
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

  // `ProfileManager.canRemove`:不能删到一个不剩 —— 那等于清空整个病历箱,
  // 该走「删掉全部」那条更明确的路。
  testWidgets('只剩一个成员:不给删', (t) async {
    await pumpCard(t, members: const [Profile(id: 'p-1', name: '张建国')]);

    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('两个成员:各自给一颗删除', (t) async {
    final removed = <String>[];
    await pumpCard(t, onRemove: (m) => removed.add(m.id));

    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    await t.tap(find.byIcon(Icons.delete_outline).first);
    await t.pump();
    expect(removed, ['p-1']);
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
          onRemove: (_) {},
        ),
      ),
    ));

    expect(find.text('—'), findsNWidgets(2));
  });
}
