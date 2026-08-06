import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应急卡上**没有数据来源**的两项:紧急联系人 与 器官捐献意愿。
///
/// 设计系统 §九 那张表里,过敏史 / 用药 / 慢病三项都能从已导入的病历抽出来,只有
/// 这两项写着「无来源 · 手填」。它们不进保险箱(保险箱存的是**病历原件与从原件抽
/// 出的事实**,而这两项是用户此刻的意愿声明,不是任何一张纸上的内容),用
/// `SharedPreferences` 存在本机,和别的本地偏好一个待遇。
///
/// **不做云端、不进导出、不进二维码。** 紧急联系人是第三方的电话号码 —— 那个人
/// 并没有同意把号码交给任何人;器官捐献意愿是极敏感的个人信息。它们只在这台手机
/// 上,只为「别人拿着你的手机」那一刻存在。
@immutable
class EmergencyExtras {
  const EmergencyExtras({
    this.contactName = '',
    this.contactRelation = '',
    this.contactPhone = '',
    this.organDonation = OrganDonation.unset,
  });

  final String contactName;
  final String contactRelation;
  final String contactPhone;
  final OrganDonation organDonation;

  /// 有没有一个能拨出去的号码。姓名可以空(急救时号码本身才是有用的那一半)。
  bool get hasPhone => contactPhone.trim().isNotEmpty;

  EmergencyExtras copyWith({
    String? contactName,
    String? contactRelation,
    String? contactPhone,
    OrganDonation? organDonation,
  }) => EmergencyExtras(
    contactName: contactName ?? this.contactName,
    contactRelation: contactRelation ?? this.contactRelation,
    contactPhone: contactPhone ?? this.contactPhone,
    organDonation: organDonation ?? this.organDonation,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmergencyExtras &&
          contactName == other.contactName &&
          contactRelation == other.contactRelation &&
          contactPhone == other.contactPhone &&
          organDonation == other.organDonation;

  @override
  int get hashCode =>
      Object.hash(contactName, contactRelation, contactPhone, organDonation);
}

/// 器官捐献意愿。
///
/// **`unset` 与 `no` 是两件不同的事,不许合并。** 「没填过」不等于「不愿意」——
/// 把没填过显示成「不愿意」是替用户表态;反过来把没填过显示成「愿意」更糟。
/// 屏幕上一律显示成「未登记」,并注明这只是本人在 App 里的记录,不具法律效力
/// (中国的器官捐献志愿登记在中国人体器官捐献管理中心,不在这里)。
enum OrganDonation {
  unset('未登记'),
  yes('愿意捐献'),
  no('不愿意捐献');

  const OrganDonation(this.label);
  final String label;

  static OrganDonation fromKey(String? k) =>
      OrganDonation.values.where((v) => v.name == k).firstOrNull ??
      OrganDonation.unset;
}

/// 手填项的本地存储。单例 + `ValueListenable`,与 `ProfileManager` 同一风格:
/// 编辑完各屏自动跟着变,不必手动传回调。
class EmergencyExtrasStore {
  EmergencyExtrasStore._();

  static final EmergencyExtrasStore instance = EmergencyExtrasStore._();

  static const _kName = 'emergency_contact_name';
  static const _kRelation = 'emergency_contact_relation';
  static const _kPhone = 'emergency_contact_phone';
  static const _kOrgan = 'emergency_organ_donation';

  final ValueNotifier<EmergencyExtras> value =
      ValueNotifier<EmergencyExtras>(const EmergencyExtras());

  Future<void>? _loading;

  /// 读一次即可,之后都走内存里的 [value]。重复调用共用同一个 Future。
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      value.value = EmergencyExtras(
        contactName: sp.getString(_kName) ?? '',
        contactRelation: sp.getString(_kRelation) ?? '',
        contactPhone: sp.getString(_kPhone) ?? '',
        organDonation: OrganDonation.fromKey(sp.getString(_kOrgan)),
      );
    } catch (e) {
      // 读不出来就当没填过 —— 应急卡的其余部分(过敏、用药、慢病)照常显示。
      // 一个偏好读失败绝不能让急救时唯一有用的那一屏白掉。
      debugPrint('[emergency] 读取手填项失败: $e');
    }
  }

  Future<void> save(EmergencyExtras next) async {
    value.value = next;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kName, next.contactName.trim());
    await sp.setString(_kRelation, next.contactRelation.trim());
    await sp.setString(_kPhone, next.contactPhone.trim());
    await sp.setString(_kOrgan, next.organDonation.name);
  }
}
