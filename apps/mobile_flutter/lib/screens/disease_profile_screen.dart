// 「病程档案」独立页 —— 从「趋势」tab 第一块那张入口卡([DiseaseProfileCard])推进来。
//
// 2026-10-22 通用病程档案 spec(稿 A):这一页先放**通用层**(不靠任何病种包:诊断按族、
// 用药表、住院/手术等进程、依据),再把每个**装着的**病种包作页内一段叠在后面 ——
// 开着的包出它自己的 sections(标题、文案全来自包,逐字),没开的只有一行名字和「开启」。
// 开关不是本地的一个 bool —— 它是病历箱里 `enable`/`disable` 两种动作事件的最新一条
// (`profile::is_enabled`),所以这里记完一条就**重算一次视图**,不在本地猜新状态。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/skill_packages.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';

/// 病程档案这一块要碰的几样原生能力,拢在一个口子上:装着哪几个包、拉一次清单、
/// 算一份(单包)视图、算通用视图、记一条动作。
///
/// 摆成可注入的**只为 widget 测试**(与 `SkillPackages` 同一手法):这几件事全都
/// 要么走 FFI、要么走平台通道,`flutter test` 不带原生库,不注入就一条都跑不起来。
class DiseaseProfileSource {
  DiseaseProfileSource({
    Future<List<String>> Function()? installed,
    Future<String> Function(String packageId)? view,
    Future<void> Function(String kind, String packageId, String at)? record,
    Future<void> Function()? refresh,
    Future<String> Function()? general,
  }) : _installed = installed ?? _installedPackageIds,
       _view = view ?? _viewFromVault,
       _record = record ?? _recordToVault,
       _refresh = refresh ?? _refreshFromIndex,
       _general = general ?? _generalFromVault;

  final Future<List<String>> Function() _installed;
  final Future<String> Function(String packageId) _view;
  final Future<void> Function(String kind, String packageId, String at) _record;
  final Future<void> Function() _refresh;
  final Future<String> Function() _general;

  /// 缓存里装着哪几个病种包(id,已排序)。空 = 一个都没有。
  Future<List<String>> installedPackages() => _installed();

  /// 拉一次清单,把清单里列的包装上。**永不抛**(`SkillPackages.refreshIndex`
  /// 自己保证):没网、验签不过,都只是这次没更新,退回缓存里已经装着的那份。
  Future<void> refresh() => _refresh();

  /// 通用视图(`vault_profile_view_general`):通用段 + 每个开着的包的段 + 顶层
  /// `packages[]`(装着的包:id / display_name / enabled)+ `documents[]` 桥。
  /// **纯投影**,不写任何东西进病历箱。算不出来就抛给调用方(入口卡退到「还没准备好」)。
  Future<Map<String, dynamic>> general() async =>
      jsonDecode(await _general()) as Map<String, dynamic>;

  /// 单包视图。出码那条路要的是这个:那串原样塞进加密分享包交给医生
  /// (`qr_share_screen.dart` 的 `profileJsonForShare`)。
  ///
  /// **算不出来就先重新拉一遍包,再算一次。** 缓存在用户可写的磁盘上,是不可信
  /// 输入,`profile::cache_load` 每次读都重新验签 —— 「装着的那份被改过一个字节」
  /// 和「压根没装」在这里是同一种失败,重新拉一遍才是出路。
  Future<Map<String, dynamic>> view(String packageId) async {
    try {
      return await _viewMap(packageId);
    } catch (e) {
      // 只有包 id 和一句错误文本,没有病历内容,可以进日志。
      debugPrint('[profile] $packageId 这次算不出来,重新拉一遍包再试:$e');
      await _refresh();
      return await _viewMap(packageId);
    }
  }

  Future<Map<String, dynamic>> _viewMap(String packageId) async =>
      jsonDecode(await viewJson(packageId)) as Map<String, dynamic>;

  /// 同 [view],但给回**没解析过的原串**;**这一路不自愈**(出码是在诊室里按的,
  /// 没网时那一趟拉包要耗到连接超时)。包坏了就这一次不带档案。
  Future<String> viewJson(String packageId) => _view(packageId);

  /// 记一条 `enable`/`disable`,**真记上了才回 `true`**。
  ///
  /// `at` 是**今天**(设备本地日期,`YYYY-MM-DD`)—— 开关闸按 `at` 排序
  /// (`profile::is_enabled`),而 FFI 那一侧会把形状不对的日期直接挡回来。
  Future<bool> record(String kind, String packageId) async {
    try {
      await _record(kind, packageId, fmtDate(DateTime.now().toIso8601String()));
      return true;
    } catch (e) {
      debugPrint('[profile] $kind 这次没记上:$e');
      return false;
    }
  }
}

/// 缓存目录里装着的包 id。与 Rust 侧 `installed_packages` 读的是**同一个目录、
/// 同一种文件名**(`skills/<id>.json`)。只列文件名、不读内容:包体每次读都要重新验签。
Future<List<String>> _installedPackageIds() async {
  final d = Directory('${await skillCacheDir()}/skills');
  if (!d.existsSync()) return const [];
  return d
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.json'))
      .map((n) => n.substring(0, n.length - '.json'.length))
      .toList()
    ..sort();
}

Future<String> _viewFromVault(String packageId) async =>
    rust_profile.vaultProfileView(dir: await skillCacheDir(), packageId: packageId);

Future<String> _generalFromVault() async =>
    rust_profile.vaultProfileViewGeneral(dir: await skillCacheDir());

/// 载荷必须是 JSON **对象**(FFI 那一侧挡着):开关这两种动作没有别的要记的,给空对象。
Future<void> _recordToVault(String kind, String packageId, String at) async {
  await rust_profile.vaultProfileRecordEvent(
    kind: kind,
    package: packageId,
    at: at,
    payloadJson: '{}',
  );
}

Future<void> _refreshFromIndex() => SkillPackages().refreshIndex();

/// 通用视图 JSON 顶层 `packages[]` 的一条。
typedef PackageRow = ({String id, String name, bool enabled});

/// 从通用视图 JSON 顶层读 `packages[]`;缺键、形状不对一律当作没有。
List<PackageRow> packageRows(Map<String, dynamic> view) => [
  for (final p in (view['packages'] as List? ?? const []))
    if (p is Map && p['id'] is String)
      (
        id: p['id'] as String,
        name: p['display_name'] as String? ?? p['id'] as String,
        enabled: p['enabled'] == true,
      ),
];

class DiseaseProfileScreen extends StatefulWidget {
  const DiseaseProfileScreen({super.key, this.source});

  /// null → 真的那一套(FFI + 平台通道)。见 [DiseaseProfileSource]。
  final DiseaseProfileSource? source;

  @override
  State<DiseaseProfileScreen> createState() => _DiseaseProfileScreenState();
}

class _DiseaseProfileScreenState extends State<DiseaseProfileScreen> {
  late final DiseaseProfileSource _source = widget.source ?? DiseaseProfileSource();
  late Future<Map<String, dynamic>> _future = _source.general();

  /// 开关记录中 —— 防连点。
  bool _busy = false;

  /// 重算一次视图。`setState` 是**语句块不是箭头**
  /// (理由见 `test/known_defect_setstate_future_test.dart`)。
  void _reload() {
    final next = _source.general();
    setState(() {
      _future = next;
    });
  }

  /// 开 / 关某个包。记一条事件,**记上了才重算**。
  Future<void> _toggle(String packageId, {required bool enabled}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _source.record(enabled ? 'disable' : 'enable', packageId);
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

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snap) {
        return Scaffold(
          appBar: AppBar(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BrandLogo(size: BrandLogo.topBar),
                SizedBox(width: 10),
                Flexible(child: Text('病程档案', overflow: TextOverflow.ellipsis)),
              ],
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(height: 1, color: c.line),
            ),
          ),
          body: _body(snap),
        );
      },
    );
  }

  /// 三态各有各的说法(加载中 / 算出来了 / 打不开),与本 app 其它整屏同一写法。
  Widget _body(AsyncSnapshot<Map<String, dynamic>> snap) {
    if (snap.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snap.hasError) return _Failed(onRetry: _reload);
    return _Body(view: snap.data!, busy: _busy, onToggle: _toggle);
  }
}

/// 失败态:一句话加一颗重试,不把 Rust 那句错误原文摆给用户看。
class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MedShape.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '这一页暂时打不开。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
            const SizedBox(height: MedShape.s3),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 哪种 section 落哪个 tab(通用层的三段 + 包的各段)。
const Map<String, int> _kTabOfKind = {
  'family_cards': 0,
  'med_table': 0,
  'state': 0,
  'status_card': 0,
  'score_card': 0,
  'reminders': 0,
  'checklist': 0,
  'journey': 1,
  'series_chart': 1,
  'evidence': 2,
};

/// 正文:三 tab,每个 tab 先通用段、再每个包一段;「现在」tab 末尾是出处与免责声明。
class _Body extends StatelessWidget {
  const _Body({required this.view, required this.busy, required this.onToggle});

  final Map<String, dynamic> view;
  final bool busy;
  final Future<void> Function(String packageId, {required bool enabled}) onToggle;

  /// `documents[]` 桥(`vault_profile_view_general` 附的):`SourceDoc::index` → document_id。
  Map<int, int> _documentIds() => {
    for (final d in (view['documents'] as List? ?? const []))
      if (d is Map && d['index'] is num && d['document_id'] is num)
        (d['index'] as num).toInt(): (d['document_id'] as num).toInt(),
  };

  ProfileLinks _links(BuildContext context, List<Map<String, dynamic>> sections) {
    final evidence = <String, Map<String, dynamic>>{};
    for (final s in sections) {
      if (s['kind'] != 'evidence') continue;
      final body = s['body'];
      final items = body is Map ? body['items'] : null;
      if (items is! List) continue;
      for (final e in items) {
        if (e is Map && e['id'] is String) {
          evidence[e['id'] as String] = e.cast<String, dynamic>();
        }
      }
    }
    final docIds = _documentIds();
    return ProfileLinks(
      evidenceById: evidence,
      onOpen: (e) {
        final idx = (e['doc'] as num?)?.toInt();
        final docId = idx == null ? null : docIds[idx];
        if (docId == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            appSnackBar(content: Text('${e['quote'] ?? ''}')),
          );
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DocumentDetailScreen(
              docId: docId,
              highlight: e['quote'] as String?,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final sections = (view['sections'] as List? ?? const [])
        .whereType<Map>()
        .map((s) => s.cast<String, dynamic>())
        .toList();
    final packages = packageRows(view);
    final sources = (view['sources'] as List? ?? const [])
        .whereType<Map>()
        .map((s) => s.cast<String, dynamic>())
        .toList();
    final disclaimer = view['disclaimer'] as String? ?? '';
    final links = _links(context, sections);

    List<Widget> page(int tab) => [
      for (final s in sections)
        if (_kTabOfKind[s['kind']] == tab && (s['package_id'] ?? 'general') == 'general')
          ProfileSectionView(s, links: links),
      for (final p in packages) ...[
        const SizedBox(height: MedShape.s3),
        _PackageHeader(
          row: p,
          busy: busy,
          onToggle: () => onToggle(p.id, enabled: p.enabled),
        ),
        if (p.enabled)
          for (final s in sections)
            if (_kTabOfKind[s['kind']] == tab && s['package_id'] == p.id)
              ProfileSectionView(s, links: links),
      ],
    ];
    const pad = EdgeInsets.fromLTRB(MedShape.s3, MedShape.s3, MedShape.s3, MedShape.s6);
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            labelColor: c.sealInk,
            unselectedLabelColor: c.ink2,
            indicatorColor: c.seal,
            dividerColor: c.line,
            tabs: const [Tab(text: '现在'), Tab(text: '进程'), Tab(text: '依据')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: pad,
                  children: [
                    ...page(0),
                    const SizedBox(height: MedShape.s4),
                    if (sources.isNotEmpty) _Sources(sources),
                    const SizedBox(height: MedShape.s2),
                    // 包给的那句话,**逐字**,不在前后加任何自己的措辞。
                    Text(
                      disclaimer,
                      style: MedType.secondary.copyWith(color: c.ink3, height: 1.6),
                    ),
                  ],
                ),
                ListView(padding: pad, children: page(1)),
                ListView(padding: pad, children: page(2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 页内一段的头:`── 系统性红斑狼疮(病种包)──` + 开/关按钮。病名是包给的,逐字。
class _PackageHeader extends StatelessWidget {
  const _PackageHeader({required this.row, required this.busy, required this.onToggle});

  final PackageRow row;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Divider(color: c.line)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MedShape.s2),
              child: Text(
                '${row.name}(病种包)',
                style: MedType.caption.copyWith(color: c.ink2),
              ),
            ),
            Expanded(child: Divider(color: c.line)),
          ],
        ),
        if (!row.enabled)
          Padding(
            padding: const EdgeInsets.only(top: MedShape.s1, bottom: MedShape.s2),
            child: Text(
              '还没开启。开启之后,这个病的用药、检查、该复查的会整理成这里的一段。',
              style: MedType.secondary.copyWith(color: c.ink2, height: 1.6),
            ),
          ),
        OutlinedButton(
          onPressed: busy ? null : onToggle,
          child: Text(row.enabled ? '关闭病程档案' : '开启病程档案'),
        ),
      ],
    );
  }
}

/// 出处全文,**默认收起**。`id · cite` **逐字**来自包的 `manifest.sources[]`。
class _Sources extends StatelessWidget {
  const _Sources(this.sources);

  final List<Map<String, dynamic>> sources;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return ExpansionTile(
      title: Text('出处', style: MedType.caption.copyWith(color: c.ink3)),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: MedShape.s2),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in sources)
          Padding(
            padding: const EdgeInsets.only(bottom: MedShape.s1),
            child: Text(
              '${s['id']} · ${s['cite']}',
              style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
            ),
          ),
      ],
    );
  }
}
