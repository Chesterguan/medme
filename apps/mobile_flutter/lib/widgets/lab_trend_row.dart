// 化验「按指标」的一行(修订 2 返工,三层):① 名称 + 偏高/偏低 | 最近值大一号 + 单位;
// ② 整行宽迷你折线(淡灰参考带、异常点橙、最后一点实心、两端年月);③ 「最近 YYYY-MM-DD」。
// 整行点进折线页。用户原话:「你觉得好看吗?挤在一起,那个缩略图可以换行呀」。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 按名字搜(大小写不敏感的子串);空查询 → 原样返回。
List<TrendSeriesDto> trendSearch(List<TrendSeriesDto> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all.where((s) => s.name.toLowerCase().contains(q)).toList();
}

String _yearMonth(String iso) => iso.length >= 7 ? iso.substring(0, 7) : iso;

class LabTrendRow extends StatelessWidget {
  const LabTrendRow({
    super.key,
    required this.series,
    required this.onTap,
    this.range = ChartRange.oneYear,
    this.today,
  });

  final TrendSeriesDto series;
  final VoidCallback onTap;

  /// 顶部 chip 定的全局区间;迷你折线只画这段(这段没点就画全部)。
  final ChartRange range;
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final pts = trendDatedPoints(series);
    if (pts.isEmpty) return const SizedBox.shrink();
    final last = pts.last;
    final status = labStatusOf(last.flag);
    final word = labStatusWord(context, last.flag);
    final unit = cleanUnit(last.unit ?? series.unit);
    final inRange = pointsInRange(pts, range, anchor: today);
    final shown = inRange.isEmpty ? pts : inRange;
    final meta = MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular, fontWeight: FontWeight.w400);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MedShape.s2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 3,
                  child: Wrap(
                    spacing: MedShape.s1,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(series.name, style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w600)),
                      ?word,
                    ],
                  ),
                ),
                const SizedBox(width: MedShape.s2),
                // 长单位(换算说明)在大字号下折到数值下面,不顶出行外。
                Flexible(
                  flex: 2,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: 4,
                    children: [
                      Text(fmtLabNumber(last.value), style: MedType.value.copyWith(color: labStatusColor(context, status))),
                      if (unit != null && unit.isNotEmpty) Text(unit, style: MedType.secondary.copyWith(color: c.ink3)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LabLineChart(series: series, points: shown, height: 36, compact: true),
            Row(
              children: [
                Text(_yearMonth(shown.first.date!), style: meta),
                const Spacer(),
                if (shown.length > 1) Text(_yearMonth(shown.last.date!), style: meta),
              ],
            ),
            Text(
              [
                '最近 ${last.date}',
                if (series.selfMeasured) '家测',
                if (last.unverified) '需核对',
                if (series.valuesConverted) unitConvertedNote(unit),
              ].join(' · '),
              style: meta,
            ),
          ],
        ),
      ),
    );
  }
}
