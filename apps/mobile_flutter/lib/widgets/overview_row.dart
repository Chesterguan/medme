// 病历 tab 成员行下的一行概况(checkpoint 1 F4):「换瓣术后 · 心内膜炎 · 肺曲霉病 ｜ 最近用药 N ｜ 过敏 N」,
// 点进健康摘要。数据走 `profile_cache.dart`(与健康摘要同一份,不重算)。用户场景 1「主要问题是什么」
// 原来要 3 次点击。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/profile_cache.dart';
import 'package:mobile_flutter/profile_json.dart';
import 'package:mobile_flutter/screens/health_summary_screen.dart';
import 'package:mobile_flutter/vault_events.dart';

typedef OverviewData = (Map<String, dynamic> view, Map<String, dynamic> meds);

Future<OverviewData> _loadFromVault() async {
  final r = await Future.wait<Map<String, dynamic>>([cachedGeneralView(), cachedMedsView()]);
  return (r[0], r[1]);
}

/// 概况那一行的文字(纯函数,可测):诊断最多三条 ｜ 最近用药 N ｜ 过敏 N;什么都没有 → 空串。
String overviewText(Map<String, dynamic> view, Map<String, dynamic> meds) {
  final dx = overviewDiagnoses(view);
  final nMeds = asMapList(meds['recent']).length;
  final nAllergy = asMapList(meds['allergies']).length;
  if (dx.isEmpty && nMeds == 0 && nAllergy == 0) return '';
  return [
    if (dx.isNotEmpty) dx.join(' · '),
    '最近用药 $nMeds',
    '过敏 $nAllergy',
  ].join(' ｜ ');
}

class OverviewRow extends StatefulWidget {
  const OverviewRow({super.key, this.load});

  /// null → 真的那一套(缓存的 FFI 视图)。测试注入。
  final Future<OverviewData> Function()? load;

  @override
  State<OverviewRow> createState() => _OverviewRowState();
}

class _OverviewRowState extends State<OverviewRow> {
  late Future<OverviewData> _future = (widget.load ?? _loadFromVault)();

  @override
  void initState() {
    super.initState();
    vaultRevision.addListener(_reload);
  }

  @override
  void dispose() {
    vaultRevision.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = (widget.load ?? _loadFromVault)());
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return FutureBuilder<OverviewData>(
      future: _future,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final (view, meds) = snap.data!;
        final text = overviewText(view, meds);
        if (text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: MedShape.s1),
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const HealthSummaryScreen()),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: MedType.secondary.copyWith(color: c.ink2, height: 1.4),
                    ),
                  ),
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
