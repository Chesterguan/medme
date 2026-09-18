import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
import 'package:mobile_flutter/screens/member_detail_screen.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/icloud_bridge.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/backup_status_line.dart';
import 'package:mobile_flutter/widgets/member_switcher.dart';

/// 与 `pubspec.yaml` 的 `version:` 字段(`x.y.z+build`)保持一致。P3 范围内没有为
/// 读版本号新增 `package_info_plus` 依赖(约束里明确不加新依赖),手工同步即可——
/// 这两颗常量本来就只在“关于”里给人看,不参与任何业务逻辑。
///
/// 这颗常量已经漂过两次(团队靠它核「有没有装到最新版」,结果显示的还是两个小版本
/// 前的号)。`test/app_version_test.dart` 会拿这里的字面量去和 `pubspec.yaml` 比对,
/// 漂了就会红——改这两行时记得同时改 `pubspec.yaml`,或者反过来。
const _appVersionName = '1.6.0';
const _appBuildNumber = '56';

/// 底部导航一级 tab「我」(`s5`)—— 云端 / 这台手机上的病历 / 口令与恢复码 ·
/// 我的设备 · 关于 / 给医生看 · 导出 / 删掉全部。
///
/// **「示例数据」「使用情况」「iCloud 同步」三节在下一层**([AboutScreen]):它们
/// 一年碰一次,平铺在首屏上占掉的是「这台手机上的病历」该占的位置。
/// 同步(iCloud)入口当前收起,见 [_showIcloudSync]。

/// 是否在「我 → 关于」里露出「iCloud 同步」入口。当前 false —— 全力做手机端本体,
/// 跨设备同步先不投入。底层能力未删,改回 true 即恢复。
const bool _showIcloudSync = false;

/// 这一节到底该不该露出来:总开关收着的情况下,如果这台设备**已经**开着 iCloud
/// 同步(老用户,在总开关收起之前开的),照样要露出来——不然这些用户找不到任何
/// 入口关掉它(C3:「请先在「我 → 关于」里关闭 iCloud 同步」这句提示指向的正是
/// 这个开关)。`icloud` 为 null(状态还没查回来)时按未开处理。
@visibleForTesting
bool shouldShowIcloudSection(IcloudStatusDto? icloud) => _showIcloudSync || (icloud?.enabled ?? false);

/// 分组卡片列表,视觉还原自 `apps/mobile/src/App.tsx` 的设置区(sect + group + row)。
/// 病历箱在 `main.dart` 启动时已打开,这里直接调 FFI,不重复任何 Rust 侧逻辑。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PatientProfileDto? _profile;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 导入/清空等在别的 tab 发生时,身份卡的记录数等也要跟着更新(本屏保活)。
    vaultRevision.addListener(_refresh);
  }

  @override
  void dispose() {
    vaultRevision.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final p = await patientProfile();
      if (!mounted) return;
      setState(() => _profile = p);
    } catch (_) {
      // 状态读取失败不影响本屏其它功能(删成员/清空仍可用),静默忽略即可。
    }
  }

  /// 切换「个人 / 医生」模式:写入持久化后,`main.dart` 的 `AppRoot` 监听同一个
  /// notifier 自动换到另一个根界面;本屏若是被 push 进来的(代拍模式下,设置没有
  /// 自己的 tab,是从 `DoctorHomeScreen` 点进来的),顺手把导航栈弹回第一层,让
  /// 换好的根界面露出来。个人模式下设置本来就是 tab、没有可弹的栈,`canPop()` 为
  /// false,这一步是 no-op。
  Future<void> _switchMode() async {
    final current = AppMode.instance.mode.value;
    final target = current == AppModeKind.doctor
        ? AppModeKind.personal
        : AppModeKind.doctor;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('切换模式?'),
        content: Text(
          target == AppModeKind.doctor
              ? '切换到代拍:主界面变成「我是医生,替病人代拍」,你自己的病历仍在——'
                    '随时可以再切回来查看。'
              : '切换到「自己/家人的病历」模式,回到「病历」「趋势」「我」三个入口。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // `where: settings` —— 事后切换。它和首屏那次选择数量上的比,直接说明
    // 「你是?」那一屏问得清不清楚。
    Analytics.track(AnalyticsEvent.modeSelected, {
      'mode': target.name,
      'where': 'settings',
    });
    Analytics.setContext({'mode': target.name});
    await AppMode.instance.setMode(target);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentMode = AppMode.instance.mode.value;
    return Scaffold(
      appBar: AppBar(title: const Text('我')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // `s5` 的「我」里**没有**模式这一节 —— 进代拍的入口在「给医生看」那一页
          // (Task 9)。但**出来**那条路今天只剩这一处:代拍模式下这一屏是从
          // `DoctorHomeScreen` 右上角 push 进来的,整节删掉等于把人永久关在代拍里。
          // 所以只在代拍模式下留这一行;Task 15 给代拍首页自己的出口之后再删。
          if (currentMode == AppModeKind.doctor) ...[
            _SectionLabel('模式'),
            _SettingsGroup(
              children: [
                _SettingsRow(
                  icon: Icons.medical_services_outlined,
                  title: '退出代拍',
                  subtitle: '点击切换到你自己的家庭档案',
                  onTap: _switchMode,
                ),
              ],
            ),
          ],
          // `s5` 第一行,**整节只有这一行**:标题「云端」+ 副标题「已备份,刚刚」+「›」。
          // 整行可点,点进去才是云端那一层(「云端整理」开关在里面,不在这一屏平铺)。
          // 云的说法全 App 只有两件事:云端备份 / 云端整理。
          //
          // 没登录时这一行自己就写着「没登录,换手机找不回来」并且点进账号那一屏,
          // 所以不再另挂一条「登录 / 注册」—— 同一件事两行说,正是这次要收掉的毛病。
          // 登录之后进账号那一屏的路仍在:下面的「口令与恢复码」「我的设备」。
          _SectionLabel('云端'),
          const _SettingsGroup(children: [BackupStatusLine()]),
          _SectionLabel('这台手机上的病历'),
          MembersCard(
            members: ProfileManager.instance.profiles,
            countOf: _countOf,
            onOpen: _openMember,
            onAdd: _addMember,
          ),
          const SizedBox(height: 16),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.key_outlined,
                title: '口令与恢复码',
                onTap: _openAccount,
              ),
              _SettingsRow(
                icon: Icons.devices_outlined,
                title: '我的设备',
                onTap: _openAccount,
              ),
              _SettingsRow(
                icon: Icons.info_outline,
                title: '关于 / 隐私政策',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
                ),
              ),
            ],
          ),
          // ⚠️ Task 17:「给医生看 · 导出」这一节与下面的「删掉全部」都撤掉了——
          // 「给医生看」首页那颗方块是导出/出码唯一的门(不在「我」首屏另开一条),
          // 「导出文件」现在是那一整页里跟着滚的次要一行(`for_doctor_screen.dart`
          // 的 `ForDoctorActions`);「删掉全部」挪到了「我 → 关于」页面的最后一行
          // (`AboutScreen`),同一套确认流程原样搬了过去。
        ],
      ),
    );
  }

  /// 账号那一层。「云端」「口令与恢复码」「我的设备」三行都进这里 —— 今天它们
  /// 确实是同一屏上的三节(云端备份 / 口令解锁 / 设备),Task 14 拆开各自的屏
  /// 之后再把这三行各自指过去。
  void _openAccount() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AccountScreen(
        flow: AccountFlow(
          ApiClient.forSession(AccountSession.instance),
          AccountSession.instance,
        ),
        onReadyCloudSync: runBackgroundSync,
      ),
    ),
  );

  /// 当前成员用刚查到的最新记录数,其余成员用缓存(没加载过为 null)。
  int? _countOf(String id) {
    final pm = ProfileManager.instance;
    if (id == pm.currentId.value && _profile != null) return _profile!.recordCount;
    return pm.countFor(id);
  }

  /// 点开一个成员:去他自己的页面(`s10`,`MemberDetailScreen`)——谁能看他的病历 /
  /// 加一个人 / 改名字 / 删除这个成员。Task 12 时这一步还是「切过去看病历」(那正是
  /// 这张卡上「31 份 ›」承诺的事);`s10` 到位后这颗承诺改由「病历」tab 的成员
  /// 切换器兑现,这一行变成管理入口(Task 13 fix round 1)。
  Future<void> _openMember(Profile m) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MemberDetailScreen(
        member: m,
        onChanged: () => setState(() {}),
      ),
    ),
  );

  /// 「添加成员」:与档案屏成员条末尾那颗「+」同一条路(`promptAddMember`),
  /// 不另起一套。
  Future<void> _addMember() =>
      promptAddMember(context, onChanged: () => setState(() {}));
}

/// 分组标题(灰色小字),对应旧版 `App.css` 里的 `.sect`。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: MedMe.faint,
        ),
      ),
    );
  }
}

/// 白色圆角卡片,内部若干行,行间用分隔线隔开——对应旧版 `.group`。
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: MedMe.line),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 可点击的一行:图标 + 标题 + 说明 + 尾部箭头(或自定义 trailing)。
/// 对应旧版 `.row`;`danger` 对应 `.row.danger`(清空按钮用 `MedMe.danger`)。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? MedMe.danger : MedMe.ink;
    return ListTile(
      leading: Icon(icon, color: danger ? MedMe.danger : MedMe.teal),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w600, color: color),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: const TextStyle(color: MedMe.faint)),
      trailing:
          trailing ??
          (onTap != null
              ? const Icon(Icons.chevron_right, color: MedMe.faint)
              : null),
      onTap: onTap,
      enabled: onTap != null || trailing != null,
    );
  }
}

/// 「载入示例数据」专属行:载入中要换成 spinner + 「正在载入 N/22…」,
/// [_SettingsRow] 那套「图标/标题/说明」是静态的,管不了这种按状态切换内容的
/// 需求,所以单独一个 widget,外观仍与 [_SettingsRow] 保持一致。
///
/// **`contentPadding` 比 [_SettingsRow] 更大**:真机实测(华为 Mate 9)踩到过
/// 一次点在这张卡与上一张卡的缝隙里、11 秒后才发现「点空了」——加大这一行的
/// 点击热区(等于加大这张卡的可点范围),降低再次点空的概率。
///
/// **载入中特意不让 [ListTile] 整行变暗**(`enabled` 恒为 true):默认禁用态会把
/// 文字连同新画的进度文案一起压暗,削弱这次改动本来要解决的「反馈不够显眼」。
class _DemoDataRow extends StatelessWidget {
  const _DemoDataRow({
    required this.loading,
    required this.progressText,
    required this.onTap,
  });

  final bool loading;

  /// 逐份进度文案(如「正在载入 3/22…」)。拿不到具体进度(刚点下去、第一条
  /// 还没从 Rust 侧报回来)时为 null——退化成一句不确定进度的提示,总比空着强。
  final String? progressText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      leading: loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : const Icon(Icons.download_outlined, color: MedMe.teal),
      title: Text(
        loading ? '正在载入示例数据…' : '载入示例数据(张建国)',
        style: const TextStyle(fontWeight: FontWeight.w600, color: MedMe.ink),
      ),
      subtitle: Text(
        loading
            ? (progressText ?? '正在载入示例数据…')
            : '单独放一个成员里,不和你的病历混在一起;看完可以去「我」首页的「这台手机上的病历」里把这个成员整个移除',
        style: const TextStyle(color: MedMe.faint),
      ),
      trailing: loading
          ? null
          : (onTap != null
                ? const Icon(Icons.chevron_right, color: MedMe.faint)
                : null),
      onTap: onTap,
      enabled: onTap != null || loading,
    );
  }
}

/// 纯展示的一行(无点击),用于「关于」里的静态信息。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(color: MedMe.faint)),
    );
  }
}

/// `s5` 的「这台手机上的病历」卡:一个成员一行 —— 头像 + 名字 + `N 份 ›`,
/// 最后一行是「添加成员」。
///
/// **这张卡上一个角色词都没有**(不写「主人 / 家人 / 能改 / 只能看」):摆在挑人的
/// 列表上,用户读到的是「家里谁是谁」,而那不是那个字段的意思 —— 授权级别只在某个
/// 成员自己的页面里说,那里有上下文(`s10`,Task 13)。
///
/// 纯 widget,**不碰 FFI、不碰 ProfileManager**(成员表和份数都由调用方传进来),
/// 这样 `flutter test` 测得到 —— [SettingsScreen] 整屏是 pump 不了的(`initState`
/// 里直接调 FFI)。见 `test/members_card_test.dart`。
class MembersCard extends StatelessWidget {
  const MembersCard({
    super.key,
    required this.members,
    required this.countOf,
    required this.onOpen,
    required this.onAdd,
  });

  final List<Profile> members;

  /// 这个成员有多少份病历;还没数出来返回 null(显示「—」,不编一个数)。
  final int? Function(String id) countOf;

  /// 点一行:去这个成员自己的页面(`s10`,`MemberDetailScreen`)。删除成员的入口
  /// 挪到那一页的「删除这个成员」去了(Task 13 fix round 1)——这张卡回到 `s5`
  /// 原本的样子,一个角色词、一颗多余的图标都没有,只有名字和份数。
  final void Function(Profile m) onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (final m in members) ...[
            if (m != members.first) const Divider(height: 1, color: MedMe.line),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: MedMe.tealSoft,
                child: Text(
                  m.name.isNotEmpty ? m.name.characters.first : '?',
                  style: const TextStyle(color: MedMe.teal, fontWeight: FontWeight.w700),
                ),
              ),
              title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    countOf(m.id) == null ? '—' : '${countOf(m.id)} 份',
                    style: const TextStyle(color: MedMe.faint, fontSize: 13),
                  ),
                  const Icon(Icons.chevron_right, color: MedMe.faint),
                ],
              ),
              onTap: () => onOpen(m),
            ),
          ],
          const Divider(height: 1, color: MedMe.line),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: MedMe.tealSoft,
              child: Icon(Icons.add, color: MedMe.teal, size: 20),
            ),
            title: const Text(
              '添加成员',
              style: TextStyle(fontWeight: FontWeight.w600, color: MedMe.teal),
            ),
            onTap: onAdd,
          ),
        ],
      ),
    );
  }
}

/// 「我 → 关于」那一层(`s5`:首屏只留一行「关于 / 隐私政策 ›」)。
///
/// 三节从首屏挪进来:**示例数据 / 使用情况 / iCloud 同步**。它们都是一年碰一次的
/// 东西,平铺在首屏上占掉的是「这台手机上的病历」该占的位置。
///
/// 这一屏 `initState` 里直接调 FFI(`icloudStatus`),同 [SettingsScreen]
/// **不能整屏 pump**。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  IcloudStatusDto? _icloud;

  /// iCloud 容器是否可用(登录了 iCloud):Rust 拿不到,由原生 channel 判断。
  bool _icloudAvailable = false;

  /// 载入示例 / 开关 iCloud 时置真,禁用本屏其它按钮,防止重复点击。
  bool _busy = false;

  /// 「载入示例数据」这一颗按钮**自己的**进行中状态,与 [_busy] 分开管:[_busy]
  /// 负责禁用全屏其它按钮(防误触),这个才负责「这颗按钮该不该画进度条」——
  /// 清空/iCloud 等操作也会置 [_busy],但不该让示例数据那一行跟着显示进度。
  ///
  /// 真机实测过(华为 Mate 9,22 份 PDF、11 秒):这段时间里屏幕纹丝不动,用户
  /// 分不清「没点上」还是「在跑」,十一秒足够让人以为没点上又点第二次。见
  /// `_loadDemoData` 里怎么用它配合逐份进度画面。
  bool _demoLoading = false;

  /// [_demoLoading] 期间显示的进度文案(如「正在载入 3/50…」——分母是
  /// `load_demo_data` 报回来的总数,不是这里写死的,示例数据增减会自己跟上);拿不到进度
  /// (刚开始、或 Rust 侧这一份还没报回来)时为 null,退化成一句不确定进度的
  /// 「正在载入示例数据…」,总比空着强。
  String? _demoProgressText;

  bool _analyticsOn = Analytics.isEnabled;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await icloudStatus();
      final available = await IcloudBridge.available(); // 原生判断容器是否可用
      if (!mounted) return;
      setState(() {
        _icloud = status;
        _icloudAvailable = available;
      });
    } catch (_) {
      // 状态读取失败不影响本屏其它功能(载入示例仍可用),静默忽略即可。
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text(text)));
  }

  Future<void> _openHomepage() => _openWeb('https://medmenow.com/', '主页');

  /// 隐私政策与用户协议:苹果与各应用商店都要求 App 内可达,不能只挂在官网上。
  Future<void> _openWeb(String url, String label) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) _showSnack('无法打开$label,请稍后重试');
  }

  /// 示例数据落进**它自己的成员**,不混进你的档案 —— 于是看完可以直接去「我」首页的
  /// 「这台手机上的病历」里把这个成员整个移除,你自己导入的东西一份不动。(早先是灌进当前成员,再被
  /// 自动命名成「张建国」,想清掉就只能动用「清空所有数据」那颗核弹。)
  static const _demoMember = '张建国(示例)';

  /// 载入示例数据要先把「当前成员」切到 [_demoMember](写入侧的技术要求——Rust
  /// 那颗 vault 是进程级单例,写哪个成员就得先开哪个成员的箱子,见
  /// `vault_boot.dart` 顶部说明),但**这只是写入侧的手段,不代表用户想把「正在
  /// 看的视角」也换过去**。早先版本载入完直接留在示例成员上、还把人跳到「健康
  /// 档案」——用户没要求换成员,自己的档案却被切走了,回来还得先发现顶部那排
  /// chip 才知道发生了什么。
  ///
  /// 现在的分工:切成员是**手段**,载入完立刻切回用户载入前正看着的那个人;
  /// 是否要去看示例数据,交给 SnackBar 上的「去看看」——用户自己点了,才在同一次
  /// 点击里把视角切过去 + 跳到「健康档案」,两件事绑在一起,而不是替他做主。
  Future<void> _loadDemoData() async {
    setState(() {
      _busy = true;
      _demoLoading = true;
      _demoProgressText = null;
    });
    try {
      final pm = ProfileManager.instance;
      await pm.ensureLoaded();
      final originalMemberId = pm.currentId.value;
      // 按名字找已存在的示例成员:名字本来可重复,但这个是我们自己建的、用户改不到,
      // 拿它认一下就够,免得再存一个 id。找不到就新建(新建会自动切过去)。
      final existing = pm.profiles
          .where((p) => p.name == _demoMember)
          .firstOrNull;
      final String demoMemberId;
      if (existing == null) {
        final created = await createProfileAndReopen(
          _demoMember,
          userManaged: false,
        );
        if (created == null) throw StateError('无法创建示例成员');
        demoMemberId = created;
      } else {
        demoMemberId = existing.id;
        if (pm.currentId.value != demoMemberId) {
          await switchProfileAndReopen(demoMemberId);
        }
      }

      // 逐份进度:见 `api::vault::load_demo_data` 的文档——这条流恒不报 Rust 侧的
      // `Err`(那样的话 Dart 这里永远等不到、也 catch 不到,详见 Rust 侧注释),
      // 失败改用 `error` 字段带出来,这里判它、`break` 出循环。
      var succeeded = 0;
      String? failure;
      await for (final p in loadDemoData()) {
        if (p.error != null) {
          failure = p.error;
          break;
        }
        succeeded = p.succeeded.toInt();
        if (!mounted) continue;
        setState(() => _demoProgressText = '正在载入 ${p.loaded}/${p.total}…');
      }

      // 埋点就发在这里 —— 循环刚结束、`failure` 已定,而后面切回成员 / 刷新 /
      // 弹 SnackBar 都还没跑。放在更后面的话,那几步里任何一个抛出去都会让这条
      // 事件丢掉,于是「示例数据坏了」在数据里仍然是零。
      //
      // **只报成没成这一个布尔**:`failure` 是 Rust 侧的一段文本、可能带路径,
      // 绝不上报(与 `doc_import_failed` 只报 `reason_code` 同一条规矩)。
      Analytics.track(AnalyticsEvent.demoDataLoaded, {'ok': failure == null});

      // 切回用户载入前正看着的那个人(见本函数顶部文档)。
      if (pm.currentId.value != originalMemberId) {
        await switchProfileAndReopen(originalMemberId);
      }
      // 通知「病历」「我」两屏自动重载(并按识别姓名自动命名档案)—— 份数这件事
      // 由那边自己重读,本屏不持有它。
      bumpVaultRevision();
      if (!mounted) return;

      if (failure != null) {
        _showSnack('载入示例数据失败:$failure');
        return;
      }
      // 带 action 的 SnackBar,而不是直接跳走:去不去看示例数据由用户自己决定。
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(
          content: Text('已载入 $succeeded 份示例病历(在「$_demoMember」里)'),
          action: SnackBarAction(
            label: '去看看',
            onPressed: () async {
              if (pm.currentId.value != demoMemberId) {
                await switchProfileAndReopen(demoMemberId);
              }
              goToRecords();
            },
          ),
        ),
      );
    } catch (e) {
      // 抛在流跑完之前(建成员、切箱子、FFI 起不来)—— 上面那条来不及发,
      // 在这里补一条 `ok:false`。**只有布尔,`e` 不上报。**
      Analytics.track(AnalyticsEvent.demoDataLoaded, {'ok': false});
      _showSnack('载入示例数据失败:$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _demoLoading = false;
          _demoProgressText = null;
        });
      }
    }
  }

  Future<void> _setAnalytics(bool on) async {
    setState(() => _analyticsOn = on);
    await Analytics.setEnabled(on);
  }

  /// 「删掉全部」——原是「我」首屏单独一节,Task 17 挪到这里当「关于」页的最后
  /// 一行:那一屏只在「云端 / 这台手机上的病历」之外还留三条二级入口(口令与
  /// 恢复码 / 我的设备 / 关于),清空整个病历箱是一年碰不到一次的动作,不该占
  /// 首屏的位置。确认流程与顺序契约原样保留,见 `test/wipe_all_data_test.dart`。
  Future<void> _confirmAndResetVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空所有数据?'),
        content: const Text(
          '确定清空全部记录?所有成员的示例数据和已添加病历都会被删除,'
          '病历箱恢复到初始状态,此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: MedMe.danger),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await wipeAllData(); // 全清:所有成员 vault + 份数缓存 + 还没核对 + 恢复出厂
      // 埋点:**无属性**,而且此刻设备上已经什么都不剩了。
      // 这是没有持久 ID 的情况下我们能看见的最强负面信号(卸载永远看不到),
      // 而且它在一道二次确认之后 —— 不会是误触。配合上下文的 `tenure_bucket`
      // 就分得开「第一天就清掉」和「用了一个月才清」,那是两种病。
      //
      // 发在 `wipeAllData()` **之后**:清空失败(磁盘故障)不该记成一次清空,
      // 那是另一件事,由用户看到的错误提示承担。
      Analytics.track(AnalyticsEvent.dataWiped);
      _showSnack('已清空');
    } catch (e) {
      _showSnack('清空失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionLabel('关于'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.home_outlined,
                title: 'MedMe 主页',
                subtitle: '了解更多、下载其它平台版本',
                onTap: _openHomepage,
              ),
              _SettingsRow(
                icon: Icons.privacy_tip_outlined,
                title: '隐私政策',
                subtitle: '我们收集什么、什么情况下数据会离开你的手机',
                onTap: () =>
                    _openWeb('https://medmenow.com/privacy.html', '隐私政策'),
              ),
              _SettingsRow(
                icon: Icons.description_outlined,
                title: '用户协议',
                subtitle: '工具定位、责任边界与开源许可',
                onTap: () =>
                    _openWeb('https://medmenow.com/terms.html', '用户协议'),
              ),
              _InfoRow(
                title: 'MedMe 医我',
                subtitle:
                    'v$_appVersionName ($_appBuildNumber) · 端到端加密:云端备份只有密文,我们打不开;'
                    '云端整理送出的是涂黑后的单据图或文字,交给深度求索(DeepSeek)的模型整理,服务器在境内。',
              ),
              const _InfoRow(
                title: '医疗免责声明',
                subtitle:
                    'MedMe 是个人病历整理工具,不是医疗器械,不提供诊断或治疗建议;'
                    '一切以原始医疗文件为准,请遵医嘱。',
              ),
            ],
          ),
          _SectionLabel('示例数据'),
          _SettingsGroup(
            children: [
              _DemoDataRow(
                loading: _demoLoading,
                progressText: _demoProgressText,
                onTap: _busy ? null : _loadDemoData,
              ),
            ],
          ),
          // 分析开关只在配了 Key 的构建里出现 —— 没配就整个 SDK 都不启动,
          // 露一个永远无效的开关只会让人困惑。
          if (Analytics.isConfigured) ...[
            const _SectionLabel('使用情况'),
            _SettingsGroup(
              children: [
                SwitchListTile(
                  value: _analyticsOn,
                  onChanged: _busy ? null : _setAnalytics,
                  title: const Text('帮助改进 MedMe'),
                  subtitle: const Text(
                    '只上报「添加了几份、用了多久、成没成」这类计数,'
                    '不含任何病历内容 —— 文字、文件名、药名、化验值一个字都不会离开这台手机。'
                    '也不会给你分配可追踪的标识。',
                    style: TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                  isThreeLine: true,
                  activeThumbColor: MedMe.teal,
                ),
              ],
            ),
          ],
          // **同步整条线暂时收起**(2026-07-27):现阶段全力做手机端本体,跨设备同步
          // 先不投入。iCloud 只覆盖 iOS,安卓另有一套,做一半反而给用户一个半成品开关。
          // Rust/原生那一侧的能力**没有删**(`icloudStatus`/`enableIcloudSync` 都还在,
          // 已开启同步的老用户不受影响),只是不在设置里露出入口 —— 想恢复把这个常量
          // 改回 true 即可。
          //
          // 原来的注释保留备查:iCloud 同步是 iOS 原生能力,安卓无 iCloud,所以这一节
          // 本来就只对 iOS 显示,否则安卓用户会看到一个永远开不了的死开关。
          if (shouldShowIcloudSection(_icloud) && Platform.isIOS) ...[
            _SectionLabel('iCloud 同步(实验性)'),
            _SettingsGroup(
              children: [
                _SettingsRow(
                  icon: (_icloud?.enabled ?? false)
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_outlined,
                  title: 'iCloud 同步',
                  subtitle: _icloudSubtitle(),
                  trailing: Switch(
                    value: _icloud?.enabled ?? false,
                    onChanged: (_busy || !_icloudAvailable)
                        ? null
                        : _toggleIcloud,
                  ),
                ),
              ],
            ),
          ],
          _SectionLabel('删掉全部'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.delete_outline,
                title: '清空所有数据 · 重置病历箱',
                // 灰字说明与点击后的确认弹窗内容重复,去掉省空间(用户反馈)。
                danger: true,
                onTap: _busy ? null : _confirmAndResetVault,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _icloudSubtitle() {
    if (_icloud == null) return '正在查询…';
    if (!_icloudAvailable) {
      return '请先在系统「设置」登录 iCloud 并开启 iCloud 云盘,再回来开启同步';
    }
    if (!_icloud!.enabled) return '开启后病历会同步到你其它苹果设备(实验性,建议先备份)';
    return '已开启 · 可在「文件」App → iCloud 云盘 → MedMe 医我 里看到已同步的病历';
  }

  Future<void> _toggleIcloud(bool want) async {
    if (want) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启 iCloud 同步?'),
          content: const Text(
            '会把你的病历(真相数据)搬进本 App 的 iCloud 空间,在你登录同一 Apple ID 的'
            '苹果设备间自动同步;数据库仍留在本机。\n\n这是实验性功能,建议先用「导出」备份一份。',
            style: TextStyle(fontSize: 13.5, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('开启'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      if (want) {
        final container = await IcloudBridge.containerPath();
        if (container == null) {
          throw 'iCloud 当前不可用,请确认已登录 iCloud 并开启 iCloud 云盘';
        }
        await enableIcloudSync(containerDir: container);
      } else {
        await disableIcloudSync();
      }
      bumpVaultRevision(); // 病历箱已重开,通知档案屏刷新
      await _refresh();
      _showSnack(want ? '已开启 iCloud 同步' : '已关闭(本机保留一份副本)');
    } catch (e) {
      _showSnack('操作失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
