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
/// 概览、「看病带这个」浮层、趋势页共用它。规范 §七「三端映射」要求同一个化验值
/// 在哪里都长一样;同一端里的三个屏各写一遍,是同一个问题的更近版本 —— 「偏高」
/// 会变成三个略微不同的意思。
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
        child: LayoutBuilder(
          builder: (context, box) {
            final nameText = Text(
              name,
              style: MedType.body.copyWith(color: c.ink),
            );
            final valueText = Text(
              [
                fmtLabNumber(value),
                if (unit case final u? when u.isNotEmpty) u,
              ].join(' '),
              style: MedType.body.copyWith(
                color: labStatusColor(context, status),
                fontWeight: FontWeight.w600,
                fontFeatures: MedType.tabular,
              ),
            );
            final subText = sub.isEmpty
                ? null
                : Text(
                    sub,
                    style: MedType.secondary.copyWith(
                      color: c.ink3,
                      fontFeatures: MedType.tabular,
                    ),
                  );
            final chevron = onTap == null
                ? null
                : Icon(Icons.chevron_right, size: 20, color: c.ink3);

            // 「名字 + pill + 数值」放不放得下同一行,**实测量,不猜**。
            //
            // 窄屏 + 长名 + 长单位(`估算肾小球滤过率` / `ml/min/1.73m2`)在任何
            // 合理字号下本来就挤不进一行 —— 硬并排的结果是各种难看形态:pill 被
            // 顶到独占一行、数值折成 `63 ml/min/` + `1.73m2`、名字被挤到第二行。
            // 那些形态在「不溢出」的意义上都是合格的,看着却是坏的。
            //
            // 所以放不下时**改成为两行而设计**(名字+pill 一行,数值单独一行右对齐),
            // 而不是继续挤。放得下时保持并排 —— 宽屏与短名不该白白多占一行。
            // `Text('文字')` 把内容放在 `data`,`textSpan` 是 null —— 直接取
            // `textSpan` 会 StateError。这里按 data + style 自己搭 span。
            double probe(Text w) {
              final tp = TextPainter(
                text: TextSpan(text: w.data ?? '', style: w.style),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: double.infinity);
              return tp.width;
            }
            final pillW = pill == null ? 0.0 : 56.0; // pill 的保守估宽,宁可早换行
            final chevronW = chevron == null ? 0.0 : 20.0;
            final needed =
                probe(nameText) +
                pillW +
                MedShape.s1 +
                MedShape.s2 +
                probe(valueText) +
                chevronW;
            final sideBySide = needed <= box.maxWidth;

            // pill 与名字**必须待在同一行里**,所以是 `Row` 而不是 `Wrap`。`Wrap` 在
            // 宽度不够时会把名字甩到第二个 run,产出的形态是:
            //
            //     [N]                  2.75 mmol/L ›
            //     低密度脂蛋白胆固醇
            //
            // pill 孤零零地跟数值待在一起,而它标注的那个名字在下一行 —— 一个飘着的
            // 状态标记比没有标记更糟。名字用 `Flexible`:宽度真不够时它自己折行变高,
            // pill 和数值都不动。
            final head = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (pill != null) ...[pill, const SizedBox(width: MedShape.s1)],
                Flexible(child: nameText),
              ],
            );

            // 次要说明行**两个分支都整宽**。它一度被放在并排分支左边那个 `Expanded`
            // 列里,于是只拿得到「总宽减去数值和箭头」的宽度 —— 而它下面右边根本没有
            // 东西占着。真机 360dp 上的后果是把参考区间从中间劈开:
            //
            //     2026-02-14 · 参考 3.1–
            //     8
            //
            // 一个被折断的数字比难看更糟:那个孤零零的 `8` 读起来像另一个值。
            if (sideBySide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 数值是**非 flex 子项**,这一点是有代价换来的:它和 `Expanded`
                      // 的 head 都写成 flex 时,`RenderFlex` 会把可用宽度**对半分**
                      // (两个 flex:1),而不是「数值取它需要的、剩下全给名字」。
                      //
                      // 411dp 上算出来:可用 ~375,减非 flex 的 8+20,余 347,对半
                      // 各 ~173。而「[N] 低密度脂蛋白胆固醇」需要 ~196(名字 144 +
                      // pill 44 + 间距 8)—— 差 23dp,于是名字被挤下去。360dp 的
                      // 华为反而看不到:那边这一行走的是下面的窄分支。
                      //
                      // 非 flex 子项先按固有宽度布局,`Expanded` 拿剩下的全部,这才是
                      // 想要的分配。上面的测量已经保证放得下;万一估偏了,head 里的
                      // `Flexible(nameText)` 会让名字折行,pill 和数值仍在原位。
                      Expanded(child: head),
                      const SizedBox(width: MedShape.s2),
                      valueText,
                      ?chevron,
                    ],
                  ),
                  if (subText != null) ...[const SizedBox(height: 2), subText],
                ],
              );
            }
            // 窄:名字+pill 一行,数值自己一行(右对齐,箭头跟着数值走)。
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                head,
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: valueText,
                      ),
                    ),
                    ?chevron,
                  ],
                ),
                if (subText != null) ...[const SizedBox(height: 2), subText],
              ],
            );
          },
        ),
      ),
    );
  }
}
