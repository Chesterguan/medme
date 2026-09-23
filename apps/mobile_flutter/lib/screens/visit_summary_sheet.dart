import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';

/// 「给医生看」正文——诊室里那 30 秒要看的东西,纯渲染,见 [VisitSummaryBody]。
///
/// ⚠️ 这里原来是一整块浮层(`VisitSummarySheet`/`showVisitSummarySheet`,从
/// **概览**与**档案**两处顶栏唤起),退出只能下滑、自动化和真人都在那儿卡住过
/// (ux-audit「试了不止一次」①②)。Task 9 把内容升格成「给医生看」整页
/// (`screens/for_doctor_screen.dart`);Task 17 把浮层本体整个删掉,只留下面这份
/// 纯渲染的 [VisitSummaryBody] 与它下面的私有 widget —— 那才是「给医生看」在用
/// 的东西。`AnalyticsEvent.visitSheetOpened`/`VisitSheetEntry`(以及
/// `visitSheetAction`/`VisitSheetAction`)几个埋点定义仍标 `@Deprecated` 留在
/// `analytics.dart`——PostHog 里有它们的历史数据,删了对不上账。
///
/// ## 段落顺序:我最近的变化 → 医生可能要问的 → 我想问医生的
///
/// 2026-09-22 UX Stage 3.5「减法」Task 7 定的顺序,取代上一版(2026-08-05,
/// 「我想问医生的」排最前)。三节现在按医生问诊的顺序走:
/// - **我最近的变化**(自测数值 + 异常化验)排最前——回答"最近有什么不一样";
/// - **医生可能要问的**(过敏史 + 用药)紧跟着,过敏史保持展开(唯一一条
///   "用错会当场出事"的信息),用药默认折叠;
/// - **我想问医生的**(笔记)排最后,紧挨着固定在底部的「出码给医生看」
///   按钮——出码前最后看一眼自己还有什么想问的。
///
/// 每节现在是「小标题 + 一张卡」(见 [_Section]),不再共用一张外层 `MedCard`,
/// 标题前也不再有图标(减法稿:类别上色/图标没有信息)。用药子节是唯一的例外
/// (见 [_MedsSubsection]):折叠且有药时只有「标题 + 箭头」,没有卡,卡要等
/// 展开才出现。四处标题字号统一成一份共用的 [_SectionLabel]。
///
/// 内容全部来自 `viewVisitSummary()` 返回的 [VisitSummaryDto],对结构化字段
/// **只搬运原文逐字内容与抽出的数值/日期,不生成任何解释或结论**——「我想问医生的」是
/// 唯一的例外:那是患者自己写的笔记,只在这一屏显示给患者自己看,绝不进交给医生
/// 的那份纯文本,也不进二维码分享(见 Rust 侧 `VisitNoteDto` 的文档)。这一屏本身
/// 也不加结论:没有「建议复查」,没有「病情稳定」。它是一页纸,不是一份意见。
class VisitSummaryBody extends StatefulWidget {
  const VisitSummaryBody({
    super.key,
    required this.summary,
    required this.onOpenDoc,
    required this.onAddNote,
    this.showHeading = true,
    this.footer,
  });

  final VisitSummaryDto summary;
  final void Function(int docId) onOpenDoc;
  final VoidCallback onAddNote;

  /// 正文顶部要不要画一行「给医生看」抬头。`ForDoctorScreen` 传 `false` ——
  /// 那一页的 AppBar 上已经写着「给医生看」,正文再画一遍就是同屏两个自己的
  /// 名字。`true`(默认值)留给**不带自己标题栏**的调用方——今天没有这样的
  /// 调用方了(原来的浮层已删,内容升格成了 tab),但组件自身的这个开关不因为
  /// 调用方一时没有就该跟着拆。患者那行「名字 · 性别 · 年龄」两边都留着。
  final bool showHeading;

  /// 接在正文最后、**跟着一起滚**的东西。「给医生看」那一页用它把「打印 / 导出」
  /// 「急救卡」「代拍」三条放进滚动流里 —— `s4` 只有「出码给医生看」那一颗固定在
  /// 底部。浮层不传。
  final Widget? footer;

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
        if (widget.showHeading) ...[
          Text('给医生看', style: MedType.title.copyWith(color: c.ink)),
          if (who.isNotEmpty) const SizedBox(height: 2),
        ],
        if (who.isNotEmpty)
          Text(who, style: MedType.subtitle.copyWith(color: c.ink)),
        const SizedBox(height: MedShape.s3),

        // ── 我最近的变化:自测数值 + 异常化验,排最前,回答"最近有什么不一样"。 ──
        _Section(
          title: '我最近的变化',
          // 这里刻意不说"都正常"——空态只说"我们观察到什么",不对身体
          // 状况下结论(规范 §六 的空态写法与 `_LabSnapshot` 同一条
          // 准则)。真没有任何化验数据(而不是"有数据但都不异常")也会
          // 走到这句,两种情况文案上不强行区分:对患者来说"要不要在意"
          // 这件事,答案都是"这里没有要提醒你的"。
          emptyText: '已添加的病历里没有自测数值,也没有标为异常的化验。',
          isEmpty: s.recentChanges.isEmpty,
          children: [
            for (final l in s.recentChanges)
              _LabRow(lab: l, onOpenDoc: widget.onOpenDoc),
          ],
        ),

        // ── 医生可能要问的:过敏史(展开)+ 用药(默认折叠)。 ──
        _DoctorMayAskSection(
          allergies: s.allergies,
          activeMeds: s.activeMeds,
          medsExpanded: _medsExpanded,
          onToggleMeds: () =>
              setState(() => _medsExpanded = !_medsExpanded),
          onOpenDoc: widget.onOpenDoc,
        ),

        // ── 我想问医生的:这一屏唯一一处"患者自己带来的东西",紧挨着固定在
        // 底部的「出码给医生看」按钮,排最后。 ──
        _NotesSection(
          notes: s.recentNotes,
          onAddNote: widget.onAddNote,
          onOpenDoc: widget.onOpenDoc,
        ),

        if (widget.footer != null) widget.footer!,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '我想问医生的',
                    style: MedType.secondary.copyWith(color: c.ink3),
                  ),
                ),
                // 「加一条」常驻(不只是空态才有)——见过一次医生之后往往又会想起
                // 新的问题,不该只在这一节空着的时候才给出路。
                TextButton.icon(
                  onPressed: onAddNote,
                  style: TextButton.styleFrom(
                    foregroundColor: c.sealInk,
                    padding: const EdgeInsets.symmetric(
                      horizontal: MedShape.s1,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('加一条', style: MedType.secondary),
                ),
              ],
            ),
          ),
          MedCard(
            child: notes.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(MedShape.s3),
                    // 空态必须有出路(规范 §六)——这里的出路就是上面那颗「加一条」,
                    // 文案直接指给它看,不是空泛的"暂无内容"。
                    child: Text(
                      // 不要在这里塞 `\n`。硬换行会在窄屏上把句子折成一条提前结束的
                      // 短行(真机 360dp 上就是「……见医生前翻开」独占半行),而
                      // `Text` 自己会按可用宽度断行——排版交给布局,不要在文案里
                      // 手工排。
                      '还没有记下想问的问题。想到什么随时点右上角「加一条」——'
                      '见医生前翻开这一屏,就不会到了诊室才想起来忘了问什么。',
                      style: MedType.body.copyWith(color: c.ink2, height: 1.5),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < notes.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, thickness: 1, color: c.line2),
                        _NoteRow(note: notes[i], onOpenDoc: onOpenDoc),
                      ],
                    ],
                  ),
          ),
        ],
      ),
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
        padding: const EdgeInsets.symmetric(
          horizontal: MedShape.s3,
          vertical: MedShape.s2,
        ),
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
/// 里**——它准确描述的是这两节(过敏史、用药都是从原文抽出来的),不是
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
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, MedShape.s2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '医生可能要问的',
                style: MedType.secondary.copyWith(color: c.ink3),
              ),
              const SizedBox(height: 2),
              Text(
                '下面每一个字都逐字来自你已添加的病历。MedMe 不做判断,也不生成结论。',
                style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
              ),
            ],
          ),
        ),

        // 过敏史排在第一位,不是按数据量排的 —— 它是这一屏里唯一一条**用错会
        // 当场出事**的信息,所以它是「医生可能要问的」两节里唯一保持展开的那个。
        _Section(
          title: '过敏史',
          // 空过敏史必须自己说话:留白会被医生读成「无过敏史」,而我们只知道
          // 「已导入的这些纸上没写」。这两件事在临床上差着一条命。
          emptyText: '已添加的病历里没有找到过敏记录 —— 这不等于你不过敏,请当面告诉医生。',
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
///
/// 有药但折叠时,这一节只有「标题 + 箭头」,没有卡——`_Section` 的「小标题 +
/// 一张卡」规则在这里唯一的例外:卡(免责声明 + 药名列表)要等展开才出现。
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
        emptyText: '已添加的病历里没有读到药名。',
        isEmpty: true,
        children: [],
      );
    }
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // 与 _SectionLabel 同一份外框(4,0,4,6)——展开时卡跟标题的间距
            // 也靠这个 6,不再另加 SizedBox。
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(MedShape.radiusControl),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                // 去掉图标槽之后这是正文里唯一的可点行,ConstrainedBox 把
                // 可点高度钉在 ≥48——不能只剩文字那 22px 高。
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          kRecordedMedsTitle,
                          style: MedType.secondary.copyWith(color: c.ink3),
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
            ),
          ),
          if (expanded) ...[
            MedCard(
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(MedShape.s3),
                    child: RecordedMedsCaveat(),
                  ),
                  for (final m in activeMeds) ...[
                    Divider(height: 1, thickness: 1, color: c.line2),
                    _LineRow(
                      title: m.name,
                      subtitle: recordedMedTiming(m),
                      documentIds: m.documentIds,
                      onOpenDoc: onOpenDoc,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一节 = 小标题(见 [_SectionLabel])+ 一张卡。空态那句话就在卡里。减法稿:
/// 标题前不再有图标。
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
      padding: const EdgeInsets.only(bottom: MedShape.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(title),
          MedCard(
            child: isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(MedShape.s3),
                    child: Text(emptyText, style: MedType.body.copyWith(color: c.ink2, height: 1.5)),
                  )
                : Column(children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
                      children[i],
                    ],
                  ]),
          ),
        ],
      ),
    );
  }
}

/// 这一屏上小标题的共用样式(13·400·ink3)。`_Section` 直接用这个 widget;
/// `_NotesSection`/`_DoctorMayAskSection`/`_MedsSubsection` 折叠头三处标题各自
/// 还带着别的东西同排(「加一条」按钮/免责声明段落/展开箭头),套不进同一个
/// `Padding` 外框(会跟同排的旁的东西对不齐左边),就地复用这里的
/// `MedType.secondary.copyWith(color: c.ink3)`。四处原来分 13/400 与 12/500
/// 两种字号各写各的,「记录中出现的药物」会随列表是不是空换字号——现在统一
/// 成这一份,不会再有第二种。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Text(text, style: MedType.secondary.copyWith(color: c.ink3)),
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
        padding: const EdgeInsets.symmetric(
          horizontal: MedShape.s3,
          vertical: MedShape.s2,
        ),
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
      // 措辞与趋势页复用同一个"· 家测"。
      // `valuesConverted` 见 `unitConvertedNote` —— 这一行的数值不是纸上印的那个
      // 时必须标注,趋势的化验快照(`trends_screen.dart` 的 `KeyLabsSnapshot`)
      // 用同一份措辞。
      meta: [
        lab.date,
        if (lab.selfMeasured) '家测',
        if (lab.valuesConverted) unitConvertedNote(lab.unit),
      ].join(' · '),
      // 云抽取图片档没能逐字核对上的行:照常显示,标出来。
      unverified: lab.unverified,
      onTap: () => onOpenDoc(lab.documentId),
    );
  }
}
