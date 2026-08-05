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

/// 这一屏一次要用到的两样东西:全部趋势序列 + 检验大类 chip 的目录(顺序、文案)。
/// 与 `emergency_card_screen.dart` 的 `_CardData` 同一手法。
typedef _TrendsData = (List<TrendSeriesDto>, List<String>);

class _TrendsScreenState extends State<TrendsScreen> {
  late Future<_TrendsData> _future = _load();

  Future<_TrendsData> _load() async {
    final r = await Future.wait([viewTrends(), viewTrendPanelCatalog()]);
    return (r[0] as List<TrendSeriesDto>, r[1] as List<String>);
  }

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

  /// 搜索栏是否展开。**默认收起,标题栏上一颗放大镜。**
  ///
  /// 分类 chip 上线后,检索的主路径是点 tag —— 手机上打「嗜酸性粒细胞百分比」比
  /// 滚一遍还慢。但搜索仍有一件 tag 干不了的事:**你不确定某个指标归进了哪个检
  /// 验大类,或者它根本没能归一化、只能在「其他」里翻**(词典没覆盖到的指标,
  /// 或者归一化到了词典里没配 panel 的专科检验)。所以它留着,只是不再每次进
  /// 页面都占掉近 90px 把第一张图挤出屏幕。
  bool _searchOpen = false;

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        // 收起就清空 —— 留一个看不见却仍在生效的过滤条件,是「怎么少了一半」的来源。
        _queryCtl.clear();
        _query = '';
      }
    });
  }

  /// 选中的检验大类 chip。`null` = 「全部」(不筛)。**选中时 [_abnormalOnly]
  /// 同样让位** —— 与搜索同一条理由(见 [_query] 的文档):点开一个大类是「我要
  /// 看这类检查都查过什么」,不是「我要看这类检查里出过问题的那两条」。默认过
  /// 滤是在替用户排序,而选中大类本身已经是一次明确的缩小范围,不该再叠一层。
  ///
  /// 取值:一个来自 [viewTrendPanelCatalog] 的大类文案,或 [kOtherTrendPanel]
  /// (「其他」桶)。与搜索不冲突,可以同时生效(先按大类筛,再按搜索词筛)。
  String? _selectedPanel;

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
            : const Text('趋势'),
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
      body: FutureBuilder<_TrendsData>(
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
          final (series, catalog) = snap.data!;
          final all = series.where(trendSeriesIsRenderable).toList();
          final searching = _query.isNotEmpty;
          final panelSelected = _selectedPanel != null;
          final chips = trendPanelChips(all, catalog: catalog);
          final shown = trendVisible(
            all,
            query: _query,
            abnormalOnly: _abnormalOnly,
            panel: _selectedPanel,
          );
          // 大类和搜索一样让「只看非正常项」让位(理由见 [_selectedPanel] 的文档),
          // 此时谈不上「被过滤隐藏了多少条」,这句提示本身就不会显示。
          final hiddenByFilter = (searching || panelSelected)
              ? 0
              : all.length - shown.length;

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
                    panelChips: chips,
                    selectedPanel: _selectedPanel,
                    onQuery: (v) => setState(() => _query = v.trim()),
                    onToggle: (v) => setState(() => _abnormalOnly = v),
                    onSelectPanel: (g) => setState(() => _selectedPanel = g),
                  ),
                  const SizedBox(height: MedShape.s3),
                  for (var i = 0; i < shown.length; i++) ...[
                    if (i > 0) const SizedBox(height: MedShape.s2),
                    SeriesCard(series: shown[i], onOpenDoc: _openDoc),
                  ],
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: MedShape.s5,
                      ),
                      child: Text(
                        // 说的是「这些记录里没有」,不是「你没查过」—— 没搜到很可能
                        // 是同一个指标印成了别的名字(见顶部说明)。
                        searching
                            ? (panelSelected
                                  ? '「${_panelChipLabel(_selectedPanel)}」里没有名字含'
                                        '「$_query」的指标。\n清空搜索可以看这个大类下的全部。'
                                  : '这些记录里没有名字含「$_query」的指标。\n'
                                        '换个叫法试试 —— 同一项在不同医院可能印成「肌酐」「血肌酐」「Cr」。')
                            // chip 只在大类下至少有一条可渲染序列时才出现(见
                            // `trendPanelChips`),选中后过滤为空理论上到不了这里;
                            // 留一句兜底文案而不是让页面崩掉或空白一片。
                            : (panelSelected
                                  ? '这个大类下没有可显示的指标。'
                                  : '这些记录里没有非正常项。'),
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

/// 「其他」分类 chip 的选中态取值。**不是** Rust 目录里的真实大类文案 —— 那些
/// 都是化验单印刷的项目组表头(「肾功能」「血脂」…),不会撞上这个哨兵。
///
/// 「其他」本身不是词典策展出来的第 15 个大类,是补集:一条序列的 `panel` 是
/// `null`(没能归一化出 `analyteKey`,或归一化到的条目在词典里没配 panel),它
/// 就落进这里 —— 判定逻辑见 [trendPanelMatches]。大类匹配本身(哪条序列属于哪
/// 个 panel)已经在 Rust 侧按 `analyteKey` 查词典算完
/// (`vault_projections.rs` 的 `terminology::panel_for`),这里只是读 `panel`
/// 判个「有没有」,不是又拿名字猜一遍(007 §2.5)。
const kOtherTrendPanel = '__other__';

/// 一条序列是否命中选中的大类 chip。
///
/// - `null`(「全部」)—— 不筛,全部命中。
/// - [kOtherTrendPanel](「其他」)—— `panel` 为 `null` 才命中。
/// - 其余 —— 精确等于 Rust 目录给的大类文案(`panel ==`,不是 `contains`:
///   一条序列只有一个 panel,不像旧的疾病泳道允许多重归属)。
bool trendPanelMatches(TrendSeriesDto s, String? panel) {
  if (panel == null) return true;
  if (panel == kOtherTrendPanel) return s.panel == null;
  return s.panel == panel;
}

/// 该显示哪些序列。**搜索、选大类都优先于「只看非正常项」,不是叠加在它上面
/// —— 但搜索和选大类彼此叠加(先按大类筛,再按搜索词筛)。**
///
/// 「只看非正常项」让位的理由对搜索和选大类是同一条:两者都是用户一次明确的
/// 「我要看 X」——搜「肌酐」却因为肌酐一直正常被过滤成空白,他会得出「我从没
/// 查过肌酐」这个错误结论;点开「肾功能」chip 却因为默认过滤只看到里面被标过的
/// 那两条,他会以为这类检查平时没怎么查。找得到 / 看得全比过滤干净重要。
///
/// 搜索和选大类不是同一件事(浏览 vs. 输入),所以彼此不互斥、可以同时生效:
/// 选中「肾功能」后再搜「肌酐」,是在肾功能这个大类里再精确定位。
List<TrendSeriesDto> trendVisible(
  List<TrendSeriesDto> all, {
  required String query,
  required bool abnormalOnly,
  String? panel,
}) {
  final byPanel = panel == null
      ? all
      : all.where((s) => trendPanelMatches(s, panel)).toList();
  if (query.isNotEmpty) {
    return byPanel.where((s) => trendNameMatches(s.name, query)).toList();
  }
  if (abnormalOnly && panel == null) {
    return byPanel.where((s) => s.anyAbnormal).toList();
  }
  return byPanel;
}

/// 一颗大类 chip 要展示的数据:选中态要喂给 [trendPanelMatches] 的 `panel`
/// 值、chip 上的文字、chip 上的计数。
class TrendPanelChipData {
  const TrendPanelChipData({
    required this.panel,
    required this.label,
    required this.count,
  });

  /// 喂给 [trendVisible]/[trendPanelMatches] 的 `panel`:`null` = 全部,
  /// [kOtherTrendPanel] = 其他,其余是 Rust 目录给的大类文案。
  final String? panel;
  final String label;
  final int count;
}

/// 组装要渲染的大类 chip 列表:「全部」恒在最前,固定大类按 [catalog](Rust
/// 给的目录顺序,即化验单印刷惯例的策展顺序)排列,「其他」殿后。
///
/// **计数为 0 的大类 chip 一律不出现**——一个点开什么都没有的 chip 是纯噪音
/// (需求原文)。计数口径是 `all` 里这条序列的数量,不受当前搜索词/「只看非
/// 正常项」影响:chip 要稳定地告诉用户「这个大类总共有几条」,不能随手指输入
/// 抖动。
///
/// 「全部」和「其他」是产品定的两个**兜底** chip,不是词典策展出来的第 15/16
/// 个大类:没能归一化的序列(实测占比不低)拿不到 panel,没有「其他」兜底,
/// 这些指标会从分类入口里彻底消失。
List<TrendPanelChipData> trendPanelChips(
  List<TrendSeriesDto> all, {
  required List<String> catalog,
}) {
  final chips = <TrendPanelChipData>[
    TrendPanelChipData(panel: null, label: '全部', count: all.length),
  ];
  for (final label in catalog) {
    final n = all.where((s) => s.panel == label).length;
    if (n > 0) {
      chips.add(TrendPanelChipData(panel: label, label: label, count: n));
    }
  }
  final otherCount = all.where((s) => s.panel == null).length;
  if (otherCount > 0) {
    chips.add(
      TrendPanelChipData(
        panel: kOtherTrendPanel,
        label: '其他',
        count: otherCount,
      ),
    );
  }
  return chips;
}

/// 选中态 `panel` 值 → 人话文案,给空态提示用。
String _panelChipLabel(String? panel) =>
    panel == kOtherTrendPanel ? '其他' : (panel ?? '全部');

/// 列表顶上的说明 + 搜索框 + 检验大类 chip + 「只看非正常项」开关。
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
    required this.panelChips,
    required this.selectedPanel,
    required this.onQuery,
    required this.onToggle,
    required this.onSelectPanel,
  });

  final int total;
  final TextEditingController controller;
  final bool searching;
  final bool abnormalOnly;
  final int hiddenByFilter;
  final List<TrendPanelChipData> panelChips;
  final String? selectedPanel;
  final ValueChanged<String> onQuery;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String?> onSelectPanel;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final panelSelected = selectedPanel != null;
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
        // 这一排是**检索的主路径**。搜索收进了标题栏的放大镜(见 `_searchOpen`):浏览
        // 「这类检查都有哪些」。少于两颗(只有恒在的「全部」)时不画这一排 ——
        // 一整排只能点「全部」等于什么都点不了,是纯噪音。
        if (panelChips.length > 1) ...[
          const SizedBox(height: MedShape.s2),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: panelChips.length,
              separatorBuilder: (_, _) => const SizedBox(width: MedShape.s1),
              itemBuilder: (context, i) {
                final chip = panelChips[i];
                return _PanelChip(
                  label: chip.label,
                  count: chip.count,
                  selected: chip.panel == selectedPanel,
                  onTap: () => onSelectPanel(
                    chip.panel == selectedPanel ? null : chip.panel,
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: MedShape.s2),
        // 搜索或选中大类时开关整个让位(理由见 `trendVisible` 的文档)。留一颗
        // 按不动的开关在那儿,只会让人以为是它没生效。
        if (searching || panelSelected)
          Text(
            searching
                ? '搜索时不过滤 —— 正常项也一起找。'
                : '「${_panelChipLabel(selectedPanel)}」下不过滤 —— 这类检查查过的都在这。',
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

/// 一颗大类 chip:未选中是描边,选中是印章色实底(与 `labStatusPill` 系的
/// 「前景+浅底」不同 —— 这里要表达的是「可点选的一个开关」,不是化验状态)。
class _PanelChip extends StatelessWidget {
  const _PanelChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MedShape.radiusPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: MedShape.s2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? c.sealWash : c.surface,
          borderRadius: BorderRadius.circular(MedShape.radiusPill),
          border: Border.all(color: selected ? c.sealInk : c.line),
        ),
        child: Text(
          // 计数直接跟在文案后面(「肾功能 6」),不用括号 —— 与卡头「最新值 +
          // 单位」同一套「数字紧挨着它描述的东西」的排法。
          '$label $count',
          style: MedType.body.copyWith(
            color: selected ? c.sealInk : c.ink2,
            fontFeatures: MedType.tabular,
          ),
        ),
      ),
    );
  }
}

/// 一条序列一张卡:卡头(项目名 + pill + 最新值)→ 折线 → 参考区间图例 + 时间跨度
/// → 最新一次的原件入口。
///
/// **不画骑缝线。** 这是一张派生卡:一条趋势是从许多份原件里算出来的结论,背后没有
/// 「某一张纸」叫做「肌酐趋势」(规范 §五,那里正是拿趋势汇总卡当反例的)。可溯源
/// 由卡底那颗「最新一次的原件」兑现 —— 它指向一个具体的 `documentId`。
class SeriesCard extends StatelessWidget {
  /// **公开是为了可测。** 「自测序列必须带文字图例」这条只能在渲染出来的卡上验证
  /// —— 整屏 pump 需要 `viewTrends()` 的 Rust FFI,测试环境没有原生库。与
  /// `manualEntryRangeError` 同一个先例:把被测单元暴露出来,而不是把断言降级成
  /// 「只测纯函数、渲染层靠肉眼」。
  const SeriesCard({super.key, required this.series, required this.onOpenDoc});

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
                // 自测序列必须**用文字**说出来。图上的空心点是区分手段,但形状不能
                // 是唯一载体 —— 没有图例的形状编码等于没有编码,没人知道空心圈是
                // 「这是你自己填的」。这与 `lab_status.dart` 那条同源:状态同时编码
                // 在色条和文字 pill 上,少任何一个就有一类用户读不到结论。
                //
                // 概览(`overview_screen.dart:434`)和就诊单
                // (`visit_summary_sheet.dart:365`)早就在日期旁标了「· 家测」,
                // 只有趋势漏了。措辞与它们一致,不另造一套。
                if (series.selfMeasured) const _SelfMeasuredLegend(),
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
///
/// 「家测」图例:一个和图里同样画法的**空心圈** + 两个字。
///
/// 图上的自测点画成空心圈(见 `TrendChart` 的 `selfMeasured`),但**形状不能是唯一
/// 载体** —— 没有图例的形状编码等于没有编码。这与 `lab_status.dart` 那条同源:
/// 偏高/偏低同时编码在色条和文字 pill 上,少任何一个就有一类用户读不到结论。
///
/// 圈的画法(线宽 1.5、半径 3.4、`seal` 描边、`surface` 填心)与
/// `_TrendPainter` 里末点的自测画法一致 —— 图例和图不一致,比没有图例更糟。
class _SelfMeasuredLegend extends StatelessWidget {
  const _SelfMeasuredLegend();

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.seal, width: 1.5),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text('家测', style: MedType.secondary.copyWith(color: c.ink3)),
      ],
    );
  }
}

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
