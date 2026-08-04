import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 化验状态的**唯一**映射点:`TrendPointDto.flag` / `VisitLabDto.flag` 这类
/// **Rust 给的原始标记字符串** → 颜色与文字 pill。
///
/// ## 这里绝不做判定
///
/// 007 §2.5 与设计系统 §二 都写死了同一条:「所有『怎么算』在 Rust,UI 只
/// 『怎么显示』」。所以这个文件里**没有** `value < refLow` 这种代码,一行都没有。
/// 三个投影 DTO 每个点都自带 `refLow`/`refHigh`,拿来反推异常是**唾手可得**的
/// —— 也正因为唾手可得,才要在这里把话说清楚:那样做就是「五处渲染各写一遍
/// 判定」这条债的复发,而手机、桌面、查看器三端算出来的边界条件不会永远一致。
/// 参考区间在 UI 里只有一个用途:**显示给人看**,以及画趋势图的参考带。
///
/// hosted-viewer 的 `sparkSVG` 用 `sumFlag(value, refLow, refHigh)` 就地重算了
/// 点的颜色 —— 那是查看器的历史包袱,**不要抄过来**。这里一律用 `flag`。
///
/// ## 认不出来的标记不吞
///
/// Rust 侧说 flag「通常是 H/L」,也就是**不保证**。认不出的标记(某些医院印
/// 「HH」「危」「*」)一律**原样显示成不上色的 pill**,而不是当成正常悄悄丢掉:
/// 化验单上印了个记号,我们读到了却不显示,比显示得难看危险得多。
enum LabStatus {
  /// 偏低 —— 化验单上印了 `L` / `↓`。
  low,

  /// 偏高 —— 化验单上印了 `H` / `↑`。
  high,

  /// 化验单上印了个我们不认识的记号。**原样透出,不上色。**
  unknown,
}

/// 原始 flag 字符串 → [LabStatus]。没有标记(null / 空串)返回 null = 正常,
/// **正常不上色**(设计系统 §二:一份血常规 22 项只有 1–2 项异常,给正常配色会
/// 把异常淹没)。
LabStatus? labStatusOf(String? flag) {
  final f = flag?.trim();
  if (f == null || f.isEmpty) return null;
  return switch (f.toUpperCase()) {
    'H' || '↑' => LabStatus.high,
    'L' || '↓' => LabStatus.low,
    _ => LabStatus.unknown,
  };
}

/// 状态 → 前景色。正常与「认不出的标记」都继承正文墨色。
///
/// 认不出的标记刻意**不上色**:我们不知道它是高是低,涂个颜色就是在替化验单
/// 下一个我们没读懂的结论。
Color labStatusColor(BuildContext context, LabStatus? s) {
  final c = MedColors.of(context);
  return switch (s) {
    LabStatus.high => c.high,
    LabStatus.low => c.low,
    LabStatus.unknown || null => c.ink,
  };
}

/// 状态 → 左侧色条色。正常/未知是**透明**的,但色条本身照画 —— 3px 的占位恒定,
/// 整列文字起点才不会因为有没有色条而左右跳(与 `report_content.dart` 同一处理)。
Color labStripeColor(BuildContext context, LabStatus? s) {
  final c = MedColors.of(context);
  return switch (s) {
    LabStatus.high => c.high,
    LabStatus.low => c.low,
    LabStatus.unknown || null => Colors.transparent,
  };
}

/// 状态 → 文字 pill。正常不给 pill;未知给一个中性 pill,**文字是原始标记本身**。
///
/// 状态同时编码在色条和 pill 上:色盲用户靠 pill 读语义,正常视力扫视靠色条
/// (设计系统 §二)。少任何一个,就有一类用户读不到这一行的结论。
///
/// ⚠️ 规范的第四级「危急值」这里画不出来:它得由 Rust 明确给出,而当前三个投影
/// DTO 的 `flag` 里没有这一级。**不在 UI 层拿参考区间反推** —— 令牌 `critical` /
/// `criticalWash` 因此在化验语境下暂时无人消费,等抽取侧补上。
Widget? labStatusPill(BuildContext context, String? flag) {
  final c = MedColors.of(context);
  final s = labStatusOf(flag);
  return switch (s) {
    null => null,
    LabStatus.high => MedPill(
      text: '偏高',
      foreground: c.high,
      background: c.highWash,
    ),
    LabStatus.low => MedPill(
      text: '偏低',
      foreground: c.low,
      background: c.lowWash,
    ),
    // 原样透出。底色用中性的 `line2`,读起来是「单子上还印了个这个」,
    // 不是任何一档临床结论。
    LabStatus.unknown => MedPill(
      text: flag!.trim(),
      foreground: c.ink2,
      background: c.line2,
    ),
  };
}

/// 参考区间 → 一行可读文本(`4.00–10.00`)。两端都没有时返回 null。
///
/// 破折号用 `–`(en dash)而不是 `-`,与规范样例、化验单印刷体一致。
String? refRangeText(double? low, double? high) {
  if (low == null && high == null) return null;
  if (low == null) return '≤ ${fmtLabNumber(high!)}';
  if (high == null) return '≥ ${fmtLabNumber(low)}';
  return '${fmtLabNumber(low)}–${fmtLabNumber(high)}';
}

/// 化验数值 → 显示文本。
///
/// **不做任何四舍五入的「美化」** —— 化验值的有效位数是临床信息(`171` 与
/// `171.0` 在化验单上不是一回事)。这里只做一件事:把 Dart `double` 打印整数时
/// 会带出来的 `.0` 去掉,因为那个 `.0` 是 IEEE 754 的产物,不是化验单上印的东西。
String fmtLabNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toStringAsFixed(0);
  }
  return v.toString();
}

/// 一行化验的**唯一**渲染实现:左侧状态色条 + 名称 + pill + 次要说明 + 右侧数值。
///
/// 概览、就诊单浮层、趋势页共用它。规范 §七「三端映射」要求同一个化验值在哪里都
/// 长一样;同一端里的三个屏各写一遍,是同一个问题的更近版本 —— 「偏高」会变成
/// 三个略微不同的意思。
class LabLine extends StatelessWidget {
  const LabLine({
    super.key,
    required this.name,
    required this.value,
    this.unit,
    this.flag,
    this.refLow,
    this.refHigh,
    this.meta,
    this.onTap,
  });

  final String name;
  final double value;
  final String? unit;

  /// **Rust 给的原始标记**。UI 不从 [refLow]/[refHigh] 反推 —— 见本文件头。
  final String? flag;

  /// 参考区间。只用于**显示**给人看,不参与任何判定。
  final double? refLow;
  final double? refHigh;

  /// 次要说明行开头额外加的一段(通常是日期)。参考区间会自动接在它后面。
  final String? meta;

  /// 点进原件。为 null 时不显示箭头 —— **不给点不动的行画箭头**,那是假承诺。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final status = labStatusOf(flag);
    final pill = labStatusPill(context, flag);
    final ref = refRangeText(refLow, refHigh);
    final sub = [
      if (meta case final m? when m.isNotEmpty) m,
      if (ref != null) '参考 $ref',
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MedShape.radiusControl),
      child: Container(
        // 3px 色条恒定占位(正常行透明)—— 整列文字起点不会因为有没有色条而左右跳。
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: labStripeColor(context, status), width: 3),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          MedShape.s2,
          MedShape.s1,
          0,
          MedShape.s1,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 名称 + pill 用 Wrap:系统字号放大后这一行必须能折,不能把
                  // 项目名省略成两个字(007 §2.5「字号可放大,不可砍」)。
                  Wrap(
                    spacing: MedShape.s1,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(name, style: MedType.body.copyWith(color: c.ink)),
                      ?pill,
                    ],
                  ),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      style: MedType.secondary.copyWith(
                        color: c.ink3,
                        fontFeatures: MedType.tabular,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MedShape.s2),
            Text(
              [
                fmtLabNumber(value),
                if (unit case final u? when u.isNotEmpty) u,
              ].join(' '),
              style: MedType.body.copyWith(
                color: labStatusColor(context, status),
                fontWeight: FontWeight.w600,
                fontFeatures: MedType.tabular,
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
