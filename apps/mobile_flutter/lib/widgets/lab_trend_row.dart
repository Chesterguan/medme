// 化验「按指标」的一张卡(修订 2 返工,三层):① 名称可换行两行(中文名,英文原名灰字小一号在其下)
// + 偏高/偏低 | 右侧最近值 + 单位固定宽度不参与换行;② 整行宽 48 高迷你折线(淡灰参考带、≤ 12 点画点
// + 连线、更多只画线、最后一点实心,x 按时间等比);③ 「最近 YYYY-MM-DD」+ 偏高/偏低。整卡点进折线页。
// 用户原话:「如果 lab 的名字太长还会崩,重新设计一下,不用挤在一行里面的,每一个 lab 一个块呀」。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 按名字搜(大小写不敏感的子串;中文名或英文原名);空查询 → 原样返回。
List<TrendSeriesDto> trendSearch(List<TrendSeriesDto> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all.where((s) => s.name.toLowerCase().contains(q) || (s.rawName ?? '').toLowerCase().contains(q)).toList();
}

/// 右侧「最近值 + 单位」那一栏的固定宽度(不参与名称换行)。
const double kLabValueColumnWidth = 112;

/// 迷你折线的高度。
const double kLabMiniChartHeight = 48;

class LabTrendCard extends StatelessWidget {
  const LabTrendCard({
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
    final raw = series.rawName;
    final meta = MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular, fontWeight: FontWeight.w400);
    return MedCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MedShape.s2, MedShape.s2, MedShape.s2, MedShape.s1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          series.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w600),
                        ),
                        if (raw != null && raw.isNotEmpty && raw != series.name)
                          Text(raw, maxLines: 2, overflow: TextOverflow.ellipsis, style: MedType.caption.copyWith(color: c.ink3)),
                      ],
                    ),
                  ),
                  const SizedBox(width: MedShape.s1),
                  SizedBox(
                    width: kLabValueColumnWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(fmtLabNumber(last.value), style: MedType.value.copyWith(color: labStatusColor(context, status))),
                        ),
                        if (unit != null && unit.isNotEmpty)
                          Text(
                            unit,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: MedType.secondary.copyWith(color: c.ink3),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: MedShape.s1),
              if (shown.length == 1)
                SizedBox(
                  height: kLabMiniChartHeight,
                  child: Row(
                    children: [
                      Expanded(child: LabLineChart(series: series, points: shown, height: kLabMiniChartHeight, compact: true)),
                      Text('仅 1 次', style: meta),
                    ],
                  ),
                )
              else
                LabLineChart(series: series, points: shown, height: kLabMiniChartHeight, compact: true),
              // 两端年月小字(规格里有):单点只写左边。
              Row(
                children: [
                  Text(shown.first.date!.substring(0, 7), style: meta),
                  const Spacer(),
                  if (shown.length > 1) Text(shown.last.date!.substring(0, 7), style: meta),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        '最近 ${last.date}',
                        if (series.selfMeasured) '家测',
                        if (last.unverified) '需核对',
                        if (series.valuesConverted) unitConvertedNote(unit),
                      ].join(' · '),
                      style: meta,
                    ),
                  ),
                  ?word,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
