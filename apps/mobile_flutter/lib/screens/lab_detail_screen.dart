// 一个指标的折线页(修订 2 硬验收):完整折线 + 参考范围带 + 每个点可点回那份原件。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

class LabDetailScreen extends StatelessWidget {
  const LabDetailScreen({super.key, required this.series, this.onOpenDoc});

  final TrendSeriesDto series;

  /// null → 真的那一套(push `DocumentDetailScreen`)。测试注入。
  final void Function(int docId)? onOpenDoc;

  void _open(BuildContext context, int docId) {
    if (onOpenDoc != null) return onOpenDoc!(docId);
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: docId)));
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final pts = trendDatedPoints(series);
    // 没有日期的点画不上轴,但原件照样可达(「原件永远可达」):列在最后。
    final undated = series.points.where((p) => p.date == null).toList();
    final ref = refRangeText(series.refLow, series.refHigh);
    final meta = MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular);
    return Scaffold(
      appBar: AppBar(title: Text(series.name, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
        children: [
          MedCard(
            child: Padding(
              padding: const EdgeInsets.all(MedShape.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TrendChart(series: series, height: 160),
                  const SizedBox(height: MedShape.s1),
                  Wrap(
                    spacing: MedShape.s2,
                    runSpacing: 4,
                    children: [
                      if (ref != null) Text('参考范围 $ref(底色带)', style: meta),
                      if (series.selfMeasured) Text('家测', style: meta),
                      if (series.valuesConverted) Text(unitConvertedNote(series.unit), style: meta),
                      Text(pts.isEmpty ? '' : '${pts.first.date} 起 ${pts.length} 次', style: meta),
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
                for (final (i, p) in [...pts.reversed, ...undated].indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  InkWell(
                    onTap: () => _open(context, p.documentId.toInt()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
                      child: Row(
                        children: [
                          Text(p.date ?? '日期不详', style: MedType.secondary.copyWith(color: c.ink2, fontFeatures: MedType.tabular)),
                          const SizedBox(width: MedShape.s2),
                          Expanded(
                            child: Text(
                              '${fmtLabNumber(p.value)}${p.unit == null || p.unit!.isEmpty ? '' : ' ${p.unit}'}'
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
