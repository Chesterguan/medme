import 'package:mobile_flutter/profile_manager.dart';

/// 认领的病历该落到哪个成员 —— **按包里的姓名认人**,不是按「当前选中的是谁」。
///
/// 「当前选中的是谁」曾经是默认,那是错的:病人从浏览器点进来,App 里恰好停在哪个
/// 成员纯属偶然,于是张三的病历灌进李四的档案,而且**是静默的**。姓名是包里唯一可靠
/// 的身份信息(医生那边由 OCR 识别填入),就用它;认不出姓名才退回当前成员。
///
/// 不做「选一个成员」的选择器:把名字改成「爸」「妈」的人本来就是会用软件的少数,
/// 他们自己能挪;为这少数把主流程做成一次选择,是让所有人替他们付成本。
enum ClaimHow {
  /// 档案里已经有同名的人 → 并进去(内容哈希去重,重复认领安全)。
  merge,

  /// 全新安装那个还没命名的「我」 → 直接把它改成这个名字,而不是在旁边多建一个。
  rename,

  /// 没有同名的人 → 新建一个成员。
  create,

  /// 包里没识别出姓名 → 只能存进当前成员。
  current,
}

class ClaimTarget {
  const ClaimTarget(this.how, this.name, [this.id]);
  final ClaimHow how;

  /// 存进去的那个成员**将会**叫什么(create/rename 时是包里的姓名)。
  final String name;

  /// 目标成员 id;`create` 时还不存在,为 null。
  final String? id;

  /// 给病人看的一句话:东西落到哪儿、会不会多出一个人来。
  String get note => switch (how) {
    ClaimHow.merge => '你的档案里已经有「$name」,这份会并进去',
    ClaimHow.rename => '这是你的第一份病历,档案就用这个名字',
    ClaimHow.create => '会在你的档案里新建「$name」',
    ClaimHow.current => '这份病历里没有姓名,存进你当前的档案',
  };
}

/// 纯函数,便于测:所有输入都从 [ProfileManager] 取,不碰磁盘。
ClaimTarget resolveClaimTarget({
  required String patientName,
  required List<Profile> profiles,
  required Profile current,
  required bool isUnnamedPlaceholder,
}) {
  final name = patientName.trim();
  if (name.isEmpty) return ClaimTarget(ClaimHow.current, current.name, current.id);
  for (final p in profiles) {
    if (p.name.trim() == name) return ClaimTarget(ClaimHow.merge, name, p.id);
  }
  if (isUnnamedPlaceholder) {
    return ClaimTarget(ClaimHow.rename, name, current.id);
  }
  return ClaimTarget(ClaimHow.create, name);
}
