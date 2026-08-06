import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 「病情摘要卡」(审阅屏选项 b 的核心):在治的病 + 关键化验 + 在用药,三十秒看懂
/// 这次代拍收上来的大局。数据来自 `EphemeralSession.summary()`(`ProxySummaryDto`,
/// Rust 侧复用与「生成加密分享」同一套 `parser::assemble_summary` 装配)。措辞与信息
/// 层级参考 `qr_share_screen.dart`「医生看到的是什么」一段:在治的疾病 · 关键化验的
/// 近期趋势 · 正在吃的药。
///
/// 干净的原生卡片:每个问题一块,内嵌它的化验(项目/最近值/趋势箭头)与在用药
/// (chips),不做图表——「清楚够用就行」。没有任何结构化问题时不占地方(原文仍在
/// 审阅屏下方「逐份识别内容」区块完整展开,不丢信息)。
///
/// **整张卡不带医生模式的紫。** 卡里全是**病人的数据**(疾病、化验、用药),不是
/// 界面 chrome —— 同一份数据在哪个模式下都该长一样,所以这里只用中性色与化验状态
/// 色。紫色留给「这是代拍」那类关于**当前模式**的信号(横幅、主按钮、图标底)。
///
/// **不带骑缝线**:这是从若干份已确认文档算出来的汇总,背后没有「某一张纸」可点
/// 进去(规范 §五)。
class ProxySummaryCard extends StatelessWidget {
  const ProxySummaryCard({super.key, required this.summary});

  final ProxySummaryDto summary;

  @override
  Widget build(BuildContext context) {
    if (summary.problems.isEmpty) return const SizedBox.shrink();
    final c = MedColors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        0,
        MedShape.s3,
        MedShape.s2,
      ),
      child: MedCard(
        child: Padding(
          padding: const EdgeInsets.all(MedShape.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('病情摘要', style: MedType.subtitle.copyWith(color: c.ink)),
              const SizedBox(height: 2),
              Text(
                '在治的病、关键化验、正在吃的药 —— 给医生三十秒看懂大局',
                style: MedType.secondary.copyWith(color: c.ink3),
              ),
              for (final p in summary.problems) ...[
                const SizedBox(height: MedShape.s2),
                _ProblemBlock(problem: p),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProblemBlock extends StatelessWidget {
  const _ProblemBlock({required this.problem});

  final ProxyProblemDto problem;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusChip(
          term: problem.term,
          status: problem.status,
          warn: problem.warn,
        ),
        if (problem.labs.isNotEmpty) ...[
          const SizedBox(height: MedShape.s1),
          for (final l in problem.labs) _LabRow(lab: l),
        ],
        if (problem.meds.isNotEmpty) ...[
          const SizedBox(height: MedShape.s1),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final m in problem.meds) _MedChip(med: m)],
          ),
        ],
      ],
    );
  }
}

/// 一个「在治的问题」的名牌:病名 + 状态。
///
/// **只有 `warn` 才上色(危急红),不 warn 的一律中性** —— 与「正常不上色」同一条
/// 道理(规范 §二):一个病人常有 4–6 条问题,若条条都染成主色,真正在报警的那条
/// 就被淹没了。原先不 warn 走 teal(= 个人模式主色),在医生模式里既错色又稀释
/// 语义;原先 warn 那个 `#FDECEF` 也是裸色值,现在归位到令牌 `criticalWash`。
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.term,
    required this.status,
    required this.warn,
  });

  final String term;
  final String status;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final Color fg = warn ? c.critical : c.ink;
    final Color bg = warn ? c.criticalWash : c.line2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: MedShape.s1, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            term,
            style: MedType.body.copyWith(
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
          const SizedBox(width: 6),
          // 状态提到 12(规范下限),原先 11 低于下限。
          Text(status, style: MedType.caption.copyWith(color: fg)),
        ],
      ),
    );
  }
}

// 化验行:项目 最近值 单位 ↑/↓/→。异常配色统一走设计系统 v1 令牌
// (`MedColors.high` / `MedColors.low`),与 `widgets/report_content.dart` 同源 ——
// 这两个色值不再在任何屏里复述,改一处全 app 生效。
//
// **医生模式不碰这里的任何一个颜色。** 同一份化验值在个人模式和医生模式下必须
// 长得一模一样,否则「偏高」就成了两个意思。

class _LabRow extends StatelessWidget {
  const _LabRow({required this.lab});

  final ProxyLabDto lab;

  @override
  Widget build(BuildContext context) {
    final tokens = MedColors.of(context);
    final abnormalHigh = lab.refHigh != null && lab.latestValue > lab.refHigh!;
    final abnormalLow = lab.refLow != null && lab.latestValue < lab.refLow!;
    // 正常不上色,继承正文墨色。
    final color = abnormalHigh
        ? tokens.high
        : abnormalLow
        ? tokens.low
        : tokens.ink;
    final value = _fmtValue(lab.latestValue);
    final unit = lab.unit ?? '';
    final arrow = switch (lab.trend) {
      'up' => '↑',
      'down' => '↓',
      'flat' => '→',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              lab.name,
              style: MedType.secondary.copyWith(color: tokens.ink),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 等宽表格数字:一列化验值的小数点必须对齐(规范 §三)。
          Text(
            '$value$unit',
            style: MedType.secondary.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: MedType.tabular,
              color: color,
            ),
          ),
          if (arrow.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              arrow,
              style: MedType.secondary.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _fmtValue(double v) {
  // 整数值不带尾随 .0(88.0 → 88),与 `parser::aggregate::fmt_num` 同一惯例。
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

/// 一味药的 chip。**在用 = 满墨色实边,停用 = 三级墨色淡边**,不用颜色区分。
///
/// 原先在用是 emerald 绿(`#ECFDF5`/`#D1FAE5`/`#047857`)—— 绿不在规范色板里,而且
/// 「绿 = 安全」正是规范 §二 刻意不做的暗示(一味在吃的药并不因此就是安全的)。
/// `widgets/report_content.dart` 的 `_MedItemCard` 已经因为同一条理由去掉了这套绿,
/// 这里跟上,两个模式的用药清单不再一个绿一个不绿。
class _MedChip extends StatelessWidget {
  const _MedChip({required this.med});

  final ProxyMedDto med;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final label = med.dose != null ? '${med.name} ${med.dose}' : med.name;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: MedShape.s1, vertical: 5),
      decoration: BoxDecoration(
        color: c.paper,
        borderRadius: BorderRadius.circular(MedShape.radiusControl),
        border: Border.all(color: med.active ? c.line : c.line2),
      ),
      child: Text(
        label,
        style: MedType.secondary.copyWith(
          fontWeight: med.active ? FontWeight.w600 : FontWeight.w400,
          color: med.active ? c.ink : c.ink3,
        ),
      ),
    );
  }
}
