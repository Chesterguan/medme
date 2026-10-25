// 「我 → 健康摘要」(修订 2,照 MyChart Health Summary):诊断 / 问题按族折叠(ADR 0012 通用层的族)、
// 手术史、植入物、过敏;SLE 包只在该族有命中诊断时出现在该族下;首屏只放最近 12 个月有诊断的族,
// 「其他 / 未归类」与「更早的诊断」一起折叠在族卡后;诊断写法最多两种 + 「还有 N 个写法」。
// 通用视图走 `profile_cache.dart`(同一 vault 版本只算一次,切 tab 不重算)。任何值点一下进原件。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/profile_cache.dart';
import 'package:mobile_flutter/profile_json.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';

/// 通用视图 JSON + 用药视图 JSON(过敏在后者里)。
typedef HealthSummaryData = (Map<String, dynamic> view, Map<String, dynamic> meds);

Future<HealthSummaryData> _loadFromVault() async {
  final r = await Future.wait<Map<String, dynamic>>([cachedGeneralView(), cachedMedsView()]);
  return (r[0], r[1]);
}

/// 「其他」「未归类」不是真正的族:排到族卡后面,和更早的诊断一起折叠。
const _kTailFamilies = {'other', 'uncoded'};

/// 包段落在健康摘要的哪些 section kind(包的 journey / series_chart / evidence 不在这页)。
const _kPackageKindsOnSummary = {'state', 'status_card', 'score_card', 'checklist', 'reminders'};

/// 植入物:ICD Z95–Z97(心脏装置 / 人工瓣膜 / 其它植入物与移植物)。
bool isImplantCode(String? code) =>
    code != null && (code.startsWith('Z95') || code.startsWith('Z96') || code.startsWith('Z97'));

class HealthSummaryScreen extends StatefulWidget {
  const HealthSummaryScreen({super.key, this.load});

  /// null → 真的那一套(FFI)。测试注入。
  final Future<HealthSummaryData> Function()? load;

  @override
  State<HealthSummaryScreen> createState() => _HealthSummaryScreenState();
}

class _HealthSummaryScreenState extends State<HealthSummaryScreen> {
  late Future<HealthSummaryData> _future = _load();

  Future<HealthSummaryData> _load() => (widget.load ?? _loadFromVault)();

  @override
  void initState() {
    super.initState();
    vaultRevision.addListener(_onVaultChanged);
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('健康摘要')),
      body: FutureBuilder<HealthSummaryData>(
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
          final (view, meds) = snap.data!;
          return RefreshIndicator(
            onRefresh: _refresh,
            color: c.seal,
            child: HealthSummaryBody(view: view, meds: meds),
          );
        },
      ),
    );
  }
}

/// 正文(公开是为了可测)。
class HealthSummaryBody extends StatelessWidget {
  const HealthSummaryBody({super.key, required this.view, required this.meds});

  final Map<String, dynamic> view;
  final Map<String, dynamic> meds;

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
    final medsIndex = EvidenceIndex.fromView(meds);
    final fam = _section('family_cards')?['body'] as Map<String, dynamic>? ?? const {};
    final allFamilies = asMapList(fam['families']);
    final families = allFamilies.where((f) => !_kTailFamilies.contains(f['key'])).toList();
    final tailFamilies = allFamilies.where((f) => _kTailFamilies.contains(f['key'])).toList();
    final earlierFamilies = [...tailFamilies, ...asMapList(fam['earlier_families'])];
    final medRows = asMapList((_section('med_table')?['body'] as Map?)?['rows']);
    final lanes = asMapList((_section('journey')?['body'] as Map?)?['lanes']);
    final surgeries = asMapList(lanes.where((l) => l['key'] == 'surgery').firstOrNull?['nodes']);
    final implants = <Map<String, dynamic>>[
      for (final f in [...families, ...earlierFamilies])
        for (final d in asMapList(f['diagnoses']))
          if (isImplantCode(d['code'] as String?)) d,
    ];
    final allergies = asMapList(meds['allergies']);
    final packages = asMapList(view['packages']).where((p) => p['applies'] == true).toList();
    List<Map<String, dynamic>> sectionsOf(String pkgId) => asMapList(view['sections'])
        .where((s) => s['package_id'] == pkgId && _kPackageKindsOnSummary.contains(s['kind']))
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
    final sources = asMapList(view['sources']);
    final disclaimer = view['disclaimer'] as String? ?? '';
    final empty = allFamilies.isEmpty && earlierFamilies.isEmpty && surgeries.isEmpty && allergies.isEmpty;
    const pad = EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6);
    if (empty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: pad,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s6),
            child: Text('还没有诊断、手术或过敏记录',
                textAlign: TextAlign.center, style: MedType.body.copyWith(color: c.ink2, height: 1.6)),
          ),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: pad,
      children: [
        _Header('诊断 / 问题'),
        if (families.isEmpty) _Hint('最近 12 个月没有诊断记录'),
        for (final f in families)
          FamilyTile(
            key: ValueKey('family:${f['key']}'),
            family: f,
            medNames: recentMedNamesOfFamily(medRows, '${f['key']}'),
            index: index,
            trailing: [
              for (final p in packages)
                if (p['family'] == f['key'] && placed.add('${p['id']}')) ...packageBlock(p),
            ],
          ),
        for (final p in packages)
          if (placed.add('${p['id']}')) ...[const SizedBox(height: MedShape.s2), ...packageBlock(p)],
        if (earlierFamilies.isNotEmpty)
          _Fold(
            title:
                '${tailFamilies.isEmpty ? '更早的诊断' : '更早的诊断与未归类'} · ${earlierFamilies.fold<int>(0, (n, f) => n + asMapList(f['diagnoses']).length)} 条',
            children: [
              for (final f in earlierFamilies) ...[
                Text('${f['label']}', style: MedType.caption.copyWith(color: c.ink2)),
                for (final d in asMapList(f['diagnoses'])) DiagnosisRow(dx: d, index: index),
              ],
            ],
          ),
        const SizedBox(height: MedShape.s3),
        _Header('手术史 · ${surgeries.length}'),
        if (surgeries.isEmpty) _Hint('记录里没找到手术'),
        for (final n in surgeries) _NodeRow(at: fmtDate(n['at'] as String?), text: '${n['to'] ?? ''}', ids: n['evidence'] as List? ?? const [], index: index),
        const SizedBox(height: MedShape.s3),
        _Header('植入物 · ${implants.length}'),
        if (implants.isEmpty) _Hint('记录里没找到植入物'),
        for (final d in implants) DiagnosisRow(dx: d, index: index),
        const SizedBox(height: MedShape.s3),
        _Header('过敏 · ${allergies.length}'),
        if (allergies.isEmpty) _Hint('记录里没找到过敏史'),
        for (final a in allergies)
          _NodeRow(
            at: '',
            text: ['${a['substance'] ?? ''}', if ('${a['reaction'] ?? ''}'.isNotEmpty) '${a['reaction']}'].join(' · '),
            ids: a['evidence'] as List? ?? const [],
            index: medsIndex,
          ),
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
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: MedType.subtitle.copyWith(color: MedColors.of(context).ink));
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

/// 一行「日期 · 文字 · 原件 ›」(手术、过敏)。
class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.at, required this.text, required this.ids, required this.index});
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
        padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (at.isNotEmpty)
              SizedBox(width: 92, child: Text(at, style: MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular))),
            Expanded(child: Text(text, style: MedType.body.copyWith(color: c.ink, height: 1.4))),
            if (has) Icon(Icons.chevron_right, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

/// 折叠一行(更早的诊断 / 出处)。
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

/// 一族一张折叠卡:标题「族名 · N 条诊断 · 最近 YYYY-MM」;展开 = 诊断行 → 最近的用药一行 → 包段。
class FamilyTile extends StatelessWidget {
  const FamilyTile({
    super.key,
    required this.family,
    required this.medNames,
    required this.index,
    this.trailing = const [],
  });

  final Map<String, dynamic> family;
  final List<String> medNames;
  final EvidenceIndex index;
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
                  // 写法最多再列一种,其余只说有几个(Epic 同一诊断能有五六种抄法)。
                  if (texts.length > 1)
                    Text(
                      [texts[1], if (texts.length > 2) '还有 ${texts.length - 2} 个写法'].join(' · '),
                      style: MedType.caption.copyWith(color: c.ink3),
                    ),
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
