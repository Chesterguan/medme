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

  /// 「只看非正常项」。**默认开。**
  ///
  /// 一份血常规就是 22 条序列,真实用户几年下来上百条 —— 全列出来要滚很久,而「复诊
  /// 前看一眼」的人多半冲着被标过的那两条来。默认过滤确实是在替用户排序,所以代价
  /// 必须付清:被隐藏了多少条**始终写在开关旁边**,一眼看得见、一下关得掉。
  ///
  /// 判据是 Rust 给的 `anyAbnormal`,**不是** UI 自己拿参考区间算的。
  ///
  /// 措辞用「非正常项」而不是「被标过 H/L 的」:`flag` 的定义是「有 ↑/↓/H/L 标记就
  /// 用标记,没有就拿值和参考区间比」(`labs.rs:63`)—— 一大半 flag 是算出来的,化验
  /// 单上根本没印箭头。说「被标过 H/L」把这半边排除在外了,不准确。
  ///
  /// 被隐藏的那些是「正常或判断不了」两类合一(没有参考区间就得不出结论),所以计数
  /// 文案照实说,不写成「N 条正常」。
  bool _abnormalOnly = true;

  /// 搜索词。**非空时 [_abnormalOnly] 让位。**
  ///
  /// 搜索是一次明确的「我要找 X」。若此时仍按非正常过滤,用户搜「肌酐」而肌酐正常,
  /// 得到的是一片空白 —— 他会以为自己从没查过肌酐。找得到比过滤干净重要。
  final _queryCtl = TextEditingController();
  String _query = '';

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
          final searching = _query.isNotEmpty;
          final shown = trendVisible(
            all,
            query: _query,
            abnormalOnly: _abnormalOnly,
          );
          final hiddenByFilter = searching ? 0 : all.length - shown.length;

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
                    controller: _queryCtl,
                    searching: searching,
                    abnormalOnly: _abnormalOnly,
                    hiddenByFilter: hiddenByFilter,
                    onQuery: (v) => setState(() => _query = v.trim()),
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
                        searching
                            // 说的是「这些记录里没有」,不是「你没查过」—— 没搜到很
                            // 可能是同一个指标印成了别的名字(见顶部说明)。
                            ? '这些记录里没有名字含「$_query」的指标。\n'
                                  '换个叫法试试 —— 同一项在不同医院可能印成「肌酐」「血肌酐」「Cr」。'
                            : '这些记录里没有非正常项。',
                        textAlign: TextAlign.center,
                        style: MedType.body.copyWith(color: c.ink2, height: 1.6),
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

/// 指标名是否命中搜索词:大小写无关的子串匹配。
///
/// **刻意只匹配显示名。** 不碰 `analyteKey`(那是 `creatinine` 这种内部键,中文用户
/// 不会去输),更不做模糊匹配 —— 把「肌酐」模糊到「肌钙蛋白」上,用户会以为自己查过
/// 一个从没查过的项目。找不到时那句空态提示会告诉他换个叫法,那比替他猜要诚实。
bool trendNameMatches(String name, String query) =>
    name.toLowerCase().contains(query.toLowerCase());

/// 该显示哪些序列。**搜索优先于「只看非正常项」,不是叠加。**
///
/// 叠加是想当然的写法,但结果是用户搜「肌酐」而肌酐一直正常时得到一片空白 ——
/// 他会得出「我从没查过肌酐」这个错误结论,而真相是查过而且都正常。搜索是一次明确
/// 的「我要找 X」,找得到比过滤干净重要。
List<TrendSeriesDto> trendVisible(
  List<TrendSeriesDto> all, {
  required String query,
  required bool abnormalOnly,
}) {
  if (query.isNotEmpty) {
    return all.where((s) => trendNameMatches(s.name, query)).toList();
  }
  return abnormalOnly ? all.where((s) => s.anyAbnormal).toList() : all;
}

/// 列表顶上的说明 + 搜索框 + 「只看非正常项」开关。
///
/// 那句说明不是客套。用户会问「我明明查过五次肌酐,这里怎么只有两个点」——
/// 答案是术语没归一化,另外三次被分到了另一条名字不同的序列里。与其让他自己猜,
/// 不如先说清楚这张图的边界在哪。
class _Preamble extends StatelessWidget {
  const _Preamble({
    required this.total,
    required this.controller,
    required this.searching,
    required this.abnormalOnly,
    required this.hiddenByFilter,
    required this.onQuery,
    required this.onToggle,
  });

  final int total;
  final TextEditingController controller;
  final bool searching;
  final bool abnormalOnly;
  final int hiddenByFilter;
  final ValueChanged<String> onQuery;
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
        TextField(
          controller: controller,
          onChanged: onQuery,
          textInputAction: TextInputAction.search,
          style: MedType.body.copyWith(color: c.ink),
          decoration: InputDecoration(
            hintText: '搜指标名,如「肌酐」「血红蛋白」',
            hintStyle: MedType.body.copyWith(color: c.ink3),
            prefixIcon: Icon(Icons.search, size: 20, color: c.ink3),
            suffixIcon: searching
                ? IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: c.ink2,
                    tooltip: '清空搜索',
                    onPressed: () {
                      controller.clear();
                      onQuery('');
                    },
                  )
                : null,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: MedShape.s2,
              vertical: MedShape.s2,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(MedShape.radiusControl),
              borderSide: BorderSide(color: c.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(MedShape.radiusControl),
              borderSide: BorderSide(color: c.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(MedShape.radiusControl),
              borderSide: BorderSide(color: c.sealInk),
            ),
          ),
        ),
        const SizedBox(height: MedShape.s2),
        // 搜索时开关整个让位。留一颗按不动的开关在那儿,只会让人以为是它没生效。
        if (searching)
          Text(
            '搜索时不过滤 —— 正常项也一起找。',
            style: MedType.secondary.copyWith(color: c.ink3),
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  // 隐藏了多少条**必须**一直写着:默认开过滤是在替用户排序,
                  // 代价就是让他随时看得见自己没在看什么。
                  abnormalOnly && hiddenByFilter > 0
                      ? '只看非正常项 · 另有 $hiddenByFilter 条正常或判断不了'
                      : '只看非正常项',
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
