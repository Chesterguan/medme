import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 「我」tab 第一行的**副标题那半句**(Task 12;这一行原来住在概览屏顶部,
/// 概览已在 Task 9 解散)。
///
/// 为什么它值一整行常驻像素:用户打开账号、输完口令、抄完恢复码之后,心里那句话是
/// 「我的病历备上了」—— 而在这之前,这件事**在产品里一个字都没有**:唯一能看见
/// 同步结果的地方是账号屏里那句「上次同步:推送 3 条、拉取 0 条」,而那是我们的
/// 词汇,也要他先想到去戳一下账号。
///
/// `s5`:这一行是**两段** —— 标题恒为「云端」,这里返回的是副标题那半句
/// (`已备份,刚刚`),末尾的 `›` 由行本身画。早先写成一整句(前缀 + 状态 + 箭头)
/// 是误读了 mockup,以 `s5` 为准。
///
/// 四态,对应四件用户真的需要知道的事:没登录 / 关掉了 / 上次失败了 / 上次什么时候
/// 成功的。`canRetry` 只决定**点下去顺不顺手踢一脚后台同步**;导航是无条件的 ——
/// 哪一态点下去都进下一层(账号屏,「云端整理」开关就在那里),见终审 I3。
@visibleForTesting
({String text, bool canRetry}) backupStatus({
  required bool loggedIn,
  required Profile profile,
  required LastSync? last,
  bool icloudOn = false,
  DateTime? now,
}) {
  // F7:这句话只在这台手机没开旧版 iCloud 同步时才真——那条同步与 MedMe 账号
  // 登录状态无关(`loadIcloudBlocksCloud` 读的是设备级开关),没登录也可能已经在
  // 往 iCloud 写。入口今天收起来了不代表这个组合态不存在,Rust 侧能力还在。
  String body;
  bool retry = false;
  if (!loggedIn) {
    body = icloudOn ? '没登录;同步到你自己的 iCloud' : '没登录,换手机找不回来';
  } else if (profile.cloudPaused) {
    body = '备份关着';
  } else if (icloudOn) {
    // 复审 I5:开着 iCloud 同步时云端备份压根开不了(见 `CloudEnableBlocked`),
    // 那时说「点这里重试」是一条点不动的提示 —— 说真正的原因。
    //
    // **不看 cloudId**(F1):这一笔(`loadIcloudBlocksCloud`)只会在 iCloud 真的挡住
    // 我们时被写成 true,而挡住的路不止"还没开通"那一条 —— 已经有 cloudId 的成员点
    // 「同步」走的是 `enableCloud` 的可续做支路(注册跳过、直接重开箱),它照样撞同一道
    // 闸(见 `sync_engine.dart` R1)。原来多判一个 `cloudId == null`,那种情形就落到
    // 下面的「上次没备份成功」—— 一条永远不可能成功的重试。
    //
    // 「iCloud 同步」是这个 App 自己那条同步的名字(见「我 → 关于」里那一节),
    // 用户要去关的就是那一行 —— 这里跟着叫同一个名字,不改口叫「iCloud 备份」
    // (那是 iOS 系统自己的另一件事,指错了地方)。
    body = '这台手机开着 iCloud 同步,两套不能一起开';
  } else if (profile.cloudId == null) {
    // 还没开通成功(默认开云那条队列还没排到它、或者上次开通失败了)。
    body = '还没开始备份';
    retry = true;
  } else if (last == null) {
    body = '还没备份过';
    retry = true;
  } else if (!last.ok) {
    body = '上次没备份成功';
    retry = true;
  } else {
    body = '已备份,${_ago(last.at, now ?? DateTime.now())}';
  }
  return (text: body, canRetry: retry);
}

/// 「刚刚 / 3 分钟前 / 5 小时前 / 9月12日」。不给时间戳 —— 用户要判断的是"这份
/// 备份是不是还算新",而不是读一个 ISO 串。
String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  return '${at.month}月${at.day}日';
}

class BackupStatusLine extends StatefulWidget {
  const BackupStatusLine({super.key, this.openAccount, this.retry});

  /// 测试注入点,默认推账号屏。
  final VoidCallback? openAccount;

  /// 测试注入点,默认真实的 `sync_engine.runBackgroundSync`(它自己在没登录/
  /// 没 cloudId/关掉了的时候 no-op,而且会顺手把"默认开云"那条队列排空 ——
  /// 所以"还没开始备份"和"上次失败"两态点的是同一条路)。
  final Future<void> Function()? retry;

  @override
  State<BackupStatusLine> createState() => _BackupStatusLineState();
}

class _BackupStatusLineState extends State<BackupStatusLine> {
  LastSync? _last;

  /// 这台手机开着 iCloud 同步吗 —— 读的是 `sync_engine` 记下来的那个布尔
  /// (复审 I5:查 FRB 的事只有后台那条队列做一次,界面不碰原生库)。
  bool _icloudOn = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
    // 三个信号各自对应一态会变的理由:同步跑完了(时间/结果)、登录态变了、
    // 用户切了成员(开关是按成员的)。
    lastSyncRevision.addListener(_reload);
    AccountSession.instance.loggedIn.addListener(_onChanged);
    ProfileManager.instance.currentId.addListener(_onChanged);
  }

  @override
  void dispose() {
    lastSyncRevision.removeListener(_reload);
    AccountSession.instance.loggedIn.removeListener(_onChanged);
    ProfileManager.instance.currentId.removeListener(_onChanged);
    super.dispose();
  }

  /// 切成员 / 登录态变了都要**重读**那一笔 —— 它是按成员存的(I6)。
  void _onChanged() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    // **按成员**(复审 I6):键是当前成员的 cloudId,切成员要重读。
    final l = await loadLastSync(ProfileManager.instance.current.cloudId);
    final icloud = await loadIcloudBlocksCloud();
    if (mounted) {
      setState(() {
        _last = l;
        _icloudOn = icloud;
      });
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await (widget.retry ?? runBackgroundSync)();
    } catch (_) {
      // 后台同步本来就静默失败(见 `triggerBackgroundSync`)—— 结果会从
      // `lastSyncRevision` 回到这一行上,不必再弹一次。
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  void _openAccount() {
    final open = widget.openAccount;
    if (open != null) return open();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountScreen(
          flow: AccountFlow(ApiClient.forSession(AccountSession.instance), AccountSession.instance),
          onReadyCloudSync: runBackgroundSync,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = backupStatus(
      loggedIn: AccountSession.instance.loggedIn.value,
      profile: ProfileManager.instance.current,
      last: _last,
      icloudOn: _icloudOn,
    );
    // **不靠文案里有没有「失败」两个字**判断这一行是不是红的 —— 那句话改一个词就
    // 悄悄失灵。上次那一笔自己就写着成没成。
    final failed = s.canRetry && _last?.ok == false;
    // `s5`:标题恒为「云端」,副标题随状态变,末尾一个 `›`。整条换成 MedBanner
    // (brief §形横幅):失败态用琥珀,其余(含没登录/关着/加载中)用蓝,不再按
    // 失败与否切换图标本身。
    return MedBanner(
      icon: Icons.cloud_outlined,
      title: '云端',
      subtitle: _busy ? '正在备份…' : s.text,
      amber: failed,
      // 终审 I3:这一行是四处文案承诺的那条路(首启同意页与 ask sheet 都写着
      // 「可以在『我 → 云端』关掉」),所以**七态里的哪一态点下去都得进得去**。
      // 原来可重试的三态(还没开始备份 / 还没备份过 / 上次没备份成功)`onTap`
      // 只做一次静默重试、永不导航 —— 而失败态恰恰是用户最想进去关它的时刻。
      // 现在:顺手踢一脚后台同步(结果由 `lastSyncRevision` 自己回到这一行上),
      // 然后照样进账号屏。
      onTap: _busy
          ? null
          : () {
              if (s.canRetry) unawaited(_retry());
              _openAccount();
            },
    );
  }
}
