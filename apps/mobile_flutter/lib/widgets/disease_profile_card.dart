// 「病程档案」入口卡 —— 「趋势」tab 自上而下的**第一块**。
//
// 2026-10-22 通用病程档案 spec(稿 A):**一张卡**,标题永远「病程档案」,正文是通用摘要
// (不靠任何病种包),每个装着的包各占一行(没开启 → 那行带「开启」按钮)。门槛:
//  · 带码诊断 ≥3 → 一行族 chip「心血管 3 · 感染 2 · …」(按引擎给的顺序,不重排);
//  · 带码诊断 <3 → 只出一行「已有 N 条诊断记录」,不展开族;
//  · 一条诊断、一种药都没有 → 卡上只写「还没有诊断或用药记录」。
// 用药一行「用药 N 种 · M 种超过 180 天没新记录」、最近住院一行,全是引擎给的数,这里只排版。
//
// **这一块出问题不许把整条「趋势」tab 带塌**:取数失败退回「还没准备好」那一行。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/disease_profile_screen.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';

// 入口卡的调用方(「趋势」tab)要拿 [DiseaseProfileSource] 去注入,一个 import 就够。
export 'package:mobile_flutter/screens/disease_profile_screen.dart'
    show DiseaseProfileSource;

const String _kTitle = '病程档案';

/// 这一块是干什么的 —— 空着的时候也要说清楚。
const String _kWhatItIs = '把诊断、用药、检查、住院串成一条线。';

class DiseaseProfileCard extends StatefulWidget {
  const DiseaseProfileCard({super.key, this.source});

  /// null → 真的那一套(FFI + 平台通道)。见 [DiseaseProfileSource]。
  final DiseaseProfileSource? source;

  @override
  State<DiseaseProfileCard> createState() => _DiseaseProfileCardState();
}

class _DiseaseProfileCardState extends State<DiseaseProfileCard> {
  late final DiseaseProfileSource _source = widget.source ?? DiseaseProfileSource();
  late Future<Map<String, dynamic>?> _future = _load();

  /// 「开启」记录中 —— 防连点。
  bool _busy = false;

  /// `null` = 这次没拿到通用视图(FFI 没起来 / 箱子没开)。
  Future<Map<String, dynamic>?> _load() async {
    try {
      final v = await _source.general();
      // 装着的包一个都没有时静默拉一次清单(没网就是这次没更新),拉到了就重算。
      if (packageRows(v).isEmpty) {
        await _source.refresh();
        if ((await _source.installedPackages()).isNotEmpty) return await _source.general();
      }
      return v;
    } catch (e) {
      debugPrint('[profile] 入口卡这次没拿到档案:$e');
      return null;
    }
  }

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
    if (mounted) _reload();
  }

  /// `setState` 是**语句块不是箭头**(理由见 `test/known_defect_setstate_future_test.dart`)。
  void _reload() {
    final next = _load();
    setState(() {
      _future = next;
    });
  }

  /// 开启某个包:记一条 `enable`,**记上了才重算**。
  Future<void> _enable(String packageId) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _source.record('enable', packageId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _reload();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: const Text('这次没记上 —— 再点一下试试')),
      );
    }
  }

  /// 点开整页。**回来必须重算一次**:那一页上可能刚开过或刚关过。
  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiseaseProfileScreen(source: _source),
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _ProfileEntry(title: _kTitle, subtitle: '$_kWhatItIs正在准备…');
        }
        final view = snap.data;
        if (view == null) {
          return _ProfileEntry(
            title: _kTitle,
            subtitle: '$_kWhatItIs还没准备好 —— 点一下重试。',
            onTap: _reload,
          );
        }
        final summary = GeneralSummary.of(view);
        final packages = packageRows(view);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileEntry(
              title: _kTitle,
              subtitle: [...summary.lines, for (final p in packages) if (p.enabled) '${p.name}:已开启'].join('\n'),
              onTap: _open,
            ),
            for (final p in packages)
              if (!p.enabled) ...[
                const SizedBox(height: MedShape.s2),
                _PackageRow(
                  name: p.name,
                  onEnable: _busy ? null : () => _enable(p.id),
                ),
              ],
          ],
        );
      },
    );
  }
}

/// 通用视图 → 入口卡上那几行字。**只排版、不计算新东西**:计数都是数引擎给的条目。
class GeneralSummary {
  const GeneralSummary(this.lines);

  final List<String> lines;

  static Map<String, dynamic>? _section(Map<String, dynamic> view, String kind) {
    for (final s in (view['sections'] as List? ?? const [])) {
      if (s is Map && s['kind'] == kind && (s['package_id'] ?? 'general') == 'general') {
        return s.cast<String, dynamic>();
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _maps(dynamic v) =>
      (v as List? ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

  static GeneralSummary of(Map<String, dynamic> view) {
    final families = _maps(_section(view, 'family_cards')?['body']?['families']);
    final rows = _maps(_section(view, 'med_table')?['body']?['rows']);
    final staleAfter = (_section(view, 'med_table')?['body']?['stale_after_days'] as num?)?.toInt() ?? 180;
    var total = 0, coded = 0;
    for (final f in families) {
      for (final d in _maps(f['diagnoses'])) {
        total++;
        if (d['code'] is String) coded++;
      }
    }
    if (total == 0 && rows.isEmpty) return const GeneralSummary(['还没有诊断或用药记录']);
    final lines = <String>[];
    if (coded >= 3) {
      lines.add([for (final f in families) '${f['label']} ${f['count']}'].join(' · '));
    } else if (total > 0) {
      lines.add('已有 $total 条诊断记录');
    }
    if (rows.isNotEmpty) {
      final stale = rows.where((r) => r['stale'] == true).length;
      lines.add(
        stale > 0 ? '用药 ${rows.length} 种 · $stale 种超过 $staleAfter 天没新记录' : '用药 ${rows.length} 种',
      );
    }
    final inpatient = _maps(_section(view, 'journey')?['body']?['lanes'])
        .where((l) => l['key'] == 'enc_inpatient')
        .expand((l) => _maps(l['nodes']))
        .where((n) => n['at'] is String)
        .toList()
      ..sort((a, b) => '${b['at']}'.compareTo('${a['at']}'));
    if (inpatient.isNotEmpty) {
      final n = inpatient.first;
      final when = '${n['to'] ?? ''}'.split(' · ').first;
      final provider = '${n['text'] ?? ''}'.split(' · ').first;
      lines.add(['最近住院 $when', if (provider.isNotEmpty) provider].join(' · '));
    }
    return GeneralSummary(lines);
  }
}

/// 卡片外壳:病历本条(白卡一行,`widgets/record_book_strip.dart`),整条可点。
class _ProfileEntry extends StatelessWidget {
  const _ProfileEntry({required this.title, required this.subtitle, this.onTap});

  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) =>
      RecordBookStrip(title: title, subtitle: subtitle, onTap: onTap);
}

/// 装着没开的包:一行名字 + 「开启」。病名是包给的,逐字。
class _PackageRow extends StatelessWidget {
  const _PackageRow({required this.name, required this.onEnable});

  final String name;
  final VoidCallback? onEnable;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 按钮是整行宽的(`MedSecondaryButton` 自己撑满),所以名字一行、按钮一行,不并排。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '可以整理「$name」这个病 —— 开启之后,用药、检查、该复查的会整理成档案页里的一段。',
          style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
        ),
        const SizedBox(height: MedShape.s2),
        MedSecondaryButton(label: '开启', onPressed: onEnable),
      ],
    );
  }
}
