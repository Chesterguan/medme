// 化验趋势行(2026-10-23 spec §4.2):名称 + 78×24 迷你折线 + 最近值 + 偏高/偏低;
// 第二行参考区间 + 日期;点开原地放大成 96 高折线 + 历年数值行,每个点可点回原件。
// 用户原话:「化验值没有折线图不容易看」。原趋势页 SeriesCard 的 78×24 占位从没放过真折线,
// 这里直接用现成的 TrendChart(只靠 height 定尺寸,无文字)。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 按名字搜(大小写不敏感的子串);空查询 → 原样返回。
List<TrendSeriesDto> trendSearch(List<TrendSeriesDto> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  return all.where((s) => s.name.toLowerCase().contains(q)).toList();
}

class LabTrendRow extends StatefulWidget {
  const LabTrendRow({super.key, required this.series, required this.onOpenDoc, this.onTap});

  final TrendSeriesDto series;
  final void Function(int docId) onOpenDoc;

  /// 给了就整行点它(修订 2:「按指标」点一行进折线页),不再原地展开。
  final VoidCallback? onTap;

  @override
  State<LabTrendRow> createState() => _LabTrendRowState();
}

class _LabTrendRowState extends State<LabTrendRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final series = widget.series;
    final pts = trendDatedPoints(series);
    if (pts.isEmpty) return const SizedBox.shrink();
    final last = pts.last;
    final status = labStatusOf(last.flag);
    final word = labStatusWord(context, last.flag);
    final ref = refRangeText(series.refLow, series.refHigh);
    final unit = last.unit ?? series.unit;
    final meta = MedType.caption.copyWith(
      color: c.ink3,
      fontFeatures: MedType.tabular,
      fontWeight: FontWeight.w400,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: widget.onTap ?? () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: MedShape.s1,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(series.name, style: MedType.body.copyWith(color: c.ink)),
                          ?word,
                        ],
                      ),
                    ),
                    const SizedBox(width: MedShape.s2),
                    // 迷你折线:不描画动画(一屏几十条,每条起一个 ticker 没有意义)。
                    SizedBox(
                      width: 78,
                      height: 24,
                      child: TrendChart(series: series, height: 24, animate: false),
                    ),
                    const SizedBox(width: MedShape.s2),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: MedBrand.trendValueMaxWidth),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 4,
                        children: [
                          Text(
                            fmtLabNumber(last.value),
                            style: MedType.value.copyWith(color: labStatusColor(context, status)),
                          ),
                          if (unit != null && unit.isNotEmpty)
                            Text(unit, style: MedType.secondary.copyWith(color: c.ink3)),
                          Icon(
                            widget.onTap != null
                                ? Icons.chevron_right
                                : (_expanded ? Icons.expand_less : Icons.expand_more),
                            size: 18,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: MedShape.s2,
                  runSpacing: 2,
                  children: [
                    if (ref != null) Text('参考 $ref', style: meta),
                    if (last.date != null) Text(last.date!, style: meta),
                    if (series.selfMeasured) Text('家测', style: meta),
                    if (last.unverified) Text('需核对', style: meta),
                    if (series.valuesConverted) Text(unitConvertedNote(unit), style: meta),
                    Text(
                      pts.length == 1 ? '只有这一次' : '${pts.first.date} 起 ${pts.length} 次',
                      style: meta,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          Container(
            decoration: const BoxDecoration(color: MedBrand.expandedChartBg),
            padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
            child: TrendChart(series: series, height: 96),
          ),
          for (final p in pts.reversed)
            InkWell(
              onTap: () => widget.onOpenDoc(p.documentId.toInt()),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text(p.date ?? '', style: meta.copyWith(color: c.ink2)),
                    const SizedBox(width: MedShape.s2),
                    // 长单位(换算说明)在大字号下折行,不顶出行外。
                    Expanded(
                      child: Text(
                        '${fmtLabNumber(p.value)}${p.unit == null || p.unit!.isEmpty ? '' : ' ${p.unit}'}'
                        '${p.unverified ? ' · 需核对' : ''}',
                        textAlign: TextAlign.end,
                        style: MedType.secondary.copyWith(
                          color: labStatusColor(context, labStatusOf(p.flag)),
                          fontFeatures: MedType.tabular,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 16, color: c.ink3),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
