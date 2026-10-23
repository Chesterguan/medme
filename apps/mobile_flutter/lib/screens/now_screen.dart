// 「现在」tab(2026-10-23 spec §4):只放此刻成立的东西 —— 最近 12 个月有记录的诊断按族折叠,
// 每族下最近化验带迷你折线;通用一排;其他化验;更早的诊断 / 化验各收成一行;病种包只在
// 对应族有诊断时作该族展开区的一段。任何值点一下进原件(`evidence_open.dart`)。
// 用户原话:「现在里面很多东西不是现在的」「太久远的化验不用展示」「化验值没有折线图不容易看」。
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/now_model.dart';
import 'package:mobile_flutter/skill_packages.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_trend_row.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';
import 'package:mobile_flutter/widgets/provenance_footer.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 通用视图 JSON、全部化验序列、化验族表。
typedef NowData = (Map<String, dynamic> view, List<TrendSeriesDto> series, LabFamilies families);

Future<NowData> _loadFromVault() async {
  final dir = await skillCacheDir();
  final r = await Future.wait<Object>([
    rust_profile.vaultProfileViewGeneral(dir: dir),
    viewTrends(),
    rust_profile.vaultProfileLabFamilies(),
  ]);
  return (
    jsonDecode(r[0] as String) as Map<String, dynamic>,
    r[1] as List<TrendSeriesDto>,
    LabFamilies.fromJson(jsonDecode(r[2] as String) as Map<String, dynamic>),
  );
}

/// 包段落在「现在」的哪些 section kind(包的 journey / series_chart / evidence 不在这页)。
const _kPackageKindsOnNow = {'state', 'status_card', 'score_card', 'checklist', 'reminders'};

class NowScreen extends StatefulWidget {
  const NowScreen({super.key, this.load, this.today});

  /// null → 真的那一套(FFI)。测试注入。
  final Future<NowData> Function()? load;

  /// 12 个月窗的「今天」;null → `DateTime.now()`。
  final DateTime? today;

  @override
  State<NowScreen> createState() => _NowScreenState();
}

class _NowScreenState extends State<NowScreen> {
  late Future<NowData> _future = _load();
  final _queryCtl = TextEditingController();
  String _query = '';
  bool _searchOpen = false;

  Future<NowData> _load() => (widget.load ?? _loadFromVault)();

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

  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
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
            : const Text('现在'),
        actions: [
          IconButton(
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            color: c.ink2,
            tooltip: _searchOpen ? '关闭搜索' : '按名字搜指标',
            onPressed: _toggleSearch,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<NowData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _Failed(onRetry: _refresh);
          }
          final (view, series, families) = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            color: c.seal,
            child: NowBody(
              view: view,
              series: series,
              families: families,
              query: _query,
              today: widget.today ?? DateTime.now(),
              onOpenDoc: _openDoc,
            ),
          );
        },
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return RefreshIndicator(
      onRefresh: onRetry,
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
}

/// 正文(公开是为了可测:整屏 pump 需要 FFI)。
class NowBody extends StatelessWidget {
  const NowBody({
    super.key,
    required this.view,
    required this.series,
    required this.families,
    required this.today,
    required this.onOpenDoc,
    this.query = '',
  });

  final Map<String, dynamic> view;
  final List<TrendSeriesDto> series;
  final LabFamilies families;
  final DateTime today;
  final String query;
  final void Function(int docId) onOpenDoc;

  Map<String, dynamic>? _section(String kind) {
    for (final s in asMapList(view['sections'])) {
      if (s['kind'] == kind && (s['package_id'] ?? 'general') == 'general') return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final index = EvidenceIndex.fromView(view);
    final all = series.where(trendSeriesIsRenderable).toList();
    const pad = EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6);

    // 搜索:整页只剩名字命中的化验行(跨族、含更早)。
    if (query.isNotEmpty) {
      final hits = trendSearch(all, query);
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: pad,
        children: [
          if (hits.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: MedShape.s5),
              child: Text(
                '这些记录里没有名字含「$query」的指标。\n换个叫法试试 —— 同一项在不同医院可能印成「肌酐」「血肌酐」「Cr」。',
                textAlign: TextAlign.center,
                style: MedType.body.copyWith(color: c.ink2, height: 1.6),
              ),
            )
          else
            for (final s in hits) LabTrendRow(key: ValueKey('lab:${s.analyteKey ?? s.name}'), series: s, onOpenDoc: onOpenDoc),
        ],
      );
    }

    final fam = _section('family_cards')?['body'] as Map<String, dynamic>? ?? const {};
    final familyCards = asMapList(fam['families']);
    final earlierFamilies = asMapList(fam['earlier_families']);
    final medRows = asMapList((_section('med_table')?['body'] as Map?)?['rows']);
    final split = trendRecentSplit(all, today: today, recentDays: families.recentDays);

    // 最近的化验按族分桶;一条序列可以进多个族(肌酐:心血管 + 肾)。
    final byFamily = <String, List<TrendSeriesDto>>{};
    for (final s in split.recent) {
      for (final f in families.familiesOfSeries(s)) {
        byFamily.putIfAbsent(f, () => []).add(s);
      }
    }
    final common = byFamily.remove('common') ?? const [];
    // 「其他 N 条」「未归类」两张诊断卡不挂化验(与 Rust 同一条规矩,审查 I4):能挂化验的族卡
    // 只有有 key 表的那些。
    final familyKeys = familyCards
        .map((f) => '${f['key']}')
        .where((k) => k != 'other' && k != 'uncoded')
        .toSet();
    // 一条序列只要已经出现在某张族卡里就不再列进「其他化验」;一张族卡都没落到的
    //(族没有诊断卡、或词典认不出、或自测)才进「其他化验」。
    final other = <TrendSeriesDto>[
      for (final s in split.recent)
        if (!families.familiesOfSeries(s).any((f) => f == 'common' || familyKeys.contains(f))) s,
    ];

    // 包段:按 view.packages[] 的 family 落到对应族卡;该族没有卡(诊断无码落在「未归类」)
    // 时作为独立一段排在族卡之后。
    final packages = asMapList(view['packages']).where((p) => p['applies'] == true).toList();
    List<Map<String, dynamic>> sectionsOf(String pkgId) => asMapList(view['sections'])
        .where((s) => s['package_id'] == pkgId && _kPackageKindsOnNow.contains(s['kind']))
        .toList();
    final links = ProfileLinks(
      evidenceById: index.evidenceById,
      onOpen: (e) => openEvidence(context, index, [e['id']]),
    );
    List<Widget> packageBlock(Map<String, dynamic> p) => [
      _PackageHeader(name: '${p['display_name'] ?? p['id']}'),
      for (final s in sectionsOf('${p['id']}')) ProfileSectionView(s, links: links),
    ];
    final placed = <String>{};

    final isEmpty = familyCards.isEmpty && earlierFamilies.isEmpty && all.isEmpty;
    if (isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: pad,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s6),
            child: Text(
              '还没有诊断或化验记录',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
          ),
        ],
      );
    }

    final sources = asMapList(view['sources']);
    final disclaimer = view['disclaimer'] as String? ?? '';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: pad,
      children: [
        for (final f in familyCards)
          FamilyTile(
            key: ValueKey('family:${f['key']}'),
            family: f,
            labs: familyKeys.contains('${f['key']}') ? (byFamily['${f['key']}'] ?? const []) : const [],
            medNames: recentMedNamesOfFamily(medRows, '${f['key']}'),
            index: index,
            onOpenDoc: onOpenDoc,
            trailing: [
              for (final p in packages)
                if (p['family'] == f['key'] && placed.add('${p['id']}')) ...packageBlock(p),
            ],
          ),
        for (final p in packages)
          if (placed.add('${p['id']}')) ...[const SizedBox(height: MedShape.s2), ...packageBlock(p)],
        if (common.isNotEmpty) ...[
          const SizedBox(height: MedShape.s3),
          _Header('血常规 / 电解质 / 肝功能'),
          for (final s in common) LabTrendRow(key: ValueKey('lab:${s.analyteKey ?? s.name}'), series: s, onOpenDoc: onOpenDoc),
        ],
        if (other.isNotEmpty) ...[
          const SizedBox(height: MedShape.s3),
          _Header('其他化验 · ${other.length}'),
          for (final s in other) LabTrendRow(key: ValueKey('lab:${s.analyteKey ?? s.name}'), series: s, onOpenDoc: onOpenDoc),
        ],
        if (earlierFamilies.isNotEmpty) ...[
          const SizedBox(height: MedShape.s3),
          _Fold(
            title: '更早的诊断 · ${earlierFamilies.fold<int>(0, (n, f) => n + asMapList(f['diagnoses']).length)} 条',
            children: [
              for (final f in earlierFamilies) ...[
                Text('${f['label']}', style: MedType.caption.copyWith(color: c.ink2)),
                for (final d in asMapList(f['diagnoses'])) DiagnosisRow(dx: d, index: index),
              ],
            ],
          ),
        ],
        if (split.earlier.isNotEmpty) ...[
          _Fold(
            title: '更早的化验 · ${split.earlier.length} 项',
            children: [for (final s in split.earlier) LabTrendRow(key: ValueKey('lab:${s.analyteKey ?? s.name}'), series: s, onOpenDoc: onOpenDoc)],
          ),
        ],
        const SizedBox(height: MedShape.s4),
        if (sources.isNotEmpty)
          _Fold(
            title: '出处',
            children: [
              for (final s in sources)
                Padding(
                  padding: const EdgeInsets.only(bottom: MedShape.s1),
                  child: Text('${s['id']} · ${s['cite']}', style: MedType.secondary.copyWith(color: c.ink2, height: 1.5)),
                ),
            ],
          ),
        if (disclaimer.isNotEmpty) ...[
          const SizedBox(height: MedShape.s2),
          Text(disclaimer, style: MedType.secondary.copyWith(color: c.ink3, height: 1.6)),
        ],
        if (all.isNotEmpty) ...[
          const SizedBox(height: MedShape.s4),
          const ProvenanceFooter(),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: MedType.caption.copyWith(color: MedColors.of(context).ink2));
}

/// 折叠一行(更早的诊断 / 更早的化验 / 出处)。
class _Fold extends StatelessWidget {
  const _Fold({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return ExpansionTile(
      title: Text(title, style: MedType.body.copyWith(color: c.ink2)),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: MedShape.s2, bottom: MedShape.s2),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _PackageHeader extends StatelessWidget {
  const _PackageHeader({required this.name});
  final String name;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
      child: Row(
        children: [
          Expanded(child: Divider(color: c.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MedShape.s2),
            child: Text('$name(病种包)', style: MedType.caption.copyWith(color: c.ink2)),
          ),
          Expanded(child: Divider(color: c.line)),
        ],
      ),
    );
  }
}

/// 一族一张折叠卡:标题「族名 · N 条诊断 · 最近 YYYY-MM」;展开 = 诊断行 → 最近的用药一行 →
/// 化验趋势行 → 包段。
class FamilyTile extends StatelessWidget {
  const FamilyTile({
    super.key,
    required this.family,
    required this.labs,
    required this.medNames,
    required this.index,
    required this.onOpenDoc,
    this.trailing = const [],
  });

  final Map<String, dynamic> family;
  final List<TrendSeriesDto> labs;
  final List<String> medNames;
  final EvidenceIndex index;
  final void Function(int docId) onOpenDoc;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final key = '${family['key']}';
    final count = (family['count'] as num?)?.toInt() ?? 0;
    final last = fmtDate(family['last_seen'] as String?);
    final title = key == 'other'
        ? '其他 $count 条'
        : [family['label'], '$count 条诊断', if (last.isNotEmpty) '最近 $last'].join(' · ');
    return ExpansionTile(
      title: Text(title, style: MedType.subtitle.copyWith(color: c.ink)),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: MedShape.s2, bottom: MedShape.s2),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in asMapList(family['diagnoses'])) DiagnosisRow(dx: d, index: index),
        if (medNames.isNotEmpty)
          InkWell(
            onTap: () => goToMeds(family: key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '最近的用药:${medNames.join(' · ')}',
                      style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: c.ink3),
                ],
              ),
            ),
          ),
        if (labs.isNotEmpty) ...[
          const SizedBox(height: MedShape.s1),
          Text('化验', style: MedType.caption.copyWith(color: c.ink2)),
          for (final s in labs) LabTrendRow(key: ValueKey('lab:${s.analyteKey ?? s.name}'), series: s, onOpenDoc: onOpenDoc),
        ],
        ...trailing,
      ],
    );
  }
}

/// 一条诊断:原文 + 码 + 第二族 + 「首次 · 最近 · N 份记录提到」;整行点 = 开原件。
class DiagnosisRow extends StatelessWidget {
  const DiagnosisRow({super.key, required this.dx, required this.index});

  final Map<String, dynamic> dx;
  final EvidenceIndex index;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final texts = (dx['texts'] as List? ?? const []).map((t) => '$t').toList();
    final code = dx['code'] as String?;
    final first = fmtDate(dx['first_seen'] as String?);
    final last = fmtDate(dx['last_seen'] as String?);
    final n = (dx['doc_count'] as num?)?.toInt() ?? 0;
    final ids = (dx['evidence'] as List? ?? const []).whereType<String>().toList();
    final hasEvidence = index.resolve(ids).isNotEmpty;
    return InkWell(
      onTap: hasEvidence ? () => openEvidence(context, index, ids) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: texts.isEmpty ? '' : texts.first, style: MedType.body.copyWith(color: c.ink)),
                        if (code != null) TextSpan(text: '  $code', style: MedType.caption.copyWith(color: c.ink2)),
                        if (dx['unverified'] == true)
                          TextSpan(text: '  需核对', style: MedType.caption.copyWith(color: c.ink3)),
                      ],
                    ),
                  ),
                  if (texts.length > 1) Text(texts.skip(1).join(' / '), style: MedType.caption.copyWith(color: c.ink3)),
                  Text(
                    [if (first.isNotEmpty) '首次 $first', if (last.isNotEmpty) '最近 $last', '$n 份记录提到'].join(' · '),
                    style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
                  ),
                ],
              ),
            ),
            if (hasEvidence) Icon(Icons.chevron_right, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
