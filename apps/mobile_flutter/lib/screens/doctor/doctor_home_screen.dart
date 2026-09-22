import 'package:flutter/material.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grants.dart';
// `expiredGrantNotice` 现在住在 `grants.dart`(两个 purge 调用点共用,见评审
// Important 4);这条 `export` 让既有的 `doctor_home_screen` 测试照旧 import 得到。
export 'package:mobile_flutter/grants.dart' show expiredGrantNotice;
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/screens/doctor/doctor_delivery_count.dart';
import 'package:mobile_flutter/screens/doctor/proxy_intake_flow.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';

/// A3b:「病人授权给我的档案」列哪些成员 —— 纯函数,好单独钉住。
///
/// 只要 `role == 'viewer'`:那正是病人出码、医生扫码兑换拿到的角色(见
/// `Grants.inviteDoctor`)。医生自己的档案(owner)和与家人共管的(editor)不属于
/// "病人授权给我的",混进来这一节就变成了第二个成员列表。
///
/// 快到期的排前面 —— 这一节的用处正是"这几天还能看谁的",不是一张通讯录。
@visibleForTesting
List<Profile> patientGrantedProfiles(List<Profile> all, {DateTime? now}) {
  final at = now ?? DateTime.now();
  // **自己也过滤过期的**(评审 Minor 17):通常 `_refresh` 里的 purge 先跑,但它包在
  // `catch (_) {}` 里、而 `removeProfileAndReopen` 也可能返回 false —— 那时医生会看到
  // 一行副标题写着已经过去的日期、还点得进去。这样这一节无论 purge 成不成都说真话。
  final rows = all
      .where((p) => p.role == 'viewer' && p.cloudId != null && (p.expiresAt?.isAfter(at) ?? true))
      .toList();
  rows.sort((a, b) {
    final x = a.expiresAt, y = b.expiresAt;
    if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
    return x.compareTo(y);
  });
  return rows;
}

/// 「只能看 · 至 M月D日」。
///
/// ⚠️ 这一行**不受**「挑人的界面零角色词」那条硬规矩管(Task 13 复审裁定的例外):
/// 代拍这一节回答的是"这几天还能看谁的",到期日是医生真正要用的信息,不是
/// 可有可无的身份标签——拿掉它,医生没法判断该催病人续、还是这几天就要失效。
/// 措辞上仍然守着一条:「只读」是内部/API 的词,界面上一律说「只能看」(与
/// `account_screen.dart` 的 `roleLabel('viewer')` 一致)。没有到期日(理论上
/// viewer 总有)就只说「只能看」。
///
/// **这一行不再和 `member_switcher.dart` 逐字相同**——那边(挑人的成员切换器)
/// 已经把角色词整个删掉,只剩名字(Task 13);这里保留是评审裁定的例外,两处
/// 分道扬镳是有意的,不是遗漏。
@visibleForTesting
String patientGrantedSubtitle(Profile p) =>
    p.expiresAt == null ? '只能看' : '只能看 · 至 ${p.expiresAt!.month}月${p.expiresAt!.day}日';



/// 代拍主界面——不放进「导出·分享」tab,是独立的应用根(见 `main.dart` 的
/// `AppRoot`)。「我是医生,替病人代拍」按钮 + **今天代拍的**列表:代拍过的病人按姓名列在这里,
/// 本机最多留 12 小时(到点由 [ProxyPatientManager] 自动删),期间可点回去补拍、
/// 继续核对、重新交付。右上「清空」一次删干净。
///
/// 视觉:主色走 `MedColors.proxy`(紫),不是个人模式的 `seal`(蓝)——代拍
/// 的每一屏都靠这个颜色宣告「这不是你自己的档案」。除主色外的一切(中性色、字阶、
/// 圆角、阴影、卡片)与个人模式同源。
class DoctorHomeScreen extends StatefulWidget {
  const DoctorHomeScreen({super.key, this.switchTo, this.purgeExpired});

  /// 测试注入点,默认真实的 `vault_boot.switchProfileAndReopen`(内部开箱调 FFI,
  /// `flutter test` 跑不到)。同 `showMemberSwitcherSheet` 的同名参数。
  final Future<void> Function(String id)? switchTo;

  /// 测试注入点,默认真实的 [Grants.purgeExpired]。
  final Future<List<Profile>> Function()? purgeExpired;

  @override
  State<DoctorHomeScreen> createState() => _DoctorHomeScreenState();
}

class _DoctorHomeScreenState extends State<DoctorHomeScreen> {
  int? _todayCount;
  List<ProxyPatient> _patients = const [];
  List<Profile> _granted = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 每次回到这一屏都重读:`ensureLoaded` 顺手执行 12 小时 TTL,所以过期的病人是在
  /// 这里消失的——不需要后台定时器。
  ///
  /// 「病人授权给我的档案」同理:清过期 + 重算列表都挂在这一次刷新上。清理失败
  /// (网络、FFI)**绝不能挡住这一屏**——吞掉,下次回来再试(同
  /// `showMemberSwitcherSheet` 里那段的理由)。
  Future<void> _refresh() async {
    final n = await DoctorDeliveryCount.instance.todayCount();
    await ProxyPatientManager.instance.ensureLoaded();
    await ProfileManager.instance.ensureLoaded();
    var removed = const <Profile>[];
    try {
      removed = await (widget.purgeExpired ??
          () => Grants(
                ApiClient.forSession(AccountSession.instance),
                AccountSession.instance,
              ).purgeExpired())();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _todayCount = n;
      _patients = ProxyPatientManager.instance.patients;
      _granted = patientGrantedProfiles(ProfileManager.instance.profiles);
    });
    final notice = expiredGrantNotice(removed);
    if (notice != null) {
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text(notice)));
    }
  }

  /// 点一份病人授权给我的档案:切过去 + 重开箱,然后直接打开档案屏。
  ///
  /// 在这之前医生得**切回个人模式、去家人列表里找** —— 诊室里没人会这么做,
  /// 于是"病人扫码授权"这件事在医生那一侧基本等于没有落地(A3b)。
  Future<void> _openGranted(Profile p) async {
    try {
      await (widget.switchTo ?? switchProfileAndReopen)(p.id);
    } catch (e) {
      // **不只接 `ProfileLocked`**(评审 Important 7):`switchProfileAndReopenImpl`
      // 回退之后会 rethrow 原始开箱错误,所以 FFI 开箱失败、箱子坏了这些也会到这里。
      // 只接一种的后果是医生点一行「什么都不发生,也没有任何提示」。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text(friendlyApiError(e))));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ArchiveScreen()),
    );
    await _refresh();
  }

  Future<void> _startCapture() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const ProxyIntakeFlow(),
      ),
    );
    await _refresh();
  }

  /// 点回一个已建档的病人:开他的箱子继续核对/补拍/交付(同意已经签过)。
  Future<void> _openPatient(ProxyPatient p) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ProxyIntakeFlow(patientId: p.id),
      ),
    );
    await _refresh();
  }

  Future<void> _removeOne(ProxyPatient p) async {
    final ok = await _confirm(
      '删掉「${p.displayName}」?',
      '这个病人在本机的病历材料会立刻删除,不可撤销。已经交给病人的加密文件不受影响。',
    );
    if (ok != true) return;
    await ProxyPatientManager.instance.remove(p.id);
    await _refresh();
  }

  Future<void> _removeAll() async {
    final ok = await _confirm(
      '清空今天代拍的?',
      '${_patients.length} 位病人在本机的材料会立刻全部删除,不可撤销。'
          '你自己的病历箱不受影响。',
    );
    if (ok != true) return;
    await ProxyPatientManager.instance.removeAll();
    await _refresh();
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: MedColors.of(context).critical,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('替病人代拍'),
        actions: [
          if (_patients.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空今天代拍的',
              onPressed: _removeAll,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MedShape.s5,
                MedShape.s5,
                MedShape.s5,
                MedShape.s1,
              ),
              // s14 的一屏一处品牌色面:这一屏唯一的 HeroCard。
              child: HeroCard(
                color: c.proxyInk,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: c.proxyWash,
                      child: Icon(
                        Icons.medical_services_outlined,
                        color: c.proxy,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: MedShape.s2),
                    Text('代拍', style: MedType.title.copyWith(color: Colors.white)),
                    const SizedBox(height: 6),
                    Text(
                      '当面征得同意后拍摄病人的纸质病历材料,拍完生成一个取件码让病人当场扫走;'
                      '网络不畅时退回加密文件+口令。本机最多留 12 小时,到时间自动删。',
                      textAlign: TextAlign.center,
                      style: MedType.secondary.copyWith(
                        color: c.onDarkMeta,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: MedShape.s4),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton.icon(
                        // 一屏唯一的主按钮:紫色纯色不用渐变(规范 §六)。代拍
                        // 主色 proxy 原样保留——brief 没动它,紫也不是品牌渐变,
                        // 不占这一屏 hero:1 的名额。
                        style: FilledButton.styleFrom(backgroundColor: c.proxy),
                        onPressed: _startCapture,
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('我是医生,替病人代拍'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            PatientGrantedSection(profiles: _granted, onTap: _openGranted),
            Expanded(child: _buildList()),
            Padding(
              padding: const EdgeInsets.only(bottom: MedShape.s2, top: 4),
              child: Text(
                '今日已交付 ${_todayCount ?? 0} 份',
                // 数字要等宽:一天下来这行只有它在变。
                style: MedType.secondary.copyWith(
                  color: c.ink3,
                  fontFeatures: MedType.tabular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final c = MedColors.of(context);
    if (_patients.isEmpty) {
      // 空态给虚线框(规范 §六)——出路就在框正上方那个主按钮,不再重复一个。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MedShape.s6),
          child: DottedBorderBox(
            child: Text(
              '还没有代拍的病人。\n代拍过的会列在这里,12 小时内可以随时回来补拍或重发。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        MedShape.s1,
        MedShape.s3,
        MedShape.s1,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, MedShape.s1),
          child: Text('今天代拍的', style: MedType.caption.copyWith(color: c.ink3)),
        ),
        for (final p in _patients)
          Padding(
            padding: const EdgeInsets.only(bottom: MedShape.s1),
            child: _PatientRow(
              patient: p,
              onTap: () => _openPatient(p),
              onDelete: () => _removeOne(p),
            ),
          ),
      ],
    );
  }
}

/// A3b:「病人让我看的档案」那一节。**不碰任何 IO** —— 成员表由
/// [DoctorHomeScreen] 读好传进来,于是这一节的渲染与点击能在 `flutter test` 里
/// 单独钉住(整屏不行:它的 `initState` 要穿过三个单例的真实文件 I/O)。
///
/// 列表为空时整节不画:这一屏的主角是代拍,没有被授权的档案时不该多一个空标题。
class PatientGrantedSection extends StatelessWidget {
  const PatientGrantedSection({super.key, required this.profiles, required this.onTap});

  final List<Profile> profiles;
  final void Function(Profile) onTap;

  @override
  Widget build(BuildContext context) {
    if (profiles.isEmpty) return const SizedBox.shrink();
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s1, MedShape.s3, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, MedShape.s1),
            child: Text('病人让我看的病历', style: MedType.caption.copyWith(color: c.ink3)),
          ),
          for (final p in profiles)
            MedCard(
              child: ListTile(
                key: Key('granted_${p.id}'),
                leading: const MedIcon(Icons.description_outlined),
                title: Text(p.name, style: MedType.subtitle.copyWith(color: c.ink)),
                subtitle: Text(
                  patientGrantedSubtitle(p),
                  style: MedType.secondary.copyWith(color: c.ink2),
                ),
                trailing: Icon(Icons.chevron_right, color: c.ink3),
                onTap: () => onTap(p),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「今天代拍的」列表一行:病人名 + 份数 + 还剩多久自动删 + 删除按钮。
///
/// **不带骑缝线。** 这是一张派生卡:名字是从若干份原件里识别出来的、份数是数出来
/// 的,背后没有「某一张纸」可点进去(点进去是这个病人的清单)。骑缝线只给点得进
/// 原件的卡(规范 §五),当装饰用就把「可溯源」这句话说成了假话。
class _PatientRow extends StatelessWidget {
  const _PatientRow({
    required this.patient,
    required this.onTap,
    required this.onDelete,
  });

  final ProxyPatient patient;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return MedCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            MedShape.s2,
            MedShape.s2,
            4,
            MedShape.s2,
          ),
          child: Row(
            children: [
              const MedIcon(Icons.camera_alt_outlined),
              const SizedBox(width: MedShape.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patient.displayName,
                      style: MedType.subtitle.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '拍了 ${patient.docCount} 份 · ${_remainingLabel(patient.remaining)}',
                      // 份数与倒计时都是数字,等宽才对得齐。
                      style: MedType.secondary.copyWith(
                        color: c.ink2,
                        fontFeatures: MedType.tabular,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: c.ink3,
                tooltip: '删除这个病人',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「N 小时/分钟后自动清掉」。不到一分钟就说「即将自动清掉」,不显示 0 分钟。
String _remainingLabel(Duration d) {
  if (d.inMinutes < 1) return '即将自动清掉';
  if (d.inHours < 1) return '${d.inMinutes} 分钟后自动清掉';
  return '${d.inHours} 小时后自动清掉';
}
