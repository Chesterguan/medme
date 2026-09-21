// 「我」tab 点开一个成员之后的页面(`s10`,Task 13 fix round 1)。最小实现,
// 四件事:谁能看这份病历 / 加一个人 / 改名字 / 删除这个成员。
//
// **云端备份 / 云端整理不在这里**——那两个开关是"这台设备"级别的
// (`account_screen.dart` 的 `_cloudMemberRow`/`_cloudExtractSwitch`),不是
// "这份病历"独有的东西;原来 Task 12 的 TODO 提过要一起挪过来,但这一轮的裁定
// 只要求「谁能看 / 加一个人 / 改名字 / 删除」四项,云端那两个开关继续留在
// 「我 → 云端」那一层,不重复一个入口。
//
// **不碰 FFI、不需要先切成当前成员**:四个操作(加人 / 撤销 / 改名 / 删除)都
// 直接对着传进来的 [MemberDetailScreen.member] 走——`Grants` 的方法本来就按
// profile 传参,不隐式吃 `ProfileManager.instance.current`
// (`grantFamilyByPhone`/`inviteDoctor`/`revoke`/`listGrants` 皆如此);
// `ProfileManager.rename`「只动标签,不动任何文件」,同理不需要先开箱。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/account_screen.dart' show roleLabel;
import 'package:mobile_flutter/vault_boot.dart' show removeProfileAndReopen;
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/link_qr_dialog.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 「谁能看」列表上的到期倒计时——`s10` 的原话是「剩 N 天」,不是
/// `account_screen.dart` 的 `expiryLabel`(那个给「我授权给谁」用,「至 M月D日」)。
/// 按日期算,不看时分:今天到期算「剩 0 天」,不做四舍五入,也不让它变成负数。
@visibleForTesting
String? daysLeftLabel(Object? iso, {DateTime? now}) {
  final t = iso == null ? null : DateTime.tryParse(iso.toString())?.toLocal();
  if (t == null) return null;
  final today = now ?? DateTime.now();
  final days = DateTime(
    t.year,
    t.month,
    t.day,
  ).difference(DateTime(today.year, today.month, today.day)).inDays;
  return '剩 ${days < 0 ? 0 : days} 天';
}

/// 删除确认弹窗里,云成员比纯本地成员多出来的一句提醒——从 `settings_screen.dart`
/// 搬过来(Task 13 fix round 1,与 [confirmRemoveMember] 一起搬)。
/// `removeProfileAndReopen` 对云成员做的其实是"从这台手机摘掉"(见
/// `vault_boot.dart` 的说明:owner 授权服务端删不掉,只是本机记一笔黑名单不再
/// 自动拉回),不是原文案暗示的"彻底删除"。纯本地成员(`p.cloudId == null`)
/// 没有这个落差,返回 null 不多说这句。
@visibleForTesting
String? cloudRemovalNotice(Profile p) => p.cloudId == null
    ? null
    // C10:末尾原来还挂着「要彻底删除请注销账号或撤销授权」。那是一句**错的指路**:
    // 注销账号删的是整个账号(连同其它成员、所有授权),不是"彻底删掉这一个成员";
    // 把它摆在删除单个成员的弹窗里,等于建议一个破坏性大得多的操作。撤销授权也只
    // 管"我给别人的",管不了自己这份 owner 档案。说清楚"这一步做了什么"就够了。
    : '从这台手机上删除;云端副本和其他设备不受影响,本机不会再自动拉回';

/// 删除一个成员的确认弹窗 + 执行——从 `settings_screen.dart` 的 `_confirmRemove`
/// 搬过来(Task 13 fix round 1):`MembersCard` 那颗小图标已经撤掉,这是删成员
/// **唯一**的入口(Task 12/13 那三个 `TODO(Task 13)` 之一)。返回真的删了没有。
///
/// [removeProfile] 默认真实的 `vault_boot.removeProfileAndReopen`(删目录 + 可能
/// 重开箱,碰真实 Rust/IO,`flutter test` 没有原生库跑不到)——同 `Grants.purgeExpired`
/// 的 `removeProfile` 参数一个套路,测试传一个假实现进来只钉"点了确认删除之后
/// 调没调、通知没通知"。
Future<bool> confirmRemoveMember(
  BuildContext context,
  Profile p, {
  Future<bool> Function(String id) removeProfile = removeProfileAndReopen,
}) async {
  final name = p.name;
  final n = ProfileManager.instance.countFor(p.id);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: MedColors.of(context).critical, size: 44),
      title: Text(
        '删除「$name」的全部病历?',
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (n != null && n > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: MedColors.of(context).critical.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$n 份病历',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: MedColors.of(context).critical),
              ),
            ),
          const SizedBox(height: 14),
          Text(
            cloudRemovalNotice(p) ??
                '连同拍摄的原件一起,从这台手机上彻底删除。\n'
                    '删除后无法恢复,我们也帮不了你。',
            textAlign: TextAlign.center,
            style: const TextStyle(height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: MedColors.of(context).critical),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  return removeProfile(p.id);
}

/// 「按手机号加成员」这条路自己的解释,从 `account_screen.dart` 的
/// `_familyLookupError` 搬过来(Task 13 fix round 1)。状态码的通用含义在
/// [friendlyApiError] 里(全 App 一份),这里只说它管不到的那一层:这个 404
/// 指的是"这个手机号没有账号",不是泛泛的"没找到"。认不出来返回 null,交回
/// 通用那一层。
String? _addByPhoneError(Object e) => switch (e) {
  ApiFailed(status: 409, message: 'no_keys') ||
  ApiFailed(status: 404, message: 'no_keys') =>
    '对方已注册,但还没设置好账号口令 —— 请他在 MedMe 里打开 我 → 口令与恢复码,完成最后两步',
  ApiFailed(status: 404) => '没有找到使用该手机号的账号',
  ApiFailed(status: 400) => '手机号格式不对',
  _ => null,
};

class MemberDetailScreen extends StatefulWidget {
  const MemberDetailScreen({
    super.key,
    required this.member,
    this.grants,
    this.onChanged,
    this.removeProfile = removeProfileAndReopen,
    this.renameProfile,
  });

  final Profile member;

  /// 测试注入点,默认为 null——真正用的时候现取现建(同 `AccountScreen.grants`)。
  final Grants? grants;

  /// 改名 / 删除成功后通知调用方刷新(`SettingsScreen` 的 `MembersCard` 要重新读
  /// `ProfileManager.instance.profiles`)。
  final VoidCallback? onChanged;

  /// 测试注入点,默认真实的 [removeProfileAndReopen]——见 [confirmRemoveMember] 的文档。
  final Future<bool> Function(String id) removeProfile;

  /// 测试注入点,默认为 null——真正用的时候落到 `ProfileManager.instance.rename`
  /// (不能像 [removeProfile] 那样直接当默认参数值:那是实例方法的 tear-off,不是
  /// 编译期常量)。同样是为了不在测试里碰真实 `dart:io` 文件写入的时序。
  final Future<void> Function(String id, String name)? renameProfile;

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  late String _name = widget.member.name;
  late final Grants _grants =
      widget.grants ?? Grants(ApiClient.forSession(AccountSession.instance), AccountSession.instance);

  /// 只有「这份档案已经上云,而且这台设备是 owner」才查得到谁能看——服务端
  /// `GET /v1/profiles/{pid}/grants` 是 owner-only(见 `services/api/app.py` 的
  /// `grants_list`)。不是 owner 就问,是摸黑试一次注定 403 的请求,索性连这一节、
  /// 连「加一个人」都不显示——这台设备没有资格替这份档案决定谁能看。
  bool get _canManageGrants => widget.member.cloudId != null && widget.member.role == 'owner';

  Future<List<Map<String, dynamic>>>? _grantsFuture;

  @override
  void initState() {
    super.initState();
    if (_canManageGrants) _grantsFuture = _grants.listGrants(widget.member);
  }

  // 不能写成 `setState(() => _grantsFuture = ...)`——赋值表达式的值就是被赋的值,
  // 那个箭头函数会被推成"返回一个 Future"的闭包,`setState` 直接断言失败
  // ("setState() callback argument returned a Future")。改成块体,显式不返回。
  void _reloadGrants() => setState(() {
    _grantsFuture = _grants.listGrants(widget.member);
  });

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final addRow = _addPersonRow();
    return Scaffold(
      appBar: AppBar(title: Text(_name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_canManageGrants) ...[..._grantsSection(), const SizedBox(height: 16)],
          if (addRow != null) ...[addRow, const SizedBox(height: 16)],
          MedCard(
            // 透明 Material:ListTile 的水波纹要画在这一层上,否则被 MedCard 的
            // 白底盖住(Flutter debug 断言;`doctor_home_screen.dart` 已有写法)。
            child: Column(
              children: [
                ListTile(
                  leading: const GlossIconTile(icon: Icons.edit_outlined, category: GlossCategory.note),
                  title: const Text('改名字'),
                  trailing: Icon(Icons.chevron_right, color: c.ink3),
                  onTap: _rename,
                ),
                Divider(height: 1, color: c.line2),
                ListTile(
                  leading: const GlossIconTile(icon: Icons.person_remove_outlined, category: GlossCategory.alert),
                  title: Text('删除这个成员', style: TextStyle(color: c.critical)),
                  trailing: Icon(Icons.chevron_right, color: c.critical),
                  onTap: _delete,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「谁能看<名字>的病历」:一行一个 grant——`editor` → 「能改」,`viewer` →
  /// 「只能看」(带到期的再接一句「剩 N 天」),行尾一颗「撤销」。**owner 那一行
  /// (服务端会把它跟其它 grant 一起原样返回)过滤掉不画**——那就是这台设备的
  /// 主人自己,不需要在"谁能看"的名单里再标一遍。
  List<Widget> _grantsSection() {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          '谁能看$_name的病历',
          style: TextStyle(color: MedColors.of(context).ink3, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _grantsFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snap.hasError) {
            return Text('加载失败:${friendlyApiError(snap.error!)}', style: TextStyle(color: MedColors.of(context).critical));
          }
          final rows = (snap.data ?? const <Map<String, dynamic>>[])
              .where((g) => g['role'] != 'owner')
              .toList();
          if (rows.isEmpty) {
            return Text('还没有人被邀请', style: TextStyle(color: MedColors.of(context).ink3));
          }
          return MedCard(
            child: Column(
              children: [
                for (final g in rows) ...[
                  if (g != rows.first) Divider(height: 1, color: MedColors.of(context).line2),
                  ListTile(
                    title: Text(_grantRowLabel(g)),
                    trailing: TextButton(
                      onPressed: () => _revoke(g['grant_id'] as String),
                      child: const Text('撤销'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ];
  }

  String _grantRowLabel(Map<String, dynamic> g) {
    final role = g['role'] as String?;
    final days = role == 'viewer' ? daysLeftLabel(g['expires_at']) : null;
    return days == null ? roleLabel(role) : '${roleLabel(role)} · $days';
  }

  /// 撤销前先问一句——原来点一下就真撤了,一次误触就没有回头路。
  ///
  /// ⚠️ fix round 1:原文案「撤销后,对方立刻看不到」超出了系统实际能兑现的
  /// 范围。真相是:`Grants.revoke` 只删服务端那一行 grant 记录
  /// (`services/api/db.py` 的 `grant_delete`,一条 `DELETE`);真正拦人的是
  /// 下次同步时 `events_pull` 的角色校验(`services/api/app.py:377-378`)——挡住的
  /// 是**以后**的同步,不是已经到手的东西。对方手机早前拉过的内容已经解密、落进
  /// 了它自己本地的 CAS(`sync_engine.dart` 的 `RustSyncApi.storeObject` 一路
  /// 注释),这台设备够不着,删不掉;而家人(editor)是**永久**授权、没有到期时间
  /// (`Grants.grantFamilyByPhone` 的文档),本机那条按时间过期的清理
  /// (`Grants.purgeExpired`)也轮不到它。文案照实说:只挡得住"以后",挡不住
  /// "已经给出去的"。
  ///
  /// **给不出对方的名字**:服务端本来就不存 grantee 的手机号/姓名(`db.py` 的
  /// `grants_list` 注释),编一个出来是撒谎,只能说「对方」。
  Future<bool> _confirmRevoke() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('不再让对方看?'),
        content: const Text(
          '撤销后,对方收不到之后新增的病历;已经同步到对方手机上的,这里收不回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: MedColors.of(context).critical),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _revoke(String grantId) async {
    if (!await _confirmRevoke()) return;
    try {
      await _grants.revoke(widget.member, grantId);
      _reloadGrants();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('撤销失败:${friendlyApiError(e)}')));
    }
  }

  /// 「加一个人」行。这个成员从没开通云端备份:显示既有的那句解释,不给一个点了
  /// 就 403 的按钮。开通了但这台设备不是 owner:也没有资格邀请别人,整行不画
  /// (同 [_canManageGrants] 的理由)——返回 `null` 让调用方连带的间距也一起省掉。
  Widget? _addPersonRow() {
    if (widget.member.cloudId == null) {
      return MedCard(
        child: ListTile(title: Text('这个成员还没开通云端备份,暂时加不了人', style: TextStyle(color: MedColors.of(context).ink3))),
      );
    }
    if (widget.member.role != 'owner') return null;
    return MedCard(
      child: ListTile(
        leading: const GlossIconTile(icon: Icons.add, category: GlossCategory.note),
        title: Text('加一个人', style: TextStyle(fontWeight: FontWeight.w600, color: MedColors.of(context).seal)),
        subtitle: const Text('手机号或扫码'),
        onTap: _addPerson,
      ),
    );
  }

  /// 「手机号或扫码」两条既有的路(`Grants.grantFamilyByPhone` / `Grants.inviteDoctor`),
  /// 从 `account_screen.dart` 挪过来给这一个成员用,不是重新发明一套——那两个
  /// `Grants` 方法本来就按 profile 传参,不需要先切成当前成员。
  Future<void> _addPerson() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('按手机号加'),
              onTap: () => Navigator.of(context).pop('phone'),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: const Text('生成二维码给医生'),
              onTap: () => Navigator.of(context).pop('qr'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'phone') await _addByPhone();
    if (choice == 'qr') await _addByQr();
  }

  /// 按手机号加(永久 `editor`)。同 `account_screen.dart` 原来的
  /// `_familySection`/`_addFamily`,只是不再吃 `ProfileManager.instance.current`,
  /// 改成对着 [widget.member] 走。
  Future<void> _addByPhone() async {
    final phoneCtrl = TextEditingController();
    String? error;
    var busy = false;
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('按手机号加成员'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('add_by_phone'),
                controller: phoneCtrl,
                autofocus: true,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: '成员手机号'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: TextStyle(color: MedColors.of(context).critical)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            busy
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : FilledButton(
                    onPressed: () async {
                      setDialogState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await _grants.grantFamilyByPhone(widget.member, phoneCtrl.text.replaceAll(' ', ''));
                        if (context.mounted) Navigator.of(context).pop(true);
                      } catch (e) {
                        setDialogState(() {
                          busy = false;
                          error = _addByPhoneError(e) ?? friendlyApiError(e);
                        });
                      }
                    },
                    child: const Text('加'),
                  ),
          ],
        ),
      ),
    );
    if (added == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已加上')));
      _reloadGrants();
    }
  }

  /// 生成一张 15 天只读邀请码(`Grants.inviteDoctor`,与出码屏「医生要长期看」
  /// 那条走的是同一个方法),用既有的 [showLinkQrDialog] 摆成码 + 复制 + 分享。
  Future<void> _addByQr() async {
    try {
      final link = await _grants.inviteDoctor(widget.member);
      if (!mounted) return;
      await showLinkQrDialog(
        context,
        title: '给他这个码',
        url: link.toUrl(),
        body:
            '让对方用手机相机拍下这个码,或者把链接发给他。扫码或点开链接后,'
            '他能看「$_name」的病历,为期 ${Grants.grantDoctorDays} 天。',
        footnote: '只有拿到这个码的人能打开,我们看不到里面的内容。到期前可以在这页撤销。',
        shareSubject: '$_name的病历',
        shareLabel: '发给他',
      );
      if (mounted) _reloadGrants();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('生成失败:${friendlyApiError(e)}')));
    }
  }

  /// 改名字。「只动标签,不动任何文件」(`ProfileManager.rename` 的文档),
  /// 不需要先开箱,与 `member_switcher.dart` 的 `promptAddMember` 同一个 UI 套路
  /// (输个名字 → 一个取消一个保存)。
  Future<void> _rename() async {
    final controller = TextEditingController(text: _name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('改名字'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入姓名'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await (widget.renameProfile ?? ProfileManager.instance.rename)(widget.member.id, name.trim());
    if (!mounted) return;
    setState(() => _name = name.trim());
    widget.onChanged?.call();
  }

  /// 删除这个成员——`confirmRemoveMember` 就是原来 `settings_screen.dart` 那颗
  /// 删除小图标背后的同一个弹窗 + 同一次 `removeProfileAndReopen`。删掉之后这一页
  /// 没有存在的理由了,直接退回成员列表;失败就留在这一页说清楚。
  ///
  /// 成功那句「已移除」是从 `settings_screen.dart` 原来的 `_confirmRemove` 搬过来
  /// 时漏掉的一条(那时候删除就在原地的列表行上,不需要跳走;搬来这一页、加了
  /// `pop()` 之后,反而更需要这句话——`ScaffoldMessenger` 是 `MaterialApp` 根上
  /// 唯一那个,`showSnackBar` 之后紧接着 `pop` 不会把它带走)。
  Future<void> _delete() async {
    final removed = await confirmRemoveMember(context, widget.member, removeProfile: widget.removeProfile);
    if (!mounted) return;
    if (removed) {
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('已移除「$_name」')));
      widget.onChanged?.call();
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('无法移除该成员')));
    }
  }
}
