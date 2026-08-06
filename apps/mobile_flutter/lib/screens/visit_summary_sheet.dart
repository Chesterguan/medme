import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/manual_entry_sheet.dart';
import 'package:mobile_flutter/screens/qr_share_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 「看病带这个」—— **刻意不是一个 tab**(设计系统 §八)。
///
/// 原名「就诊单」,2026-08-05 产品真机验收后改名:「就诊单似乎不太好理解」——
/// 「单」这个字暗示这是医院/系统发下来的一张单据,而它其实是**你自己带进诊室的
/// 那张纸**。文件名、函数名(`showVisitSummarySheet`)、类名、下面的内部注释仍然
/// 沿用旧名——那是给读代码的人用的内部标识符,不是给患者看的界面文案,批量改
/// 标识符只会放大这次 diff 的风险却不会改变任何人看到的东西:**只改字(界面上
/// 显示的文案),不改名(Dart 符号)**。
///
/// 它是诊室里那 30 秒的动作:医生问「你最近吃什么药、过敏吗、上次化验多少」,你
/// 把手机递过去。这不是一个你会常驻浏览的空间,所以它没有底栏席位,而是从**概览**
/// 与**档案**两处以浮层唤起 —— 那两处正好是「日常打开」和「找单子」,进诊室前你
/// 本来就在其中之一。
///
/// ## 2026-08-05 改版:段落顺序反了过来
///
/// 产品真机验收拆出四条具体问题:
/// 1. 名字像医院发的东西(已解决,见上);
/// 2. 前三屏全是免责声明(MedMe 不判断 → 过敏史没找到不等于没有 → 用药不代表
///    当前医嘱),三句话都对、都必要,连着堆在开场却把内容压没了;
/// 3. 药排在化验前面,10 条药(含重复提及)要滚两屏才见到化验,而医生问诊通常
///    是先问现在怎么了、再看指标、最后核药,顺序反了;
/// 4. 「复制全文给医生」与「医生要看原件·出示二维码」两个按钮分不清,得自己推。
/// 还缺一样东西:**整屏都是"系统从病历里读到了什么",没有一处是"患者自己带来
/// 的"**——「记录」里写的笔记存完就沉进时间线,没有出口。
///
/// 新顺序(`_body` 的四个区块)一起解决这些:
/// - **我想问医生的**(笔记)排最前——这是这一屏唯一一处"你自己的东西",也是
///   唯一动手就能加的一节;
/// - **我最近的变化**紧跟着(自测数值 + 异常化验)——回答"最近有什么不一样",
///   医生问诊的第二步;
/// - **医生可能要问的**(过敏史 + 用药)收在后面,过敏史保持展开(它是这一屏
///   唯一一条"用错会当场出事"的信息),用药默认折叠——两节各自的免责声明跟着
///   自己的内容走,不再连着堆在开场。
///
/// 内容全部来自 `viewVisitSummary()`,而那个投影对结构化字段**只搬运原文逐字
/// 内容与抽出的数值/日期,不生成任何解释或结论**——「我想问医生的」是唯一的
/// 例外:那是患者自己写的笔记,只在这一屏显示给患者自己看,绝不进「复制给医生」
/// 的文本或二维码分享(见 Rust 侧 `VisitNoteDto` 的文档)。这一屏本身也不加结论:
/// 没有「建议复查」,没有「病情稳定」。它是一页纸,不是一份意见。
Future<void> showVisitSummarySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const VisitSummarySheet(),
  );
}

/// 浮层本体。生产只由 [showVisitSummarySheet] 用默认构造建;两个可注入的钩子存在的
/// 唯一理由是**测试**:这一屏的数据源与「加一条」都要走 Rust FFI,而 `flutter test`
/// 不加载原生库(见 `test/visit_summary_sheet_test.dart` 顶部同一条限制)。注入之后
/// 「存完笔记要重新拉一次数据」才能被钉成一条不依赖设备的回归。
class VisitSummarySheet extends StatefulWidget {
  const VisitSummarySheet({super.key, this.load, this.onRequestAddNote});

  /// 数据源。null → [viewVisitSummary](FFI)。
  final Future<VisitSummaryDto> Function()? load;

  /// 「加一条」按下时走的动作,返回「是否真的存了一条」。null → 开录入弹层(FFI)。
  final Future<bool?> Function(BuildContext context)? onRequestAddNote;

  @override
  State<VisitSummarySheet> createState() => _VisitSummarySheetState();
}

class _VisitSummarySheetState extends State<VisitSummarySheet> {
  late Future<VisitSummaryDto> _future = _load();

  Future<VisitSummaryDto> _load() =>
      widget.load?.call() ?? viewVisitSummary();

  void _openDoc(int id) {
    // 与档案屏同一条埋点:只报「打开了一份」,不带 id、不带任何内容。
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(appSnackBar(content: Text('已复制,可以粘贴到微信发给医生')));
  }

  /// 「我想问医生的」空态与常态共用的「加一条」——直接开录入弹层,预选中「笔记」,
  /// 跳过六选一(用户点这颗按钮时意图已经是"记笔记",没理由再点一次)。存完刷新
  /// 这一屏的数据,不需要用户自己关掉浮层再重开——参见 `overview_screen.dart` 的
  /// `_openManualEntry` 同一条理由:存完立刻看见结果,不是靠额外的 SnackBar 交代。
  Future<void> _addNote() async {
    final add = widget.onRequestAddNote;
    final saved = add != null
        ? await add(context)
        : await showManualEntrySheet(
            context,
            initialKind: ManualEntryKind.note,
          );
    if (saved == true && mounted) await _refresh();
  }

  /// 重新拉一次数据并**真的重建这一屏**。
  ///
  /// 与概览 / 趋势 / 档案三屏同一个写法,理由也同一条:`setState(() => _future = …)`
  /// 的**箭头体**会把赋值结果(一个 `Future`)当成 setState 的返回值交出去,
  /// `State.setState` 在断言里发现它是 Future 就抛 —— 而那一抛发生在
  /// `markNeedsBuild()` **之前**。于是 `_future` 换成了新的,却没有任何一次重建被
  /// 调度:用户看着自己刚写的笔记没出现,自然会再写一遍。这一处还更狠 —— 它在一个
  /// `async` 方法里、由 `VoidCallback` 调起,异常直接逃成未捕获的 zone 错误,连控制台
  /// 上都只是一条与现象对不上的噪音。release 里断言被剥掉看不出来,debug/profile 必现。
  /// **所以必须是语句块,不是箭头。**
  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _future = next;
    });
    await next;
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 浮层高度上限取屏高的 88%:再高就盖住了顶栏,读起来像换了一屏而不是「递过去
    // 一张纸」;再矮则一屏放不下过敏 + 用药两节,医生要滚才看得到最要紧的过敏史。
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: FutureBuilder<VisitSummaryDto>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(MedShape.s6),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(MedShape.s5),
              child: Text(
                '加载失败:${snap.error}',
                style: MedType.body.copyWith(color: c.ink2, height: 1.6),
              ),
            );
          }
          final s = snap.data!;
          return SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: VisitSummaryBody(
                    summary: s,
                    onOpenDoc: _openDoc,
                    onAddNote: _addNote,
                  ),
                ),
                _actions(context, s),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 底部动作条。**一屏只允许一颗主按钮**(规范 §六),这里是「复制」——
  /// 因为诊室里最常见的一步是把这段字发到医生的微信/工作站,而不是让医生扫码。
  Widget _actions(BuildContext context, VisitSummaryDto s) {
    final c = MedColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s4,
        MedShape.s2,
        MedShape.s4,
        MedShape.s2,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _copy(s.plainText),
              icon: const Icon(Icons.copy_all_outlined, size: 20),
              label: const Text('复制全文给医生'),
            ),
          ),
          const SizedBox(height: MedShape.s1),
          // 二维码分享与这一屏是**两个场景**:这一屏是本地的、离线的、30 秒读完的
          // 一页纸;扫码是端到端加密、要联网、把**完整病历含原件**交出去。医生说
          // 「我要看原片」时才升级到这一步,所以它是次级按钮,不是并列。两个按钮
          // 的文案刻意不对称——一个说「给文字」,一个说「给原件」,不用靠图标或
          // 顺序去猜哪个更"重"。
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const QrShareScreen()),
              ),
              icon: const Icon(Icons.qr_code_2, size: 20),
              label: const Text('医生要看原件 · 出示二维码'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「看病带这个」浮层的内容主体——**不碰 FFI**,纯粹拿一份已经取到的
/// [VisitSummaryDto] 渲染。
///
/// 从 `_VisitSummarySheetState.build()` 里拆成一个公开 widget,是为了让
/// `flutter test` 能在没有 Rust 原生库的环境下对这一屏做多视口 + 大字号溢出
/// 回归测试——`_VisitSummarySheet` 本身在 `_future` 字段初始化那一刻就会调
/// `viewVisitSummary()`,在测试环境里直接崩(见 `manual_entry_sheet_test.dart`
/// 顶部注释,这是本项目反复踩过的坑,也是这一屏在这次改版前一直没有测试文件的
/// 原因)。这层拆分让"数据从哪来"(FFI,留在 `_VisitSummarySheetState`)和
/// "数据怎么显示"(纯 widget 树,搬到这里)分开,后者才是这次改版真正要验的
/// 内容——见 `test/visit_summary_sheet_test.dart`。
class VisitSummaryBody extends StatefulWidget {
  const VisitSummaryBody({
    super.key,
    required this.summary,
    required this.onOpenDoc,
    required this.onAddNote,
  });

  final VisitSummaryDto summary;
  final void Function(int docId) onOpenDoc;
  final VoidCallback onAddNote;

  @override
  State<VisitSummaryBody> createState() => _VisitSummaryBodyState();
}

class _VisitSummaryBodyState extends State<VisitSummaryBody> {
  /// 「记录里的用药」默认折叠(规则见文件顶部类文档:过敏史必须一进来就看见,
  /// 用药那节连着它的免责声明一起收起来,不占开场的地方)。
  bool _medsExpanded = false;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final s = widget.summary;
    final p = s.patient;
    final who = [
      p.name,
      p.gender,
      p.age,
    ].whereType<String>().where((x) => x.isNotEmpty).join(' · ');

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s4,
        0,
        MedShape.s4,
        MedShape.s3,
      ),
      children: [
        Text('看病带这个', style: MedType.title.copyWith(color: c.ink)),
        if (who.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(who, style: MedType.subtitle.copyWith(color: c.ink)),
        ],
        const SizedBox(height: MedShape.s4),

        // ── 我想问医生的:这一屏唯一一处"患者自己带来的东西",排最前。 ──
        _NotesSection(
          notes: s.recentNotes,
          onAddNote: widget.onAddNote,
          onOpenDoc: widget.onOpenDoc,
        ),

        const SizedBox(height: MedShape.s5),

        // ── 我最近的变化:自测数值 + 异常化验,医生问诊的第二步。 ──
        _Section(
          title: '我最近的变化',
          // 这里刻意不说"都正常"——空态只说"我们观察到什么",不对身体状况下
          // 结论(规范 §六 的空态写法与 `_LabSnapshot` 同一条准则)。真没有任何
          // 化验数据(而不是"有数据但都不异常")也会走到这句,两种情况文案上不
          // 强行区分:对患者来说"要不要在意"这件事,答案都是"这里没有要提醒你
          // 的"。
          emptyText: '已导入的病历里没有自测数值,也没有标为异常的化验。',
          isEmpty: s.recentChanges.isEmpty,
          children: [
            for (final l in s.recentChanges)
              _LabRow(lab: l, onOpenDoc: widget.onOpenDoc),
          ],
        ),

        const SizedBox(height: MedShape.s5),

        // ── 医生可能要问的:过敏史(展开)+ 用药(默认折叠)。 ──
        _DoctorMayAskSection(
          allergies: s.allergies,
          activeMeds: s.activeMeds,
          medsExpanded: _medsExpanded,
          onToggleMeds: () => setState(() => _medsExpanded = !_medsExpanded),
          onOpenDoc: widget.onOpenDoc,
        ),
      ],
    );
  }
}

/// 「我想问医生的」一节。**只显示最近几条笔记,不分类**——设计取舍见下。
///
/// ## 为什么不是"勾选标记要问医生的笔记"这个更精确的方案
///
/// `MANUAL-ENTRY-DESIGN.md` §5.4 提过一个更细的方案:录入笔记时加一个"要问
/// 医生"的勾选,只有勾了的笔记才进这一节——这样"今天头晕"和"问王医生片子的
/// 事"不会混在一起。做这个标记不需要动 `packages/core-model`(`DocType::Note`
/// 已经够用),但要往笔记的 OCR 文本里编码一个隐藏标记(仿 `self_entry.rs` 给
/// 自测值编结构化载荷的先例),而笔记的 OCR 文本在这个项目里是反复强调的不变量:
/// 「逐字来自你写的东西」——往里塞一个显示时要再摘掉的隐藏前缀,是为了一个 UI
/// 分类去弄脏这条不变量,而且没有老笔记的回填路径(标记上线前写的笔记永远没有
/// 这个标记,那这个功能对他们就是永久性缺失)。权衡下来选了更简单的路:直接列
/// 最近几条,不分类(见 Rust 侧 `VisitNoteDto` 的完整讨论)。代价是"今天头晕"
/// 和"问王医生片子的事"会挨在一起;好处是零 core-model/parser 改动、老笔记立刻
/// 可用。
class _NotesSection extends StatelessWidget {
  const _NotesSection({
    required this.notes,
    required this.onAddNote,
    required this.onOpenDoc,
  });

  final List<VisitNoteDto> notes;
  final VoidCallback onAddNote;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '我想问医生的',
                style: MedType.caption.copyWith(color: c.ink3),
              ),
            ),
            // 「加一条」常驻(不只是空态才有)——见过一次医生之后往往又会想起
            // 新的问题,不该只在这一节空着的时候才给出路。
            TextButton.icon(
              onPressed: onAddNote,
              style: TextButton.styleFrom(
                foregroundColor: c.sealInk,
                padding: const EdgeInsets.symmetric(horizontal: MedShape.s1),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('加一条', style: MedType.secondary),
            ),
          ],
        ),
        const SizedBox(height: MedShape.s1),
        if (notes.isEmpty)
          // 空态必须有出路(规范 §六)——这里的出路就是上面那颗「加一条」,文案
          // 直接指给它看,不是空泛的"暂无内容"。
          Text(
            // 不要在这里塞 `\n`。硬换行会在窄屏上把句子折成一条提前结束的短行
            // (真机 360dp 上就是「……见医生前翻开」独占半行),而 `Text` 自己会
            // 按可用宽度断行——排版交给布局,不要在文案里手工排。
            '还没有记下想问的问题。想到什么随时点右上角「加一条」——'
            '见医生前翻开这一屏,就不会到了诊室才想起来忘了问什么。',
            style: MedType.body.copyWith(color: c.ink2, height: 1.5),
          )
        else
          for (final n in notes) _NoteRow(note: n, onOpenDoc: onOpenDoc),
      ],
    );
  }
}

/// 一条笔记:原文 + 记录日期,右侧箭头点进原件(笔记本身就是它自己的"原件"——
/// 打开看到的是完整原文,不会被这一行的显示截断)。
class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note, required this.onOpenDoc});

  final VisitNoteDto note;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return InkWell(
      onTap: () => onOpenDoc(note.documentId),
      borderRadius: BorderRadius.circular(MedShape.radiusControl),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(note.text, style: MedType.body.copyWith(color: c.ink)),
                  if (note.date case final d? when d.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      d,
                      style: MedType.secondary.copyWith(
                        color: c.ink2,
                        fontFeatures: MedType.tabular,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

/// 「医生可能要问的」:过敏史(展开)+ 用药(默认折叠)。
///
/// 「下面每一个字都逐字来自你已导入的病历」这句总说明**从第一屏最上头挪到了这
/// 里**——它准确描述的是这两节(过敏史、用药都是从原文抽出来的),不是上面
/// 「我想问医生的」(患者自己写的笔记)或「我最近的变化」(部分是自测值,同样
/// 不是"从病历读出来的")。位置换了,意思一个字没改。
class _DoctorMayAskSection extends StatelessWidget {
  const _DoctorMayAskSection({
    required this.allergies,
    required this.activeMeds,
    required this.medsExpanded,
    required this.onToggleMeds,
    required this.onOpenDoc,
  });

  final List<AllergyItemDto> allergies;
  final List<ActiveMedDto> activeMeds;
  final bool medsExpanded;
  final VoidCallback onToggleMeds;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('医生可能要问的', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: 2),
        Text(
          '下面每一个字都逐字来自你已导入的病历。MedMe 不做判断,也不生成结论。',
          style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
        ),
        const SizedBox(height: MedShape.s3),

        // 过敏史排在第一位,不是按数据量排的 —— 它是这一屏里唯一一条**用错会
        // 当场出事**的信息,所以它是「医生可能要问的」两节里唯一保持展开的那个。
        _Section(
          title: '过敏史',
          // 空过敏史必须自己说话:留白会被医生读成「无过敏史」,而我们只知道
          // 「已导入的这些纸上没写」。这两件事在临床上差着一条命。
          emptyText: '已导入的病历里没有找到过敏记录 —— 这不等于你不过敏,请当面告诉医生。',
          isEmpty: allergies.isEmpty,
          children: [
            for (final a in allergies)
              _LineRow(
                title: a.substance,
                subtitle: a.reaction.isEmpty ? null : a.reaction,
                documentIds: a.documentIds,
                onOpenDoc: onOpenDoc,
              ),
          ],
        ),

        _MedsSubsection(
          activeMeds: activeMeds,
          expanded: medsExpanded,
          onToggle: onToggleMeds,
          onOpenDoc: onOpenDoc,
        ),
      ],
    );
  }
}

/// 「记录里的用药」——默认折叠。没有药可显示时不折叠:空态文案必须一进来就
/// 看得见(规范 §六:空态是"出路",藏在一次多余的点击后面就不是出路了)。
class _MedsSubsection extends StatelessWidget {
  const _MedsSubsection({
    required this.activeMeds,
    required this.expanded,
    required this.onToggle,
    required this.onOpenDoc,
  });

  final List<ActiveMedDto> activeMeds;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    if (activeMeds.isEmpty) {
      return const _Section(
        title: kRecordedMedsTitle,
        emptyText: '已导入的病历里没有读到药名。',
        isEmpty: true,
        children: [],
      );
    }
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(MedShape.radiusControl),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      kRecordedMedsTitle,
                      style: MedType.caption.copyWith(color: c.ink3),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: c.ink3,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: MedShape.s1),
            const RecordedMedsCaveat(),
            const SizedBox(height: MedShape.s1),
            for (final m in activeMeds)
              _LineRow(
                title: m.name,
                subtitle: recordedMedTiming(m),
                documentIds: m.documentIds,
                onOpenDoc: onOpenDoc,
              ),
          ],
        ],
      ),
    );
  }
}

/// 这一屏上的一节:标题 + 内容,或标题 + 一句诚实的空态。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.emptyText,
    required this.isEmpty,
    required this.children,
  });

  final String title;
  final String emptyText;
  final bool isEmpty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: MedType.caption.copyWith(color: c.ink3)),
          const SizedBox(height: MedShape.s1),
          if (isEmpty)
            Text(
              emptyText,
              style: MedType.body.copyWith(color: c.ink2, height: 1.5),
            )
          else
            ...children,
        ],
      ),
    );
  }
}

/// 一行「名称 + 说明」,右侧箭头点进原件。
///
/// 骑缝线不画在这里 —— 这是浮层里的一**行**不是一张卡,而骑缝线是卡级的签名元素
/// (规范 §五)。可溯源在这一层由**右侧的箭头 + 可点**兑现:`documentIds` 为空时
/// 箭头不出现,行也点不动,不给假承诺。
class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.title,
    required this.subtitle,
    required this.documentIds,
    required this.onOpenDoc,
  });

  final String title;
  final String? subtitle;
  final List<BigInt> documentIds;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 一条信息可能被好几份病历提到(同一个药开过三次)。浮层这一层不做「选哪一
    // 份」的分歧界面 —— 跳**最后一份**,因为那是最近一次提到它的那张纸,也是医生
    // 追问时最想看的那张。想看全部提及,走档案。
    final target = lastDocumentId(documentIds);
    return InkWell(
      onTap: target == null ? null : () => onOpenDoc(target),
      borderRadius: BorderRadius.circular(MedShape.radiusControl),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: MedType.body.copyWith(color: c.ink)),
                  if (subtitle case final sub? when sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
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
              Icon(Icons.chevron_right, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

/// 这一屏上的一行化验。渲染全部交给共用的 [LabLine] —— 同一个化验值在概览、
/// 这一屏、趋势三处必须长得一模一样,否则「偏高」就成了三个意思(规范 §七)。
class _LabRow extends StatelessWidget {
  const _LabRow({required this.lab, required this.onOpenDoc});

  final VisitLabDto lab;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    return LabLine(
      name: lab.name,
      value: lab.value,
      unit: lab.unit,
      flag: lab.flag,
      refLow: lab.refLow,
      refHigh: lab.refHigh,
      // 自测值(家测血压/血糖/体重/体温/心率)与医院值排在同一份「我最近的
      // 变化」里,靠这个标注分清"这是病人自己量的"——见 MANUAL-ENTRY-DESIGN.md,
      // 措辞与概览、趋势页复用同一个"· 家测"。
      // `valuesConverted` 见 `unitConvertedNote` —— 这一行的数值不是纸上印的那个
      // 时必须标注,概览行(overview_screen)用同一份措辞。
      meta: [
        lab.date,
        if (lab.selfMeasured) '家测',
        if (lab.valuesConverted) unitConvertedNote(lab.unit),
      ].join(' · '),
      onTap: () => onOpenDoc(lab.documentId),
    );
  }
}
