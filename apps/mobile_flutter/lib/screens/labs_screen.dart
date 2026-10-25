// 「化验」tab(修订 2 返工,照 MyChart Test Results):顶部「按报告 / 按指标」切换 + 全局时间区间
// chip(3 个月 / 半年 / 1 年 / 全部,默认 1 年)。按报告 = 一天的化验一行(面板名 · 日期 · 项数,
// 异常徽标),区间外的折进「更早的报告」;按指标 = 关键指标 / 其他指标(折叠)/ 更早(折叠)三层,
// 每行三层(名称 + 最近值 / 整行宽迷你折线 / 最近日期),「只看异常」开关默认关;点开是完整折线页。
// 用户原话:「应该在顶部直接允许医生选择时间区间……否则这个趋势图没有意义」。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/profile_cache.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/lab_detail_screen.dart';
import 'package:mobile_flutter/screens/labs_model.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart' show ChartRange, chartRangeDays, cleanUnit, kChartRangeLabel;
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/provenance_footer.dart';

/// 报告列表 + 全部序列 + 关键指标 key(通用关键项 + 有诊断的族的化验表 key)。
typedef LabsData = (List<LabReportDto> reports, List<TrendSeriesDto> series, Set<String> keyKeys);

Future<LabsData> _loadFromVault() async {
  final r = await Future.wait<Object>([viewLabReports(), viewTrends()]);
  var keys = keyLabKeys(diagnosedFamilies: const {}, familyLabKeys: const {});
  try {
    final g = await Future.wait<Map<String, dynamic>>([cachedGeneralView(), cachedLabFamilies()]);
    keys = keyLabKeys(diagnosedFamilies: diagnosedFamiliesOf(g[0]), familyLabKeys: familyLabKeysOf(g[1]));
  } catch (_) {
    // 通用视图打不开(没装包、空库)只影响「关键指标」的族补充,化验页照常。
  }
  return (r[0] as List<LabReportDto>, r[1] as List<TrendSeriesDto>, keys);
}

enum LabsMode { reports, analytes }

class LabsScreen extends StatefulWidget {
  const LabsScreen({super.key, this.load, this.today});

  /// null → 真的那一套(FFI)。测试注入。
  final Future<LabsData> Function()? load;

  /// 时间区间的「今天」;null → `DateTime.now()`。
  final DateTime? today;

  @override
  State<LabsScreen> createState() => _LabsScreenState();
}

class _LabsScreenState extends State<LabsScreen> {
  late Future<LabsData> _future = _load();
  LabsMode _mode = LabsMode.reports;
  ChartRange _range = ChartRange.oneYear;
  bool _abnormalOnly = false;
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

  void _openSeries(TrendSeriesDto s) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LabDetailScreen(series: s, initialRange: _range)));
  }

  void _openReport(LabReportDto r, List<TrendSeriesDto> series) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LabReportScreen(report: r, series: series, initialRange: _range)),
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
    final today = widget.today ?? DateTime.now();
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
          final (reports, series, keyKeys) = snap.data!;
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
              Padding(
                padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s2, MedShape.s3, 0),
                child: ChartRangeChips(
                  value: _range,
                  onChanged: (r) {
                    Analytics.track(AnalyticsEvent.trendsFilterUsed, {'control': TrendsFilterControl.range.name});
                    setState(() => _range = r);
                  },
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  color: c.seal,
                  child: _mode == LabsMode.reports
                      ? LabReportsList(
                          reports: reports,
                          today: today,
                          range: _range,
                          onOpen: (r) => _openReport(r, series),
                        )
                      : LabAnalytesList(
                          series: series,
                          keyKeys: keyKeys,
                          group: _group,
                          query: _query,
                          today: today,
                          range: _range,
                          abnormalOnly: _abnormalOnly,
                          onToggleAbnormal: (v) => setState(() => _abnormalOnly = v),
                          onSelectGroup: (g) => setState(() => _group = g),
                          onOpenSeries: _openSeries,
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

/// 时间区间 chip 一排(化验页顶部、用药页共用)。
class ChartRangeChips extends StatelessWidget {
  const ChartRangeChips({super.key, required this.value, required this.onChanged});

  final ChartRange value;
  final ValueChanged<ChartRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Wrap(
      spacing: MedShape.s1,
      children: [
        for (final r in ChartRange.values)
          ChoiceChip(
            key: ValueKey('range:${r.name}'),
            label: Text(kChartRangeLabel[r]!),
            selected: r == value,
            showCheckmark: false,
            labelStyle: MedType.secondary.copyWith(color: r == value ? c.sealInk : c.ink2),
            selectedColor: c.sealWash,
            side: BorderSide(color: r == value ? c.seal : c.line),
            onSelected: (_) => onChanged(r),
          ),
      ],
    );
  }
}

/// 一天的化验一行:「电解质、血常规、肝功能 等 N 个面板」+ 日期 · 时间 · 项数,异常徽标靠右;
/// 区间外的折进「更早的报告 · N 份」。
class LabReportsList extends StatelessWidget {
  const LabReportsList({
    super.key,
    required this.reports,
    required this.onOpen,
    required this.today,
    this.range = ChartRange.oneYear,
  });

  final List<LabReportDto> reports;
  final void Function(LabReportDto) onOpen;
  final DateTime today;
  final ChartRange range;

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
    final days = chartRangeDays(range);
    final cutoff = days == null ? null : DateTime(today.year, today.month, today.day).subtract(Duration(days: days));
    final recent = <LabReportDto>[];
    final earlier = <LabReportDto>[];
    for (final r in reports) {
      final d = r.date == null ? null : DateTime.tryParse(r.date!);
      (cutoff != null && d != null && d.isBefore(cutoff) ? earlier : recent).add(r);
    }
    Widget row(LabReportDto r) => MedCard(
      key: ValueKey('report:${r.documentId}'),
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
                    Text(r.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w600)),
                    Text(
                      [fmtDate(r.date), ?r.time, '${r.items.length} 项'].where((s) => s.isNotEmpty).join(' · '),
                      style: MedType.secondary.copyWith(color: c.ink2, fontFeatures: MedType.tabular),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: MedShape.s2),
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
    final items = <Widget>[
      if (recent.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: MedShape.s3),
          child: Text('${kChartRangeLabel[range]}内没有化验单', textAlign: TextAlign.center, style: MedType.body.copyWith(color: c.ink2)),
        ),
      for (final r in recent) Padding(padding: const EdgeInsets.only(bottom: MedShape.s1), child: row(r)),
      if (earlier.isNotEmpty)
        ExpansionTile(
          title: Text('更早的报告 · ${earlier.length} 份', style: MedType.body.copyWith(color: c.ink2)),
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final r in earlier) Padding(padding: const EdgeInsets.only(bottom: MedShape.s1), child: row(r))],
        ),
    ];
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
      itemCount: items.length,
      itemBuilder: (context, i) => items[i],
    );
  }
}

/// 按指标:chip 一排 → 只看异常 → 关键指标 → 「其他指标 · 还有 N 项」折叠 → 「更早的 N 项」折叠。
class LabAnalytesList extends StatelessWidget {
  const LabAnalytesList({
    super.key,
    required this.series,
    required this.keyKeys,
    required this.group,
    required this.query,
    required this.today,
    required this.range,
    required this.abnormalOnly,
    required this.onToggleAbnormal,
    required this.onSelectGroup,
    required this.onOpenSeries,
  });

  final List<TrendSeriesDto> series;
  final Set<String> keyKeys;
  final String group;
  final String query;
  final DateTime today;
  final ChartRange range;
  final bool abnormalOnly;
  final ValueChanged<bool> onToggleAbnormal;
  final void Function(String group) onSelectGroup;
  final void Function(TrendSeriesDto) onOpenSeries;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final visible = labsVisible(series, group: group, query: query);
    final chips = labGroupChips(trendRecentSplit(series, today: today, recentDays: null).recent);
    final tiers = labTiers(visible, today: today, recentDays: chartRangeDays(range), keyKeys: keyKeys, abnormalOnly: abnormalOnly);
    // 自测与医院值同 key 不同序列(aggregate 刻意分组),key 要带上 selfMeasured 才唯一(审查 C4)。
    // 一个指标一张卡,卡间 12pt(用户:「不用挤在一行里面的,每一个 lab 一个块呀」)。
    Widget row(TrendSeriesDto s) => Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s2),
      child: LabTrendCard(
        key: ValueKey('lab:${s.selfMeasured}:${s.analyteKey ?? s.name}'),
        series: s,
        range: range,
        today: today,
        onTap: () => onOpenSeries(s),
      ),
    );
    Widget header(String text) => Padding(
      padding: const EdgeInsets.only(top: MedShape.s2, bottom: MedShape.s1),
      child: Text(text, style: MedType.subtitle.copyWith(color: c.ink)),
    );
    Widget fold(String title, List<TrendSeriesDto> list) => ExpansionTile(
      title: Text(title, style: MedType.body.copyWith(color: c.ink2)),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final s in list) row(s)],
    );
    final nothing = tiers.key.isEmpty && tiers.other.isEmpty && tiers.earlier.isEmpty;
    // 几百条序列、每条一张折线:按需构建,不一次全建(审查 I7)。
    final items = <Widget>[
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
      Row(
        children: [
          Expanded(child: Text('只看异常', style: MedType.secondary.copyWith(color: c.ink2))),
          Switch.adaptive(value: abnormalOnly, onChanged: onToggleAbnormal),
        ],
      ),
      if (nothing)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: MedShape.s5),
          child: Text(
            query.isNotEmpty
                ? '没有名字含「$query」的指标。'
                : abnormalOnly
                    ? '没有偏高 / 偏低的指标。'
                    : '还没有可以画的指标。',
            textAlign: TextAlign.center,
            style: MedType.body.copyWith(color: c.ink2, height: 1.6),
          ),
        ),
      if (tiers.key.isNotEmpty) header('关键指标 · ${tiers.key.length}'),
      for (final s in tiers.key) row(s),
      // 没有关键指标可列时「其他」直接展开,别让用户面对一屏折叠。
      if (tiers.other.isNotEmpty && tiers.key.isEmpty) ...[
        header('指标 · ${tiers.other.length}'),
        for (final s in tiers.other) row(s),
      ] else if (tiers.other.isNotEmpty)
        fold('其他指标 · 还有 ${tiers.other.length} 项', tiers.other),
      if (tiers.earlier.isNotEmpty)
        fold('更早的 ${tiers.earlier.length} 项(超过${kChartRangeLabel[range]}没有结果)', tiers.earlier),
    ];
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s2, MedShape.s3, MedShape.s6),
      itemCount: items.length,
      itemBuilder: (context, i) => items[i],
    );
  }
}

/// 一张化验单:项目 / 数值 / 单位 / 参考 / 箭头 的表;认得出的行点开进折线页,认不出的进原件。
class LabReportScreen extends StatelessWidget {
  const LabReportScreen({
    super.key,
    required this.report,
    required this.series,
    this.onOpenDoc,
    this.onOpenSeries,
    this.initialRange = ChartRange.oneYear,
  });

  final LabReportDto report;
  final List<TrendSeriesDto> series;
  final void Function(int docId)? onOpenDoc;
  final void Function(TrendSeriesDto)? onOpenSeries;
  final ChartRange initialRange;

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
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LabDetailScreen(series: s, initialRange: initialRange)));
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
            [fmtDate(report.date), ?report.time, '${report.items.length} 项', if (report.abnormalCount > 0) '${report.abnormalCount} 项异常']
                .where((s) => s.isNotEmpty)
                .join(' · '),
            style: MedType.secondary.copyWith(color: c.ink2, fontFeatures: MedType.tabular),
          ),
          if (report.panels.length > 3) ...[
            const SizedBox(height: 2),
            Text(report.panels.join('、'), style: MedType.caption.copyWith(color: c.ink3)),
          ],
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
                    '${item.value}${cleanUnit(item.unit) == null ? '' : ' ${cleanUnit(item.unit)}'}$arrow${item.unverified ? ' · 需核对' : ''}',
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
