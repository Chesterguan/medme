import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/screens/export_screen.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/icloud_bridge.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 与 `pubspec.yaml` 的 `version:` 字段(`x.y.z+build`)保持一致。P3 范围内没有为
/// 读版本号新增 `package_info_plus` 依赖(约束里明确不加新依赖),手工同步即可——
/// 这两颗常量本来就只在“关于”里给人看,不参与任何业务逻辑。
///
/// 这颗常量已经漂过两次(团队靠它核「有没有装到最新版」,结果显示的还是两个小版本
/// 前的号)。`test/app_version_test.dart` 会拿这里的字面量去和 `pubspec.yaml` 比对,
/// 漂了就会红——改这两行时记得同时改 `pubspec.yaml`,或者反过来。
const _appVersionName = '1.6.0';
const _appBuildNumber = '56';

/// 底部导航一级 tab「设置」—— 保险箱/成员 / 载入示例数据 / 清空重置 / 关于。
///
/// 同步(iCloud)入口当前收起,见 [_showIcloudSync]。

/// 是否在设置里露出「iCloud 同步」入口。当前 false —— 全力做手机端本体,跨设备
/// 同步先不投入。底层能力未删,改回 true 即恢复。
const bool _showIcloudSync = false;

/// 分组卡片列表,视觉还原自 `apps/mobile/src/App.tsx` 的设置区(sect + group + row)。
/// 保险箱在 `main.dart` 启动时已打开,这里直接调 FFI,不重复任何 Rust 侧逻辑。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  IcloudStatusDto? _icloud;
  PatientProfileDto? _profile;
  // iCloud 容器是否可用(登录了 iCloud):Rust 拿不到,由原生 channel 判断。
  bool _icloudAvailable = false;

  /// 载入示例 / 清空时置真,禁用所有操作按钮,防止重复点击(尤其清空——
  /// 用户反馈过「载入示例后清空点了没反应」,这里确保按钮忙时不可再点,
  /// 而不是悄悄丢弃点击)。
  bool _busy = false;

  /// 「载入示例数据」这一颗按钮**自己的**进行中状态,与 [_busy] 分开管:[_busy]
  /// 负责禁用全屏其它按钮(防误触),这个才负责「这颗按钮该不该画进度条」——
  /// 清空/iCloud 等操作也会置 [_busy],但不该让示例数据那一行跟着显示进度。
  ///
  /// 真机实测过(华为 Mate 9,22 份 PDF、11 秒):这段时间里屏幕纹丝不动,用户
  /// 分不清「没点上」还是「在跑」,十一秒足够让人以为没点上又点第二次。见
  /// `_loadDemoData` 里怎么用它配合逐份进度画面。
  bool _demoLoading = false;

  /// [_demoLoading] 期间显示的进度文案(如「正在载入 3/22…」);拿不到进度
  /// (刚开始、或 Rust 侧这一份还没报回来)时为 null,退化成一句不确定进度的
  /// 「正在载入示例数据…」,总比空着强。
  String? _demoProgressText;

  bool _analyticsOn = Analytics.isEnabled;

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
      final results = await Future.wait([icloudStatus(), patientProfile()]);
      final available = await IcloudBridge.available(); // 原生判断容器是否可用
      if (!mounted) return;
      setState(() {
        _icloud = results[0] as IcloudStatusDto;
        _profile = results[1] as PatientProfileDto;
        _icloudAvailable = available;
      });
    } catch (_) {
      // 状态读取失败不影响本屏其它功能(载入示例/清空仍可用),静默忽略即可。
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

  /// 示例数据落进**它自己的成员**,不混进你的档案 —— 于是看完可以直接在「保险箱」
  /// 里把这个成员整个移除,你自己导入的东西一份不动。(早先是灌进当前成员,再被
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

      // 切回用户载入前正看着的那个人(见本函数顶部文档)。
      if (pm.currentId.value != originalMemberId) {
        await switchProfileAndReopen(originalMemberId);
      }
      bumpVaultRevision(); // 通知「健康档案」屏自动重载(并按识别姓名自动命名档案)
      await _refresh();
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
              goToArchive();
            },
          ),
        ),
      );
    } catch (e) {
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

  Future<void> _confirmAndResetVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空所有数据?'),
        content: const Text(
          '确定清空全部记录?所有成员的示例数据和已导入病历都会被删除,'
          '保险箱恢复到初始状态,此操作不可撤销。',
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
      await wipeAllData(); // 全清:所有成员 vault + 份数缓存 + 待确认 + 恢复出厂
      await _refresh();
      _showSnack('已清空');
    } catch (e) {
      _showSnack('清空失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 切换「个人 / 医生」模式:写入持久化后,`main.dart` 的 `AppRoot` 监听同一个
  /// notifier 自动换到另一个根界面;本屏若是被 push 进来的(医生模式下,设置没有
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
              ? '切换到「医生模式」:主界面变成「为病人代拍」,你自己的病历仍在——'
                    '随时可以再切回来查看。'
              : '切换到「自己/家人的病历」模式,回到健康档案 / 导出分享 / 设置。',
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
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionLabel('模式'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: currentMode == AppModeKind.doctor
                    ? Icons.medical_services_outlined
                    : Icons.folder_shared_outlined,
                title: currentMode == AppModeKind.doctor ? '医生模式' : '自己/家人的病历',
                subtitle: currentMode == AppModeKind.doctor
                    ? '点击切换到你自己的家庭档案'
                    : '点击切换到「为病人代拍」',
                onTap: _switchMode,
              ),
            ],
          ),
          _SectionLabel('保险箱'),
          _VaultCard(profile: _profile, onChanged: () => setState(() {})),
          // ⚠️ 「导出·分享」原本是一个一级 tab。五 tab 信息架构(设计系统 §八)按
          // 「使用时刻」重排之后,它没有属于自己的时刻:它不是「日常打开」、不是
          // 「复诊前」、不是「找单子」、更不是急诊室。它是**低频、正式、要联网**的
          // 一次交付动作,心智恰好落在这个 tab 的定义上 ——「数据主权:我的数据往
          // 哪去」,和下面的「清空所有数据」是同一件事的两个方向。
          //
          // 它没有并进「看病带这个」(原名「就诊单」,2026-08-05 改名),因为那是
          // 两个场景:「看病带这个」是本地的、离线的、一页纸、三十秒;这里是端到
          // 端加密、把**完整病历含原件**交出去。
          //
          // 诊室现场那条最高频的路没有变长:「看病带这个」浮层底部直接就有
          // 「医生要看原件 · 出示二维码」,一步到同一个界面(见
          // `visit_summary_sheet.dart`)。
          _SectionLabel('数据出口'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.ios_share_outlined,
                title: '导出 · 分享',
                subtitle: '当面出示二维码给医生,或导出可打印文件用于报销、留档',
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ExportScreen(),
                        ),
                      ),
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
                    '只上报「导入了几份、用了多久、成没成」这类计数,'
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
          _SectionLabel('数据管理'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.delete_outline,
                title: '清空所有数据 · 重置保险箱',
                // 灰字说明与点击后的确认弹窗内容重复,去掉省空间(用户反馈)。
                danger: true,
                onTap: _busy ? null : _confirmAndResetVault,
              ),
            ],
          ),
          // **同步整条线暂时收起**(2026-07-27):现阶段全力做手机端本体,跨设备同步
          // 先不投入。iCloud 只覆盖 iOS,安卓另有一套,做一半反而给用户一个半成品开关。
          // Rust/原生那一侧的能力**没有删**(`icloudStatus`/`enableIcloudSync` 都还在,
          // 已开启同步的老用户不受影响),只是不在设置里露出入口 —— 想恢复把这个常量
          // 改回 true 即可。
          //
          // 原来的注释保留备查:iCloud 同步是 iOS 原生能力,安卓无 iCloud,所以这一节
          // 本来就只对 iOS 显示,否则安卓用户会看到一个永远开不了的死开关。
          if (_showIcloudSync && Platform.isIOS) ...[
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
                    'v$_appVersionName ($_appBuildNumber) · 本地优先:你的病历只保存在你自己的设备上',
              ),
              const _InfoRow(
                title: '医疗免责声明',
                subtitle:
                    'MedMe 是个人病历整理工具,不是医疗器械,不提供诊断或治疗建议;'
                    '一切以原始医疗文件为准,请遵医嘱。',
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
      bumpVaultRevision(); // 保险箱已重开,通知档案屏刷新
      await _refresh();
      _showSnack(want ? '已开启 iCloud 同步' : '已关闭(本机保留一份副本)');
    } catch (e) {
      _showSnack('操作失败:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 保险箱卡:展示 + 可改**保险箱名字**(整个箱子的名字,不是某个人),多成员时列出
/// 每位成员各有多少份档案。切换成员/导入/加成员都在「健康档案」页,这里不重复那些
/// 功能——只做「这是哪个箱子、里面各人多少份」。
///
/// **箱子名与成员名必须不同**:箱子默认「我的医疗档案」(家庭/个人层面),初始成员默认
/// 「我」。两者曾用同一个字符串,导致这里显示成「我的医疗档案 → 我的医疗档案」,层级
/// 读不出来。
class _VaultCard extends StatelessWidget {
  const _VaultCard({required this.profile, required this.onChanged});
  final PatientProfileDto? profile;
  final VoidCallback onChanged;

  /// 当前成员用刚查到的最新记录数,其余成员用缓存(没加载过为 null)。
  int? _countOf(String id) {
    final pm = ProfileManager.instance;
    if (id == pm.currentId.value && profile != null) {
      return profile!.recordCount;
    }
    return pm.countFor(id);
  }

  /// 移除一个成员:连同他的全部病历一起删,不可撤销。当前成员被删时会自动切回
  /// 第一个成员(`ProfileManager.remove` 负责),各屏随 `bumpVaultRevision` 刷新。
  Future<void> _confirmRemove(BuildContext context, Profile p) async {
    final name = p.name;
    final n = _countOf(p.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: MedMe.danger,
          size: 44,
        ),
        title: Text(
          '删除「$name」的全部病历?',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (n != null && n > 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: MedMe.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$n 份病历',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: MedMe.danger,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            const Text(
              '连同拍摄的原件一起,从这台手机上彻底删除。\n'
              '删除后无法恢复,我们也帮不了你。',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MedMe.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final removed = await removeProfileAndReopen(p.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(appSnackBar(content: Text(removed ? '已移除「$name」' : '无法移除该成员')));
    onChanged();
  }

  Future<void> _rename(BuildContext context) async {
    final pm = ProfileManager.instance;
    final controller = TextEditingController(text: pm.vaultName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保险箱名字'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如:我家、张建国的病历'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await pm.setVaultName(name);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pm = ProfileManager.instance;
    final members = pm.profiles;
    final multi = members.length > 1;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const CircleAvatar(
              radius: 24,
              backgroundColor: MedMe.tealSoft,
              child: Icon(Icons.folder_shared, color: MedMe.teal, size: 26),
            ),
            title: Text(
              pm.vaultName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              multi
                  ? '${members.length} 位成员'
                  : '${_countOf(pm.currentId.value) ?? 0} 份记录',
              style: const TextStyle(color: MedMe.faint),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined, color: MedMe.faint),
              tooltip: '改名字',
              onPressed: () => _rename(context),
            ),
          ),
          if (multi) ...[
            const Divider(height: 1, color: MedMe.line),
            for (final m in members)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  8,
                  pm.canRemove(m.id) ? 8 : 20,
                  8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(m.name, style: const TextStyle(fontSize: 14)),
                    ),
                    Text(
                      _countOf(m.id) == null ? '—' : '${_countOf(m.id)} 份',
                      style: const TextStyle(color: MedMe.faint, fontSize: 13),
                    ),
                    // 只剩一个成员时不给删:那等于清空整个保险箱,该走「清空所有
                    // 数据」那条更明确的路(见 `ProfileManager.canRemove`)。
                    if (pm.canRemove(m.id))
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        color: MedMe.faint,
                        tooltip: '移除「${m.name}」',
                        onPressed: () => _confirmRemove(context, m),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
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
            : '单独放一个成员里,不和你的病历混在一起;看完可在上面「保险箱」里整个移除',
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
