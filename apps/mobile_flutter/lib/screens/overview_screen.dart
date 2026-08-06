import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/import_flow.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/manual_entry_sheet.dart';
import 'package:mobile_flutter/screens/visit_summary_sheet.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/member_switcher.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 底部导航一级 tab「概览」—— 使用时刻:**日常打开,看一眼「我现在怎么样」**
/// (设计系统 §八)。
///
/// 一屏讲完三件事,顺序就是这三句话:
///
/// 1. **你是谁** —— 顶部深色 hero 身份卡(姓名 / 性别年龄 / 多少份记录 /
///    最近一次就诊),整卡可点,弹出成员切换器——家庭多成员时,切完是谁一眼
///    可辨,不会把家人的病历当自己的给医生看;
/// 2. **你怎么样** —— 最近的关键化验,带状态色条与 pill;
/// 3. **东西在哪** —— 最近归档的几份,一点就进原件。
///
/// 中间横着一排快捷操作,因为「日常打开」这个时刻最常见的下一步不是读,是**拍**。
///
/// ## 这一屏不算任何东西
///
/// 数据全部来自 `viewVisitSummary()` 一次调用。那个投影只搬运原文逐字内容与抽出的
/// 数值/日期,**不生成解释性文字或结论**;这一屏也不加。没有「本月指标向好」,没有
/// 「建议复查」,没有健康分。异常与否一律读 Rust 给的 `flag`(见 `lab_status.dart`)。
///
/// 概览是这个 app 里最容易长出「智能健康助手」的地方,也是最不该长的地方 ——
/// 一句「你的血糖控制得不错」是我们既没有能力、也没有资格说的。
class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  late Future<VisitSummaryDto> _future = viewVisitSummary();

  @override
  void initState() {
    super.initState();
    // 本屏在 `IndexedStack` 里保活,`initState` 不会重跑 —— 别处导入/清空后
    // 要靠这个信号重载,否则切回来还是旧数据(与档案屏同一处理)。
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

  Future<void> _refresh() async {
    final next = viewVisitSummary();
    // 语句块而非箭头:`() => _future = next` 会把赋值结果(一个 Future)当返回值
    // 交给 setState,Flutter 判定「在 setState 里做异步」直接抛(见档案屏同一处注释)。
    setState(() {
      _future = next;
    });
    await next;
  }

  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
  }

  Future<void> _import(ImportChoice? choice) async {
    final messenger = ScaffoldMessenger.of(context);
    ImportRunResult? result;
    try {
      result = choice == null
          ? await showImportSheet(context)
          : await runImport(context, choice);
    } catch (e) {
      // 与档案屏同一条兜底:导入流程里漏网的异常若不接住,只会掉进 zone,
      // 屏上一片安静 —— 那就是「点了没反应」的最后一段。
      debugPrint('[overview] 导入流程未捕获异常: $e');
      if (!messenger.mounted) return;
      messenger.showSnackBar(
        appSnackBar(
          content: Text('导入没能开始:$e'),
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }
    _goReviewNewDocs(result);
  }

  /// 导入成功后带用户去核对新东西 —— 「待确认」是这个产品最重要的一道质量闸门
  /// (抽取质量是已知短板,见 `review_state.dart`),但它靠用户自己走到档案屏
  /// 才看得见。此前从概览发起的导入只是原地刷新,从没带用户过去 —— 这道闸门
  /// 对所有从首页导入的人完全不可见,不是跳转缺失,是一整套写好的机制在这条
  /// 路径上静默失效。档案屏自己触发导入时不需要这个 —— 人已经在那儿,置顶的
  /// 待确认节就在眼前。
  ///
  /// 只在真的有新文档落库时才跳([dispatchImportReview] / [reviewDestinationFor]
  /// 判断);取消、全部失败、全部重复都不跳 —— 跳到一个空的待确认列表比不跳更糟。
  ///
  /// 单份直接进那一份的详情,复核动作就在详情页里;多份进档案屏,置顶的
  /// 「待确认」节已经把它们聚好了,不用本屏自己再拼一份列表。两条路都是
  /// `Navigator.push`,不碰底部 tab 状态 —— 系统返回键原样弹回本屏,不会把人
  /// 困在别的 tab,也不会让 tab 高亮和实际内容对不上(与 `goToArchive()` 那种
  /// 切 tab 的跳转是两回事,那种不进返回栈)。
  void _goReviewNewDocs(ImportRunResult? result) {
    if (!mounted) return;
    dispatchImportReview(
      result,
      openSingleDocument: _openDoc,
      openArchive: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ArchiveScreen())),
    );
  }

  /// 「记录」快捷操作:打开手动录入弹层。
  ///
  /// 存完**不**走 [_goReviewNewDocs] 那条"待确认"复核路径 —— 那道闸门是为
  /// OCR 抽取质量不确定而设的(见 `_goReviewNewDocs` 的文档),手动录入没有
  /// OCR 这一步:用户填的数字就是存进去的数字,没有"识别错了"这回事需要核对。
  ///
  /// 但"导入要跳转"还有第二个理由——**让人看见结果**,这一条手动录入同样需要
  /// 兑现,不能因为不需要复核就顺带把它也省了。核对过下面这条链路,确认存完
  /// 就地关弹层**不会**是「点了没反应」:`showManualEntrySheet` 内部先
  /// `bumpVaultRevision`才 `pop`,本屏监听着这个信号 `_onVaultChanged` →
  /// `_refresh()` 会重新拉一次 `viewVisitSummary()`——
  ///   · 数值项(血压/心率/体重/体温/血糖)落在 `recentLabs` 里,新记录按测量
  ///     时间排序,默认就是"现在",会排到「最近的关键化验」最上面;
  ///   · 笔记落在 `recentVisits` 里(它就是一份普通文档,`load_archive()`
  ///     按日期倒序),同样会排到「最近归档」最上面。
  /// 弹层一关,底下这屏正好翻到新记录所在的那个区块,不需要另开一个页面
  /// 去"证明"存上了——再加一条 SnackBar 是双重确认,不是唯一的反馈渠道。
  Future<void> _openManualEntry() async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showManualEntrySheet(context);
    if (saved == true && messenger.mounted) {
      messenger.showSnackBar(appSnackBar(content: Text('已记录')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('概览'),
        // 顶栏与内容之间一道 `line` —— 层次靠边框不靠阴影(规范 §四)。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<VisitSummaryDto>(
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
                      '加载概览失败:\n${snap.error}\n\n下拉可重试。',
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                    ),
                  ),
                ],
              ),
            );
          }
          final s = snap.data!;
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
                IdentityHeroCard(
                  // 显示名取当前成员(用户自己给档案起的名),不取报告里抽出来的
                  // `profile.name` —— 后者可能因为某一张单子上印着别人而漂。
                  // 与档案屏同一取法。
                  name: ProfileManager.instance.displayName,
                  gender: s.patient.gender,
                  age: s.patient.age,
                  recordCount: s.patient.recordCount.toInt(),
                  // 与下方「最近归档」同一份数据,取最新一条的日期——不是本卡
                  // 单独算出来的数字。列表为空或那条记录没识别到日期都算「没有」。
                  recentVisitDate: s.recentVisits.isNotEmpty
                      ? s.recentVisits.first.date
                      : null,
                  onSwitchMember: () => showMemberSwitcherSheet(
                    context,
                    onChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                const SizedBox(height: MedShape.s3),
                QuickActions(
                  onArchiveIn: () => _import(null),
                  onManualEntry: _openManualEntry,
                  onEmergency: goToEmergencyCard,
                ),
                const SizedBox(height: MedShape.s2),
                VisitSheetBanner(
                  onTap: () => showVisitSummarySheet(
                    context,
                    from: VisitSheetEntry.overview,
                  ),
                ),
                const SizedBox(height: MedShape.s5),
                if (s.patient.recordCount == 0)
                  _FirstRunEmpty(onImport: () => _import(null))
                else ...[
                  _LabSnapshot(labs: s.recentLabs, onOpenDoc: _openDoc),
                  const SizedBox(height: MedShape.s5),
                  _RecentArchive(
                    visits: s.recentVisits,
                    total: s.patient.recordCount,
                    onOpenDoc: _openDoc,
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

/// 一排三颗快捷操作:存档 / 记录 / 应急卡。
///
/// 为什么是这三颗:前两颗是**往里放**(日常打开最常见的下一步是添一条新东西),
/// 后一颗是**往外拿**(急诊室,别人翻你的手机)。「看病带这个」原来也在这一排
/// (第四颗,当时叫「就诊单」),2026-08-05 产品验收后挪了出去——真机上看这颗
/// 图标挤在四等分的第四格里被反馈「蛮有用的」但不够显眼,于是改成下面单独一整
/// 条的 [VisitSheetBanner],不再和这三颗挤同一排(见该类文档的完整理由)。
/// 「看」不在这一排里 —— 看什么下面就是。
///
/// 原先前两颗是「拍照 / 存档」,但拍照本来就是存档三选一(拍照/相册/文件,见
/// `showImportSheet`)里的一个分支,两颗并排读起来像两件不同的事。改成
/// 「存档 / 记录」才是两件真正不同的事(有没有原件),拍照仍然是存档流程里最
/// 顺手的默认选项(`showImportSheet` 把它做成视觉主选项,抵消多出的一次点击)。
///
/// 用 `Wrap` 不用 `GridView`:系统字号放大后文字会撑宽,固定列数会把文字挤掉
/// 一半。Wrap 让它自然掉到第二行(007 §2.5「字号可放大,不可砍」)。
class QuickActions extends StatelessWidget {
  const QuickActions({
    super.key,
    required this.onArchiveIn,
    required this.onManualEntry,
    required this.onEmergency,
  });

  final VoidCallback onArchiveIn;
  final VoidCallback onManualEntry;
  final VoidCallback onEmergency;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 三列平分,列间距 s2。放大字号后每颗自己变高,不裁字。
        const gap = MedShape.s2;
        final w = (constraints.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            QuickAction(
              width: w,
              icon: Icons.add_box_outlined,
              label: '存档',
              onTap: onArchiveIn,
            ),
            QuickAction(
              width: w,
              icon: Icons.edit_note_outlined,
              label: '记录',
              onTap: onManualEntry,
            ),
            QuickAction(
              width: w,
              icon: Icons.emergency_outlined,
              label: '应急卡',
              onTap: onEmergency,
            ),
          ],
        );
      },
    );
  }
}

/// 「看病带这个」的入口卡——单独一整条,不和上面三颗快捷操作挤同一排。
///
/// ## 为什么要单独拎出来,而不是四等分里的第四格
///
/// 产品真机验收原话:「这个功能蛮有用的」,要求比原来更显眼。原来它是四等分
/// 快捷操作里视觉权重最低的一格——一个图标 + 两个字,和「存档」「记录」长得
/// 一样重。但它和另外三颗不是同一种"重要性":存档/记录/应急卡是**动作**,
/// 点一下就完成;这一条是**入口**,点进去是接下来几分钟要用的一整屏内容
/// (医生问诊时递给他看的东西)。用一整条、带说明文字的卡片而不是一个图标格,
/// 是让它的视觉权重配得上它的使用价值,不是单纯"调大字号"——调大字号在四等分
/// 网格里做不到(会把另外三颗挤变形),换成独立一整行是唯一不破坏那三颗现有
/// 布局的做法。
///
/// 用 `sealWash`/`sealInk` 这对强调色(而不是普通卡片的 `surface`/`line`)—— 与
/// `RecordedMedsCaveat` 的 `highWash`/`high` 同一手法(左侧竖条 + 浅底强调一整块),
/// 但换成品牌强调色而不是警示色:这不是一条警告,是一处**推荐路径**。
class VisitSheetBanner extends StatelessWidget {
  const VisitSheetBanner({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Material(
      color: c.sealWash,
      borderRadius: BorderRadius.circular(MedShape.radiusBlock),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MedShape.s3,
            vertical: MedShape.s2,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MedShape.radiusBlock),
            border: Border.all(color: c.sealInk.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.assignment_outlined, size: 26, color: c.sealInk),
              const SizedBox(width: MedShape.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '看病带这个',
                      style: MedType.body.copyWith(
                        color: c.sealInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '过敏史、用药、化验,医生问什么都在这一页',
                      style: MedType.secondary.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: c.sealInk),
            ],
          ),
        ),
      ),
    );
  }
}

class QuickAction extends StatelessWidget {
  const QuickAction({
    super.key,
    required this.width,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double width;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return SizedBox(
      width: width,
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MedShape.radiusBlock),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MedShape.radiusBlock),
              border: Border.all(color: c.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 图标用 `seal`(非文本 UI 组件,3:1 门槛足够);文字用 `ink`。
                Icon(icon, size: 22, color: c.seal),
                const SizedBox(height: 4),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: MedType.secondary.copyWith(color: c.ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「你怎么样」—— 最近的关键化验。
///
/// 数据是 `recentLabs`:每条序列取**最新一个带日期的点**,按日期倒序。也就是说这
/// 张卡回答的是「我最近一次测的这些指标是多少」,**不是**「我现在的身体状况」。
/// 标题因此写「最近的关键化验」而不是「健康快照」—— 后者是一个我们给不出的承诺。
///
/// **不带骑缝线**:卡里每一行来自不同的原件,这张卡本身不对应任何一张纸。可溯源
/// 由每一行右侧的箭头兑现(点进去就是那一次化验的那份报告)。
class _LabSnapshot extends StatelessWidget {
  const _LabSnapshot({required this.labs, required this.onOpenDoc});

  final List<VisitLabDto> labs;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '最近的关键化验',
          actionLabel: labs.isEmpty ? null : '看趋势',
          onAction: labs.isEmpty ? null : goToTrends,
        ),
        const SizedBox(height: MedShape.s1),
        MedCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
            child: labs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      MedShape.s4,
                      MedShape.s2,
                      MedShape.s4,
                      MedShape.s2,
                    ),
                    // 空态说的是我们**观察到**什么,不是用户身上有没有事。
                    child: Text(
                      '已导入的病历里还没有读到可显示的化验数值。拍一张化验单试试。',
                      style: MedType.body.copyWith(color: c.ink2, height: 1.5),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < labs.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, thickness: 1, color: c.line2),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: MedShape.s2,
                          ),
                          child: LabLine(
                            name: labs[i].name,
                            value: labs[i].value,
                            unit: labs[i].unit,
                            flag: labs[i].flag,
                            refLow: labs[i].refLow,
                            refHigh: labs[i].refHigh,
                            // 见 visit_summary_sheet.dart 的 `_LabRow` 同一处注释。
                            meta: [
                              labs[i].date,
                              if (labs[i].selfMeasured) '家测',
                              if (labs[i].valuesConverted)
                                unitConvertedNote(labs[i].unit),
                            ].join(' · '),
                            onTap: () => onOpenDoc(labs[i].documentId),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// 「东西在哪」—— 最近归档的几份。
///
/// 每一条各自一张卡,**骑缝线按档案屏的同一条规则画**:
///  · 只含一份文档的记录 → 点了就是那一份原件 → 画;
///  · 一次就诊含好几份 → 点了是去档案里展开那一组,背后没有「一张纸」→ 不画。
class _RecentArchive extends StatelessWidget {
  const _RecentArchive({
    required this.visits,
    required this.total,
    required this.onOpenDoc,
  });

  final List<VisitRecordDto> visits;
  final int total;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '最近归档',
          actionLabel: '全部 $total 份',
          onAction: goToArchive,
        ),
        const SizedBox(height: MedShape.s1),
        if (visits.isEmpty)
          MedCard(
            child: Padding(
              padding: const EdgeInsets.all(MedShape.s4),
              child: Text(
                '还没有归档的记录。',
                style: MedType.body.copyWith(color: c.ink2),
              ),
            ),
          )
        else
          for (var i = 0; i < visits.length; i++) ...[
            if (i > 0) const SizedBox(height: MedShape.s2),
            _VisitCard(visit: visits[i], onOpenDoc: onOpenDoc),
          ],
      ],
    );
  }
}

/// 右侧那一列日期该不该渲染 —— 标题里已经带了就不重复。
///
/// 公开是为了可测:整屏 pump 需要 `viewVisitSummary()` 的 Rust FFI,测试环境没有
/// 原生库。与 `manualEntryRangeError`、`SeriesCard` 同一先例。
bool visitCardShowsDate({required String title, required String date}) =>
    date.isNotEmpty && !title.contains(date);

/// 副标题文案 —— 标题里已有的类型不重复,份数(多份时)照常给。全被涵盖时返回空串,
/// 调用方据此整行不渲染。
String visitCardDesc({
  required String title,
  required String kindLabel,
  required int docCount,
}) => [
  if (!title.contains(kindLabel)) kindLabel,
  if (docCount != 1) '$docCount 份记录',
].join(' · ');

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.visit, required this.onOpenDoc});

  final VisitRecordDto visit;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final single = visit.documentIds.length == 1;
    final date = fmtDate(visit.date);
    final kindLabel = visitKindLabel(visit.kind);
    final title = visit.title ?? kindLabel;

    // **标题里已经有的东西不再重复说一遍。**
    //
    // 标题来自保险箱里的就诊组标题,而它常常已经把类型和日期都拼进去了
    // (示例数据里就是 `门诊 · 2026-06-20`)。此前这里无条件在右侧再渲染一次日期、
    // 在副标题里再渲染一次类型,于是一张卡把同样的信息说三遍:
    //
    //     门诊 · 2026-06-20        2026-06-20
    //     门诊
    //
    // 三处各自都对,合起来是坏的。改成按标题的实际内容裁剪。
    final showDate = visitCardShowsDate(title: title, date: date);
    final desc = visitCardDesc(
      title: title,
      kindLabel: kindLabel,
      docCount: visit.documentIds.length,
    );

    return MedCard(
      perforated: single,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: single
              ? () => onOpenDoc(visit.documentIds.first.toInt())
              // 多份的一组在概览里不展开 —— 展开是档案屏的事,那里才有删除、
              // 子文档列表这些配套。这里只负责把人送过去。
              : goToArchive,
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
                    borderRadius: BorderRadius.circular(MedShape.radiusControl),
                  ),
                  child: Icon(
                    iconForVisitKind(visit.kind),
                    size: 20,
                    color: c.seal,
                  ),
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
                              title,
                              style: MedType.subtitle.copyWith(color: c.ink),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (showDate) ...[
                            const SizedBox(width: MedShape.s1),
                            Text(
                              date,
                              style: MedType.secondary.copyWith(
                                color: c.ink3,
                                fontFeatures: MedType.tabular,
                              ),
                            ),
                          ],
                        ],
                      ),
                      // 全被标题涵盖时整行不渲染 —— 空的副标题只会留一道空隙。
                      if (desc.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          desc,
                          style: MedType.secondary.copyWith(color: c.ink2),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: c.ink3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 分区标题 + 右侧的一个次级动作。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionLabel, this.onAction});

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(title, style: MedType.caption.copyWith(color: c.ink3)),
        ),
        if (actionLabel != null)
          // 正文级链接用 `sealInk`(6.76:1),不用 `seal`(3.90:1,不过 AA)。
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: c.sealInk,
              padding: const EdgeInsets.symmetric(horizontal: MedShape.s1),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(actionLabel!, style: MedType.secondary),
          ),
      ],
    );
  }
}

/// 一份记录都没有时的概览。
///
/// 规范 §六:**空态必须给出路** —— 留白等于说「你没有相关检查」,那是临床上的假话。
class _FirstRunEmpty extends StatelessWidget {
  const _FirstRunEmpty({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return DottedBorderBox(
      child: Column(
        children: [
          Icon(Icons.folder_outlined, size: 48, color: c.ink3),
          const SizedBox(height: MedShape.s2),
          Text('还没有病历', style: MedType.subtitle.copyWith(color: c.ink)),
          const SizedBox(height: MedShape.s1),
          Text(
            '拍一张化验单或出院小结,MedMe 会把上面的字读出来、按时间排好。\n'
            '你的病历只保存在这台手机上。',
            textAlign: TextAlign.center,
            style: MedType.body.copyWith(color: c.ink2, height: 1.6),
          ),
          const SizedBox(height: MedShape.s3),
          FilledButton(onPressed: onImport, child: const Text('导入第一份病历')),
        ],
      ),
    );
  }
}
