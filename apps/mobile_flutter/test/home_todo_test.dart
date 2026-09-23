// 首页「待办」卡([HomeTodo]/[HomeTodoItem])+ `DueReminder` 的 JSON 小模型与
// [reminderNote] 拼接规则。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/widgets/home_todo.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('空列表 —— 整棵树里没有 MedCard', (tester) async {
    await pumpStage3(tester, const HomeTodo(items: []));
    expect(find.byType(MedCard), findsNothing);
  });

  testWidgets('三条 —— 三行、两条分隔线、title/note 都在、点第二行触发它的 onTap', (tester) async {
    var tapped = -1;
    await pumpStage3(tester, HomeTodo(items: [
      HomeTodoItem(title: '血常规逾期 8 个月', note: '超期 240 天', onTap: () => tapped = 0),
      HomeTodoItem(title: '眼底检查还没查过', note: '没查到', onTap: () => tapped = 1),
      HomeTodoItem(title: '最近 30 天有 2 项偏高或偏低', note: '给医生看', onTap: () => tapped = 2),
    ]));

    expect(find.byType(MedCard), findsOneWidget);
    expect(find.byType(Divider), findsNWidgets(2));
    for (final s in ['血常规逾期 8 个月', '超期 240 天', '眼底检查还没查过', '没查到', '最近 30 天有 2 项偏高或偏低', '给医生看']) {
      expect(find.text(s), findsOneWidget, reason: '「$s」应该在卡上');
    }

    await tester.tap(find.text('眼底检查还没查过'));
    expect(tapped, 1);
  });

  testWidgets('2× 字号 360×640 不溢出', (tester) async {
    await pumpStage3(
      tester,
      HomeTodo(items: [
        HomeTodoItem(title: '血常规逾期 8 个月', note: '超期 240 天', onTap: () {}),
        HomeTodoItem(title: '最近 30 天有 2 项偏高或偏低', note: '给医生看', onTap: () {}),
      ]),
      size: const Size(360, 640),
      textScale: 2.0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('颜色面预算 0/0,树里没有渐变', (tester) async {
    await pumpStage3(tester, HomeTodo(items: [
      HomeTodoItem(title: '血常规逾期 8 个月', note: '超期 240 天', onTap: () {}),
    ]));
    expectSurfaceBudget();
    expectNoGradientAnywhere();
  });

  test('reminderNote:超期显示「超期 N 天」,其余(never)显示档案页的状态标签', () {
    expect(
      reminderNote(const DueReminder(
        packageId: 'sle', packageName: '狼疮', id: 'r1', text: '复查血常规',
        state: 'overdue', overdueDays: 240,
      )),
      '超期 240 天',
    );
    expect(
      reminderNote(const DueReminder(
        packageId: 'sle', packageName: '狼疮', id: 'r2', text: '眼底检查',
        state: 'never',
      )),
      '没查到',
    );
  });

  test('DueReminder.fromJson', () {
    final r = DueReminder.fromJson(const {
      'package_id': 'sle',
      'package_name': '狼疮',
      'id': 'r1',
      'text': '复查血常规',
      'state': 'overdue',
      'due_at': '2026-01-01',
      'overdue_days': 240,
      'basis': 'guideline',
    });
    expect(r.packageId, 'sle');
    expect(r.packageName, '狼疮');
    expect(r.id, 'r1');
    expect(r.text, '复查血常规');
    expect(r.state, 'overdue');
    expect(r.dueAt, '2026-01-01');
    expect(r.overdueDays, 240);
    expect(r.basis, 'guideline');
  });

  test('DueReminder.fromJson:null 字段(id/text/due_at/overdue_days/basis)不炸', () {
    final r = DueReminder.fromJson(const {
      'package_id': 'sle',
      'package_name': '狼疮',
      'id': null,
      'text': null,
      'state': 'never',
      'due_at': null,
      'overdue_days': null,
      'basis': null,
    });
    expect(r.text, '');
    expect(r.dueAt, isNull);
    expect(r.overdueDays, isNull);
    expect(r.basis, isNull);
  });
}
