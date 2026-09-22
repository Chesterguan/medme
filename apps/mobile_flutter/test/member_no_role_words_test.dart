// mockup:成员相关的界面上**不出现亲属/角色词**,只写名字。
//
// 钉的是产品定的语义,不是某一版措辞:切换器、主页成员一行这类「挑人」的界面上,
// 任何身份词都不许出现。角色只在某一个成员自己的页面里说 —— 那里有上下文,
// 这里没有。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/member_header.dart';

const kRoleWords = [
  '家人', '家属', '本人', '主人', '只读', '能改', '可编辑',
  'owner', 'editor', 'viewer',
];

Widget wrap(Widget child) => MaterialApp(
  theme: MedMe.theme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('成员一行只写名字、性别年龄、份数 —— 没有角色', (tester) async {
    await tester.pumpWidget(
      wrap(MemberHeader(
        name: '张建国',
        gender: '男',
        age: '68岁',
        recordCount: 12,
        recentVisitDate: '2024-03-01',
        onSwitchMember: () {},
      )),
    );
    expect(find.textContaining('张建国'), findsOneWidget);
    for (final w in kRoleWords) {
      expect(find.textContaining(w), findsNothing, reason: '成员一行不说「$w」');
    }
  });
}
