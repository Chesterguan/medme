// 一个指标的折线页(修订 2 硬验收):完整折线(y 轴 / x 轴刻度 + 参考范围灰带)+ 时间范围切换
// (3 个月 / 半年 / 1 年 / 全部,初值跟化验页顶部的全局区间)+ 每个点可点回那份原件。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart' show trendDatedPoints;

class LabDetailScreen extends StatefulWidget {
  const LabDetailScreen({super.key, required this.series, this.onOpenDoc, this.initialRange = ChartRange.oneYear});

  final TrendSeriesDto series;
  final ChartRange initialRange;

  /// null → 真的那一套(push `DocumentDetailScreen`)。测试注入。
  final void Function(int docId)? onOpenDoc;

  @override
  State<LabDetailScreen> createState() => _LabDetailScreenState();
}

class _LabDetailScreenState extends State<LabDetailScreen> {
  late ChartRange _range = widget.initialRange;

  void _open(int docId) {
    if (widget.onOpenDoc != null) return widget.onOpenDoc!(docId);
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: docId)));
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final series = widget.series;
    final dated = trendDatedPoints(series);
    final inRange = pointsInRange(dated, _range);
    final undated = series.points.where((p) => p.date == null).toList();
    final unit = cleanUnit(series.unit);
    final ref = refRangeText(series.refLow, series.refHigh);
    final meta = MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular);
    return Scaffold(
      appBar: AppBar(title: Text(series.name, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
        children: [
          SegmentedButton<ChartRange>(
            segments: [
              for (final r in ChartRange.values) ButtonSegment(value: r, label: Text(kChartRangeLabel[r]!)),
            ],
            selected: {_range},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _range = s.first),
          ),
          const SizedBox(height: MedShape.s2),
          MedCard(
            child: Padding(
              padding: const EdgeInsets.all(MedShape.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (inRange.isEmpty)
                    Text('这段时间没有结果', style: MedType.secondary.copyWith(color: c.ink2))
                  else
                    LabLineChart(series: series, points: inRange, height: 200),
                  const SizedBox(height: MedShape.s1),
                  Wrap(
                    spacing: MedShape.s2,
                    runSpacing: 4,
                    children: [
                      if (unit != null) Text('单位 $unit', style: meta),
                      if (ref != null) Text('参考范围 $ref(灰带)', style: meta),
                      if (series.selfMeasured) Text('家测', style: meta),
                      if (series.valuesConverted) Text(unitConvertedNote(unit), style: meta),
                      Text(
                        inRange.length > kChartMaxRawPoints
                            ? '${inRange.length} 次 · 按周取中位数画线'
                            : '${inRange.length} 次',
                        style: meta,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: MedShape.s3),
          Text('每一次(点一行看那份原件)', style: MedType.caption.copyWith(color: c.ink2)),
          const SizedBox(height: MedShape.s1),
          MedCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, p) in [...inRange.reversed, ...undated].indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  InkWell(
                    onTap: () => _open(p.documentId.toInt()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
                      child: Row(
                        children: [
                          Text(p.date ?? '日期不详', style: MedType.secondary.copyWith(color: c.ink2, fontFeatures: MedType.tabular)),
                          const SizedBox(width: MedShape.s2),
                          Expanded(
                            child: Text(
                              '${fmtLabNumber(p.value)}${cleanUnit(p.unit) == null ? '' : ' ${cleanUnit(p.unit)}'}'
                              '${p.unverified ? ' · 需核对' : ''}',
                              textAlign: TextAlign.end,
                              style: MedType.body.copyWith(
                                color: labStatusColor(context, labStatusOf(p.flag)),
                                fontFeatures: MedType.tabular,
                              ),
                            ),
                          ),
                          const SizedBox(width: MedShape.s1),
                          ?labStatusWord(context, p.flag),
                          Icon(Icons.chevron_right, size: 18, color: c.ink3),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
