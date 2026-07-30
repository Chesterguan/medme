import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/claim_target.dart';
import 'package:mobile_flutter/profile_manager.dart';

/// 「这份病历存进谁的档案」——存错人是**静默**的,只有测试挡得住。
void main() {
  const me = Profile(id: 'p-1', name: '我');
  const zhang = Profile(id: 'p-2', name: '张建国');

  ClaimTarget run(
    String patientName, {
    List<Profile> profiles = const [me],
    Profile current = me,
    bool placeholder = false,
  }) => resolveClaimTarget(
    patientName: patientName,
    profiles: profiles,
    current: current,
    isUnnamedPlaceholder: placeholder,
  );

  test('全新安装:占位的「我」被改名,而不是旁边多出一个空成员', () {
    final t = run('张建国', placeholder: true);
    expect(t.how, ClaimHow.rename);
    expect(t.id, 'p-1');
    expect(t.name, '张建国');
  });

  test('档案里已经有同名的人 → 并进那个人,不新建', () {
    final t = run('张建国', profiles: [me, zhang]);
    expect(t.how, ClaimHow.merge);
    expect(t.id, 'p-2');
  });

  test('已经在用的档案、没有同名 → 新建成员(不灌进当前选中的那个)', () {
    final t = run('李秀英', profiles: [me, zhang], current: zhang);
    expect(t.how, ClaimHow.create);
    expect(t.name, '李秀英');
    expect(t.id, isNull);
  });

  test('包里没识别出姓名 → 才退回当前成员', () {
    final t = run('  ', profiles: [me, zhang], current: zhang);
    expect(t.how, ClaimHow.current);
    expect(t.id, 'p-2');
  });

  test('姓名两边的空白不算区别 —— 否则同一个人会被劈成两个成员', () {
    final t = run(' 张建国 ', profiles: [me, zhang]);
    expect(t.how, ClaimHow.merge);
    expect(t.id, 'p-2');
  });

  test('占位状态下遇到同名,合并优先于改名', () {
    final t = run('我', placeholder: true);
    expect(t.how, ClaimHow.merge);
    expect(t.id, 'p-1');
  });
}
