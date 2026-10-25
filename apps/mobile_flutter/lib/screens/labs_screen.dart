// 「化验」tab(修订 2,照 MyChart Test Results):顶部「按报告 / 按指标」切换。
// 按报告 = 一张化验单一行,点开是项目 / 数值 / 单位 / 参考 / 箭头的表;
// 按指标 = 一项一行(最近值 + 迷你折线 + 日期),chip + 搜索,12 个月没结果的收进「更早」,
// 点开是完整折线页(`LabDetailScreen`)。用户原话:「化验的折线是必须要有的」。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/lab_detail_screen.dart';
import 'package:mobile_flutter/screens/labs_model.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/provenance_footer.dart';

/// 报告列表 + 全部序列。
typedef LabsData = (List<LabReportDto> reports, List<TrendSeriesDto> series);

Future<LabsData> _loadFromVault() async {
  final r = await Future.wait<Object>([viewLabReports(), viewTrends()]);
  return (r[0] as List<LabReportDto>, r[1] as List<TrendSeriesDto>);
}

enum LabsMode { reports, analytes }

class LabsScreen extends StatefulWidget {
  const LabsScreen({super.key, this.load, this.today});

  /// null → 真的那一套(FFI)。测试注入。
  final Future<LabsData> Function()? load;

  /// 12 个月窗的「今天」;null → `DateTime.now()`。
  final DateTime? today;

  @override
  State<LabsScreen> createState() => _LabsScreenState();
}

class _LabsScreenState extends State<LabsScreen> {
  late Future<LabsData> _future = _load();
  LabsMode _mode = LabsMode.reports;
  String _group = kAllGroup;
  final _queryCtl = TextEditingController();
  String _query = '';
  bool _searchOpen = false;

  Future<LabsData> _load() => (widget.load ?? _loadFromVault)();

  @override
  void initState() {
    super.initState();
    vaultRevision.addListener(_onVaultChanged);
  }

  @override
  void dispose() {
    _queryCtl.dispose();
    vaultRevision.removeListener(_onVaultChanged);
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) _refresh();
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() {
      _future = next;
    });
    await next;
  }

  void _toggleSearch() {
    if (!_searchOpen) {
      Analytics.track(AnalyticsEvent.trendsFilterUsed, {'control': TrendsFilterControl.search.name});
    }
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _queryCtl.clear();
        _query = '';
      }
    });
  }

  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
  }

  void _openSeries(TrendSeriesDto s) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LabDetailScreen(series: s)));
  }

  void _openReport(LabReportDto r, List<TrendSeriesDto> series) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LabReportScreen(report: r, series: series)),
    );
  }

  void _showProvenance() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: const SingleChildScrollView(child: ProvenanceFooter()),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('知道了'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: _searchOpen
            ? TextField(
                controller: _queryCtl,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v.trim()),
                textInputAction: TextInputAction.search,
                style: MedType.subtitle.copyWith(color: c.ink),
                decoration: InputDecoration(
                  hintText: '搜指标名,如「肌酐」「血红蛋白」',
                  hintStyle: MedType.subtitle.copyWith(color: c.ink3),
                  border: InputBorder.none,
                  isDense: true,
                ),
              )
            : const Text('化验'),
        actions: [
          if (_mode == LabsMode.analytes)
            IconButton(
              icon: Icon(_searchOpen ? Icons.close : Icons.search),
              color: c.ink2,
              tooltip: _searchOpen ? '关闭搜索' : '按名字搜指标',
              onPressed: _toggleSearch,
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            color: c.ink2,
            tooltip: '参考区间的出处',
            onPressed: _showProvenance,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<LabsData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(MedShape.s6),
                    child: Text('这一页暂时打不开。下拉可重试。',
                        textAlign: TextAlign.center, style: MedType.body.copyWith(color: c.ink2, height: 1.6)),
                  ),
                ],
              ),
            );
          }
          final (reports, series) = snap.data!;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s2, MedShape.s3, 0),
                child: SegmentedButton<LabsMode>(
                  segments: const [
                    ButtonSegment(value: LabsMode.reports, label: Text('按报告')),
                    ButtonSegment(value: LabsMode.analytes, label: Text('按指标')),
                  ],
                  selected: {_mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  color: c.seal,
                  child: _mode == LabsMode.reports
                      ? LabReportsList(reports: reports, onOpen: (r) => _openReport(r, series))
                      : LabAnalytesList(
                          series: series,
                          group: _group,
                          query: _query,
                          today: widget.today ?? DateTime.now(),
                          onSelectGroup: (g) => setState(() => _group = g),
                          onOpenSeries: _openSeries,
                          onOpenDoc: _openDoc,
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 按报告:一张单一行「血常规 · 肝功能」+ 日期 + 「N 项异常」徽标。
class LabReportsList extends StatelessWidget {
  const LabReportsList({super.key, required this.reports, required this.onOpen});

  final List<LabReportDto> reports;
  final void Function(LabReportDto) onOpen;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    if (reports.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(MedShape.s6),
            child: Text('还没有化验单', textAlign: TextAlign.center, style: MedType.body.copyWith(color: c.ink2)),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
      itemCount: reports.length,
      separatorBuilder: (_, _) => const SizedBox(height: MedShape.s1),
      itemBuilder: (context, i) {
        final r = reports[i];
        return MedCard(
          child: InkWell(
            onTap: () => onOpen(r),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.title, style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w600)),
                        Text(
                          [fmtDate(r.date), '${r.items.length} 项'].where((s) => s.isNotEmpty).join(' · '),
                          style: MedType.secondary.copyWith(color: c.ink2, fontFeatures: MedType.tabular),
                        ),
                      ],
                    ),
                  ),
                  if (r.abnormalCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: MedShape.s1, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.high),
                        borderRadius: BorderRadius.circular(MedShape.radiusPill),
                      ),
                      child: Text('${r.abnormalCount} 项异常', style: MedType.caption.copyWith(color: c.high)),
                    ),
                  const SizedBox(width: MedShape.s1),
                  Icon(Icons.chevron_right, size: 18, color: c.ink3),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 按指标:chip 一排 → 最近 12 个月的指标行 → 「更早 · N 项」折叠。
class LabAnalytesList extends StatelessWidget {
  const LabAnalytesList({
    super.key,
    required this.series,
    required this.group,
    required this.query,
    required this.today,
    required this.onSelectGroup,
    required this.onOpenSeries,
    required this.onOpenDoc,
  });

  final List<TrendSeriesDto> series;
  final String group;
  final String query;
  final DateTime today;
  final void Function(String group) onSelectGroup;
  final void Function(TrendSeriesDto) onOpenSeries;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final split = trendRecentSplit(series, today: today);
    final chips = labGroupChips([...split.recent, ...split.earlier]);
    final recent = sortByLatest(labsVisible(split.recent, group: group, query: query));
    final earlier = sortByLatest(labsVisible(split.earlier, group: group, query: query));
    Widget row(TrendSeriesDto s) => LabTrendRow(
      key: ValueKey('lab:${s.analyteKey ?? s.name}'),
      series: s,
      onOpenDoc: onOpenDoc,
      onTap: () => onOpenSeries(s),
    );
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s2, MedShape.s3, MedShape.s6),
      children: [
        if (chips.length > 1)
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: MedShape.s1),
              itemBuilder: (context, i) => MedChip(
                label: chips[i].group,
                count: chips[i].count,
                selected: chips[i].group == group,
                onTap: () => onSelectGroup(chips[i].group == group ? kAllGroup : chips[i].group),
              ),
            ),
          ),
        const SizedBox(height: MedShape.s2),
        if (recent.isEmpty && earlier.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s5),
            child: Text(
              query.isNotEmpty ? '没有名字含「$query」的指标。' : '还没有可以画的指标。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
          ),
        for (final s in recent) row(s),
        if (earlier.isNotEmpty)
          ExpansionTile(
            title: Text('更早 · ${earlier.length} 项(超过 12 个月没有结果)', style: MedType.body.copyWith(color: c.ink2)),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final s in earlier) row(s)],
          ),
      ],
    );
  }
}

/// 一张化验单:项目 / 数值 / 单位 / 参考 / 箭头 的表;认得出的行点开进折线页,认不出的进原件。
class LabReportScreen extends StatelessWidget {
  const LabReportScreen({super.key, required this.report, required this.series, this.onOpenDoc, this.onOpenSeries});

  final LabReportDto report;
  final List<TrendSeriesDto> series;
  final void Function(int docId)? onOpenDoc;
  final void Function(TrendSeriesDto)? onOpenSeries;

  void _openDoc(BuildContext context) {
    if (onOpenDoc != null) return onOpenDoc!(report.documentId.toInt());
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: report.documentId.toInt())));
  }

  void _openRow(BuildContext context, LabReportItemDto it) {
    final s = it.analyteKey == null
        ? null
        : series.where((s) => s.analyteKey == it.analyteKey && !s.selfMeasured).firstOrNull;
    if (s == null) return _openDoc(context);
    if (onOpenSeries != null) return onOpenSeries!(s);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LabDetailScreen(series: s)));
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(report.title, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
        children: [
          Text(
            [fmtDate(report.date), '${report.items.length} 项', if (report.abnormalCount > 0) '${report.abnormalCount} 项异常']
                .where((s) => s.isNotEmpty)
                .join(' · '),
            style: MedType.secondary.copyWith(color: c.ink2, fontFeatures: MedType.tabular),
          ),
          const SizedBox(height: MedShape.s2),
          MedCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < report.items.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  _ItemRow(item: report.items[i], onTap: () => _openRow(context, report.items[i])),
                ],
              ],
            ),
          ),
          const SizedBox(height: MedShape.s3),
          OutlinedButton.icon(
            onPressed: () => _openDoc(context),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('查看原件'),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.onTap});
  final LabReportItemDto item;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final status = labStatusOf(item.flag);
    final arrow = switch (item.flag) { 'H' => '↑', 'L' => '↓', _ => '' };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Text(item.name, style: MedType.body.copyWith(color: c.ink)),
            ),
            const SizedBox(width: MedShape.s2),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${item.value}${item.unit == null ? '' : ' ${item.unit}'}$arrow${item.unverified ? ' · 需核对' : ''}',
                    textAlign: TextAlign.end,
                    style: MedType.body.copyWith(color: labStatusColor(context, status), fontWeight: FontWeight.w600, fontFeatures: MedType.tabular),
                  ),
                  if (item.reference != null)
                    Text('参考 ${item.reference}', style: MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
