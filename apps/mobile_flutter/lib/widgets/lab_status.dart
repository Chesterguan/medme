import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart' show trendYDomain;

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

/// 原始 flag 字符串 → [LabStatus]。返回 null = **正常,什么都不画**——不给状态词、
/// 不给 pill,数值文字维持正文墨色 `MedColors.ink`(减法稿 2026-09-22:「正常
/// 不上色」,预检裁定 R2 的「正常档也上色」作废)。
///
/// ## `"N"` 也是正常,不是「读不懂的记号」
///
/// Rust 侧 flag 的取值域是 `"H" | "L" | "N" | null`(`packages/parser/src/labs.rs`
/// 的 `LabObservation::flag`;自测值走 `aggregate.rs` 同一套):有参考区间且值落在
/// 区间内就给 `"N"`,没有区间可判才给 `null`。这里曾经只认 H/L,于是 `"N"` 掉进
/// [LabStatus.unknown]——那一档的语义是「化验单上印了个我们不认识的记号,原样透出」,
/// 结果一个**内部编码**被当成印刷体印给了用户:22 项里 20 项各挂一个灰色「N」pill,
/// 真正的「偏高」淹在里面,而「HH」「危」这类**真读不懂**的记号跟例行正常值长得
/// 一模一样 —— 后面这条才是危险的地方。
///
/// ## 为什么不把 `"N"` 和 `null` 区分开
///
/// 两者的语义确实不同(「明确判定为正常」vs「没有标记/无从判断」),但在**这一层**
/// 不该区分,理由有三条:
///
/// 1. 这个函数的产出只喂给三样东西 —— [labStatusColor]、[labStatusWord]、刻度条
///    上圆点的颜色。而「正常」现在恰恰只有一种呈现:什么都不上色、不加字(减法稿
///    2026-09-22)。给「明确正常」再发明第四种视觉状态,就是这一条规则的直接违反。
/// 2. 信息没有丢:原始 `flag` 仍然挂在 DTO 上,谁要区分自己读。
/// 3. `"N"` 本来就是可推的 —— 它等价于「refLow/refHigh 至少有一个且值在区间内」,
///    而参考区间同一个 DTO 里就带着。
LabStatus? labStatusOf(String? flag) {
  final f = flag?.trim();
  if (f == null || f.isEmpty) return null;
  return switch (f.toUpperCase()) {
    'H' || '↑' => LabStatus.high,
    'L' || '↓' => LabStatus.low,
    'N' => null, // Rust 明确判定为正常 —— 与「没有标记」一样,什么都不画。
    _ => LabStatus.unknown,
  };
}

/// 状态 → 前景色。正常(`null`)与认不出的标记都是正文墨色——减法稿 2026-09-22:
/// **颜色只说状态,正常不上色**(预检裁定 R2 的「正常档也上色」作废)。
Color labStatusColor(BuildContext context, LabStatus? s) {
  final c = MedColors.of(context);
  return switch (s) {
    LabStatus.high => c.high,
    LabStatus.low => c.low,
    LabStatus.unknown || null => c.ink,
  };
}

/// 状态 → 右列那个词:「偏高」/「偏低」是上了色的字(无底,`statusWord`);认不出的
/// 标记原样透出成「看一眼」中性 chip(`MedPill.check`);正常**什么都不画、不加字**。
///
/// 色盲用户靠这个词读语义,正常视力靠颜色和刻度上的点——同一行里两种编码都在。
Widget? labStatusWord(BuildContext context, String? flag) {
  final c = MedColors.of(context);
  return switch (labStatusOf(flag)) {
    null => null,
    LabStatus.high => statusWord('偏高', c.high),
    LabStatus.low => statusWord('偏低', c.low),
    LabStatus.unknown => MedPill.check(flag!.trim()),
  };
}

/// 刻度条上三个位置(0–1):参考带起止与这次的值。值域用折线图同一个 [trendYDomain]
/// (上下各 20% 余量、两端界值都装得进去),所以「≥ 90」而实测 63 时,点在带子左外侧,
/// 而不是被夹到边上。**不做判定**:只是把三个数画在一条线上,颜色由 `flag` 决定。
({double bandFrom, double bandTo, double markerAt}) labRangeFractions({
  required double value,
  double? refLow,
  double? refHigh,
}) {
  final (lo, hi) = trendYDomain([value], refLow: refLow, refHigh: refHigh);
  double at(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  return (
    bandFrom: refLow == null ? 0.0 : at(refLow),
    bandTo: refHigh == null ? 1.0 : at(refHigh),
    markerAt: at(value),
  );
}

/// 细刻度条(减法稿 `.bar`):74×3 的浅条(`line`),参考区间那一段 `ink3` 压 30%,
/// 一枚 9px 圆点标出这次的值。没有参考区间时调用方不画它——没有带子,点就无从落位。
class LabRangeBar extends StatelessWidget {
  const LabRangeBar({super.key, required this.value, this.refLow, this.refHigh, required this.markerColor});

  final double value;
  final double? refLow;
  final double? refHigh;
  final Color markerColor;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final f = labRangeFractions(value: value, refLow: refLow, refHigh: refHigh);
    return SizedBox(
      width: MedBrand.rangeBarWidth,
      height: MedBrand.rangeMarkerSize,
      child: CustomPaint(
        painter: _RangeBarPainter(
          track: c.line,
          band: c.ink3.withValues(alpha: MedBrand.rangeBandAlpha),
          marker: markerColor,
          bandFrom: f.bandFrom,
          bandTo: f.bandTo,
          markerAt: f.markerAt,
        ),
      ),
    );
  }
}

class _RangeBarPainter extends CustomPainter {
  const _RangeBarPainter({
    required this.track, required this.band, required this.marker,
    required this.bandFrom, required this.bandTo, required this.markerAt,
  });

  final Color track;
  final Color band;
  final Color marker;
  final double bandFrom;
  final double bandTo;
  final double markerAt;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const h = MedBrand.rangeBarHeight;
    const r = Radius.circular(h / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - h / 2, size.width, h), r),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bandFrom * size.width, cy - h / 2, (bandTo - bandFrom) * size.width, h), r),
      Paint()..color = band,
    );
    canvas.drawCircle(Offset(markerAt * size.width, cy), MedBrand.rangeMarkerSize / 2, Paint()..color = marker);
  }

  @override
  bool shouldRepaint(covariant _RangeBarPainter o) =>
      o.track != track || o.band != band || o.marker != marker ||
      o.bandFrom != bandFrom || o.bandTo != bandTo || o.markerAt != markerAt;
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

/// 「已统一换算」标注 —— 一条趋势线上混了不同印刷单位时用。
///
/// 常态下 app 显示的数值/单位/参考区间就是化验单上**逐字印的**那一套(患者要拿
/// 屏幕去核对手里那张纸)。只有当同一指标的几份报告用了不同单位、一条线上没法
/// 同时画两种单位时,Rust 才把值和参考区间**一起**换算到规范单位(见
/// `packages/parser/src/aggregate.rs` 的「哪一层用哪一套单位」)。那一刻屏幕上的
/// 数字在用户那张纸上**找不到**,必须说出来 —— 不说等于改写原文
/// (`docs/007_UI_Guidelines.md` §2.1「原件永远可达」)。
///
/// 措辞只写这一份,「趋势」与「给医生看」共用 —— 同一件事在两个屏上不该有
/// 两种说法(与 `LabLine` 只有一个实现同源)。
String unitConvertedNote(String? unit) =>
    (unit == null || unit.isEmpty) ? '已统一换算' : '已统一换算为 $unit';

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

/// 一行化验的**唯一**渲染实现:无色条:名称 + 说明 | 数值 + 状态词 + 刻度条。
///
/// 「给医生看」与「趋势」共用它。规范 §七「三端映射」要求同一个化验值
/// 在哪里都长一样;同一端里的几个屏各写一遍,是同一个问题的更近版本 —— 「偏高」
/// 会变成几个略微不同的意思。
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
    this.unverified = false,
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

  /// 这个值**本机没能逐字核对上**(云抽取图片档;`VisitLabDto.unverified` /
  /// `TrendPointDto.unverified` 透传)。
  ///
  /// `true` 时这一行**照常显示**,只是多一枚「需核对」chip —— 丢掉它更糟:用户
  /// 看不到这个数,也就无从核对。这条是 spec §4 定的:图片档校验不过的行保留、
  /// 标记,不丢弃(文本档才整条丢)。
  final bool unverified;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final status = labStatusOf(flag);
    final word = labStatusWord(context, flag);
    final reviewPill = unverified ? MedPill.check('需核对') : null;
    final ref = refRangeText(refLow, refHigh);
    final sub = [
      if (meta case final m? when m.isNotEmpty) m,
      if (ref != null) '参考 $ref',
    ].join(' · ');
    // 认不出的标记不给圆点上色:我们不知道它是高是低。
    final markerColor = switch (status) {
      LabStatus.high => c.high,
      LabStatus.low => c.low,
      LabStatus.unknown || null => c.ink3,
    };
    final unitText = (unit == null || unit!.isEmpty)
        ? null
        : Text(unit!, style: MedType.caption.copyWith(fontSize: 12, color: c.ink3, fontWeight: FontWeight.w400));

    final right = ConstrainedBox(
      // R19 同款上限:长单位(`ml/min/1.73m2`)在 2× 字号下折到数值下一行,不把名字挤没。
      constraints: const BoxConstraints(maxWidth: MedBrand.trendValueMaxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 4,
            children: [
              Text(fmtLabNumber(value), style: MedType.value.copyWith(color: labStatusColor(context, status))),
              ?unitText,
            ],
          ),
          if (word != null) ...[const SizedBox(height: 2), word],
          if (refLow != null || refHigh != null) ...[
            const SizedBox(height: 4),
            LabRangeBar(value: value, refLow: refLow, refHigh: refHigh, markerColor: markerColor),
          ],
        ],
      ),
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    if (reviewPill != null) ...[reviewPill, const SizedBox(width: MedShape.s1)],
                    Flexible(child: Text(name, style: MedType.body.copyWith(
                        color: c.ink, fontWeight: FontWeight.w500, fontVariations: MedType.w500))),
                  ]),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub, style: MedType.secondary.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MedShape.s2),
            right,
            if (onTap != null) Icon(Icons.chevron_right, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
