import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/emergency_contact.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 底部导航一级 tab「应急卡」—— 使用时刻:**急诊室,别人拿着你的手机**
/// (设计系统 §八、§九)。
///
/// 这是全 app 唯一一个**读者不是用户本人**的界面。所有取舍都从这一句推出来:
///
/// * **[EmergencyBigCardScreen] 大字模式**才是这个 tab 的产品本体,平时这一屏
///   只是它的维护界面。所以主按钮是「大字模式」,不是别的。
/// * **血型不给编。** `EmergencyCardDto.bloodType` 恒为 null(抽取链路里没有血型
///   抽取),这里显示「未登记」并且**不提供任何输入框** —— 见 [_BloodTypeCard]。
/// * **「在用药」这四个字不许出现。** 见 `widgets/recorded_meds.dart`:
///   `MedSpan.status` 恒为 `active`,那个列表真正的语义是「记录里提到过的药」。
///   急救医生把它当成当前医嘱会改变处置决定。
/// * 过敏史排第一,因为它是这一屏唯一一条**用错会当场出事**的信息。
class EmergencyCardScreen extends StatefulWidget {
  const EmergencyCardScreen({super.key, this.load});

  /// 数据源。生产恒为 null → 走 FFI([viewEmergencyCard] + [patientProfile])。
  /// `flutter test` 不加载 Rust 原生库,注入一个假的才能把「保险箱一变这一屏就
  /// 重新拉一次」钉成不依赖设备的回归(见 `test/emergency_card_refresh_test.dart`)。
  final Future<CardData> Function()? load;

  @override
  State<EmergencyCardScreen> createState() => _EmergencyCardScreenState();
}

/// 应急卡一次要用到的两样东西:抽取出来的卡本体 + 档案里的姓名性别年龄。
typedef CardData = (EmergencyCardDto, PatientProfileDto);

class _EmergencyCardScreenState extends State<EmergencyCardScreen> {
  late Future<CardData> _future = _load();

  @override
  void initState() {
    super.initState();
    vaultRevision.addListener(_onVaultChanged);
    // 手填项(紧急联系人 / 器官捐献)本机存,与保险箱无关,单独载入一次。
    EmergencyExtrasStore.instance.ensureLoaded();
  }

  @override
  void dispose() {
    vaultRevision.removeListener(_onVaultChanged);
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) _refresh();
  }

  /// 与概览 / 趋势 / 档案三屏同一个写法,理由也同一条:`setState(() => _future = …)`
  /// 的**箭头体**会把赋值结果(一个 `Future`)当成 setState 的返回值交出去,
  /// `State.setState` 在断言里发现它是 Future 就抛 —— 而那一抛发生在
  /// `markNeedsBuild()` **之前**。于是 `_future` 换成了新的,却没有任何一次重建被
  /// 调度;五个 tab 全在 `IndexedStack` 里、`tabScreens` 又是 `const` 列表,切 tab
  /// 也不重建(`identical(newWidget, oldWidget)` 直接跳过),这一屏就停在冷启动那
  /// 一刻,直到 App 重启。release 里断言被剥掉看不出来,debug/profile 必现。
  /// **所以必须是语句块,不是箭头。**
  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _future = next;
    });
    await next;
  }

  Future<CardData> _load() async {
    final inject = widget.load;
    if (inject != null) return inject();
    final r = await Future.wait([viewEmergencyCard(), patientProfile()]);
    return (r[0] as EmergencyCardDto, r[1] as PatientProfileDto);
  }

  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('应急卡'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<CardData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(MedShape.s6),
              child: Text(
                '加载应急卡失败:\n${snap.error}',
                textAlign: TextAlign.center,
                style: MedType.body.copyWith(color: c.ink2, height: 1.6),
              ),
            );
          }
          final (card, profile) = snap.data!;
          return ValueListenableBuilder<EmergencyExtras>(
            valueListenable: EmergencyExtrasStore.instance.value,
            builder: (context, extras, _) => ListView(
              padding: const EdgeInsets.fromLTRB(
                MedShape.s3,
                MedShape.s3,
                MedShape.s3,
                MedShape.s6,
              ),
              children: [
                _BigModeLauncher(
                  onOpen: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => EmergencyBigCardScreen(
                        card: card,
                        profile: profile,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: MedShape.s5),
                _BloodTypeCard(bloodType: card.bloodType),
                const SizedBox(height: MedShape.s5),
                _AllergySection(allergies: card.allergies, onOpenDoc: _openDoc),
                const SizedBox(height: MedShape.s5),
                _MedsSection(meds: card.activeMeds, onOpenDoc: _openDoc),
                const SizedBox(height: MedShape.s5),
                _ConditionSection(
                  conditions: card.conditions,
                  onOpenDoc: _openDoc,
                ),
                const SizedBox(height: MedShape.s5),
                _ExtrasSection(extras: extras),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 大字模式的入口。一屏只允许一颗主按钮(规范 §六),这个 tab 把它花在这里。
class _BigModeLauncher extends StatelessWidget {
  const _BigModeLauncher({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return MedCard(
      child: Padding(
        padding: const EdgeInsets.all(MedShape.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '给急救人员看的一屏',
              style: MedType.subtitle.copyWith(color: c.ink),
            ),
            const SizedBox(height: MedShape.s1),
            Text(
              '黑底大字、过敏史框起来、联系人一键拨号。你昏迷时,拿着这台手机的人'
              '需要在三秒内读到这些。',
              style: MedType.body.copyWith(color: c.ink2, height: 1.5),
            ),
            const SizedBox(height: MedShape.s3),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.format_size, size: 20),
                label: const Text('打开大字模式'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 血型。**恒为「未登记」,而且刻意不给编。**
///
/// `parser` 抽不出血型(化验单上有,但抽取链路没做这一项),`EmergencyCardDto`
/// 因此恒为 null。可以给用户一个输入框吗?**不可以** —— 那正是这一屏最危险的
/// 设计。手填的血型会以「MedMe 显示 A 型」的权威感出现在急救现场,而它的正确性
/// 只等于用户某天晚上的记忆。临床上输血前一律现场配血,一个记错的血型不会加快
/// 抢救,只会制造一个可能被采信的错误。
///
/// 宁可空着让人去问。这不是功能缺失,是**拒绝提供**。
class _BloodTypeCard extends StatelessWidget {
  const _BloodTypeCard({required this.bloodType});

  final String? bloodType;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('血型', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        // 派生自「我们没有」这个事实,背后没有原件 → 不画骑缝线。
        MedCard(
          child: Padding(
            padding: const EdgeInsets.all(MedShape.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bloodType ?? '未登记',
                  style: MedType.display.copyWith(color: c.ink3),
                ),
                const SizedBox(height: MedShape.s1),
                Text(
                  'MedMe 不从病历里抽取血型,也不提供手动填写 —— 急救时按一个记错的'
                  '血型输血会出人命,而输血前本来就要现场配血。这一栏空着,是为了让'
                  '医生去问,而不是相信手机。',
                  style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 过敏史 —— 这一屏最要紧的一节,所以整块用 `critical` 描边框起来(规范 §九
/// 「过敏史框起来」)。
///
/// 空过敏史必须自己说话:留白会被读成「无过敏史」,而我们只知道「已导入的这些纸
/// 上没写」。这两件事在急救现场差着一条命。
class _AllergySection extends StatelessWidget {
  const _AllergySection({required this.allergies, required this.onOpenDoc});

  final List<AllergyItemDto> allergies;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('过敏史', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        MedCard(
          borderColor: allergies.isEmpty ? null : c.critical,
          borderWidth: allergies.isEmpty ? 1 : 1.5,
          child: Padding(
            padding: const EdgeInsets.all(MedShape.s3),
            child: allergies.isEmpty
                ? Text(
                    '已导入的病历里没有找到过敏记录。\n'
                    '这不等于没有过敏 —— 只说明这些纸上没写。请当面告知医生。',
                    style: MedType.body.copyWith(color: c.ink2, height: 1.5),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final a in allergies)
                        _SourceRow(
                          title: a.substance,
                          titleStyle: MedType.subtitle.copyWith(
                            color: c.critical,
                          ),
                          subtitle: a.reaction.isEmpty ? null : a.reaction,
                          documentIds: a.documentIds,
                          onOpenDoc: onOpenDoc,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// 「记录中出现的药物」。标题与说明一律走 `recorded_meds.dart` 的常量 ——
/// 那个文件的存在理由就是不让「在用药」三个字出现在这一屏上。
class _MedsSection extends StatelessWidget {
  const _MedsSection({required this.meds, required this.onOpenDoc});

  final List<ActiveMedDto> meds;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kRecordedMedsTitle, style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        MedCard(
          child: Padding(
            padding: const EdgeInsets.all(MedShape.s3),
            child: meds.isEmpty
                ? Text(
                    '已导入的病历里没有读到药名。',
                    style: MedType.body.copyWith(color: c.ink2),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const RecordedMedsCaveat(),
                      const SizedBox(height: MedShape.s2),
                      for (final m in meds)
                        _SourceRow(
                          title: m.name,
                          subtitle: recordedMedTiming(m),
                          documentIds: m.documentIds,
                          onOpenDoc: onOpenDoc,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// 确诊慢病。`term` 是病历原文逐字的诊断名,不做归一化改写。
class _ConditionSection extends StatelessWidget {
  const _ConditionSection({required this.conditions, required this.onOpenDoc});

  final List<ChronicConditionDto> conditions;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('病历里的诊断', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        MedCard(
          child: Padding(
            padding: const EdgeInsets.all(MedShape.s3),
            child: conditions.isEmpty
                ? Text(
                    '已导入的病历里没有读到诊断名。',
                    style: MedType.body.copyWith(color: c.ink2),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final x in conditions)
                        _SourceRow(
                          title: x.term,
                          subtitle: [
                            if (x.onset case final o? when o.isNotEmpty)
                              '最早出现 $o'
                            else
                              '记录里没有日期',
                            if (x.icdCode case final i? when i.isNotEmpty) i,
                          ].join(' · '),
                          documentIds: x.documentIds,
                          onOpenDoc: onOpenDoc,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// 手填的两项:紧急联系人、器官捐献意愿。
class _ExtrasSection extends StatelessWidget {
  const _ExtrasSection({required this.extras});

  final EmergencyExtras extras;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final who = [
      extras.contactName,
      extras.contactRelation,
    ].where((x) => x.trim().isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('你自己填的', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        MedCard(
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.phone_outlined, color: c.seal),
                  title: Text(
                    '紧急联系人',
                    style: MedType.body.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    extras.hasPhone
                        ? [
                            if (who.isNotEmpty) who,
                            extras.contactPhone,
                          ].join(' · ')
                        : '未填写 —— 急救人员需要一个能打通的号码',
                    style: MedType.secondary.copyWith(
                      color: c.ink2,
                      fontFeatures: MedType.tabular,
                    ),
                  ),
                  trailing: Icon(Icons.edit_outlined, size: 20, color: c.ink3),
                  onTap: () => _editContact(context, extras),
                ),
                Divider(height: 1, thickness: 1, color: c.line2),
                ListTile(
                  leading: Icon(Icons.favorite_outline, color: c.seal),
                  title: Text(
                    '器官捐献意愿',
                    style: MedType.body.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    // 「未登记」不等于「不愿意」—— 见 `OrganDonation` 的文档。
                    '${extras.organDonation.label} · 这只是你在 App 里的记录,'
                    '不具法律效力;正式登记在中国人体器官捐献管理中心。',
                    style: MedType.secondary.copyWith(
                      color: c.ink2,
                      height: 1.4,
                    ),
                  ),
                  isThreeLine: true,
                  trailing: Icon(Icons.edit_outlined, size: 20, color: c.ink3),
                  onTap: () => _editOrgan(context, extras),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editContact(
    BuildContext context,
    EmergencyExtras current,
  ) async {
    final name = TextEditingController(text: current.contactName);
    final relation = TextEditingController(text: current.contactRelation);
    final phone = TextEditingController(text: current.contactPhone);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('紧急联系人'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '姓名'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: MedShape.s2),
              TextField(
                controller: relation,
                decoration: const InputDecoration(
                  labelText: '关系',
                  hintText: '配偶 / 子女 / 朋友',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: MedShape.s2),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: '电话'),
              ),
              const SizedBox(height: MedShape.s2),
              Text(
                '只存在这台手机上,不会同步、不会进导出文件、不会进给医生的二维码 ——'
                '这是别人的号码,他并没有同意把它交出去。',
                style: MedType.secondary.copyWith(
                  color: MedColors.of(context).ink2,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await EmergencyExtrasStore.instance.save(
      current.copyWith(
        contactName: name.text.trim(),
        contactRelation: relation.text.trim(),
        contactPhone: phone.text.trim(),
      ),
    );
  }

  Future<void> _editOrgan(
    BuildContext context,
    EmergencyExtras current,
  ) async {
    final picked = await showModalBottomSheet<OrganDonation>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in OrganDonation.values)
              ListTile(
                title: Text(v.label),
                trailing: v == current.organDonation
                    ? Icon(Icons.check, color: MedColors.of(context).seal)
                    : null,
                onTap: () => Navigator.of(context).pop(v),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await EmergencyExtrasStore.instance.save(
      current.copyWith(organDonation: picked),
    );
  }
}

/// 一条带来源的信息:标题 + 说明 + 「原件」按钮。
///
/// **「原件永远可达」**(007 §2.1):三个 DTO 每一项都带 `documentIds`,这里就得
/// 用上。`documentIds` 为空时不画按钮 —— 不给点不动的东西画入口。
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.title,
    required this.documentIds,
    required this.onOpenDoc,
    this.subtitle,
    this.titleStyle,
  });

  final String title;
  final String? subtitle;
  final TextStyle? titleStyle;
  final List<BigInt> documentIds;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 一条信息常被好几份病历提到。跳**最后一份** —— 最近一次提到它的那张纸,
    // 也是追问时最想看的那张。想看全部提及,走档案。
    final target = lastDocumentId(documentIds);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: titleStyle ?? MedType.subtitle.copyWith(color: c.ink),
                ),
                if (subtitle case final s? when s.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    s,
                    style: MedType.secondary.copyWith(
                      color: c.ink2,
                      fontFeatures: MedType.tabular,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (target != null)
            TextButton(
              onPressed: () => onOpenDoc(target),
              style: TextButton.styleFrom(
                foregroundColor: c.sealInk,
                padding: const EdgeInsets.symmetric(horizontal: MedShape.s1),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('原件', style: MedType.secondary),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 大字模式
// ─────────────────────────────────────────────────────────────────────────────

/// 大字模式:纯黑底、姓名血型 28px、过敏史框起来、联系人一键拨号(规范 §九)。
///
/// ## 字阶
///
/// 规范说这里是「全 app 唯一允许突破常规字阶的地方 —— **只能更大**」。实际做下来
/// **一个新字号都不需要发明**:规则是「每一档沿现有字阶上移一级」——
/// 正文 15 → 副标题 17,项目名 17 → 标题 20,姓名血型 → display 28。字阶顶已经是
/// 28,够用。发明第五个字号只会让别的屏将来有借口跟着发明。
///
/// `MediaQuery.textScaler` 在这里照常生效(全部走 `MedType` 常量),用户把系统
/// 字号调大,这一屏跟着更大 —— 那正是它该有的方向。
///
/// ## 配色
///
/// 底色是**纯黑**(规范原话),不是令牌里的 `paper`。前景直接复用 `MedColors.dark`
/// 那一套 —— 它本来就是为深底设计的,在纯黑上对比度只会更高。**不新造色值**:
/// 急救屏更没有资格成为色板的例外。整棵子树用 `Theme` 换掉扩展,`MedPill`
/// 这类共用件不改一行就跟着变深色。
class EmergencyBigCardScreen extends StatelessWidget {
  const EmergencyBigCardScreen({
    super.key,
    required this.card,
    required this.profile,
  });

  final EmergencyCardDto card;
  final PatientProfileDto profile;

  @override
  Widget build(BuildContext context) {
    const c = MedColors.dark;
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: const <ThemeExtension<dynamic>>[c],
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: ValueListenableBuilder<EmergencyExtras>(
            valueListenable: EmergencyExtrasStore.instance.value,
            builder: (context, extras, _) => Column(
              children: [
                _bigHeader(context),
                Expanded(child: _bigBody(context, extras)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bigHeader(BuildContext context) {
    const c = MedColors.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        MedShape.s1,
        MedShape.s3,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '医疗应急信息',
              style: MedType.caption.copyWith(color: c.ink3),
            ),
          ),
          // 退出按钮刻意小而靠边:这一屏可能被陌生人拿着,最不该发生的是他为了
          // 找信息误触退出。
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            color: c.ink3,
            tooltip: '退出大字模式',
          ),
        ],
      ),
    );
  }

  Widget _bigBody(BuildContext context, EmergencyExtras extras) {
    const c = MedColors.dark;
    final who = ProfileManager.instance.displayName;
    final sub = [
      profile.gender,
      profile.age,
    ].whereType<String>().where((x) => x.isNotEmpty).join(' · ');

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s4,
        0,
        MedShape.s4,
        MedShape.s6,
      ),
      children: [
        Text(who, style: MedType.display.copyWith(color: c.ink)),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub, style: MedType.subtitle.copyWith(color: c.ink2)),
        ],
        const SizedBox(height: MedShape.s4),

        // 血型 —— 28px,和姓名同级。显示的是「未登记」,而这正是要大声说的事:
        // 急救人员一眼看到「未登记」就知道要去配血,而不是在小字里翻找。
        Text('血型', style: MedType.caption.copyWith(color: c.ink3)),
        Text(
          card.bloodType ?? '未登记',
          style: MedType.display.copyWith(color: c.ink3),
        ),
        Text(
          'MedMe 不记录血型,请现场配血',
          style: MedType.body.copyWith(color: c.ink2),
        ),
        const SizedBox(height: MedShape.s5),

        _bigAllergyBox(context),
        const SizedBox(height: MedShape.s5),

        _bigList(
          context,
          title: kRecordedMedsTitle,
          // 急诊医生没有时间读三行 —— 短、硬、就在标题下面。
          note: kRecordedMedsCaveatUrgent,
          empty: '病历里没有读到药名',
          items: [
            for (final m in card.activeMeds) (m.name, recordedMedTiming(m)),
          ],
        ),
        const SizedBox(height: MedShape.s5),

        _bigList(
          context,
          title: '病历里的诊断',
          empty: '病历里没有读到诊断名',
          items: [
            for (final x in card.conditions)
              (x.term, x.onset == null ? '' : '最早出现 ${x.onset}'),
          ],
        ),
        const SizedBox(height: MedShape.s5),

        _bigContact(context, extras),
      ],
    );
  }

  /// 过敏史:框起来(规范 §九)。用 `critical` 描边 + 极浅底,是这一屏唯一上色的块。
  Widget _bigAllergyBox(BuildContext context) {
    const c = MedColors.dark;
    final has = card.allergies.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MedShape.s3),
      decoration: BoxDecoration(
        color: has ? c.criticalWash : null,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        border: Border.all(color: has ? c.critical : c.line, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '过敏史',
            style: MedType.subtitle.copyWith(color: has ? c.critical : c.ink3),
          ),
          const SizedBox(height: MedShape.s1),
          if (!has)
            // 空过敏史在急救屏上尤其危险:留白会被读成「无过敏史」。
            Text(
              '病历里没有找到过敏记录。\n这不等于没有过敏 —— 请向本人或家属确认。',
              style: MedType.subtitle.copyWith(color: c.ink2, height: 1.4),
            )
          else
            for (final a in card.allergies)
              Padding(
                padding: const EdgeInsets.only(bottom: MedShape.s1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 常规字阶里项目名是 17;这里上移一级到 20。
                    Text(
                      a.substance,
                      style: MedType.title.copyWith(color: c.critical),
                    ),
                    if (a.reaction.isNotEmpty)
                      Text(
                        a.reaction,
                        style: MedType.subtitle.copyWith(color: c.ink),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _bigList(
    BuildContext context, {
    required String title,
    required String empty,
    required List<(String, String)> items,
    String? note,
  }) {
    const c = MedColors.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: MedType.subtitle.copyWith(color: c.ink3)),
        if (note != null)
          Text(
            note,
            style: MedType.body.copyWith(color: c.high, height: 1.4),
          ),
        const SizedBox(height: MedShape.s1),
        if (items.isEmpty)
          Text(empty, style: MedType.subtitle.copyWith(color: c.ink2))
        else
          for (final (name, meta) in items)
            Padding(
              padding: const EdgeInsets.only(bottom: MedShape.s1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: MedType.title.copyWith(color: c.ink)),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: MedType.body.copyWith(
                        color: c.ink2,
                        fontFeatures: MedType.tabular,
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  /// 紧急联系人 + 一键拨号。
  Widget _bigContact(BuildContext context, EmergencyExtras extras) {
    const c = MedColors.dark;
    final who = [
      extras.contactName,
      extras.contactRelation,
    ].where((x) => x.trim().isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('紧急联系人', style: MedType.subtitle.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        if (!extras.hasPhone)
          Text(
            '机主没有填写紧急联系人',
            style: MedType.subtitle.copyWith(color: c.ink2),
          )
        else ...[
          if (who.isNotEmpty)
            Text(who, style: MedType.title.copyWith(color: c.ink)),
          Text(
            extras.contactPhone,
            style: MedType.display.copyWith(
              color: c.ink,
              fontFeatures: MedType.tabular,
            ),
          ),
          const SizedBox(height: MedShape.s2),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              // 按钮底色用深色一套的 `sealInk`(#8FD3F0)配黑字 —— 浅色一套的
              // sealInk 是深蓝,压在纯黑上根本读不出来。
              style: FilledButton.styleFrom(
                backgroundColor: c.sealInk,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: MedShape.s3),
              ),
              onPressed: () => _dial(context, extras.contactPhone),
              icon: const Icon(Icons.call, size: 24),
              label: Text('拨打', style: MedType.subtitle),
            ),
          ),
        ],
      ],
    );
  }

  /// 拨号。**只拉起拨号盘,不直接呼出** —— `tel:` 在 iOS 上会先弹系统确认,安卓上
  /// 走 `ACTION_DIAL` 把号码填进拨号盘等人按。急救时误触直接呼出不是帮忙。
  Future<void> _dial(BuildContext context, String phone) async {
    final messenger = ScaffoldMessenger.of(context);
    // 号码里常带空格、连字符或全角字符(用户手打的),`tel:` 只认数字与 +*#。
    final digits = phone.replaceAll(RegExp(r'[^0-9+*#]'), '');
    if (digits.isEmpty) {
      messenger.showSnackBar(appSnackBar(content: Text('这个号码拨不出去')));
      return;
    }
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: digits));
      if (!ok && messenger.mounted) {
        messenger.showSnackBar(appSnackBar(content: Text('无法拨号,请手动拨 $digits')));
      }
    } catch (e) {
      if (messenger.mounted) {
        messenger.showSnackBar(appSnackBar(content: Text('无法拨号,请手动拨 $digits')));
      }
    }
  }
}
