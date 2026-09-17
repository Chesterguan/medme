import 'package:flutter/material.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/account_screen.dart';
import 'package:mobile_flutter/sync_engine.dart';

/// 概览屏顶部那一行备份状态(UX 第二轮,创始人拍板)。
///
/// 为什么它值一整行常驻像素:用户打开账号、输完口令、抄完恢复码之后,心里那句话是
/// 「我的病历备上了」—— 而在这之前,这件事**在产品里一个字都没有**:唯一能看见
/// 同步结果的地方是账号屏里那句「上次同步:推送 3 条、拉取 0 条」,而那是我们的
/// 词汇,也要他先想到去戳一下账号。
///
/// 四态,对应四件用户真的需要知道的事:没登录 / 关掉了 / 上次失败了 / 上次什么时候
/// 成功的。**失败那条是可点的**(点一下就重试),其余点进账号屏。
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
  if (!loggedIn) {
    return icloudOn
        ? (text: '未登录 · 同步到你自己的 iCloud', canRetry: false)
        : (text: '未登录 · 只存在这台手机', canRetry: false);
  }
  if (profile.cloudPaused) return (text: '云同步已关闭', canRetry: false);
  // 复审 I5:开着 iCloud 同步时云同步压根开不了(见 `CloudEnableBlocked`),
  // 那时说「点这里重试」是一条点不动的提示 —— 说真正的原因。
  //
  // **不看 cloudId**(F1):这一笔(`loadIcloudBlocksCloud`)只会在 iCloud 真的挡住
  // 我们时被写成 true,而挡住的路不止"还没开通"那一条 —— 已经有 cloudId 的成员点
  // 「同步」走的是 `enableCloud` 的可续做支路(注册跳过、直接重开箱),它照样撞同一道
  // 闸(见 `sync_engine.dart` R1)。原来多判一个 `cloudId == null`,那种情形就落到
  // 下面的「上次备份失败 · 点这里重试」—— 一条永远不可能成功的重试。
  if (icloudOn) {
    return (text: '这台手机开着 iCloud 同步,两套同步不能一起开', canRetry: false);
  }
  // 还没开通成功(默认开云那条队列还没排到它、或者上次开通失败了)。
  if (profile.cloudId == null) return (text: '还没开始备份 · 点这里重试', canRetry: true);
  if (last == null) return (text: '还没备份过 · 点这里立刻备份', canRetry: true);
  if (!last.ok) return (text: '上次备份失败 · 点这里重试', canRetry: true);
  return (text: '已备份 · ${_ago(last.at, now ?? DateTime.now())}', canRetry: false);
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
    final c = MedColors.of(context);
    final s = backupStatus(
      loggedIn: AccountSession.instance.loggedIn.value,
      profile: ProfileManager.instance.current,
      last: _last,
      icloudOn: _icloudOn,
    );
    final failed = s.canRetry && s.text.contains('失败');
    return Material(
      color: failed ? c.highWash : c.surface,
      child: InkWell(
        onTap: _busy ? null : (s.canRetry ? _retry : _openAccount),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s1),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
          child: Row(
            children: [
              Icon(
                failed ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                size: 16,
                color: failed ? c.high : c.ink3,
              ),
              const SizedBox(width: MedShape.s1),
              Expanded(
                child: Text(
                  _busy ? '正在备份…' : s.text,
                  style: MedType.caption.copyWith(color: failed ? c.high : c.ink2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
