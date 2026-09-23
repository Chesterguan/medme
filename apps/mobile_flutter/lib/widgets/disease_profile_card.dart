// 「病程档案」入口卡 —— 「趋势」tab 自上而下的**第一块**(mockup `s2`:
// 病程档案入口 → 关键化验 → 最近就诊 → 记录一下)。
//
// 三态,各说各的实话:
//  · **一个病种包都没装上** —— 只说「还没准备好」,并**静默**拉一次清单
//    (`SkillPackages.refreshIndex`,它自己保证永不抛)。不摆一份不存在的档案。
//  · **装上了但还没开启** —— 给一颗「开启」。**不自动开**:开不开是用户的事
//    (spec §4「从未开启 = 不算、不显示、不提醒」)。按诊断文本猜「这份病历像是
//    狼疮相关」的那张**建议卡**(spec §5.1)不在这一步的范围里,所以这里既不猜、
//    也不替他贴任何标签。
//  · **开启了** —— 标题带上包给的病名,下面一行摘要**原文来自包**(第一块
//    `reminders`/`score_card`),点进去是 `DiseaseProfileScreen`。
//
// 这张卡自己一句病种文案都没有:病名、摘要标题、空态提示全是包给的字符串
// (`widgets/profile_sections.dart` 头部同一条规矩)。
//
// **这一块出问题不许把整条「趋势」tab 带塌**:取数的每一步都兜住,兜不住就退回
// 「还没准备好」那一行 —— 用户此刻真正要看的是下面的化验趋势。
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

/// 卡片顶上那个名字。病名(包给的 `display_name`)接在它后面。
const String _kTitle = '病程档案';

/// 这一块是干什么的 —— 空着的时候也要说清楚,否则用户在一张空卡上学不到任何东西。
const String _kWhatItIs = '把一个病的用药、检查、变化串成一条线。';

/// 装着哪个包 + 它这一刻的视图。
typedef _Entry = (String packageId, Map<String, dynamic> view);

class DiseaseProfileCard extends StatefulWidget {
  const DiseaseProfileCard({super.key, this.source});

  /// null → 真的那一套(FFI + 平台通道)。见 [DiseaseProfileSource]。
  final DiseaseProfileSource? source;

  @override
  State<DiseaseProfileCard> createState() => _DiseaseProfileCardState();
}

class _DiseaseProfileCardState extends State<DiseaseProfileCard> {
  late final DiseaseProfileSource _source =
      widget.source ?? DiseaseProfileSource();
  late Future<_Entry?> _future = _load();

  /// 「开启」记录中 —— 防连点。
  bool _busy = false;

  /// `null` = 没有可显示的档案(一个包都没装上,或者这次读不出来)。
  Future<_Entry?> _load() async {
    try {
      var ids = await _source.installedPackages();
      if (ids.isEmpty) {
        // 第一次显示时拉一次清单。**静默**:没网就是这次没更新,退回缓存里那份
        // (`refreshIndex` 永不抛,失败只是返回空列表)。
        await _source.refresh();
        ids = await _source.installedPackages();
      }
      if (ids.isEmpty) return null;
      // ponytail: 装了不止一个包时只显示第一个 —— 今天清单里就一个病。真出现第二
      // 个病时再决定怎么挑(或者并排摆两张),那是一次要重新看设计的改动,不是这里
      // 随手加个循环能定的。
      final id = ids.first;
      return (id, await _source.view(id));
    } catch (e) {
      // 包 id 与错误文本里没有病历内容,可以进日志。
      debugPrint('[profile] 入口卡这次没拿到档案:$e');
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    // 添加了新病历,这张卡上那句「待补 / 逾期 3 项」就可能过期了 —— 与「趋势」整屏
    // 同一条信号(`trends_screen.dart` 的 `_onVaultChanged`)。
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

  /// 重新取一次。`setState` 是**语句块不是箭头**
  /// (理由见 `test/known_defect_setstate_future_test.dart`)。
  void _reload() {
    final next = _load();
    setState(() {
      _future = next;
    });
  }

  /// 开启:记一条 `enable`,**记上了才重算** —— 开关状态由事件算出来,不在本地猜。
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
  Future<void> _open(String packageId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiseaseProfileScreen(
          packageId: packageId,
          source: _source,
        ),
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Entry?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // 加载中也是一句话,不摆转圈:这张卡是整屏的第一眼,一个转菊花的
          // 方块什么也没告诉用户,而这一句同时把「这一块是干什么的」说清楚了。
          return const _ProfileEntry(title: _kTitle, subtitle: '$_kWhatItIs正在准备…');
        }
        final entry = snap.data;
        if (entry == null) {
          return _ProfileEntry(
            title: _kTitle,
            subtitle: '$_kWhatItIs还没准备好 —— 联网之后点一下重试。',
            onTap: _reload,
          );
        }
        final (packageId, view) = entry;
        final name = view['display_name'] as String? ?? '';
        if (view['enabled'] != true) {
          return _ProfileEntry(
            title: _kTitle,
            subtitle: name.isEmpty
                ? '开启之后,这个病的用药、检查、该复查的会串成一页。'
                : '可以整理「$name」这个病 —— 开启之后,用药、检查、该复查的会串成一页。',
            action: MedSecondaryButton(
              label: '开启',
              onPressed: _busy ? null : () => _enable(packageId),
            ),
          );
        }
        final summary = _summaryOf(view);
        final (subtitle, bigNumber, bigNumberCaption) = _splitSummary(summary);
        return _ProfileEntry(
          title: name.isEmpty ? _kTitle : '$_kTitle · $name',
          subtitle: subtitle,
          bigNumber: bigNumber,
          bigNumberCaption: bigNumberCaption,
          onTap: () => _open(packageId),
        );
      },
    );
  }
}

/// 卡上那一行摘要:按**包给的顺序**取第一块 `reminders` / `score_card`
/// (spec §5.6「首页永远先出待补/逾期」—— 哪块在前由包决定,这里不重排)。
///
/// 返回 `(左边那句话, 右边那个数)`。两样都原文来自包:空态是包给的 `empty_hint`,
/// 有数据时左边是包给的 `title`。取不到就 `null` —— 卡上只剩标题,点进去看全部。
(String, String?)? _summaryOf(Map<String, dynamic> view) {
  for (final raw in view['sections'] as List? ?? const []) {
    if (raw is! Map) continue;
    final kind = raw['kind'];
    if (kind != 'reminders' && kind != 'score_card') continue;
    // 折叠态:原样举着包给的那句话(与渲染引擎同一条规矩,不自己造措辞)。
    if (raw['empty_hint'] case final String hint) return (hint, null);
    final title = raw['title'] as String? ?? '';
    final body = raw['body'];
    if (body is! Map) return (title, null);
    if (kind == 'reminders') {
      return (title, '${(body['items'] as List? ?? const []).length} 项');
    }
    // 分数照包给的那两个数写,**不换算、不四舍五入、不加一句自己的结论**;
    // 「这是化验可算的哪一部分」由包写在 `title` 里(渲染引擎同一条)。
    return (title, '${body['score']} / ${body['max']}');
  }
  return null;
}

/// 把 `_summaryOf` 那对 `(label, value)` 拆成 `RecordBookStrip` 的三个格子:
/// `(subtitle, bigNumber, bigNumberCaption)`。**字符串一个不动**,只决定它落进
/// 哪一格:
///  · 没有 `value`(空态提示,或者压根没有摘要)—— 整句进 `subtitle`,数字行不画;
///  · 有 `value`(「N 项」「N / M」这类)—— `value` **整个不拆**地进 `bigNumber`,
///    `label` 进 `bigNumberCaption`,`subtitle` 空着。不拆开是因为「2 项」拆成
///    「2」+「项」就不再是同一个字符串——`disease_profile_card_test.dart` 那条
///    `find.text('2 项')` 断言靠的正是它是**一整块**;拆开的形状(mockup 的
///    「4」+「/18」)没有现成测试钉住,与其猜一个拆法,不如保底不丢一个字。
(String, String?, String?) _splitSummary((String, String?)? summary) {
  if (summary == null) return ('', null, null);
  final (label, value) = summary;
  if (value == null) return (label, null, null);
  return ('', value, label);
}

/// 卡片外壳:病历本条(白卡一行,`widgets/record_book_strip.dart`)+「开启」
/// 按钮独立一行摆在它下面。整条可点,有 `›`。
class _ProfileEntry extends StatelessWidget {
  const _ProfileEntry({
    required this.title,
    required this.subtitle,
    this.bigNumber,
    this.bigNumberCaption,
    this.action,
    this.onTap,
  });

  final String title;

  /// 一句说明(这一块是干什么的 / 这一刻在等什么),或包给的摘要整句
  /// (见 [_splitSummary])。
  final String subtitle;

  final String? bigNumber;
  final String? bigNumberCaption;

  /// 「开启」。**只在没开启时出现**。
  final Widget? action;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RecordBookStrip(
          title: title,
          subtitle: subtitle,
          bigNumber: bigNumber,
          bigNumberCaption: bigNumberCaption,
          onTap: onTap,
        ),
        if (action case final a?) ...[
          const SizedBox(height: MedShape.s3),
          a,
        ],
      ],
    );
  }
}
