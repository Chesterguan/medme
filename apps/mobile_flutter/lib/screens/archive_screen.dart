import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/import_flow.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

/// 底部导航一级 tab「健康档案」—— 生命时间线:就诊组 + 独立文档,按日期倒序,
/// 点开看详情。与旧 Tauri 移动端 App.tsx 的 archive tab(phead + tl)同一观感,
/// 数据来自 FFI `loadArchive` / `patientProfile`(见 lib/src/rust/api/vault.dart)。

// doc_type / encounter kind → 中文标签(与 core-model types.rs、旧 App.tsx 一致)。
const Map<String, String> _docLabel = {
  'lab_report': '化验',
  'imaging_report': '影像',
  'discharge_summary': '出院小结',
  'prescription': '处方',
  'clinical_note': '病历',
  'pathology': '病理',
  'surgery': '手术',
  'other': '其他',
  'unknown': '待归类',
};
const Map<String, String> _kindLabel = {
  'inpatient': '住院',
  'outpatient': '门诊',
  'emergency': '急诊',
  'exam': '检查',
};

// 文档类型/就诊类型 → 图标。
//
// **配色表整张删掉了。** 原先每种文档类型一个颜色(化验蓝 #1D4ED8、影像橙
// #B45309、病理红 #BE123C、处方绿、出院靛、手术紫……九色),问题不是花,是
// **撞语义**:那三个色值正是设计系统里「偏低 / 偏高 / 危急值」的化验状态色。
// 一枚 #1D4ED8 的「化验」徽标和一行 #1D4ED8 的「偏低」在同一屏上,颜色在讲
// 两件毫不相干的事 —— 而这一屏的用户正在学「蓝=偏低」。
//
// 现在类型只靠**图标形状**区分,底色统一用主色 `seal` 的极浅底。三个状态色
// 从此在个人模式里只有一个含义:化验值不正常。
const Map<String, IconData> _docIcon = {
  'lab_report': Icons.science_outlined,
  'imaging_report': Icons.document_scanner_outlined,
  'prescription': Icons.medication_outlined,
  'discharge_summary': Icons.bed_outlined,
  'clinical_note': Icons.medical_services_outlined,
  'pathology': Icons.biotech_outlined,
  'surgery': Icons.content_cut,
  'other': Icons.description_outlined,
  'unknown': Icons.help_outline,
};
const Map<String, IconData> _kindIcon = {
  'outpatient': Icons.medical_services_outlined,
  'inpatient': Icons.bed_outlined,
};
IconData _iconForDoc(String docType) =>
    _docIcon[docType] ?? Icons.description_outlined;

IconData _iconForKind(String kind) =>
    _kindIcon[kind] ?? Icons.local_hospital_outlined;

String _fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String _groupTitle(TimelineGroupDto g) {
  return switch (g) {
    TimelineGroupDto_Encounter(:final encounter) =>
      encounter.provider != null
          ? '${_kindLabel[encounter.kind] ?? encounter.kind} · ${encounter.provider}'
          : (_kindLabel[encounter.kind] ?? encounter.kind),
    TimelineGroupDto_Document(:final doc) =>
      doc.title ?? _docLabel[doc.docType] ?? '记录',
  };
}

String _groupDate(TimelineGroupDto g) {
  return switch (g) {
    TimelineGroupDto_Encounter(:final encounter) => _fmtDate(
      encounter.startDate,
    ),
    TimelineGroupDto_Document(:final doc) => _fmtDate(doc.docDate),
  };
}

String _groupDesc(TimelineGroupDto g) {
  return switch (g) {
    TimelineGroupDto_Encounter(:final encounter, :final docs) => () {
      final kinds = <String>{};
      for (final d in docs) {
        kinds.add(_docLabel[d.docType] ?? d.docType);
      }
      // 用实际 docs.length —— 待确认剔除后 `_confirmedOnly` 会重建只含已确认文档的组,
      // 此时 encounter.docCount(FFI 按全量算)会 stale,显示条数与展开数量对不上。
      final parts = ['${docs.length} 份记录', ...kinds.take(3)];
      if (encounter.transferred) parts.add('转院');
      return parts.join(' · ');
    }(),
    TimelineGroupDto_Document(:final doc) => [
      _docLabel[doc.docType] ?? doc.docType,
      if (doc.sliceCount != null) '影像 ${doc.sliceCount} 张',
    ].join(' · '),
  };
}

/// 把时间线分组拍平成文档列表(就诊组内文档 + 独立文档),用于「待确认」筛选。
List<DocumentSummaryDto> _allDocs(List<TimelineGroupDto> groups) {
  final out = <DocumentSummaryDto>[];
  for (final g in groups) {
    switch (g) {
      case TimelineGroupDto_Encounter(:final docs):
        out.addAll(docs);
      case TimelineGroupDto_Document(:final doc):
        out.add(doc);
    }
  }
  return out;
}

/// 「已确认」时间线:把待确认文档从分组里剔除(它们单独在顶部红框区展示,避免重复)。
/// 就诊组里若有部分文档待确认,重建一个只含已确认文档的组;整组都待确认则整组略去。
List<TimelineGroupDto> _confirmedOnly(List<TimelineGroupDto> groups) {
  final out = <TimelineGroupDto>[];
  for (final g in groups) {
    switch (g) {
      case TimelineGroupDto_Document(:final doc):
        if (!ReviewState.instance.isPending(doc.id)) out.add(g);
      case TimelineGroupDto_Encounter(:final encounter, :final docs):
        final kept = docs
            .where((d) => !ReviewState.instance.isPending(d.id))
            .toList();
        if (kept.isEmpty) continue;
        out.add(
          kept.length == docs.length
              ? g
              : TimelineGroupDto.encounter(encounter: encounter, docs: kept),
        );
    }
  }
  return out;
}

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  late Future<(PatientProfileDto, List<TimelineGroupDto>)> _future = _load();
  // 已展开的就诊组(按 **encounter.id** 记,不用列表下标——删除/导入后下标会错位)。
  final Set<int> _expanded = {};

  @override
  void initState() {
    super.initState();
    // 导入/清空/载入示例后自动重载(本屏在 IndexedStack 里保活,initState 不会重跑)。
    vaultRevision.addListener(_onVaultChanged);
  }

  @override
  void dispose() {
    vaultRevision.removeListener(_onVaultChanged);
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) _refresh();
  }

  Future<(PatientProfileDto, List<TimelineGroupDto>)> _load() async {
    final results = await Future.wait([patientProfile(), loadArchive()]);
    final profile = results[0] as PatientProfileDto;
    final groups = results[1] as List<TimelineGroupDto>;
    // 载入「待确认」集(build 里同步判断 isPending 前要先加载好)。
    await ReviewState.instance.ensureLoaded();
    // 兜底自动命名:示例数据等不走导入流程的路径,也能把默认档案改成识别到的姓名。
    await autoNameCurrentProfileFrom(profile.name);
    // 埋点的库存来源就是这里 —— **不为埋点额外读一次库**,用本来就要读的这次。
    // 上传的只有分桶(0 / 1 / 2-5 / …),精确份数不出设备。
    Analytics.setLibrarySize(profile.recordCount);
    // 回填当前成员记录数,设置页据此展示每人多少份(不必逐个开库去数)。
    await ProfileManager.instance.setCount(
      ProfileManager.instance.currentId.value,
      profile.recordCount,
    );
    return (profile, groups);
  }

  /// 删除前确认(销毁性操作)。返回用户是否确认。
  Future<bool> _confirmDelete(String what) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份记录?'),
        content: Text('「$what」将从健康档案移除,此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MedColors.of(context).critical,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 删除一份文档:调 FFI(追加删除事件 + 重放),清掉可能的「待确认」标记,刷新档案。
  Future<void> _delete(int docId) async {
    try {
      await deleteDocument(documentId: docId);
      await ReviewState.instance.markReviewed(docId);
      bumpVaultRevision();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败:$e')));
      }
    }
  }

  /// 确认后删除(供 review 卡按钮 / 时间线左滑复用)。
  Future<void> _confirmAndDelete(int docId, String label) async {
    if (await _confirmDelete(label)) await _delete(docId);
  }

  /// 切到某成员(tab 条与弹出式共用)。已经是当前成员则不做事,避免白重开保险箱。
  Future<void> _switchTo(String id) async {
    if (id == ProfileManager.instance.currentId.value) return;
    await switchProfileAndReopen(id);
    if (mounted) setState(() {});
  }

  /// 顶部 banner 点击:弹出成员切换器(成员多于 kMemberTabsMax 时用)。
  Future<void> _showProfileSwitcher() async {
    await ProfileManager.instance.ensureLoaded();
    final members = ProfileManager.instance.profiles;
    final currentId = ProfileManager.instance.currentId.value;
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final c = MedColors.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  MedShape.s4,
                  4,
                  MedShape.s4,
                  MedShape.s1,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '切换成员',
                    style: MedType.title.copyWith(color: c.ink),
                  ),
                ),
              ),
              for (final m in members)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: c.sealWash,
                    child: Text(
                      m.name.isNotEmpty ? m.name[0] : '?',
                      style: MedType.subtitle.copyWith(color: c.sealInk),
                    ),
                  ),
                  title: Text(
                    m.name,
                    style: MedType.subtitle.copyWith(color: c.ink),
                  ),
                  trailing: m.id == currentId
                      ? Icon(Icons.check, color: c.seal)
                      : null,
                  onTap: () => Navigator.of(context).pop('member:${m.id}'),
                ),
              const Divider(),
              ListTile(
                leading: Icon(Icons.person_add_alt, color: c.seal),
                title: Text(
                  '添加成员',
                  style: MedType.subtitle.copyWith(color: c.ink),
                ),
                onTap: () => Navigator.of(context).pop('add'),
              ),
              const SizedBox(height: MedShape.s1),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    if (action == 'add') {
      await _addMember();
    } else if (action.startsWith('member:')) {
      // action 里带的是**成员 id**,不是名字 —— 名字可改、可重复,不能拿来寻址。
      final id = action.substring('member:'.length);
      if (id != currentId) {
        await switchProfileAndReopen(id);
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _addMember() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加成员'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入姓名'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await createProfileAndReopen(name.trim());
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final next = _load();
    // 必须用**语句块**而不是箭头:`() => _future = next` 会把赋值结果(一个 Future)
    // 当返回值交给 setState,Flutter 判定「在 setState 里做异步」直接抛。这个异常会
    // 从 `bumpVaultRevision()` 的调用点冒出去,把调用方的后续步骤一起中断掉 ——
    // 「载入示例数据」就是这么坏的:建完成员触发刷新、异常打断,真正的载入没跑到。
    setState(() {
      _future = next;
    });
    await next;
  }

  void _openDoc(int id) {
    // 埋点:**只报「打开了一份」,不带 id、不带任何内容**。回答的是「档案是被看的
    // 还是被堆的」——导入了从不打开,说明这是个垃圾桶而不是助手。
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
        title: const Text('健康档案'),
        // 顶栏与内容之间一道 `line` —— 层次靠边框不靠阴影(规范 §四)。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
        actions: [
          // 右上角「导入」:弹三选一(拍照/相册/选文件),导入后本屏经 vaultRevision 自动刷新。
          Padding(
            padding: const EdgeInsets.only(right: MedShape.s1),
            child: TextButton.icon(
              onPressed: () => showImportSheet(context),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('导入'),
            ),
          ),
        ],
      ),
      body: FutureBuilder<(PatientProfileDto, List<TimelineGroupDto>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(MedShape.s6),
                    child: Text(
                      '加载健康档案失败:\n${snap.error}\n\n下拉可重试。',
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                    ),
                  ),
                ],
              ),
            );
          }

          final (profile, groups) = snap.data!;
          // 待确认(新导入)文档:红框置顶,新的(id 大)在前;确认在详情页做。
          final pending =
              _allDocs(
                  groups,
                ).where((d) => ReviewState.instance.isPending(d.id)).toList()
                ..sort((a, b) => b.id.compareTo(a.id));
          // 已确认时间线:剔除待确认文档,避免和上面红框区重复。
          final confirmed = _confirmedOnly(groups);
          return RefreshIndicator(
            onRefresh: _refresh,
            color: c.seal,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                MedShape.s3,
                MedShape.s3,
                MedShape.s3,
                MedShape.s6,
              ),
              children: [
                // 成员不多时(≤ kMemberTabsMax)用常驻 tab 条:点谁是谁,一步到位。
                // 超过就退回弹出式列表——横滑的 tab 条会把当前选中的推到屏幕外,
                // 而且人一多,列表本来就比 tab 好扫。
                if (ProfileManager.instance.profiles.length <= kMemberTabsMax)
                  _MemberTabs(
                    profiles: ProfileManager.instance.profiles,
                    currentId: ProfileManager.instance.currentId.value,
                    onPick: _switchTo,
                    onAdd: _addMember,
                  ),
                if (ProfileManager.instance.profiles.length <= kMemberTabsMax)
                  const SizedBox(height: MedShape.s2),
                _PatientHeader(
                  profile: profile,
                  memberName: ProfileManager.instance.displayName,
                  // tab 条已经在管「选谁」,身份卡就不再兼职切换入口;
                  // 人多退回弹出式时,它仍是唯一的切换入口。
                  showName: ProfileManager.instance.profiles.length > kMemberTabsMax,
                  onTap: ProfileManager.instance.profiles.length > kMemberTabsMax
                      ? _showProfileSwitcher
                      : null,
                ),
                const SizedBox(height: MedShape.s4),
                // 待确认:琥珀框卡片,点开进详情核对 + 确认;左滑删除。
                for (final d in pending) ...[
                  _PendingCard(
                    doc: d,
                    mismatchName: ReviewState.instance.mismatchName(d.id),
                    onOpen: _openDoc,
                    onDelete: _confirmAndDelete,
                  ),
                  const SizedBox(height: MedShape.s2),
                ],
                if (pending.isNotEmpty && confirmed.isNotEmpty) ...[
                  const SizedBox(height: MedShape.s1),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: MedShape.s2,
                        ),
                        child: Text(
                          '以下为已确认',
                          style: MedType.caption.copyWith(color: c.ink3),
                        ),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: MedShape.s2),
                ],
                if (pending.isEmpty && confirmed.isEmpty)
                  const _EmptyState()
                else
                  for (var i = 0; i < confirmed.length; i++) ...[
                    if (i > 0) const SizedBox(height: MedShape.s2),
                    _TimelineItem(
                      group: confirmed[i],
                      // 按就诊组 id 记展开态(不用列表下标)——删除/导入后下标会错位到别的组。
                      expanded: switch (confirmed[i]) {
                        TimelineGroupDto_Encounter(:final encounter) =>
                          _expanded.contains(encounter.id),
                        _ => false,
                      },
                      onTap: () {
                        switch (confirmed[i]) {
                          case TimelineGroupDto_Document(:final doc):
                            _openDoc(doc.id);
                          case TimelineGroupDto_Encounter(:final encounter):
                            setState(() {
                              if (!_expanded.add(encounter.id)) {
                                _expanded.remove(encounter.id);
                              }
                            });
                        }
                      },
                      onOpenSubDoc: _openDoc,
                      onDelete: _confirmAndDelete,
                    ),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 患者头卡:姓名 / 性别·年龄 / 记录数,字段可空一律优雅缺省。
/// 常驻成员 tab 条的人数上限。超过就退回弹出式列表:横滑的 tab 会把当前选中的
/// 推到屏幕外(选中项看不见,是 tab 最糟的失败方式);而人一多,列表本来就更好扫。
/// 5 是按「一个家庭通常管几个人」定的——自己 + 父母 + 孩子,再多属于少数情况。
const int kMemberTabsMax = 5;

/// 成员选择器:点谁是谁,一步到位。
///
/// **只负责选人,不负责管人。** 改名与删除留在设置页的「保险箱」卡片里——它们低频、
/// 需要确认、误触代价高(一下就是几十份病历),不该和高频的切换动作挤在同一排。
/// tab 条上唯一的管理入口是末尾的「+」,因为「用着用着发现要再加一个人」是高频场景。
class _MemberTabs extends StatelessWidget {
  const _MemberTabs({
    required this.profiles,
    required this.currentId,
    required this.onPick,
    required this.onAdd,
  });

  final List<Profile> profiles;
  final String currentId;
  final ValueChanged<String> onPick;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 横滑列表必须有确定高度,但**不能写死** —— 写死的 38 在系统字号放大后会把
    // 名字裁掉一截(007 §2.5「字号可放大,不可砍」)。按当前 textScaler 下的
    // body 实际行高 + 上下各 12 内边距 + 边框算出来,放大到多少都装得下。
    final labelHeight = MediaQuery.textScalerOf(
      context,
    ).scale(MedType.body.fontSize!);
    final tabHeight = labelHeight + MedShape.s2 * 2 + 2;
    // pill:圆角 999(规范 §四)。用 StadiumBorder 语义的半高圆角即可。
    final radius = BorderRadius.circular(MedShape.radiusPill);
    return SizedBox(
      height: tabHeight,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: profiles.length,
              separatorBuilder: (_, _) => const SizedBox(width: MedShape.s1),
              itemBuilder: (context, i) {
                final p = profiles[i];
                final on = p.id == currentId;
                return Material(
                  color: on ? c.seal : c.surface,
                  borderRadius: radius,
                  child: InkWell(
                    onTap: on ? null : () => onPick(p.id),
                    borderRadius: radius,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MedShape.s3,
                      ),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: on ? c.seal : c.line),
                      ),
                      child: Text(
                        p.name,
                        style: MedType.body.copyWith(
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                          color: on ? c.surface : c.ink,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: MedShape.s1),
          Material(
            color: c.surface,
            borderRadius: radius,
            child: InkWell(
              onTap: onAdd,
              borderRadius: radius,
              child: Container(
                width: tabHeight,
                height: tabHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: c.line),
                ),
                child: Icon(Icons.add, size: 20, color: c.seal),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PatientHeader extends StatelessWidget {
  final PatientProfileDto profile;
  final String memberName;
  /// 是否在卡片里显示姓名。有 tab 条时传 false —— 姓名由 tab 条负责,
  /// 卡片只讲这个人的档案信息,免得同一个名字在屏幕上出现两次。
  final bool showName;
  final VoidCallback? onTap;
  const _PatientHeader({
    required this.profile,
    required this.memberName,
    required this.showName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final initial = memberName.isNotEmpty ? memberName[0] : '我';
    final subParts = [
      profile.gender,
      profile.age,
    ].whereType<String>().where((s) => s.isNotEmpty).toList();
    subParts.add('${profile.recordCount} 份记录');

    // **不带骑缝线。** 这是一张派生卡:姓名/性别/年龄/份数都是从许多份原件里
    // 算出来的汇总,背后没有「某一张纸」可点进去。骑缝线只给点得进原件的卡
    // (规范 §五)—— 给它画一道,就是拿签名元素说了句假话。
    return MedCard(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap, // 点顶部切换成员(家庭多成员)
          child: Padding(
            padding: const EdgeInsets.all(MedShape.s4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: c.sealWash,
                  child: Text(
                    initial,
                    style: MedType.title.copyWith(color: c.sealInk),
                  ),
                ),
                const SizedBox(width: MedShape.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showName) ...[
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                memberName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: MedType.subtitle.copyWith(color: c.ink),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.unfold_more, size: 18, color: c.ink3),
                          ],
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        subParts.join(' · '),
                        // 份数是数字 —— 等宽表格数字,换个成员不会左右跳。
                        style:
                            (showName
                                    ? MedType.secondary.copyWith(color: c.ink2)
                                    : MedType.subtitle.copyWith(color: c.ink))
                                .copyWith(fontFeatures: MedType.tabular),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 空态引导:没有记录时提示点右上角「导入」,或去「设置」载入示例数据。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 空态用虚线框(规范 §六):留白等于说「你没有相关检查」,那是临床上的假话;
    // 框起来 + 明说下一步该点哪,才是「给出路」。
    //
    // 规范的空态样例里还有一颗按钮。这里**刻意没加** —— 加一颗按钮就是新增一个
    // 交互入口,本次是纯视觉改版。出路由文案给:右上角那颗「导入」一直在。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MedShape.s6),
      child: DottedBorderBox(
        child: Column(
          children: [
            Icon(Icons.folder_outlined, size: 48, color: c.ink3),
            const SizedBox(height: MedShape.s2),
            Text('还没有病历', style: MedType.subtitle.copyWith(color: c.ink)),
            const SizedBox(height: MedShape.s1),
            Text(
              '点右上角「导入」拍照或选择文件添加,\n或在「设置」里载入示例数据试试看',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时间线一项:就诊组(可展开子文档)或独立文档。
/// 时间线/待确认项左滑删除时的红底背景(靠右露出删除图标),Outlook 邮件式。
/// 圆角必须与卡片同档(20),否则滑动过程中会露出一圈错位的直角。
Widget swipeDeleteBackground(BuildContext context) => Container(
  alignment: Alignment.centerRight,
  padding: const EdgeInsets.symmetric(horizontal: MedShape.s4),
  decoration: BoxDecoration(
    // 删除是销毁性动作 —— `critical` 在个人模式里只用在这里和危急值上。
    color: MedColors.of(context).critical,
    borderRadius: BorderRadius.circular(MedShape.radiusCard),
  ),
  child: const Icon(Icons.delete_outline, color: Colors.white),
);

class _TimelineItem extends StatelessWidget {
  final TimelineGroupDto group;
  final bool expanded;
  final VoidCallback onTap;
  final void Function(int docId) onOpenSubDoc;
  final Future<void> Function(int docId, String label) onDelete;

  const _TimelineItem({
    required this.group,
    required this.expanded,
    required this.onTap,
    required this.onOpenSubDoc,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final isEncounter = group is TimelineGroupDto_Encounter;
    final icon = switch (group) {
      TimelineGroupDto_Encounter(:final encounter) => _iconForKind(
        encounter.kind,
      ),
      TimelineGroupDto_Document(:final doc) => _iconForDoc(doc.docType),
    };

    final Widget card = MedCard(
      // 骑缝线 = 「背后有一份原件、点得进去」(规范 §五)。
      //  · 独立文档卡 → 点了就是那一份原件的详情 → **画**。
      //  · 就诊组卡 → 点了是展开一个分组;这个组本身是按日期/机构算出来的,
      //    背后没有「一张纸」叫做「门诊·某某医院」→ **不画**。组里每一份文档
      //    展开后各自可点开,那是下一层的事。
      perforated: !isEncounter,
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(MedShape.s2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.sealWash,
                        borderRadius: BorderRadius.circular(
                          MedShape.radiusControl,
                        ),
                      ),
                      child: Icon(icon, size: 20, color: c.seal),
                    ),
                    const SizedBox(width: MedShape.s2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Expanded(
                                child: Text(
                                  _groupTitle(group),
                                  style: MedType.subtitle.copyWith(
                                    color: c.ink,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: MedShape.s1),
                              Text(
                                _groupDate(group),
                                // 日期是数字,等宽 —— 一列日期才对得齐。
                                style: MedType.secondary.copyWith(
                                  color: c.ink3,
                                  fontFeatures: MedType.tabular,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _groupDesc(group),
                            style: MedType.secondary.copyWith(color: c.ink2),
                          ),
                        ],
                      ),
                    ),
                    if (isEncounter)
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: c.ink3,
                      ),
                  ],
                ),
              ),
            ),
            if (expanded)
              switch (group) {
                TimelineGroupDto_Encounter(:final docs) => _SubDocList(
                  docs: docs,
                  onOpenSubDoc: onOpenSubDoc,
                  onDelete: onDelete,
                ),
                TimelineGroupDto_Document() => const SizedBox.shrink(),
              },
          ],
        ),
      ),
    );

    // 独立文档项:左滑删除(Outlook 式)。就诊组不整组删——展开后删组内单份。
    if (group case TimelineGroupDto_Document(:final doc)) {
      return Dismissible(
        key: ValueKey('tl-doc-${doc.id}'),
        direction: DismissDirection.endToStart,
        background: swipeDeleteBackground(context),
        confirmDismiss: (_) async {
          await onDelete(doc.id, _groupTitle(group));
          return false; // 由数据重载移除,避免与 Dismissible 自身移除冲突
        },
        child: card,
      );
    }
    return card;
  }
}

class _SubDocList extends StatelessWidget {
  final List<DocumentSummaryDto> docs;
  final void Function(int docId) onOpenSubDoc;
  final Future<void> Function(int docId, String label) onDelete;

  const _SubDocList({
    required this.docs,
    required this.onOpenSubDoc,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      children: [
        for (final d in docs)
          Dismissible(
            key: ValueKey('sub-doc-${d.id}'),
            direction: DismissDirection.endToStart,
            background: swipeDeleteBackground(context),
            confirmDismiss: (_) async {
              await onDelete(d.id, d.title ?? _docLabel[d.docType] ?? '记录');
              return false;
            },
            child: Container(
              // 卡内行间用二级分隔线 `line-2`,比卡片外框浅一档 —— 嵌套层次靠
              // 边框的深浅递减来分,不叠第二层阴影。
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line2)),
              ),
              child: InkWell(
                onTap: () => onOpenSubDoc(d.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MedShape.s2,
                    vertical: MedShape.s2,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.sealWash,
                          borderRadius: BorderRadius.circular(MedShape.s1),
                        ),
                        child: Icon(
                          _iconForDoc(d.docType),
                          size: 15,
                          color: c.seal,
                        ),
                      ),
                      const SizedBox(width: MedShape.s2),
                      Expanded(
                        child: Text(
                          d.title ?? _docLabel[d.docType] ?? '记录',
                          style: MedType.body.copyWith(color: c.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: MedShape.s1),
                      Text(
                        _fmtDate(d.docDate),
                        style: MedType.caption.copyWith(
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                          fontFeatures: MedType.tabular,
                          color: c.ink3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 待确认(新导入)卡片:琥珀框 + 「待确认」pill,点开进**详情页**核对并确认
/// (确认按钮在详情页,不在这里)。左滑删除。识别姓名与当前档案不符时下方警告。
/// 确认后本卡消失,该文档以标准样式进入下方时间线。
///
/// **框色从红(`critical`)降到琥珀(`high`),同时把姓名不符的警告从橙升到红。**
/// 原先每一份刚导入的文档都顶着一圈红框 —— 而「刚导入、还没核对」是导入成功后的
/// 常态,不是事故;红色天天出现就会被学会忽略。真正该报红的是它下面那条「这张单
/// 子上的名字不是你」——那才是可能把别人的病历归进你档案的一步。两级现在分开了:
/// 琥珀 = 请你看一眼,红 = 可能导错人。
class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.doc,
    required this.mismatchName,
    required this.onOpen,
    required this.onDelete,
  });

  final DocumentSummaryDto doc;
  final String? mismatchName;
  final void Function(int docId) onOpen;
  final Future<void> Function(int docId, String label) onDelete;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final label = doc.title ?? _docLabel[doc.docType] ?? '记录';
    final card = MedCard(
      // 这张卡背后就是刚导入的那份原件,点开即达 → 画骑缝线。
      perforated: true,
      borderColor: c.high,
      borderWidth: 1.5,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => onOpen(doc.id),
              child: Padding(
                padding: const EdgeInsets.all(MedShape.s2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.highWash,
                        borderRadius: BorderRadius.circular(
                          MedShape.radiusControl,
                        ),
                      ),
                      child: Icon(
                        _iconForDoc(doc.docType),
                        size: 20,
                        color: c.high,
                      ),
                    ),
                    const SizedBox(width: MedShape.s2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 标题行会挤:pill + 标题 + 日期。用 Wrap 让它在窄屏
                          // 或大字号下自然折行,而不是把标题省略成两个字。
                          Wrap(
                            spacing: MedShape.s1,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              MedPill(
                                text: '待确认',
                                foreground: c.high,
                                background: c.highWash,
                              ),
                              Text(
                                label,
                                style: MedType.subtitle.copyWith(color: c.ink),
                              ),
                              Text(
                                _fmtDate(doc.docDate),
                                style: MedType.secondary.copyWith(
                                  color: c.ink3,
                                  fontFeatures: MedType.tabular,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [_docLabel[doc.docType] ?? doc.docType, '点开核对并确认']
                                .join(' · '),
                            style: MedType.secondary.copyWith(color: c.ink2),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 20, color: c.ink3),
                  ],
                ),
              ),
            ),
            if (mismatchName case final who?) _MismatchBanner(who: who),
          ],
        ),
      ),
    );
    return Dismissible(
      key: ValueKey('pending-${doc.id}'),
      direction: DismissDirection.endToStart,
      background: swipeDeleteBackground(context),
      confirmDismiss: (_) async {
        await onDelete(doc.id, label);
        return false;
      },
      child: card,
    );
  }
}

/// 这份报告识别到的患者姓名和当前档案不一致 → 醒目提示,可能导错了人。
/// 只警告不自动搬(用户可自行处理);点开核对无误后「确认」即可归档。
///
/// 用 `critical` 红:这是本屏最高一级的提醒。原先是 Material 调色板里的
/// `Colors.orange` + 一个裸的 `#B25E00` 文字色 —— 两个都不在规范色板里,而且
/// 和外层「待确认」框同为橙,一眼分不出哪个更要紧。现在外框琥珀、这条红,
/// 层级立住了。左侧三像素竖条是规范 §warn 的样式。
class _MismatchBanner extends StatelessWidget {
  const _MismatchBanner({required this.who});

  final String who;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        MedShape.s2,
        0,
        MedShape.s2,
        MedShape.s2,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: MedShape.s2,
        vertical: MedShape.s1,
      ),
      decoration: BoxDecoration(
        color: c.criticalWash,
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(MedShape.radiusBlock),
        ),
        border: Border(left: BorderSide(color: c.critical, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: c.critical, size: 18),
          const SizedBox(width: MedShape.s1),
          Expanded(
            child: Text(
              '报告上的姓名是「$who」,与当前档案「${ProfileManager.instance.current}」不一致,'
              '请核对是否导错了人。',
              style: MedType.secondary.copyWith(color: c.ink, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
