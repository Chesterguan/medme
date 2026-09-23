import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/disease_profile_card.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 底部导航一级 tab「趋势」—— 使用时刻:**复诊前自己看「这两年怎么变的」**
/// (设计系统 §八)。
///
/// **自上而下**(Task 6 重整后的顺序):病程档案入口([DiseaseProfileCard])→
/// 「关键化验」标题 + 检验大类 chip + 「只看异常」开关([PanelChipsRow])→ 一张
/// `MedCard` 装下全部「测过 ≥ 2 次」的序列,一行一个([TrendRow]:折叠态一条
/// 78×24 的迷你折线,点开原地放大成真图)→ 页尾折叠「只测过一次的 N 项」
/// ([_SinglesFold],单次序列按化验行样式列出,没有折线可言)→ [ProvenanceFooter]。
///
/// **合并的由来:** 「关键化验各行」(原来独立一张卡,现已删)与「全序列折线卡」
/// (原来一条序列一张卡,现重排成 [TrendRow])在合并之前是分开的两块——同一个
/// 指标看两遍,却只有下面那块能点开看全部历史。现在合成一份列表:折叠态就是
/// 原来「关键化验」那一行的信息量(名称 + 最新值 + 状态),多一条迷你折线;
/// 点开就是原来的趋势图。「最近就诊」那一块(原来也搬来这一屏的一张独立列表)
/// 一并删掉——「病历」tab 自己就是完整列表,这里不需要再摆一份摘要。
///
/// 「记录一下」原来是这一屏的入口,Task 5 挪进了「病历」tab 的「添加」四选一,
/// 这一屏不再有它。
///
/// 「病程档案」那一块的内容在 [DiseaseProfileCard] 自己里头(没有病种包 / 装上了
/// 还没开启 / 开启了,三态各说各的话),这一屏只负责把它摆在第一位。
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
/// 它照原样显示 —— UI 不按名字猜、不合并。这一屏顶上不放常驻说明,这件事只在
/// 搜不到指标时的空态里说一句「同一项在不同医院可能印成「肌酐」「血肌酐」「Cr」」。
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key, this.load, this.profileSource});

  /// 数据源。null → 两个真实投影(FFI)。
  ///
  /// 这两个注入点与 `ForDoctorScreen`(Task 3)同款,理由也一样:整屏碰 FFI,
  /// `flutter test` 不带原生库;而「存完一条记录要当场刷新」这条回归
  /// (BUG-4)只有整屏能验。
  final Future<TrendsData> Function()? load;

  /// 病程档案那一块的取数口子(装着哪个包 / 算一份视图 / 记一条开关)。
  /// null → 真的那一套(FFI + 平台通道)。**摆成注入点只为测试**,与 [load] 同款。
  final DiseaseProfileSource? profileSource;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

/// 这一屏一次要用到的两样东西:全部趋势序列 + 检验大类 chip 的目录(顺序、文案)。
/// 与 `emergency_card_screen.dart` 的 `_CardData` 同一手法。
typedef TrendsData = (List<TrendSeriesDto>, List<String>);

class _TrendsScreenState extends State<TrendsScreen> {
  late Future<TrendsData> _future = _load();

  Future<TrendsData> _load() async {
    final injected = widget.load;
    if (injected != null) return injected();
    final r = await Future.wait([viewTrends(), viewTrendPanelCatalog()]);
    return (r[0] as List<TrendSeriesDto>, r[1] as List<String>);
  }

  /// 「只看异常」开关。**默认关**(Task 6 controller ruling,推翻了这一屏诞生时
  /// 「默认只看非正常项」的旧默认)。
  ///
  /// 旧默认的理由是「替用户排序,但代价必须付清」——那份权衡在合并列表(Task 6)
  /// 之后站不住了:默认把正常的趋势序列也隐藏掉,会让这份列表和页尾「只测过
  /// 一次的」折叠区混在一起分不清,到底是没有更多正常序列,还是被过滤掉了。
  /// 合并后的列表本身已经把异常序列排在前面([trendSplit] 的稳定排序),这个
  /// 信号已经够用,不需要再默认藏一半内容。
  ///
  /// 判据是 Rust 给的 `anyAbnormal`,**不是** UI 自己拿参考区间算的。
  bool _abnormalOnly = false;

  /// 搜索词。**非空时无视 [_abnormalOnly]**——搜索是一次明确的「我要找 X」,若此时
  /// 仍按异常过滤,用户搜「肌酐」而肌酐正常,得到的是一片空白——他会以为自己
  /// 从没查过肌酐。找得到比过滤干净重要。但仍然**受大类约束**(与
  /// [_selectedPanel] 叠加,不是二选一),见 `trendVisible` 的文档。
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

  /// 「只看异常」被拨动。埋点方向不变(仍然分 on/off 两档,见
  /// [TrendsFilterControl]),即使默认值从「开」改成了「关」(Task 6,见
  /// [_abnormalOnly] 的文档)——哪个方向被点得更多,答的还是同一个问题:默认
  /// 藏没藏错东西。
  void _onToggleAbnormalOnly(bool v) {
    Analytics.track(AnalyticsEvent.trendsFilterUsed, {
      'control': (v
              ? TrendsFilterControl.abnormalOnlyOn
              : TrendsFilterControl.abnormalOnlyOff)
          .name,
    });
    setState(() => _abnormalOnly = v);
  }

  /// 点了一颗检验大类 chip。
  ///
  /// ⚠️ **绝不上报是哪个大类。** 「这台设备在看肝功能 / 肿瘤标志物」是对机主的
  /// 健康推断,与「不采内容」同级。这里只报「chip 这条路被走了一次」,回答的是
  /// 「大类目录那份词典投入值不值」,不需要知道是哪一类。
  ///
  /// 取消选中(再点一次同一颗,`g == null`)同样计一次 —— 它一样是「用户在用
  /// chip 这个控件」。
  void _onSelectPanel(String? g) {
    Analytics.track(AnalyticsEvent.trendsFilterUsed, {
      'control': TrendsFilterControl.panel.name,
    });
    setState(() => _selectedPanel = g);
  }

  void _toggleSearch() {
    // 只在**展开**时报一次,收起不报,输入更不报 —— 搜索词是内容。
    if (!_searchOpen) {
      Analytics.track(AnalyticsEvent.trendsFilterUsed, {
        'control': TrendsFilterControl.search.name,
      });
    }
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        // 收起就清空 —— 留一个看不见却仍在生效的过滤条件,是「怎么少了一半」的来源。
        _queryCtl.clear();
        _query = '';
      }
    });
  }

  /// 选中的检验大类 chip。`null` = 「全部」(不筛)。
  ///
  /// **与 [_abnormalOnly] 叠加**(Task 6 起,两者不再互相让位):选中一个大类
  /// 只是缩小范围,开着的「只看异常」照样在这个范围内继续筛——「肾功能」+
  /// 「只看异常」= 肾功能里的异常项,是两次独立的缩小,不是二选一。
  ///
  /// 取值:一个来自 [viewTrendPanelCatalog] 的大类文案,或 [kOtherTrendPanel]
  /// (「其他」桶)。与搜索不冲突,可以同时生效(先按大类筛,再按搜索词筛;
  /// 搜索时仍然无视 [_abnormalOnly],见 [_query] 的文档)。
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
      body: FutureBuilder<TrendsData>(
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
          final visible = trendVisible(
            all,
            query: _query,
            abnormalOnly: _abnormalOnly,
            panel: _selectedPanel,
          );
          // 测过 ≥ 2 次(有日期的点)的才是「趋势」,单次的另放到页尾折叠。
          final (:multi, :single) = trendSplit(visible);

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
                // ① 病程档案入口。三态(没有病种包 / 装上了还没开启 / 开启了)全在
                //    卡片自己里头(`DiseaseProfileCard`),这一屏只负责把它摆在第一位。
                DiseaseProfileCard(source: widget.profileSource),
                const SizedBox(height: MedShape.s4),
                // ② 「关键化验」标题 + 分类 chip + 「只看异常」开关(末尾一颗
                //    chip)。搜索展开且有输入时这颗开关不画(Fix round 1,
                //    Important 3,controller ruling)——搜索本来就无视这个开关
                //    (见 `trendVisible` 的文档),留着看得见却不生效,像是坏了。
                //    `all` 为空时整排跟着不画(Minor 4:对着空列表的开关是噪音)。
                const _SectionHeader('关键化验'),
                const SizedBox(height: MedShape.s1),
                if (all.isNotEmpty) ...[
                  PanelChipsRow(
                    chips: chips,
                    selectedPanel: _selectedPanel,
                    onSelectPanel: _onSelectPanel,
                    abnormalOnly: _abnormalOnly,
                    onToggleAbnormal: () =>
                        _onToggleAbnormalOnly(!_abnormalOnly),
                    showAbnormalToggle: !searching,
                  ),
                  const SizedBox(height: MedShape.s3),
                ],
                // ③ 关键化验 + 全序列折线 合并成的一份列表:一张 `MedCard` 装下
                //    全部「测过 ≥ 2 次」的序列,`TrendRow` 之间用 `Divider` 分。
                //    `all` 整体为空 → 空态;`visible`(筛完的结果)整体为空 →
                //    沿用现有那几句「没有结果」文案;`multi` 为空但 `single`
                //    非空(筛完只剩单次序列)→ 这里两个分支都不画,交给下面的
                //    页尾折叠去说(Fix round 1,Important 2:原来拿
                //    `multi.isEmpty` 当判据,会把「有结果、只是都在折叠区」的
                //    一屏错说成「没有结果」)。
                if (all.isEmpty)
                  const _EmptyTrends()
                else if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: MedShape.s5,
                    ),
                    child: Text(
                      // 说的是「这些记录里没有」,不是「你没查过」—— 没搜到很可能
                      // 是同一个指标印成了别的名字,下面这句文案就说这个。
                      searching
                          ? (panelSelected
                                ? '「${_panelChipLabel(_selectedPanel)}」里没有名字含'
                                      '「$_query」的指标。\n清空搜索可以看这个大类下的全部。'
                                : '这些记录里没有名字含「$_query」的指标。\n'
                                      '换个叫法试试 —— 同一项在不同医院可能印成「肌酐」「血肌酐」「Cr」。')
                          // 「只看异常」与选中大类是叠加关系(`trendVisible`,两个
                          // 条件都作用在同一份 `visible` 上),所以选中的大类可能
                          // 恰好被「只看异常」筛空 —— 让筛子先说话,而不是大类。
                          : (_abnormalOnly
                                ? '这些记录里没有非正常项。'
                                : '这个大类下没有可显示的指标。'),
                      textAlign: TextAlign.center,
                      style: MedType.body.copyWith(
                        color: c.ink2,
                        height: 1.6,
                      ),
                    ),
                  )
                else if (multi.isNotEmpty)
                  MedCard(
                    child: Column(
                      children: [
                        for (var i = 0; i < multi.length; i++) ...[
                          if (i > 0)
                            Divider(height: 1, thickness: 1, color: c.line2),
                          TrendRow(series: multi[i], onOpenDoc: _openDoc),
                        ],
                      ],
                    ),
                  ),
                // ④ 只测过一次的序列:折叠在页尾,`single` 为空时整块不画。
                if (single.isNotEmpty)
                  _SinglesFold(series: single, onOpenDoc: _openDoc),
                // 页脚只交代一次「参考区间的三种出处」,不重复在每张卡上说——
                // 只要 `all` 非空(这一屏至少能画出一条线)就露出来,不随筛选
                // 结果增减而消失,免得用户搜/筛到没有结果时反而看不见这段说明。
                if (all.isNotEmpty) ...[
                  const SizedBox(height: MedShape.s5),
                  const ProvenanceFooter(),
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

/// 该显示哪些序列。**先按大类筛,再按搜索(搜索时无视「只看异常」),最后按
/// 「只看异常」筛——大类与开关叠加,不再互相让位。**
///
/// 大类与「只看异常」曾经互相让位(选中一个大类会让开关整个失效)——Task 6
/// controller ruling 改掉了这条:合并列表之后异常序列本就排在前面
/// ([trendSplit] 的稳定排序),选中大类不再需要靠「放开过滤」来避免看起来
/// 空空如也,两者叠加才是更可预期的行为(「肾功能」+「只看异常」= 肾功能里的
/// 异常项,不是全部肾功能项)。
///
/// 搜索仍然优先于「只看异常」:搜索是一次明确的「我要找 X」,若此时仍按异常
/// 过滤,用户搜「肌酐」而肌酐正常,得到的是一片空白——他会以为自己从没查过
/// 肌酐。找得到比过滤干净重要。但搜索仍然**受大类约束**:选中「肾功能」后再
/// 搜「肌酐」,是在肾功能这个大类里再精确定位,不是搜全部(与选大类不是同一
/// 件事,浏览 vs. 输入,彼此不互斥)。
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
  return abnormalOnly ? byPanel.where((s) => s.anyAbnormal).toList() : byPanel;
}

/// 测过 ≥ 2 次(有日期的点)的才是「趋势」;不到 2 次的另放到页尾折叠
/// ([_SinglesFold])——`trendDatedPoints` 只数有日期的点,无日期的点本来就画
/// 不到时间轴上,不算「测过」。
///
/// `multi` 组内**有异常的排前面**(稳定排序,各自保持 [visible] 原有的相对
/// 顺序——Rust 给的顺序已经按名称排好,这里不重新按名字排一遍)。理由:合并
/// 列表之后不再有默认过滤把正常序列整个藏起来(见 [trendVisible] 的 controller
/// ruling),异常序列排前面是唯一还在的「优先看这几条」的信号。
({List<TrendSeriesDto> multi, List<TrendSeriesDto> single}) trendSplit(
  List<TrendSeriesDto> visible,
) {
  final multi = <TrendSeriesDto>[];
  final single = <TrendSeriesDto>[];
  for (final s in visible) {
    (trendDatedPoints(s).length >= 2 ? multi : single).add(s);
  }
  final abnormal = multi.where((s) => s.anyAbnormal).toList();
  final normal = multi.where((s) => !s.anyAbnormal).toList();
  return (multi: [...abnormal, ...normal], single: single);
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
/// (需求原文)。计数口径是 `all` 里这条序列的数量,不受当前搜索词/「只看
/// 异常」影响:chip 要稳定地告诉用户「这个大类总共有几条」,不能随手指输入
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

/// 「关键化验」标题下面那一排检验大类 chip([TrendPanelChipData])+ 末尾一颗
/// 「只看异常」开关 chip(开关原来是整行 `Switch`,Task 6 收进这一排的末尾)。
///
/// 这一排是**检索的主路径**;搜索收进了标题栏的放大镜(见 `_searchOpen`)。
///
/// **公开是为了可测**(与 `TrendRow`/`ProvenanceFooter` 同一先例):
/// 每一颗大类 chip 的渲染是共用的 [MedChip];这一层继续留着,管选中态、开关态
/// 与横向滚动布局。
class PanelChipsRow extends StatelessWidget {
  const PanelChipsRow({
    super.key,
    required this.chips,
    required this.selectedPanel,
    required this.onSelectPanel,
    required this.abnormalOnly,
    required this.onToggleAbnormal,
    required this.showAbnormalToggle,
  });

  final List<TrendPanelChipData> chips;
  final String? selectedPanel;
  final ValueChanged<String?> onSelectPanel;

  /// 「只看异常」开关的当前值,渲染成末尾那一颗 [MedChip](`count: null`,纯
  /// 开关,不带计数)。与 [selectedPanel] 叠加,不再互相让位——见
  /// `trendVisible` 的文档。
  final bool abnormalOnly;
  final VoidCallback onToggleAbnormal;

  /// 末尾那颗开关 chip 要不要画。**搜索时传 `false`**(controller ruling,
  /// Fix round 1 Important 3)——`trendVisible` 里搜索本来就无视这个开关,
  /// 一颗看得见却点了没用的开关比没有更误导人;关掉搜索它自然回来。
  final bool showAbnormalToggle;

  @override
  Widget build(BuildContext context) {
    final itemCount = chips.length + (showAbnormalToggle ? 1 : 0);
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: MedShape.s1),
        itemBuilder: (context, i) {
          // 末尾一颗开关 chip:与大类叠加,不再互相让位;搜索时整颗不画。
          if (showAbnormalToggle && i == chips.length) {
            return MedChip(
              label: '只看异常',
              count: null,
              selected: abnormalOnly,
              onTap: onToggleAbnormal,
            );
          }
          final chip = chips[i];
          return MedChip(
            label: chip.label,
            count: chip.count,
            selected: chip.panel == selectedPanel,
            onTap: () =>
                onSelectPanel(chip.panel == selectedPanel ? null : chip.panel),
          );
        },
      ),
    );
  }
}

/// 一条序列一行。**折叠态**(恒在)= 名称 + 状态词 + 78×24 迷你折线 + 最新值 +
/// 「历年数值/图例」那一行(自测图例、参考区间图例或换算说明、测了几次)。
/// **展开态**(点 ▾ 才画)= 96 高的真图 + 出处引文 + 未定日说明 + 「查看最新
/// 一次的原件」——这几样是这一条序列自己的细节,折叠着的时候不该占地方
/// (Fix round 1,Important 4,controller ruling:原来这几行不受展开态影响、
/// 恒在,把「一行摘要」硬撑成了「一份详情」)。
///
/// 这是**派生**内容:一条趋势是从许多份原件里算出来的结论,背后没有「某一张
/// 纸」叫做「肌酐趋势」(规范 §五,那里正是拿趋势汇总卡当反例的)。可溯源由
/// 展开区下方那颗「最新一次的原件」兑现——它指向一个具体的 `documentId`,
/// **只在点开之后才够得到**。
///
/// **不再自带外层 `MedCard`**(Task 6 由「一条序列一张卡」改名重排):现在
/// 「关键化验」整份列表共用**一张**卡([_TrendsScreenState.build] 里的那个
/// `MedCard(Column([TrendRow, Divider, TrendRow, …]))`),行与行之间靠
/// `Divider` 分,不再各自一张卡——那张卡内部已经垫了一层透明 `Material`
/// (`MedCard` 自己的 R24),这一行的 `InkWell` 不需要再单独垫一层。
class TrendRow extends StatefulWidget {
  /// **公开是为了可测。** 「自测序列必须带文字图例」这条只能在渲染出来的行上
  /// 验证 —— 整屏 pump 需要 `viewTrends()` 的 Rust FFI,测试环境没有原生库。与
  /// `manualEntryRangeError` 同一个先例:把被测单元暴露出来,而不是把断言降级成
  /// 「只测纯函数、渲染层靠肉眼」。
  const TrendRow({super.key, required this.series, required this.onOpenDoc});

  final TrendSeriesDto series;
  final void Function(int docId) onOpenDoc;

  @override
  State<TrendRow> createState() => _TrendRowState();
}

/// `StatefulWidget`——行按 mockup `.tr` 有「点开原地展开」(`▾`/`▴`),需要一个
/// 本地的展开态。
class _TrendRowState extends State<TrendRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final series = widget.series;
    final pts = trendDatedPoints(series);
    // 调用方已经从 `trendVisible`/`trendSplit` 过滤过,这里 pts 必不为空;真为
    // 空也只是少画一行,不崩。
    if (pts.isEmpty) return const SizedBox.shrink();

    final last = pts.last;
    final status = labStatusOf(last.flag);
    final word = labStatusWord(context, last.flag);
    final ref = refRangeText(series.refLow, series.refHigh);
    final refSourceCitation = trendRefSourceCitation(series);
    // 单位以**点自己的**为准:同一指标跨报告单位可能不一致,序列级 unit 只是取了
    // 最后一个点的(见 DTO 文档)。这里显示的就是最后一个点,两者其实同源。
    final unit = last.unit ?? series.unit;
    final undated = series.points.length - pts.length;
    // 「第二行历年数值」的字阶(brief §形):12 · ink3 · tabular · 400。
    final metaStyle = MedType.caption.copyWith(
      color: c.ink3,
      fontFeatures: MedType.tabular,
      fontWeight: FontWeight.w400,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 折叠态本体(mockup `.tr`):名称+状态词 | 78×24 迷你折线 | 数值 + ▾ ──
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              MedShape.s3,
              MedShape.s2,
              MedShape.s3,
              MedShape.s2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                          ?word,
                        ],
                      ),
                    ),
                    const SizedBox(width: MedShape.s2),
                    // 78×24 迷你折线:compact 模式只画线和点,不画参考带/末点
                    // 光环(`TrendChart` 的 `compact` 分支);不描画动画——折叠态
                    // 是默认呈现,不该每次进页面都跑一遍描线动画。
                    SizedBox(
                      width: 78,
                      height: 24,
                      child: TrendChart(
                        series: series,
                        height: 24,
                        compact: true,
                        animate: false,
                      ),
                    ),
                    const SizedBox(width: MedShape.s2),
                    // 最新值用 `value` 字阶(16 · 500 · 等宽表格数字,mockup
                    // `.tr .v`)。`Wrap` 带宽度上限:装不下时单位/箭头自己换行,
                    // 不越界(fix round 1 R19,长名称 + 长单位在 2× 字号下会把
                    // 一个不设上限的 `Row` 顶出卡外)。
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: MedBrand.trendValueMaxWidth,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 4,
                        children: [
                          Text(
                            fmtLabNumber(last.value),
                            style: MedType.value.copyWith(
                              color: labStatusColor(context, status),
                            ),
                          ),
                          if (unit != null && unit.isNotEmpty)
                            Text(
                              unit,
                              style: MedType.secondary.copyWith(color: c.ink3),
                            ),
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),

                // ── 第二行:历年数值/图例(mockup `.tr .m`,跨满整行)──
                Wrap(
                  spacing: MedShape.s2,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // 自测序列必须**用文字**说出来。图上的空心点是区分手段,但形状不能
                    // 是唯一载体 —— 没有图例的形状编码等于没有编码,没人知道空心圈是
                    // 「这是你自己填的」。这与 `lab_status.dart` 那条同源:状态同时编码
                    // 在状态词的文字和刻度条上圆点的颜色/位置上,少任何一个就有一类
                    // 用户读不到结论。
                    if (series.selfMeasured)
                      _SelfMeasuredLegend(style: metaStyle),
                    // 图例本身只加一句短后缀交代出处:医院化验的出处是化验单原件
                    // 本身,不新造一个跳转入口 —— 展开区下方「查看最新一次的
                    // 原件」按钮已经能兑现它,这里只是指一下。家测序列的出处
                    // (指南/共识引文)往往一句话放不下,另起一段显示在展开区
                    // 下面,见下方 `refSourceCitation`。
                    if (ref != null)
                      _RefLegend(
                        text: trendRefLegendText(series, ref),
                        style: metaStyle,
                      )
                    // 家测但**没有**参考区间(体温/体重/血糖)—— 不是漏配,是
                    // `self_entry::home_ref_range` 的拍板决定(查不到出处就不给
                    // 区间)。裸值旁边说一句,免得用户以为是 bug。
                    else if (series.selfMeasured)
                      Text(trendNoHomeRangeNote, style: metaStyle),
                    // 这条线上混了不同医院/不同单位的报告,Rust 把值和参考区间一起
                    // 换算到了规范单位(否则连不成一条线)。**说出来** —— 屏幕上
                    // 这些数字在用户手里那张化验单上找不到,不说等于改写原文。
                    if (series.valuesConverted)
                      Text(unitConvertedNote(unit), style: metaStyle),
                    Text(
                      pts.length == 1
                          ? '只有 ${pts.first.date} 这一次'
                          : '${pts.first.date} 起 ${pts.length} 次',
                      style: metaStyle,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // ── 展开态:点开才画,折叠时不占地方(Fix round 1,Important 4)──
        // 真图(96 高,底色 expandedChartBg)+ 出处引文 / 未定日说明 / 查看
        // 原件——这几样是这一条序列自己的详情,原来跟折叠态无关地恒在,现在
        // 跟着 `_expanded` 一起收起/展开。
        if (_expanded) ...[
          Container(
            padding: const EdgeInsets.all(MedShape.s2),
            color: MedBrand.expandedChartBg,
            child: TrendChart(series: series),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MedShape.s3,
              MedShape.s2,
              MedShape.s3,
              MedShape.s3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 家测参考区间的完整引文 —— 一句指南/共识原话往往比 Wrap 里能塞下的
                // 短图例长得多,另起一段,不挤在图例那一行里。医院化验序列
                // `refSourceCitation` 恒为 null(见 `trendRefSourceCitation` 的文档),
                // 这一段不出现。
                if (refSourceCitation != null) ...[
                  Text(
                    '出处:$refSourceCitation',
                    style: MedType.secondary.copyWith(
                      color: c.ink3,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],

                // 无日期的点画不到时间轴上,所以图里没有它们。**说出来** —— 否则用户
                // 数图上的点会发现比他记忆里的次数少,而少掉的那几次没有任何交代。
                if (undated > 0) ...[
                  Text(
                    '另有 $undated 次没能从报告上定出日期,画不到时间轴上;它们在「病历」里照样能翻到。',
                    style: MedType.secondary.copyWith(
                      color: c.ink3,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],

                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => widget.onOpenDoc(last.documentId),
                    style: TextButton.styleFrom(
                      foregroundColor: c.sealInk,
                      padding: const EdgeInsets.symmetric(
                        horizontal: MedShape.s1,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('查看最新一次的原件', style: MedType.secondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
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
/// 偏高/偏低同时编码在状态词的文字和刻度条上圆点的颜色/位置上,少任何一个就有
/// 一类用户读不到结论。
///
/// 圈的画法(线宽 1.5、半径 3.4、`seal` 描边、`surface` 填心)与
/// `_TrendPainter` 里末点的自测画法一致 —— 图例和图不一致,比没有图例更糟。
class _SelfMeasuredLegend extends StatelessWidget {
  const _SelfMeasuredLegend({required this.style});

  /// 「历年数值」那一行的字阶(`TrendRow` 的 `metaStyle`)——只此一处调用,
  /// 颜色/字号跟着行走,不在这里另存一份裸样式。
  final TextStyle style;

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
        Text('家测', style: style),
      ],
    );
  }
}

/// 参考区间图例上的文字。医院化验序列的出处就是化验单原件本身 —— 展开区下方
/// 已经有「查看最新一次的原件」入口(见 [TrendRow]),这里只是**指一下**,不新造
/// 一个跳转;家测序列的出处是一句可能很长的指南/共识引文,放不进这一行短图例,
/// 另起一段显示,见 [trendRefSourceCitation]。
String trendRefLegendText(TrendSeriesDto series, String ref) => series.selfMeasured
    ? '参考区间 $ref'
    : '参考区间 $ref · 出自化验单原件';

/// 家测序列参考区间的引文(指南/共识出处,`TrendSeriesDto.refSource` 原样
/// 透传)。医院化验序列恒为 `null` —— 它的出处是化验单原件本身,不是这段引文
/// 的用途(见 [TrendSeriesDto.refSource] 的文档);家测但没有可引用区间(体温/
/// 体重/血糖)时同样为 `null`,那种情况改由 [trendNoHomeRangeNote] 交代。
String? trendRefSourceCitation(TrendSeriesDto series) =>
    series.selfMeasured ? series.refSource : null;

/// 家测序列**没有**参考区间时的说明(体温/体重/血糖 —— 见
/// `self_entry::home_ref_range` 的文档:「查不到出处就不给区间」是拍板决定,
/// 不是漏配)。医院化验序列没区间就是报告本身没印,不需要额外解释,这句只给
/// 家测序列用。
const trendNoHomeRangeNote = '暂无公认家测正常区间,仅显示数值';

class _RefLegend extends StatelessWidget {
  const _RefLegend({required this.text, required this.style});

  final String text;

  /// 同 [_SelfMeasuredLegend.style]:「历年数值」那一行的字阶,不在这里另存
  /// 一份裸样式。
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      // Fix round 1(R19):原来是 `mainAxisSize: min` + 裸 `Text`——一句长参考
      // 区间图例(`"参考区间 ... · 出自化验单原件"`)在这个 Row 里没有宽度上限,
      // 会把整行挤出卡外。文字不能拿宽度上限硬砍(与化验行数值簇同一条「单位小字
      // 可折到数值下一行」的精神,不是删字),所以让色块非 flex、文字
      // `Expanded` 吃掉剩余宽度、允许自己换行——色块位置不受影响,行只会变高。
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 16,
          height: 10,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: c.sealWash,
            border: Border.all(color: c.ink3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: Text(text, style: style, softWrap: true)),
      ],
    );
  }
}

/// 《中国高血压防治指南(2024年修订版)》原文 PDF —— 血压两条家测序列
/// (`bp_systolic`/`bp_diastolic`)的 [TrendSeriesDto.refSource] 引用的就是这份
/// 指南。**2026-08-06 用 WebFetch 实际抓取验证过**:文件首页标题、发布机构
/// (中国高血压防治指南修订委员会、高血压联盟(中国)等)、期刊出处(《中华
/// 高血压杂志(中英文)》2024 年 7 月第 32 卷第 7 期,doi:10.16439/j.issn.
/// 1673-7245.2024.07.002)与本文引用的指南名称、发布年份逐字对得上,不是二手
/// 摘要或转载。链接本身来自高血压联盟(中国)官网 chlonline.cn 首页「下载中心」
/// 给出的直接下载地址(文件实际托管在该联盟使用的会议文件服务上,但入口在联盟
/// 自己的官网首页)。
///
/// **只有这一条出处现在能给一个验证过的链接。** 心率参考区间的出处是「内科学/
/// 生命体征通用共识」—— 跨教材的基础生理学常数,没有单一可指认、可验证的官方
/// 发布页,所以心率**不**配链接,只在卡片上留文字出处(见
/// [trendRefSourceCitation])。体温/体重/血糖没有家测参考区间,更谈不上链接。
/// **绝不为验不到的出处编一个链接** —— 死链或猜的链接比不放链接更伤这页要证明
/// 的事(「我们用的是官方来源」)。
const _hypertensionGuidelineUrl =
    'https://files.sciconf.cn/medcon/2024/08/20240814/2024081410492823875104169.pdf';

/// 页脚:参考区间的三种出处,统一交代一次。
///
/// 产品原话:「如果不是每个都可以链接,至少底下得有」—— 三类出处里只有血压
/// 那条现在能给出经过验证的链接(见 [_hypertensionGuidelineUrl]),其余两类
/// 只有文字说明,这一段把三类都说全,不是只给能链接的那类交代。
///
/// **公开是为了可测**,与 [TrendRow] 同一个先例(见那里的文档):整屏
/// `TrendsScreen` 需要 `viewTrends()` 的 Rust FFI,测试环境没有原生库,只能
/// 把这块单独暴露出来,直接 pump 它来测文案是否齐全。
class ProvenanceFooter extends StatelessWidget {
  const ProvenanceFooter({super.key});

  Future<void> _openGuideline(BuildContext context) async {
    final ok = await launchUrl(
      Uri.parse(_hypertensionGuidelineUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(appSnackBar(content: const Text('无法打开指南原文,请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final bodyStyle = MedType.secondary.copyWith(color: c.ink3, height: 1.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('参考区间的出处', style: MedType.body.copyWith(color: c.ink)),
        const SizedBox(height: 4),
        Text(
          '· 医院化验:来自化验单原件本身 —— 点开卡片下方「查看最新一次的原件」'
          '核对。\n'
          '· 家测(血压、心率等):来自公开发布的临床指南或医学共识,出处写在'
          '各卡片区间下方。\n'
          '· 体温、体重、血糖(家测):目前没有可靠、可引用的家测正常区间,'
          '只显示数值,不做偏高偏低的判断。',
          style: bodyStyle,
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _openGuideline(context),
          child: Text(
            '查看《中国高血压防治指南(2024年修订版)》原文',
            style: bodyStyle.copyWith(
              color: c.sealInk,
              decoration: TextDecoration.underline,
              decorationColor: c.sealInk,
            ),
          ),
        ),
        const SizedBox(height: 2),
        // 期刊卷期 + DOI,和上面那条链接并列。
        //
        // **链接会烂,卷期和 DOI 不会。** [_hypertensionGuidelineUrl] 指的是会议
        // 文件服务上的一个具体路径(入口在联盟官网首页下载中心),路径一旦轮换,
        // 这页就在替一个死链背书;而 `launchUrl` 只在唤不起浏览器时才返回 false,
        // 浏览器打开一个 404 页面在它看来是成功的,所以那条失败提示兜不住这种烂法。
        //
        // 这行字是链接烂掉之后的后备:用户凭卷期或 DOI 照样查得到原文。而且它本身
        // 就是这一段想证明的那件事(「我们引的是正式发表的指南」)最硬的证据 ——
        // 一个 URL 证明不了发表过,一个卷期号能。
        Text(
          '《中华高血压杂志(中英文)》2024年7月第32卷第7期\n'
          'doi:10.16439/j.issn.1673-7245.2024.07.002',
          style: bodyStyle.copyWith(color: c.ink3),
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
              '在「病历」里添加几张化验单,这里就会长出线来。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
            const SizedBox(height: MedShape.s3),
            OutlinedButton(
              onPressed: goToRecords,
              child: const Text('去「病历」添加化验单'),
            ),
          ],
        ),
      ),
    );
  }
}

// 「关键化验各行」(原 `KeyLabsSnapshot`)与「最近就诊」(原
// `RecentVisitsCard`/`_VisitCard`/`visitCardShowsDate`/`visitCardDesc`)
// Task 6 全部删掉:前者并进了上面的 `TrendRow` 列表(折叠态就是它原来的信息
// 量,多一条迷你折线);后者没有下家——「病历」tab 本来就是完整列表,这一屏
// 不需要再摆一份摘要。

/// 页尾折叠:测过不到 2 次(没有折线可言)的序列,收进一行「只测过一次的 N
/// 项」里,点开按化验行([LabLine])样式列出——名称 · 值 · 状态词 · 日期,
/// 没有折线。
///
/// **`series` 为空时调用方不渲染这个 widget**(见 [_TrendsScreenState.build]
/// 的 `single.isNotEmpty` 判断),这里不再自己判空。
class _SinglesFold extends StatefulWidget {
  const _SinglesFold({required this.series, required this.onOpenDoc});

  final List<TrendSeriesDto> series;
  final void Function(int docId) onOpenDoc;

  @override
  State<_SinglesFold> createState() => _SinglesFoldState();
}

class _SinglesFoldState extends State<_SinglesFold> {
  bool _open = false;

  /// 单次序列的唯一一个点,按化验行样式画一行:没有折线可言,`LabLine` 已经是
  /// 「名称 · 值 · 状态词 · 参考区间」这套渲染的唯一实现,不再另写一份。
  ///
  /// `meta` 拼「日期 · 家测 · 已统一换算」(Fix round 1,Important 1)——原来
  /// 只传了日期,把这两个标注漏掉了。措辞与 `KeyLabsSnapshot`(已删)当年拼
  /// 同一份 `meta` 时一致(`lab.date`/`'家测'`/`unitConvertedNote(...)`,同一句
  /// 「· 家测」`_SelfMeasuredLegend`/`visit_summary_sheet.dart` 也在用),不是
  /// 新造的说法:一条只测过一次的家测序列(比如只量过一次的血压)混进这个
  /// 折叠区,没有这两个标注就会被误读成医院化验值。
  ///
  /// `trendDatedPoints(s).single`:调用方(`_TrendsScreenState.build` 的
  /// `trendSplit`)已经保证 `single` 桶里的序列**恰好**有一个有日期的点——
  /// 整条序列在进这个桶之前先经过 `trendSeriesIsRenderable` 过滤(至少一个点
  /// 带日期),再被 `trendSplit` 按「< 2」分进 `single`,两条约束叠起来就是
  /// 「恰好 1 个」,`.single` 不会抛。
  Widget _row(TrendSeriesDto s) {
    final p = trendDatedPoints(s).single;
    return LabLine(
      name: s.name,
      value: p.value,
      unit: p.unit ?? s.unit,
      flag: p.flag,
      refLow: s.refLow,
      refHigh: s.refHigh,
      meta: [
        p.date,
        if (s.selfMeasured) '家测',
        if (s.valuesConverted) unitConvertedNote(p.unit ?? s.unit),
      ].join(' · '),
      unverified: p.unverified,
      onTap: () => widget.onOpenDoc(p.documentId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, MedShape.s4, 4, 6),
            // 正文里的可点行,最小可点高度钉在 48(Minor 8,与
            // `visit_summary_sheet.dart` 「在用药」标题行同一手法)——文字自己
            // 那一行不到 48,不能让可点区域只剩文字那么高。
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '只测过一次的 ${widget.series.length} 项',
                      style: MedType.secondary.copyWith(color: c.ink3),
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: c.ink3,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          MedCard(
            child: Column(
              children: [
                for (var i = 0; i < widget.series.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
                  _row(widget.series[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// 分区标题:13 号 `ink3`,padding 左右 4。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(title, style: MedType.secondary.copyWith(color: c.ink3)),
    );
  }
}

// 「病程档案」入口卡搬去了 `widgets/disease_profile_card.dart`:它现在是有状态、
// 要取数的一块(装着哪个包、开没开启、包给的摘要),不再是这一屏里的一张死卡。
// 「记录一下」入口(原来住在这里的 `RecordEntryCard`)Task 5 挪进了「病历」
// tab 的「添加」四选一(`import_flow.dart` 的 `AddSheetBody`)。
