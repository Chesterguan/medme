// 「病程档案」独立页 —— 从「趋势」tab 第一块那张入口卡([DiseaseProfileCard])推进来。
//
// 这一页自己**一句病种文案都没有**:标题是包给的 `display_name`,正文是包给的
// `sections`(按包给的顺序,逐块交给 [ProfileSectionView]),页脚那句免责声明是包给的
// `disclaimer`,逐字显示。App 里写死一句,「加一个病不发版」就不成立了
// (`widgets/profile_sections.dart` 头部同一条)。
//
// 页上只有一个动作:**开启 / 关闭**。开关不是本地的一个 bool —— 它是病历箱里
// `enable`/`disable` 两种动作事件的最新一条(`profile::is_enabled`),所以这里
// 记完一条就**重算一次视图**,不在本地猜新状态。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/skill_packages.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';

/// 病程档案这一块要碰的四样原生能力,拢在一个口子上:装着哪几个包、拉一次清单、
/// 算一份视图、记一条动作。
///
/// 摆成可注入的**只为 widget 测试**(与 `SkillPackages` 同一手法):这四件事全都
/// 要么走 FFI、要么走平台通道,`flutter test` 不带原生库,不注入就一条都跑不起来。
class DiseaseProfileSource {
  DiseaseProfileSource({
    Future<List<String>> Function()? installed,
    Future<String> Function(String packageId)? view,
    Future<void> Function(String kind, String packageId, String at)? record,
    Future<void> Function()? refresh,
  }) : _installed = installed ?? _installedPackageIds,
       _view = view ?? _viewFromVault,
       _record = record ?? _recordToVault,
       _refresh = refresh ?? _refreshFromIndex;

  final Future<List<String>> Function() _installed;
  final Future<String> Function(String packageId) _view;
  final Future<void> Function(String kind, String packageId, String at) _record;
  final Future<void> Function() _refresh;

  /// 缓存里装着哪几个病种包(id,已排序)。空 = 一个都没有。
  ///
  /// 「装着」在这里只到**文件在**为止;那份文件验不验得过要等 [view] 去算才知道
  /// (那里算不出来会自己重新拉一遍包,见它的文档)。
  Future<List<String>> installedPackages() => _installed();

  /// 拉一次清单,把清单里列的包装上。**永不抛**(`SkillPackages.refreshIndex`
  /// 自己保证):没网、验签不过,都只是这次没更新,退回缓存里已经装着的那份。
  Future<void> refresh() => _refresh();

  /// 算一份 `ProfileView`。**纯投影**,不写任何东西进病历箱。
  ///
  /// **算不出来就先重新拉一遍包,再算一次。** 缓存在用户可写的磁盘上,是不可信
  /// 输入,`profile::cache_load` 每次读都重新验签 —— 所以「装着的那份被改过一个
  /// 字节」和「压根没装」在这里是同一种失败。而磁盘上那个坏文件的名字还在,
  /// [installedPackages] 看谁都是「装着」,光原地重试一万次也只会一万次验不过。
  /// 重新拉一遍(`refresh` 把清单里列的包整份重装)才是那条出路 —— 入口卡与独立页
  /// 都从这一个函数过,闸放这一处就够,不必各自补一遍。
  ///
  /// 还是不行就把错误抛给调用方:没网的时候走的就是这一路,两边的处置本来就一样
  /// (说一句「还没准备好 —— 联网之后点一下重试」,不摆一份不存在的档案)。
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

  /// 同 [view],但给回**没解析过的原串**。
  ///
  /// 出码那条路要的是这个:那串要原样塞进加密分享包交给医生
  /// (`qr_share_screen.dart` 的 `profileJsonForShare`),解开再拼回去等于多一次
  /// 序列化;而且一份档案一次分享**只算一遍** —— 这个函数每调一次,Rust 那边就
  /// 把整箱病历重新投影一次。
  ///
  /// **这一路不自愈**(与 [view] 相反,那边算不出来会去重新拉一遍包)。出码是在
  /// 诊室里按的:没网时那一趟拉包要耗到连接超时(`Net.connect`,20 秒),而病人
  /// 此刻要的是那个码。包坏了就这一次不带档案 —— 入口卡那一路会把它修好。
  Future<String> viewJson(String packageId) => _view(packageId);

  /// 记一条 `enable`/`disable`,**真记上了才回 `true`**。
  ///
  /// `at` 是**今天**(设备本地日期,`YYYY-MM-DD`)—— 开关闸按 `at` 排序
  /// (`profile::is_enabled`),而 FFI 那一侧会把形状不对的日期直接挡回来。
  ///
  /// 记不上时回 `false` 而不是抛:两个调用方(入口卡与本页)的处置一样 ——
  /// 原地说一句「这次没记上」,**绝不假装已经开了**。
  ///
  /// 记上了要 [bumpVaultRevision]:这一条动作日志是真写进病历箱的一份文档,
  /// 首页待办卡(`ArchiveScreen` 监听 `vaultRevision`)和防抖同步推送都靠这个信号
  /// 才知道要重新算一次 —— 放在这个包装函数里(而不是 `_recordToVault` 内部),
  /// 注入假 `record` 的测试也照样会触发。
  Future<bool> record(String kind, String packageId) async {
    try {
      await _record(kind, packageId, fmtDate(DateTime.now().toIso8601String()));
      bumpVaultRevision();
      return true;
    } catch (e) {
      // 这里只有 kind/包 id 和一句错误文本,没有病历内容,可以进日志。
      debugPrint('[profile] $kind 这次没记上:$e');
      return false;
    }
  }
}

/// 缓存目录里装着的包 id。与 Rust 侧 `installed_packages` 读的是**同一个目录、
/// 同一种文件名**(`skills/<id>.json`,`packages/profile/src/package.rs:380`)。
///
/// 这里只列文件名、不读内容:包体每次读都要重新验签(`cache_load`),所以列错一个
/// 名字也换不出一份假档案 —— `vault_profile_view` 会当作「没有这个包」。落盘写到一半
/// 的 `.json.tmp` 天然不以 `.json` 结尾,不会被数进来。
///
/// 代价是这份名单会把**被改过的那份**也算成装着(名字还在)。那一半由
/// [DiseaseProfileSource.view] 兜着:算不出来就重新拉一遍包,坏的那份被整份换掉。
/// 别在这里改成「挨个验一遍」——那等于把一整箱病历的投影跑 N 遍,只为了得到一个
/// 紧接着就会被算出来的答案。
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
    rust_profile.vaultProfileView(
      dir: await skillCacheDir(),
      packageId: packageId,
    );

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

class DiseaseProfileScreen extends StatefulWidget {
  const DiseaseProfileScreen({
    super.key,
    required this.packageId,
    this.source,
  });

  final String packageId;

  /// null → 真的那一套(FFI + 平台通道)。见 [DiseaseProfileSource]。
  final DiseaseProfileSource? source;

  @override
  State<DiseaseProfileScreen> createState() => _DiseaseProfileScreenState();
}

class _DiseaseProfileScreenState extends State<DiseaseProfileScreen> {
  late final DiseaseProfileSource _source =
      widget.source ?? DiseaseProfileSource();
  late Future<Map<String, dynamic>> _future = _source.view(widget.packageId);

  /// 开关记录中 —— 防连点(同一天连着记两条 enable 不会错,但没必要)。
  bool _busy = false;

  /// 重算一次视图。`setState` 是**语句块不是箭头**
  /// (理由见 `test/known_defect_setstate_future_test.dart`)。
  void _reload() {
    final next = _source.view(widget.packageId);
    setState(() {
      _future = next;
    });
  }

  /// 开 / 关。记一条事件,**记上了才重算** —— 开关状态是事件算出来的,不是本地的 bool。
  Future<void> _toggle({required bool enabled}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _source.record(
      enabled ? 'disable' : 'enable',
      widget.packageId,
    );
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
        final view = snap.data;
        return Scaffold(
          appBar: AppBar(
            // 真 logo 30px(brief §品牌:病程档案页头,与主页顶栏同一尺寸)+
            // 标题——字符串不动,标题前面多了一枚图。标题是包给的病名;拿到之前
            // 先用这一块自己的名字,不占位编一个病名。`Flexible` + 省略号防止
            // 病名一旦很长顶出顶栏(`archive_screen.dart` 的标题是固定的「病历」
            // 两个字,没有这个风险;这里是包给的动态字符串,得防一手)。
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BrandLogo(size: BrandLogo.topBar),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    view?['display_name'] as String? ?? '病程档案',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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

/// 失败态。**说得出是哪一种失败**:没有包(还没装上 / 装的那份验不过)与
/// 「算不出来」在这一页上的处置一样 —— 重试 —— 所以只给一句话加一颗重试,
/// 不把 Rust 那句错误原文摆给用户看(里面是路径和包 id,对他没用)。
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

/// 正文:包给的 section 按包给的顺序 → 开关 → 出处 → 免责声明(逐字,最后一行)。
class _Body extends StatelessWidget {
  const _Body({required this.view, required this.busy, required this.onToggle});

  final Map<String, dynamic> view;
  final bool busy;
  final Future<void> Function({required bool enabled}) onToggle;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final enabled = view['enabled'] == true;
    final sections = (view['sections'] as List? ?? const [])
        .map((s) => (s as Map).cast<String, dynamic>())
        .toList();
    final sources = (view['sources'] as List? ?? const [])
        .map((s) => (s as Map).cast<String, dynamic>())
        .toList();
    final disclaimer = view['disclaimer'] as String? ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        MedShape.s3,
        MedShape.s3,
        MedShape.s6,
      ),
      children: [
        // 没开启时引擎不算任何东西(`sections` 为空),这一页就只剩这句话和那颗按钮。
        if (!enabled) ...[
          Text(
            '还没开启。开启之后,这个病的用药、检查、该复查的会整理成这一页。',
            style: MedType.body.copyWith(color: c.ink2, height: 1.6),
          ),
          const SizedBox(height: MedShape.s4),
        ],
        for (final s in sections) ProfileSectionView(s),
        const SizedBox(height: MedShape.s2),
        // 开关本身。关掉之后引擎就不再算、不再提醒(spec §4),所以这颗按钮不藏进
        // 二级菜单 —— 用户要能一眼找到怎么让它停下来。
        OutlinedButton(
          onPressed: busy ? null : () => onToggle(enabled: enabled),
          child: Text(enabled ? '关闭病程档案' : '开启病程档案'),
        ),
        const SizedBox(height: MedShape.s4),
        if (sources.isNotEmpty) _Sources(sources),
        const SizedBox(height: MedShape.s2),
        // 包给的那句话,**逐字**,不在前后加任何自己的措辞。
        Text(
          disclaimer,
          style: MedType.secondary.copyWith(color: c.ink3, height: 1.6),
        ),
      ],
    );
  }
}

/// 出处全文,**默认收起**。
///
/// 卡片里每个数值旁边印的是出处 id(`出处 S12`,`widgets/profile_sections.dart`),
/// 全文只在这里有一份 —— 没有这一块,那些 id 就是查不到去处的编号。`id · cite`
/// **逐字**来自包的 `manifest.sources[]`,这里不加书名号、不重排、不缩写。
///
/// 收起是因为它是「要查的时候才查」的东西:二十几条文献题录摆在开关下面,会把
/// 真正要看的内容挤出屏幕。
class _Sources extends StatelessWidget {
  const _Sources(this.sources);

  final List<Map<String, dynamic>> sources;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return ExpansionTile(
      title: Text('出处', style: MedType.caption.copyWith(color: c.ink3)),
      // 展开/收起时 Material 自己那两道分隔线在这一屏上是多余的一档层次
      // (层次靠边框,设计系统 §四)。
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
