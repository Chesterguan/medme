import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/widgets/import_queue_card.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/for_doctor_screen.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/import_flow.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';
import 'package:mobile_flutter/widgets/member_switcher.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 底部导航一级 tab「病历」(`s1`)—— 生命时间线:就诊组 + 独立文档,按月分组、
/// 日期倒序,点开看详情。数据来自 FFI `loadArchive` / `patientProfile`
/// (见 lib/src/rust/api/vault.dart)。
///
/// 三 tab 信息架构里这一屏**同时是首页**:概览整屏解散之后,「你是谁、现在看的是谁」
/// 那张 [IdentityHeroCard] 搬到了这里的最上面,底下是两颗等宽方块
/// ([HomeTiles]:`添加` / `给医生看`)。「给医生看」没有底栏席位 —— 那颗方块是它
/// **全 App 唯一的入口**。
///
/// 文档类型标签与图标已挪到 `lib/doc_labels.dart`(四个屏共用,免得同一份病历在
/// 两个 tab 上叫两个名字)。

String _groupTitle(TimelineGroupDto g) {
  return switch (g) {
    TimelineGroupDto_Encounter(:final encounter) =>
      encounter.provider != null
          ? '${kindLabel[encounter.kind] ?? encounter.kind} · ${encounter.provider}'
          : (kindLabel[encounter.kind] ?? encounter.kind),
    TimelineGroupDto_Document(:final doc) => docDisplayTitle(doc),
  };
}

String _groupDate(TimelineGroupDto g) {
  return switch (g) {
    TimelineGroupDto_Encounter(:final encounter) => fmtDate(
      encounter.startDate,
    ),
    TimelineGroupDto_Document(:final doc) => fmtDate(doc.docDate),
  };
}

/// 时间线按月分组用的那一行字(`s1`:`2026 年 8 月`)。**月份不补零。**
///
/// 没识别到日期的那几份自成一段「没有日期」,**不许并进上一个月** —— 那等于拿一个
/// 我们并不知道的日期说话(与 `fmtDate` 对空/坏日期返回空串是同一条约定)。
String monthLabel(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  return d == null ? '没有日期' : '${d.year} 年 ${d.month} 月';
}

String _groupDesc(TimelineGroupDto g) {
  return switch (g) {
    TimelineGroupDto_Encounter(:final encounter, :final docs) => () {
      final kinds = <String>{};
      for (final d in docs) {
        kinds.add(docLabel[d.docType] ?? d.docType);
      }
      // 用实际 docs.length —— 待确认剔除后 `_confirmedOnly` 会重建只含已确认文档的组,
      // 此时 encounter.docCount(FFI 按全量算)会 stale,显示条数与展开数量对不上。
      final parts = ['${docs.length} 份记录', ...kinds.take(3)];
      if (encounter.transferred) parts.add('转院');
      return parts.join(' · ');
    }(),
    TimelineGroupDto_Document(:final doc) => [
      docRowLabel(doc),
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
        ).showSnackBar(appSnackBar(content: Text('删除失败:$e')));
      }
    }
  }

  /// 确认后删除(供 review 卡按钮 / 时间线左滑复用)。
  Future<void> _confirmAndDelete(int docId, String label) async {
    if (await _confirmDelete(label)) await _delete(docId);
  }

  /// hero 卡上那对 `⌃⌄`:弹出成员切换器。**换成员只有这一条路**(`s1` 不在顶栏
  /// 再放成员 chip)。UI 与状态更新路径都在 `widgets/member_switcher.dart` 里 ——
  /// 真相只有 `ProfileManager.instance.currentId` 一处。
  Future<void> _showProfileSwitcher() => showMemberSwitcherSheet(
    context,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  /// 「添加」:弹三选一(拍照 / 相册 / 选文件),排进后台队列后本屏经
  /// `vaultRevision` 自动刷新。顶栏那颗和 [HomeTiles] 那颗走的是**同一条**。
  ///
  /// ⚠️ 这里曾是 `() => showImportSheet(context)` —— 一个**没人 await、没有
  /// catchError 的 Future**。里面抛出的任何异常都只会掉进 zone,屏上一片安静,
  /// 这就是「点了没反应」的最后一段。现在 await 起来,兜底 catch 至少把话说出来。
  Future<void> _startAdd() async {
    // messenger 在 await 之前同步取好,免得跨 async gap 用 context。
    final messenger = ScaffoldMessenger.of(context);
    try {
      await showImportSheet(context);
    } catch (e) {
      debugPrint('[archive] 添加流程未捕获异常: $e');
      if (!messenger.mounted) return;
      messenger.showSnackBar(
        appSnackBar(
          content: Text('没能开始添加:$e'),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  /// 「找一找」:Stage 1 只摆入口位,搜索本身(医院 / 日期 / 类型 / 指标 / 药名)
  /// 是 Stage 2(ia-proposal §6)。点了**明说还在做**,不装作能用。
  void _search() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(appSnackBar(content: const Text('找一找还在做')));
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
        title: const Text('病历'),
        // 顶栏与内容之间一道 `line` —— 层次靠边框不靠阴影(规范 §四)。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
        actions: [
          // 那个剪贴板图标(「给医生看」的第二入口)已删 —— 它现在是 hero 卡下面
          // 那颗「给医生看」方块推进去的一整页,有固定位置,不需要在这里再开一个
          // 口子(ia-proposal §2:每个功能只有一条路到达)。
          Padding(
            padding: const EdgeInsets.only(right: MedShape.s1),
            child: TextButton.icon(
              onPressed: _startAdd,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('添加'),
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
                // 「你是谁、现在看的是谁」(`s1`)。换成员点卡上那对 `⌃⌄` ——
                // 顶栏**不再**放成员 tab 条/chip:同一件事两个入口,人下次
                // 找不到自己上回是从哪儿进的。
                IdentityHeroCard(
                  // 显示名取当前成员(用户自己给档案起的名),不取报告里抽出来的
                  // `profile.name` —— 后者可能因为某一张单子上印着别人而漂。
                  name: ProfileManager.instance.displayName,
                  gender: profile.gender,
                  age: profile.age,
                  recordCount: profile.recordCount.toInt(),
                  // 「最近就诊」取时间线最新一条的日期(`s1` 那一行),不是本卡
                  // 单独算的数:没有记录、或那条没识别到日期,卡片自己显示「暂无」。
                  recentVisitDate: groups.isNotEmpty
                      ? _groupDate(groups.first)
                      : null,
                  onSwitchMember: _showProfileSwitcher,
                ),
                const SizedBox(height: MedShape.s3),
                HomeTiles(
                  onAdd: _startAdd,
                  onForDoctor: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ForDoctorScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: MedShape.s3),
                // 后台识别队列:添加点完就回到这一屏,这几行是「东西确实在处理」
                // 的唯一去处(见 `import_queue.dart`)。它自己监听模块级的
                // `importJobs`,不进本屏的 FutureBuilder —— 切走再切回来还在。
                const ImportQueueCard(),
                // s1:一条横幅说一次,不是每行一个橙框(ux-audit P6)。
                // 「N 份」的 N 是还没核对的份数。
                PendingReviewBanner(count: pending.length),
                if (pending.isNotEmpty) const SizedBox(height: MedShape.s2),
                // 还没核对的:琥珀框卡片,点开进详情核对;左滑删除。
                for (final d in pending) ...[
                  _PendingCard(
                    doc: d,
                    mismatchName: ReviewState.instance.mismatchName(d.id),
                    onOpen: _openDoc,
                    onDelete: _confirmAndDelete,
                  ),
                  const SizedBox(height: MedShape.s2),
                ],
                if (pending.isEmpty && confirmed.isEmpty)
                  const _EmptyState()
                else
                  for (var i = 0; i < confirmed.length; i++) ...[
                    // 时间线按**月份**分组(`s1`)。列表本来就按日期倒序,所以
                    // 「这一条和上一条不同月」就是一段的开头,不必先建一张分组表。
                    if (i == 0 ||
                        monthLabel(_groupDate(confirmed[i])) !=
                            monthLabel(_groupDate(confirmed[i - 1])))
                      MonthHeader(
                        label: monthLabel(_groupDate(confirmed[i])),
                        // 「找一找」只在**最上面那条**月份标题右边(`s1`):它是
                        // 搜索的入口位,每个月都挂一条就成了噪音。
                        onSearch: i == 0 ? _search : null,
                      )
                    else
                      const SizedBox(height: MedShape.s2),
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

/// 空态引导:没有记录时提示点上面那颗「添加」,或去「设置」载入示例数据。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 空态用虚线框(规范 §六):留白等于说「你没有相关检查」,那是临床上的假话;
    // 框起来 + 明说下一步该点哪,才是「给出路」。
    //
    // 规范的空态样例里还有一颗按钮。这里**刻意没加** —— 加一颗按钮就是新增一个
    // 交互入口。出路由文案给:上面那颗「添加」方块一直在。
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
              '点上面那颗「添加」拍照或选择文件,\n或在「设置」里载入示例数据试试看',
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
      TimelineGroupDto_Encounter(:final encounter) => iconForKind(
        encounter.kind,
      ),
      TimelineGroupDto_Document(:final doc) => iconForDoc(doc.docType),
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
              await onDelete(d.id, docRowLabel(d));
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
                          iconForDoc(d.docType),
                          size: 15,
                          color: c.seal,
                        ),
                      ),
                      const SizedBox(width: MedShape.s2),
                      Expanded(
                        child: Text(
                          docRowLabel(d),
                          style: MedType.body.copyWith(color: c.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: MedShape.s1),
                      Text(
                        fmtDate(d.docDate),
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
    final label = docDisplayTitle(doc);
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
                        iconForDoc(doc.docType),
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
                                fmtDate(doc.docDate),
                                style: MedType.secondary.copyWith(
                                  color: c.ink3,
                                  fontFeatures: MedType.tabular,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              docRowLabel(doc),
                              '点开核对并确认',
                            ].join(' · '),
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
              '报告上的姓名是「$who」,与当前档案「${ProfileManager.instance.current.name}」不一致,'
              '请核对是否导错了人。',
              style: MedType.secondary.copyWith(color: c.ink, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「病历」首页 hero 下面那两颗方块(`s1`)。
///
/// **两颗等宽同高**,区别只在底色:`添加` 填主色(最高频的动作),`给医生看` 白底
/// 带描边。**不做成一条通栏大按钮** —— 它们是一对并列的动作,不是一主一次。
///
/// 「给医生看」没有底栏席位,这颗方块是它**全 App 唯一的入口**;ia-proposal §2
/// 拒绝候选 B 的理由正是「老人在底栏找不到它」,那条风险现在压在这颗方块上。
/// 谁把它改小、改成纯图标、或者塞进某个菜单里,就是在把那条风险放大 ——
/// 它在 iPhone SE + 2× 字号下必须仍然写得全那四个字(见 `test/archive_header_test.dart`)。
class HomeTiles extends StatelessWidget {
  const HomeTiles({super.key, this.onAdd, this.onForDoctor});

  final VoidCallback? onAdd;
  final VoidCallback? onForDoctor;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      children: [
        Expanded(
          child: _Tile(
            icon: Icons.add_a_photo_outlined,
            label: '添加',
            background: c.seal,
            foreground: Colors.white,
            onTap: onAdd,
          ),
        ),
        const SizedBox(width: MedShape.s2),
        Expanded(
          child: _Tile(
            icon: Icons.assignment_outlined,
            label: '给医生看',
            background: c.surface,
            foreground: c.sealInk,
            border: c.line,
            onTap: onForDoctor,
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    this.border,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final Color? border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(MedShape.radiusBlock),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: MedShape.s3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MedShape.radiusBlock),
            border: border == null ? null : Border.all(color: border!),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: foreground),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: MedType.body.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「还没核对」横幅(`s1`)。逐字:`N 份还没核对` + `扫描件,识别出的字有几处不确定`。
///
/// **一条横幅说一次**,不是每行一个橙框(ux-audit P6:7 份就是 7 条错误提示)。
/// 0 份时整条不画 —— 没有要核对的东西还留一条横幅,就是在制造一件不存在的待办。
class PendingReviewBanner extends StatelessWidget {
  const PendingReviewBanner({super.key, required this.count, this.onTap});

  final int count;

  /// 点整条的去处。**没有去处就别给** —— 那枚 `›` 跟着它一起出现/消失,
  /// 不画一个点不动的箭头。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final c = MedColors.of(context);
    return Material(
      color: c.sealWash,
      borderRadius: BorderRadius.circular(MedShape.radiusBlock),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        child: Padding(
          padding: const EdgeInsets.all(MedShape.s3),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count 份还没核对',
                      style: MedType.body.copyWith(
                        color: c.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '扫描件,识别出的字有几处不确定',
                      style: MedType.secondary.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// 月份分组标题(`s1`)。右边那条「找一找」是**搜索的入口位**:Stage 1 点了只说
/// 一句「还在做」,搜索本身(医院 / 日期 / 类型 / 指标 / 药名)是 Stage 2。
///
/// 为什么现在就摆出来:ux-audit P10「找不回东西」是这个定位的核心动作,而一个
/// 空白的月份标题不会让任何人想起「原来可以搜」。占位不等于假装能用 —— 点了
/// 明说还在做。
class MonthHeader extends StatelessWidget {
  const MonthHeader({super.key, required this.label, this.onSearch});

  final String label;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, MedShape.s4, 0, MedShape.s1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: MedType.caption.copyWith(color: c.ink3)),
          if (onSearch != null)
            GestureDetector(
              onTap: onSearch,
              child: Text('找一找', style: MedType.caption.copyWith(color: c.sealInk)),
            ),
        ],
      ),
    );
  }
}
