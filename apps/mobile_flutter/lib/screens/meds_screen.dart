// 「用药」tab(2026-10-23 spec §5):最近的用药(180 天内有记录、原文没写停)在上,过敏紧随,
// 下面可搜索的更早的用药按药名聚合、点开看剂量变化链;每行、每个节点、每条过敏都能点开原件。
// 用户原话:「把药单独加一个 tab 显示最近,医生可以搜过往,过敏也移过去」。
// 措辞不用「当前用药 / 在吃 / 已停」:MedSpan.status 恒 active,不能暗示有效医嘱。
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/evidence_open.dart';
import 'package:mobile_flutter/screens/meds_model.dart';
import 'package:mobile_flutter/screens/now_model.dart' show asMapList;
import 'package:mobile_flutter/skill_packages.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

Future<Map<String, dynamic>> _loadFromVault() async =>
    jsonDecode(await rust_profile.vaultProfileMedsView(dir: await skillCacheDir())) as Map<String, dynamic>;

class MedsScreen extends StatefulWidget {
  const MedsScreen({super.key, this.load});

  /// null → 真的那一套(FFI)。测试注入。
  final Future<Map<String, dynamic>> Function()? load;

  @override
  State<MedsScreen> createState() => _MedsScreenState();
}

class _MedsScreenState extends State<MedsScreen> {
  late Future<Map<String, dynamic>> _future = _load();
  final _queryCtl = TextEditingController();
  String _query = '';
  bool _searchOpen = false;

  Future<Map<String, dynamic>> _load() => (widget.load ?? _loadFromVault)();

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
                  hintText: '搜药名,如「华法林」「Warfarin」',
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
            tooltip: _searchOpen ? '关闭搜索' : '按名字搜药',
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
    this.query = '',
    this.family,
    this.onClearFamily,
  });

  final Map<String, dynamic> view;
  final String query;
  final String? family;
  final VoidCallback? onClearFamily;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final index = EvidenceIndex.fromView(view);
    final staleDays = (view['stale_after_days'] as num?)?.toInt() ?? 180;
    final recent = medsByFamily(asMapList(view['recent']), family).where((r) => medMatches(r, query)).toList();
    final earlier = medsByFamily(asMapList(view['earlier']), family).where((r) => medMatches(r, query)).toList();
    final allergies = asMapList(view['allergies']).where((a) => allergyMatches(a, query)).toList();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6),
      children: [
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
        _SectionTitle('最近的用药 · ${recent.length}', sub: '$staleDays 天内有记录'),
        if (recent.isEmpty)
          _Hint('最近 $staleDays 天没有用药记录')
        else
          MedCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < recent.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  MedRowView(row: recent[i], index: index),
                ],
              ],
            ),
          ),
        const SizedBox(height: MedShape.s4),
        // 过敏紧随最近的用药(spec §5.2):空态不说「无过敏」——没找到不等于没有。
        _SectionTitle('过敏 · ${allergies.length}'),
        if (allergies.isEmpty)
          _Hint('记录里没找到过敏史')
        else
          MedCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < allergies.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  _AllergyRow(allergies[i], index),
                ],
              ],
            ),
          ),
        const SizedBox(height: MedShape.s4),
        _SectionTitle('更早的用药 · ${earlier.length}'),
        if (earlier.isEmpty)
          _Hint(query.isEmpty ? '没有更早的用药记录' : '没有名字含「$query」的药')
        else
          MedCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < earlier.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: c.line),
                  MedRowView(row: earlier[i], index: index),
                ],
              ],
            ),
          ),
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

/// 一味药一行:名 · 剂量 · 族;第二行「记录中自 … 起 · N 天前有记录」或「病历写了停药 · 日期」;
/// 点开 → 剂量变化链,每个节点带「原件 ›」。
class MedRowView extends StatefulWidget {
  const MedRowView({super.key, required this.row, required this.index});

  final Map<String, dynamic> row;
  final EvidenceIndex index;

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
    final muted = stale || stopped is Map;
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
                      Text(
                        stopped is Map
                            ? '病历写了停药 · ${fmtDate(stopped['at'] as String?)}'
                            : [
                                if (since.isNotEmpty) '记录中自 $since 起',
                                if (days != null) stale ? '$days 天没有新记录' : '$days 天前有记录',
                              ].join(' · '),
                        style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
                      ),
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

class _AllergyRow extends StatelessWidget {
  const _AllergyRow(this.a, this.index);
  final Map<String, dynamic> a;
  final EvidenceIndex index;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final ids = (a['evidence'] as List? ?? const []);
    final has = index.resolve(ids).isNotEmpty;
    final reaction = '${a['reaction'] ?? ''}';
    return InkWell(
      onTap: has ? () => openEvidence(context, index, ids) : null,
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
                  ],
                ),
              ),
            ),
            if (has) Icon(Icons.chevron_right, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
