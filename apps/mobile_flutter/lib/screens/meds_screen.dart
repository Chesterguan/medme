// 「用药」tab(2026-10-23 spec §5;修订 2 返工 2026-10-25):过敏钉在最上(按过敏原合并,展开,最多
// 1/3 屏),时间区间 chip 与化验页同一套(默认 1 年);「最近的用药」按药类分组(抗感染 / 心血管 /
// 抗凝 / 电解质·营养 / 其他),每行中文名在前、剂量、「记录中自 X 起 · N 天前有记录」;「更早的用药」
// 一味药一行「首次 → 最近 · N 次记录」按最近倒序、同类相邻;搜索跨药名(中英)/ 过敏原,结果横跨两段;
// 点行 = 剂量变化链,每个节点回原件。用户原话:「用药也是类似的,也有时效性的,你不能只管 list,重点是医生要能找到信息」。
// 措辞不用「当前用药 / 在吃 / 已停」:MedSpan.status 恒 active,不能暗示有效医嘱。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/profile_cache.dart';
import 'package:mobile_flutter/profile_json.dart' show asMapList;
import 'package:mobile_flutter/screens/labs_screen.dart' show ChartRangeChips;
import 'package:mobile_flutter/screens/meds_model.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_line_chart.dart' show ChartRange, chartRangeDays, kChartRangeLabel;
import 'package:mobile_flutter/widgets/med_card.dart';

class MedsScreen extends StatefulWidget {
  const MedsScreen({super.key, this.load, this.today});

  /// null → 真的那一套(FFI,进程内缓存)。测试注入。
  final Future<Map<String, dynamic>> Function()? load;

  /// 时间区间的「今天」;null → `DateTime.now()`。
  final DateTime? today;

  @override
  State<MedsScreen> createState() => _MedsScreenState();
}

class _MedsScreenState extends State<MedsScreen> {
  late Future<Map<String, dynamic>> _future = _load();
  final _queryCtl = TextEditingController();
  String _query = '';
  bool _searchOpen = false;
  ChartRange _range = ChartRange.oneYear;

  Future<Map<String, dynamic>> _load() => (widget.load ?? cachedMedsView)();

  @override
  void initState() {
    super.initState();
    vaultRevision.addListener(_onVaultChanged);
    medsFilterFamily.addListener(_onFilterChanged);
  }

  @override
  void dispose() {
    _queryCtl.dispose();
    vaultRevision.removeListener(_onVaultChanged);
    medsFilterFamily.removeListener(_onFilterChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    if (mounted) setState(() {});
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
    // 展开一次发一次,不随输入发(输入的是内容)。
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
                  hintText: '搜药名或过敏原,如「华法林」「Warfarin」',
                  hintStyle: MedType.subtitle.copyWith(color: c.ink3),
                  border: InputBorder.none,
                  isDense: true,
                ),
              )
            : const Text('用药'),
        actions: [
          IconButton(
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            color: c.ink2,
            tooltip: _searchOpen ? '关闭搜索' : '按名字搜药或过敏原',
            onPressed: _toggleSearch,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
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
                    child: Text(
                      '这一页暂时打不开。下拉可重试。',
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            color: c.seal,
            child: MedsBody(
              view: snap.data!,
              query: _query,
              family: medsFilterFamily.value,
              range: _range,
              today: widget.today ?? DateTime.now(),
              onRangeChanged: (r) {
                Analytics.track(AnalyticsEvent.trendsFilterUsed, {'control': TrendsFilterControl.range.name});
                setState(() => _range = r);
              },
              onClearFamily: () => medsFilterFamily.value = null,
            ),
          );
        },
      ),
    );
  }
}

/// 正文(公开是为了可测)。
class MedsBody extends StatelessWidget {
  const MedsBody({
    super.key,
    required this.view,
    required this.today,
    this.query = '',
    this.family,
    this.range = ChartRange.oneYear,
    this.onRangeChanged,
    this.onClearFamily,
  });

  final Map<String, dynamic> view;
  final DateTime today;
  final String query;
  final String? family;
  final ChartRange range;
  final ValueChanged<ChartRange>? onRangeChanged;
  final VoidCallback? onClearFamily;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final index = EvidenceIndex.fromView(view);
    final all = medsByFamily([...asMapList(view['recent']), ...asMapList(view['earlier'])], family)
        .where((r) => medMatches(r, query))
        .toList();
    final split = medsSplit(all, today: today, recentDays: chartRangeDays(range));
    final recentGroups = medsByClass(split.recent);
    final earlierGroups = medsByClass(split.earlier);
    final allergies = asMapList(view['allergies']).where((a) => allergyMatches(a, query)).toList();
    final maxAllergyHeight = MediaQuery.sizeOf(context).height / 3;
    Widget sectionCard(List<Widget> rows) => MedCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: c.line),
            rows[i],
          ],
        ],
      ),
    );
    Widget classLabel(String text) => Padding(
      padding: const EdgeInsets.only(top: MedShape.s2, bottom: 4),
      child: Text(text, style: MedType.caption.copyWith(color: c.ink2)),
    );
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
      children: [
        // 过敏钉在最上(spec §5.2 + 修订 2 返工):空态不说「无过敏」——没找到不等于没有。
        _SectionTitle('过敏 · ${allergies.length}'),
        if (allergies.isEmpty)
          _Hint(query.isEmpty ? '记录里没找到过敏史' : '没有含「$query」的过敏原')
        else
          // 最多 1/3 屏,多了在卡内滚;ConstrainedBox 放在卡**里**(卡的 Column 给子项的高度是无界的)。
          MedCard(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxAllergyHeight),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: allergies.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: c.line),
                itemBuilder: (context, i) => _AllergyRow(allergies[i], index, key: ValueKey('allergy:${allergies[i]['substance']}')),
              ),
            ),
          ),
        const SizedBox(height: MedShape.s3),
        if (family != null)
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              label: Text(kFamilyLabel[family] ?? family!),
              onDeleted: onClearFamily,
              deleteIcon: const Icon(Icons.close, size: 16),
              side: BorderSide(color: c.seal),
              backgroundColor: c.surface,
              labelStyle: MedType.secondary.copyWith(color: c.sealInk),
            ),
          ),
        if (onRangeChanged != null) ChartRangeChips(value: range, onChanged: onRangeChanged!),
        const SizedBox(height: MedShape.s2),
        _SectionTitle('最近的用药 · ${split.recent.length}', sub: '${kChartRangeLabel[range]}内有记录'),
        if (split.recent.isEmpty)
          _Hint(query.isEmpty && family == null ? '${kChartRangeLabel[range]}内没有用药记录' : '没有符合的药')
        else
          for (final g in recentGroups) ...[
            if (recentGroups.length > 1 || g.label != '其他') classLabel('${g.label} · ${g.rows.length}'),
            sectionCard([
              for (final r in g.rows) MedRowView(key: ValueKey('med:${r['drug_key'] ?? r['name']}'), row: r, index: index),
            ]),
          ],
        const SizedBox(height: MedShape.s4),
        _SectionTitle('更早的用药 · ${split.earlier.length}', sub: '一味药一行 · 首次 → 最近'),
        if (split.earlier.isEmpty)
          _Hint(query.isEmpty ? '没有更早的用药记录' : '没有名字含「$query」的药')
        else
          for (final g in earlierGroups) ...[
            if (earlierGroups.length > 1 || g.label != '其他') classLabel('${g.label} · ${g.rows.length}'),
            sectionCard([
              for (final r in g.rows)
                MedRowView(key: ValueKey('med-earlier:${r['drug_key'] ?? r['name']}'), row: r, index: index, earlier: true),
            ]),
          ],
        const SizedBox(height: MedShape.s4),
        Text(
          view['disclaimer'] as String? ?? '只整理你病历里已有的记录,不做诊断。',
          style: MedType.secondary.copyWith(color: c.ink3, height: 1.6),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.sub});
  final String text;
  final String? sub;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s1),
      child: Wrap(
        spacing: MedShape.s2,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          Text(text, style: MedType.subtitle.copyWith(color: c.ink)),
          if (sub != null) Text(sub!, style: MedType.caption.copyWith(color: c.ink3)),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: MedShape.s2),
    child: Text(text, style: MedType.secondary.copyWith(color: MedColors.of(context).ink2, height: 1.5)),
  );
}

/// 一味药一行:名 · 剂量 · 族;第二行「记录中自 … 起 · N 天前有记录」(最近)或
/// 「首次 → 最近 · N 次记录」(更早);点开 → 剂量变化链,每个节点带「原件 ›」。
class MedRowView extends StatefulWidget {
  const MedRowView({super.key, required this.row, required this.index, this.earlier = false});

  final Map<String, dynamic> row;
  final EvidenceIndex index;

  /// 「更早的用药」段的一行:第二行写首次 → 最近 · N 次记录。
  final bool earlier;

  @override
  State<MedRowView> createState() => _MedRowViewState();
}

class _MedRowViewState extends State<MedRowView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final row = widget.row;
    final name = '${row['name'] ?? ''}';
    final raw = '${row['raw_name'] ?? ''}';
    final dose = row['dose'] as String?;
    final since = fmtDate(row['since'] as String?);
    final days = (row['days_since'] as num?)?.toInt();
    final stale = row['stale'] == true;
    final stopped = row['stopped'];
    final fam = row['family'] as String?;
    final note = row['family_note'] as String?;
    final tags = [if (fam != null && fam != 'other') kFamilyLabel[fam] ?? fam, ?note].join(' · ');
    final nodes = asMapList(row['nodes']);
    final muted = widget.earlier || stale || stopped is Map;
    final second = widget.earlier
        ? medEarlierLine(row)
        : stopped is Map
            ? '病历写了停药 · ${fmtDate(stopped['at'] as String?)}'
            : [
                if (since.isNotEmpty) '记录中自 $since 起',
                if (days != null) stale ? '$days 天没有新记录' : '$days 天前有记录',
              ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: name, style: MedType.body.copyWith(color: muted ? c.ink2 : c.ink, fontWeight: FontWeight.w600)),
                            if (dose != null && dose.isNotEmpty)
                              TextSpan(text: '  $dose', style: MedType.body.copyWith(color: muted ? c.ink2 : c.ink)),
                            if (tags.isNotEmpty) TextSpan(text: '  $tags', style: MedType.caption.copyWith(color: c.ink3)),
                            if (row['unverified'] == true) TextSpan(text: '  需核对', style: MedType.caption.copyWith(color: c.ink3)),
                          ],
                        ),
                      ),
                      if (raw.isNotEmpty && raw != name) Text(raw, style: MedType.caption.copyWith(color: c.ink3)),
                      Text(second, style: MedType.secondary.copyWith(color: c.ink2, height: 1.5, fontFeatures: MedType.tabular)),
                    ],
                  ),
                ),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: c.ink3),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(MedShape.s3, 0, MedShape.s3, MedShape.s2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (nodes.isEmpty)
                  _NodeLine(
                    at: fmtDate(row['last_seen'] as String?),
                    text: '最近一次记录',
                    ids: (row['evidence'] as List? ?? const []),
                    index: widget.index,
                  )
                else
                  for (final n in nodes)
                    _NodeLine(
                      at: fmtDate(n['at'] as String?),
                      text: medNodeText(n),
                      ids: (n['evidence'] as List? ?? const []),
                      index: widget.index,
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

class _NodeLine extends StatelessWidget {
  const _NodeLine({required this.at, required this.text, required this.ids, required this.index});
  final String at;
  final String text;
  final List<dynamic> ids;
  final EvidenceIndex index;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final has = index.resolve(ids).isNotEmpty;
    return InkWell(
      onTap: has ? () => openEvidence(context, index, ids) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 92, child: Text(at, style: MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular))),
            Expanded(child: Text(text, style: MedType.secondary.copyWith(color: c.ink2, height: 1.5))),
            if (has) Text('原件 ›', style: MedType.caption.copyWith(color: c.sealInk)),
          ],
        ),
      ),
    );
  }
}

/// 一个过敏原一行:名(词典中文在前)+ 合并的反应 + 「N 份记录」;点开看原文各写法,每条可进原件。
class _AllergyRow extends StatelessWidget {
  const _AllergyRow(this.a, this.index, {super.key});
  final Map<String, dynamic> a;
  final EvidenceIndex index;

  void _showOriginals(BuildContext context) {
    final c = MedColors.of(context);
    final ids = (a['evidence'] as List? ?? const []);
    final aliases = (a['aliases'] as List? ?? const []).map((x) => '$x').toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(MedShape.s3, 0, MedShape.s3, MedShape.s4),
          children: [
            Text('${a['substance'] ?? ''}', style: MedType.subtitle.copyWith(color: c.ink)),
            const SizedBox(height: MedShape.s1),
            Text('病历里的写法 · ${aliases.length}', style: MedType.caption.copyWith(color: c.ink3)),
            for (final s in aliases)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(s, style: MedType.secondary.copyWith(color: c.ink2, height: 1.5)),
              ),
            if (index.resolve(ids).isNotEmpty) ...[
              const SizedBox(height: MedShape.s2),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  openEvidence(context, index, ids);
                },
                icon: const Icon(Icons.visibility_outlined),
                label: Text('查看原件 · ${ids.length} 份'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final ids = (a['evidence'] as List? ?? const []);
    final reaction = '${a['reaction'] ?? ''}';
    return InkWell(
      onTap: () => _showOriginals(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${a['substance'] ?? ''}', style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w600)),
                    if (reaction.isNotEmpty) TextSpan(text: '  $reaction', style: MedType.secondary.copyWith(color: c.ink2)),
                    if (ids.isNotEmpty) TextSpan(text: '  ${ids.length} 份记录', style: MedType.caption.copyWith(color: c.ink3)),
                  ],
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
