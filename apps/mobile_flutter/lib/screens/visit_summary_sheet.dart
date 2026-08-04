import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/qr_share_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/recorded_meds.dart';

/// 「就诊单」—— **刻意不是一个 tab**(设计系统 §八)。
///
/// 它是诊室里那 30 秒的动作:医生问「你最近吃什么药、过敏吗、上次化验多少」,你
/// 把手机递过去。这不是一个你会常驻浏览的空间,所以它没有底栏席位,而是从**概览**
/// 与**档案**两处以浮层唤起 —— 那两处正好是「日常打开」和「找单子」,进诊室前你
/// 本来就在其中之一。
///
/// 内容全部来自 `viewVisitSummary()`,而那个投影**只搬运原文逐字内容与抽出的
/// 数值/日期,不生成任何解释或结论**。这一屏也不加:没有「建议复查」,没有
/// 「病情稳定」。它是一页纸,不是一份意见。
Future<void> showVisitSummarySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _VisitSummarySheet(),
  );
}

class _VisitSummarySheet extends StatefulWidget {
  const _VisitSummarySheet();

  @override
  State<_VisitSummarySheet> createState() => _VisitSummarySheetState();
}

class _VisitSummarySheetState extends State<_VisitSummarySheet> {
  late final Future<VisitSummaryDto> _future = viewVisitSummary();

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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制,可以粘贴到微信发给医生')),
    );
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
                '生成就诊单失败:${snap.error}',
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
                Expanded(child: _body(context, s)),
                _actions(context, s),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context, VisitSummaryDto s) {
    final c = MedColors.of(context);
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
        Text('就诊单', style: MedType.title.copyWith(color: c.ink)),
        const SizedBox(height: 2),
        Text(
          '下面每一个字都逐字来自你已导入的病历。MedMe 不做判断,也不生成结论。',
          style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
        ),
        const SizedBox(height: MedShape.s4),

        if (who.isNotEmpty) ...[
          Text(who, style: MedType.subtitle.copyWith(color: c.ink)),
          const SizedBox(height: MedShape.s4),
        ],

        // 过敏史排在第一位,不是按数据量排的 —— 它是这一页里唯一一条**用错会
        // 当场出事**的信息。
        _Section(
          title: '过敏史',
          // 空过敏史必须自己说话:留白会被医生读成「无过敏史」,而我们只知道
          // 「已导入的这些纸上没写」。这两件事在临床上差着一条命。
          emptyText: '已导入的病历里没有找到过敏记录 —— 这不等于你不过敏,请当面告诉医生。',
          isEmpty: s.allergies.isEmpty,
          children: [
            for (final a in s.allergies)
              _LineRow(
                title: a.substance,
                subtitle: a.reaction.isEmpty ? null : a.reaction,
                documentIds: a.documentIds,
                onOpenDoc: _openDoc,
              ),
          ],
        ),

        _Section(
          title: kRecordedMedsTitle,
          emptyText: '已导入的病历里没有读到药名。',
          isEmpty: s.activeMeds.isEmpty,
          note: s.activeMeds.isEmpty ? null : const RecordedMedsCaveat(),
          children: [
            for (final m in s.activeMeds)
              _LineRow(
                title: m.name,
                subtitle: recordedMedTiming(m),
                documentIds: m.documentIds,
                onOpenDoc: _openDoc,
              ),
          ],
        ),

        _Section(
          title: '最近的关键化验',
          emptyText: '已导入的病历里没有可显示的化验数值。',
          isEmpty: s.recentLabs.isEmpty,
          children: [
            for (final l in s.recentLabs)
              _LabRow(lab: l, onOpenDoc: _openDoc),
          ],
        ),

        _Section(
          title: '最近就诊',
          emptyText: '还没有记录。',
          isEmpty: s.recentVisits.isEmpty,
          children: [
            for (final v in s.recentVisits)
              _LineRow(
                title: v.title ?? visitKindLabel(v.kind),
                subtitle: [
                  visitKindLabel(v.kind),
                  if (fmtDate(v.date).isNotEmpty) fmtDate(v.date),
                  '${v.documentIds.length} 份',
                ].join(' · '),
                documentIds: v.documentIds,
                onOpenDoc: _openDoc,
              ),
          ],
        ),
      ],
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
          // 二维码分享与就诊单是**两个场景**:就诊单是本地的、离线的、30 秒读完的
          // 一页纸;扫码是端到端加密、要联网、把**完整病历含原件**交出去。医生说
          // 「我要看原片」时才升级到这一步,所以它是次级按钮,不是并列。
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

/// 就诊单上的一节:标题 + 内容,或标题 + 一句诚实的空态。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.emptyText,
    required this.isEmpty,
    required this.children,
    this.note,
  });

  final String title;
  final String emptyText;
  final bool isEmpty;
  final List<Widget> children;
  final Widget? note;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: MedType.caption.copyWith(color: c.ink3),
          ),
          const SizedBox(height: MedShape.s1),
          if (isEmpty)
            Text(
              emptyText,
              style: MedType.body.copyWith(color: c.ink2, height: 1.5),
            )
          else ...[
            if (note != null) ...[note!, const SizedBox(height: MedShape.s1)],
            ...children,
          ],
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

/// 就诊单上的一行化验。渲染全部交给共用的 [LabLine] —— 同一个化验值在概览、
/// 就诊单、趋势三处必须长得一模一样,否则「偏高」就成了三个意思(规范 §七)。
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
      meta: lab.date,
      onTap: () => onOpenDoc(lab.documentId),
    );
  }
}
