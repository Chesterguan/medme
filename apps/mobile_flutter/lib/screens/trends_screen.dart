import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 底部导航一级 tab「趋势」—— 使用时刻:**复诊前自己看「这两年怎么变的」**
/// (设计系统 §八)。
///
/// 与概览的分工很硬:概览回答「我最近一次测的是多少」(每条序列只取最新一个点),
/// 这一屏回答「它是怎么走到这个数的」(全部点)。这是两个时刻,不是两种排版。
///
/// ## 这一屏最容易撒的谎
///
/// 规范 §十把趋势排在落地顺序最后,理由写得很直白:**它是抽取质量的放大器**。
/// 实测术语未映射 65%,而 `aggregate.rs` 的分组键**永不**把「未匹配」与「已匹配」
/// 合并 —— 于是同一个指标可能出现「肌酐」「血肌酐」「Cr」三条各两点的断线,而不是
/// 一条六点的趋势。
///
/// 这一屏没有、也不该有任何代码去「聪明地」把它们并起来:UI 层按名字猜哪两条是同一
/// 个指标,就是在数据里造关系。`TrendSeriesDto` 带着 `analyteKey` / `loinc` 正是为了
/// 让**归一化在 Rust 侧**做完再下发;`analyteKey == null` 的序列就是没归一化成功的,
/// 它照原样显示,顶部那条说明把这件事说给用户听。
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  late Future<List<TrendSeriesDto>> _future = viewTrends();

  /// 「只看有异常的」。默认关 —— 默认过滤掉正常序列等于替用户决定什么值得看。
  ///
  /// 但这颗开关是必要的:一份血常规就是 22 条序列,全列出来要滚很久,而「复诊前
  /// 看一眼」的人多半冲着被标过 H/L 的那两条来。判据是 Rust 给的 `anyAbnormal`,
  /// **不是** UI 拿参考区间算的。
  bool _abnormalOnly = false;

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
    final next = viewTrends();
    setState(() {
      _future = next;
    });
    await next;
  }

  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('趋势'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<List<TrendSeriesDto>>(
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
                      '加载趋势失败:\n${snap.error}\n\n下拉可重试。',
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                    ),
                  ),
                ],
              ),
            );
          }

          // ⚠️ **UI 自己再 gate 一次。** Rust 侧的 `is_renderable`
          // (handoff.rs:369)已经把「全部点都无日期」的序列挡掉了,这里仍然独立
          // 判一次 —— 渲染器该自己知道自己画不了什么,而不是相信下发的数据。
          // 查看器在同一处留了同样的注释。
          final all = snap.data!.where(trendSeriesIsRenderable).toList();
          final shown = _abnormalOnly
              ? all.where((s) => s.anyAbnormal).toList()
              : all;
          final hiddenByFilter = all.length - shown.length;

          return RefreshIndicator(
            onRefresh: _refresh,
            color: c.seal,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                MedShape.s3,
                MedShape.s3,
                MedShape.s3,
                MedShape.s6,
              ),
              children: [
                if (all.isEmpty)
                  const _EmptyTrends()
                else ...[
                  _Preamble(
                    total: all.length,
                    abnormalOnly: _abnormalOnly,
                    hiddenByFilter: hiddenByFilter,
                    onToggle: (v) => setState(() => _abnormalOnly = v),
                  ),
                  const SizedBox(height: MedShape.s3),
                  for (var i = 0; i < shown.length; i++) ...[
                    if (i > 0) const SizedBox(height: MedShape.s2),
                    _SeriesCard(series: shown[i], onOpenDoc: _openDoc),
                  ],
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: MedShape.s5,
                      ),
                      child: Text(
                        '这些记录里没有任何一条被化验单标过 H/L。',
                        textAlign: TextAlign.center,
                        style: MedType.body.copyWith(color: c.ink2),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 列表顶上的说明 + 「只看有异常的」开关。
///
/// 那句说明不是客套。用户会问「我明明查过五次肌酐,这里怎么只有两个点」——
/// 答案是术语没归一化,另外三次被分到了另一条名字不同的序列里。与其让他自己猜,
/// 不如先说清楚这张图的边界在哪。
class _Preamble extends StatelessWidget {
  const _Preamble({
    required this.total,
    required this.abnormalOnly,
    required this.hiddenByFilter,
    required this.onToggle,
  });

  final int total;
  final bool abnormalOnly;
  final int hiddenByFilter;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$total 条指标可以画成趋势。同一个指标在不同医院可能印成不同的名字'
          '(「肌酐」「血肌酐」「Cr」),MedMe 只在能确定是同一项时才把它们连成一条线 ——'
          '所以你可能看到同一个指标出现不止一次。',
          style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
        ),
        const SizedBox(height: MedShape.s2),
        Row(
          children: [
            Expanded(
              child: Text(
                abnormalOnly && hiddenByFilter > 0
                    ? '只看被标过 H/L 的 · 已隐藏 $hiddenByFilter 条'
                    : '只看被标过 H/L 的',
                style: MedType.body.copyWith(color: c.ink),
              ),
            ),
            Switch(value: abnormalOnly, onChanged: onToggle),
          ],
        ),
      ],
    );
  }
}

/// 一条序列一张卡:卡头(项目名 + pill + 最新值)→ 折线 → 参考区间图例 + 时间跨度
/// → 最新一次的原件入口。
///
/// **不画骑缝线。** 这是一张派生卡:一条趋势是从许多份原件里算出来的结论,背后没有
/// 「某一张纸」叫做「肌酐趋势」(规范 §五,那里正是拿趋势汇总卡当反例的)。可溯源
/// 由卡底那颗「最新一次的原件」兑现 —— 它指向一个具体的 `documentId`。
class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.series, required this.onOpenDoc});

  final TrendSeriesDto series;
  final void Function(int docId) onOpenDoc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final pts = trendDatedPoints(series);
    // 调用方已经 gate 过 `trendSeriesIsRenderable`,这里必不为空;真为空也只是
    // 少画一张卡,不崩。
    if (pts.isEmpty) return const SizedBox.shrink();

    final last = pts.last;
    final status = labStatusOf(last.flag);
    final pill = labStatusPill(context, last.flag);
    final ref = refRangeText(series.refLow, series.refHigh);
    // 单位以**点自己的**为准:同一指标跨报告单位可能不一致,序列级 unit 只是取了
    // 最后一个点的(见 DTO 文档)。这里显示的就是最后一个点,两者其实同源。
    final unit = last.unit ?? series.unit;
    final undated = series.points.length - pts.length;

    return MedCard(
      child: Padding(
        padding: const EdgeInsets.all(MedShape.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 卡头 ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: MedShape.s1,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        series.name,
                        style: MedType.subtitle.copyWith(color: c.ink),
                      ),
                      ?pill,
                    ],
                  ),
                ),
                const SizedBox(width: MedShape.s2),
                // 最新值用 `value` 字阶(22 · 600 · 等宽表格数字)。sparkSVG 是把
                // 它用 10px 画在图里的 —— 10 低于字阶下限 12,而且画布里的字不跟
                // 系统字号放大。搬到这里既更大也更可放大。
                Text(
                  fmtLabNumber(last.value),
                  style: MedType.value.copyWith(
                    color: labStatusColor(context, status),
                  ),
                ),
                if (unit != null && unit.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      unit,
                      style: MedType.secondary.copyWith(color: c.ink3),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: MedShape.s2),

            // ── 图 ──
            TrendChart(series: series),
            const SizedBox(height: MedShape.s1),

            // ── 图例与跨度 ──
            Wrap(
              spacing: MedShape.s2,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (ref != null) _RefLegend(text: '参考区间 $ref'),
                Text(
                  pts.length == 1
                      ? '只有 ${pts.first.date} 这一次'
                      : '${pts.first.date} 起 ${pts.length} 次',
                  style: MedType.secondary.copyWith(
                    color: c.ink3,
                    fontFeatures: MedType.tabular,
                  ),
                ),
              ],
            ),

            // 无日期的点画不到时间轴上,所以图里没有它们。**说出来** —— 否则用户
            // 数图上的点会发现比他记忆里的次数少,而少掉的那几次没有任何交代。
            if (undated > 0) ...[
              const SizedBox(height: 4),
              Text(
                '另有 $undated 次没能从报告上定出日期,画不到时间轴上;它们在档案里照样能翻到。',
                style: MedType.secondary.copyWith(color: c.ink3, height: 1.4),
              ),
            ],

            const SizedBox(height: MedShape.s1),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => onOpenDoc(last.documentId),
                style: TextButton.styleFrom(
                  foregroundColor: c.sealInk,
                  padding: const EdgeInsets.symmetric(horizontal: MedShape.s1),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('查看最新一次的原件', style: MedType.secondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 参考带的图例:一小块和图里同色的色块 + 文字。
///
/// 图里那条带子没有标数值(画布里一个字都没有,见 `TrendChart` 的文档),数值由
/// 这行文字给。色块和带子同色同边框,眼睛才连得起来。
class _RefLegend extends StatelessWidget {
  const _RefLegend({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 10,
          decoration: BoxDecoration(
            color: c.sealWash,
            border: Border.all(color: c.ink3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: MedType.secondary.copyWith(
            color: c.ink3,
            fontFeatures: MedType.tabular,
          ),
        ),
      ],
    );
  }
}

/// 空态。规范 §六:**必须给出路**,留白等于说「你没有相关检查」,那是临床上的假话。
class _EmptyTrends extends StatelessWidget {
  const _EmptyTrends();

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MedShape.s6),
      child: DottedBorderBox(
        child: Column(
          children: [
            Icon(Icons.show_chart, size: 48, color: c.ink3),
            const SizedBox(height: MedShape.s2),
            Text('还画不出趋势', style: MedType.subtitle.copyWith(color: c.ink)),
            const SizedBox(height: MedShape.s1),
            // 说的是我们**观察到**什么,不是用户身上有没有事。
            Text(
              '趋势需要同一个指标在不同日期至少测过一次,并且报告上能定出日期。\n'
              '在「档案」里导入几张化验单,这里就会长出线来。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
            const SizedBox(height: MedShape.s3),
            OutlinedButton(
              onPressed: goToArchive,
              child: const Text('去档案导入化验单'),
            ),
          ],
        ),
      ),
    );
  }
}
