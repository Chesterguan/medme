import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/export_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' show syncKdfBenchMs;
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/link_qr_dialog.dart';
import 'package:share_plus/share_plus.dart';

/// Task 14(a):KDF 真机基准——m_kib 梯度 × t 梯度,p 固定 1。只是量,不是选择,
/// 别在这里加第三个参数当"更全",四台机器等的是这四个数,不是笛卡尔积。
const _kdfBenchMKibLadder = [16384, 32768, 65536, 131072];
const _kdfBenchTLadder = [2, 3];

/// [syncKdfBenchMs] 的签名——测试注入一个假实现时用这个别名对齐类型。
typedef KdfBenchFn = Future<BigInt> Function({required int mKib, required int t, required int p});

class _KdfBenchResult {
  _KdfBenchResult({required this.mKib, required this.t, this.ms, this.error});
  final int mKib;
  final int t;
  final int? ms;
  final String? error;
}

/// 账号屏的状态机:手机号登录 → OTP → (首次)设口令 + 展示恢复码 / (换设备)口令或
/// 恢复码解锁 → 就绪(设备批准 + 授权列表 + 云同步 + 退出/注销)。切状态的判断逻辑全在
/// [AccountFlow],本屏只负责按返回值/异常显示对应界面。
enum _Phase { idle, otpSent, keySetup, showRecovery, unlock, ready }

/// A4:注册口令的最短长度。打错一个字要到换机那天才暴露,唯一的出路是恢复码——
/// 所以这一步要做的是**让人看见自己打的是什么**(眼睛)加**挡住手滑**(长度下限),
/// 不是加更多规则。6 位是下限不是建议,不强制数字/符号:强制复杂度只会让老人
/// 把它写在手机壳上。
const _minPasswordLen = 6;

/// 设备列表一行该怎么写 —— 纯函数,不碰 IO/网络,于是这条判断能在
/// `flutter test` 里单独钉住。
///
/// ## A2:这里曾经把用户自己正在用的手机标成「等待批准」
///
/// `GET /v1/devices` 的 `approved` 字段是 `approved_priv IS NOT NULL`(见
/// `services/api/db.py` 的 `devices_list`):它的意思是「服务端存着一份**等这台
/// 设备自己来取**的批准密文」,**不是**「这台设备可用」。一台正常工作的设备
/// ——包括全新账号的第一台(见 `db.device_is_trusted`)——两列都是 NULL,
/// 于是 `approved == false`,旧文案就把它写成「等待批准」。用户打开账号屏看见
/// 自己手里这台手机写着"等待批准",而屏上没有任何东西可以批准。
///
/// 真正区分「新设备在等批准」的只有 `eph_public`:只有调过
/// `POST /v1/devices/request` 的设备才有它,批准之后服务端把它置回 NULL
/// (`db.device_approve`)。所以三态收敛成两支,判据只看这一个字段。
@visibleForTesting
({String name, String status, bool pending}) deviceRow(Map<String, dynamic> d, {DateTime? now}) {
  final raw = d['name']?.toString() ?? '';
  // 服务端存的是 `Platform.operatingSystem`(见 `account_flow.dart` 的
  // `device_name`)—— 给用户看「android」毫无意义。
  final name = switch (raw) {
    'android' => '安卓手机',
    'ios' => 'iPhone/iPad',
    '' => d['device_id']?.toString() ?? '未知设备',
    _ => raw,
  };
  if (d['eph_public'] != null) return (name: name, status: '新设备,等你批准', pending: true);
  final seen = DateTime.tryParse(d['last_seen']?.toString() ?? '');
  if (seen == null) return (name: name, status: '这台设备已可用', pending: false);
  return (
    name: name,
    status: '这台设备已可用 · 最近${_lastSeenLabel(seen.toLocal(), now ?? DateTime.now())}',
    pending: false,
  );
}

/// ISO8601 的 `last_seen` → 一句人话。不给「2026-09-12T03:04:05.000Z」那种东西。
String _lastSeenLabel(DateTime seen, DateTime now) {
  if (now.difference(seen).inMinutes < 60) return '刚刚';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(seen.year, seen.month, seen.day);
  if (day == today) return '今天';
  if (day == today.subtract(const Duration(days: 1))) return '昨天';
  return '${seen.month}月${seen.day}日';
}

/// 服务端的角色词 → 中文。`viewer`/`editor`/`owner` 是 API 的词汇,不该出现在
/// 界面上 —— 「只能看 / 能一起录 / 主人」说的是同一件事,而老人读得懂。
@visibleForTesting
String roleLabel(String? role) => switch (role) {
  'viewer' => '只能看',
  'editor' => '能一起录',
  'owner' => '主人',
  null => '未知',
  _ => role,
};

/// 到期时间(服务端给的 ISO 串)→ 「至 M月D日」。**与 `member_switcher.dart` 和
/// 医生主页那一节逐字相同**,同一件事不该有三种写法。ISO 串一个字都不露出来。
///
/// 三态,不是两态(评审 Minor 16):没有到期日(owner)是「长期有效」;**解析不了**
/// 是「到期时间不明」。原来两者都说「长期有效」—— 一个格式坏掉的 `expires_at` 会让
/// 一份有期限的授权读起来像永久的,对一个**权限标签**来说这是朝错误的方向失败。
/// (紧挨着的 [createdLabel] 解析不了时正确地返回 null。)
@visibleForTesting
String expiryLabel(Object? iso) {
  if (iso == null) return '长期有效';
  final t = DateTime.tryParse(iso.toString())?.toLocal();
  return t == null ? '到期时间不明' : '至 ${t.month}月${t.day}日';
}

/// 创建时间 → 「M月D日添加」。认不出来就不说(不编一个日期)。
@visibleForTesting
String? createdLabel(Object? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso.toString())?.toLocal();
  return t == null ? null : '${t.month}月${t.day}日添加';
}

/// Argon2id 在老机器上要几秒(64 MiB/t=3,见 `AccountFlow.kdf`),而转圈时原来
/// 一句话都没有——用户会以为卡死了、切走、甚至杀掉 App(那一刻杀掉正好是
/// `prepareKeys` 还没 commit 的窗口,等于白做一遍)。
const _kdfWaitHint = '正在生成密钥,老一点的手机可能要等几秒,请不要退出';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.flow,
    this.grants,
    this.syncEngine,
    this.debugModeOverride,
    this.kdfBenchFn,
  });
  final AccountFlow flow;

  /// 测试注入点,默认为 null——真正用的时候按 [flow] 现取现建(见
  /// `_AccountScreenState._grants`)。`Grants` 内部按需碰 FRB(`grantFamilyByPhone`
  /// 的 `sealTo`),测试传一个带假 `GrantsRust` 的实例进来,不碰真实原生库。
  final Grants? grants;

  /// 测试注入点,同 [grants]——「开通云同步」「立即同步」用得到,默认为 null,
  /// 真正用的时候按 [flow] 现取现建(见 `_AccountScreenState._sync`)。
  final SyncEngine? syncEngine;

  /// 测试注入点——`flutter test` 下 `kDebugMode` 恒为 true,没法测「非 debug
  /// 不显示这一行」,这里给一个显式覆盖;真正用的时候为 null,落到真的
  /// `kDebugMode`。
  final bool? debugModeOverride;

  /// 测试注入点——同上,默认为 null 落到真的 [syncKdfBenchMs](碰 FRB,
  /// `flutter test` 跑不了)。
  final KdfBenchFn? kdfBenchFn;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  _Phase _phase = _Phase.idle;

  /// 禁用当前这一步的按钮(防重复点击),按钮位置换成进度圈——不是把整屏锁死。
  bool _busy = false;

  /// 上一步失败的原因,红字展示在按钮上方;按钮本身保留,允许直接重试。
  String? _error;

  bool _useRecoveryUnlock = false;

  /// A4:口令眼睛。注册和解锁各一个——两屏不会同时在,但把它们合成一个字段会让
  /// 「注册时点过显示」莫名其妙地带到换机那天的解锁屏上。
  bool _showRegPassword = false;
  bool _showUnlockPassword = false;

  String? _recoveryCode;

  /// `prepareKeys()` 备好、还没 `commitKeys()` 上传/落盘的那一份——只在
  /// showRecovery 阶段的内存里活着,confirm 成功后即弃(见 [_confirmRecovery]);
  /// 没提交之前强杀 App,这份连同它的私钥一起消失,不留任何残留状态。
  PreparedKeys? _preparedKeys;

  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _regPasswordCtrl = TextEditingController();
  final _unlockPasswordCtrl = TextEditingController();
  final _unlockRecoveryCtrl = TextEditingController();
  final _familyPhoneCtrl = TextEditingController();

  /// 验证码重发冷却。**这是给"没收到短信就连点"准备的,不是服务端规则的镜像**——
  /// 服务端那两条是:一小时最多 5 条(`auth.OTP_MAX_SENDS_PER_HOUR`)、验证码本身
  /// 5 分钟过期(`OTP_TTL`)。原来这一屏既没有倒计时也没有重发按钮,短信没来的人
  /// 只能返回上一屏重走一遍。
  static const _otpResendCooldown = 60;
  int _otpSecondsLeft = 0;
  Timer? _otpTimer;

  bool _familyBusy = false;
  String? _familyError;

  /// B5:正在生成一条转移链接(防连点;生成链接是会在服务端建 invite 记录的)。
  bool _transferBusy = false;

  /// 正在撤销一份授权(评审 Minor 20:双击会发两个 DELETE,第二个在成功撤销之后
  /// 立刻显示「撤销失败:没有找到…」—— 一次成功的操作看起来像失败了)。
  bool _revokeBusy = false;

  Grants get _grants => widget.grants ?? Grants(widget.flow.api, widget.flow.session);
  SyncEngine get _sync => widget.syncEngine ?? SyncEngine(widget.flow.api, widget.flow.session);

  Future<List<dynamic>>? _devicesFuture;
  Future<List<dynamic>>? _grantsFuture;

  /// 「我授权给谁」——见 `_loadMyGrants`。
  Future<List<Map<String, dynamic>>>? _myGrantsFuture;

  // ---- 云同步(Task 15):开通 + 触发 + 展示上一次结果 ----
  bool _cloudBusy = false;
  String? _cloudError;
  bool _syncBusy = false;
  String? _syncError;
  SyncReport? _lastSyncReport;

  // ---- 退出登录 / 注销账号 ----
  bool _logoutBusy = false;
  bool _deleteFormOpen = false;
  bool _deleteOtpBusy = false;
  bool _deleteBusy = false;
  String? _deleteError;
  final _deletePhoneCtrl = TextEditingController();
  final _deleteOtpCtrl = TextEditingController();

  // ---- KDF 真机基准(Task 14a,仅 debug)----
  bool _kdfBenchRunning = false;
  final List<_KdfBenchResult> _kdfBenchResults = [];

  @override
  void initState() {
    super.initState();
    // 冷启动/本屏重建时,如果本机已经有登录 token,据此判断该落在哪个阶段——
    // 不重新发 OTP。**没提交的密钥不算数**:`prepareKeys()` 只在内存里,重建
    // 之后必然读不到,`_afterLogin` 会照实判成 needsKeySetup。
    //
    // `resumeIfLoggedIn()` 对非 404 的失败(网络错误、401、500……)会
    // rethrow——`_afterLogin` 只吞 404。这里必须接住,否则是一次不带 `await`
    // 的 initState 里的裸 Future,失败就是一次未处理的 rejection:用户停在
    // idle 却看不到任何错误,像是"卡住了"而不是"网络失败"。停在 idle(不切
    // phase)、把错误摆到 `_error` 上——idle 的界面本来就会渲染 `_error`。
    widget.flow
        .resumeIfLoggedIn()
        .then((outcome) {
          if (!mounted || outcome == null) return;
          _enterPhaseFor(outcome);
        })
        .catchError((Object e) {
          if (!mounted) return;
          setState(() { _error = friendlyApiError(e); });
        });
  }

  @override
  void dispose() {
    _otpTimer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _regPasswordCtrl.dispose();
    _unlockPasswordCtrl.dispose();
    _unlockRecoveryCtrl.dispose();
    _familyPhoneCtrl.dispose();
    _deletePhoneCtrl.dispose();
    _deleteOtpCtrl.dispose();
    super.dispose();
  }

  /// 跑一步异步操作,期间按钮换成进度圈,失败把原因摆在按钮上方。
  ///
  /// **三处 `mounted` 守卫都是必需的**(评审 Important 10,带复现):`body()` 里
  /// await 之后的 `setState` 在屏已经 dispose 时会抛,`catch` 随即跑、它自己那次
  /// `setState` 再抛一次 —— 而**后面这一次**没人接,变成一个未处理的异步错误
  /// (`setState() called after dispose()`)。
  ///
  /// 可达性不是理论:`PopScope` 只在恢复码那一阶段挡返回,所以在**长达几秒的
  /// Argon2 转圈**里退出就会撞上 —— 正是 [_kdfWaitHint] 那句「请不要退出」所描述的
  /// 等待。加了警告文案却不让这个隐患变得可承受,等于没修。
  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
      if (!mounted) return;
    } catch (e) {
      if (mounted) setState(() { _error = friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「发送验证码」与「重新发送」是同一条路:后者只是在已经到了验证码屏之后再点
  /// 一次。重发要把上一次打进去的码清掉——否则用户会对着新短信、拿旧的那串去点
  /// 「登录」,撞一次 401,还以为是新码也不对。
  Future<void> _sendOtp() => _run(() async {
    final resend = _phase == _Phase.otpSent;
    try {
      await widget.flow.sendOtp(_phoneCtrl.text.trim());
    } finally {
      // 重发:**成没成都进冷却**(评审 Minor 21)。重发失败最常见的原因正是服务端
      // 在限流(429,一小时 5 条),而按钮保持可点只会让用户继续猛戳一个已经在限
      // 流他的服务端 —— 越戳越回不来。
      if (resend && mounted) _startOtpCountdown();
    }
    if (!mounted) return;
    if (resend) _codeCtrl.clear();
    setState(() => _phase = _Phase.otpSent);
    if (!resend) _startOtpCountdown();
    if (resend) {
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('验证码已重新发送')));
    }
  });

  /// 倒计时用**周期 Timer + setState**,到 0 自己取消。
  ///
  /// 到 0 就取消这件事不只是省电:`flutter test` 里一个永不停的周期 Timer 会让
  /// `pumpAndSettle` 永远等不到"没有新帧要画"(它会一直跑到 10 分钟超时),
  /// 而且用例结束时还会留下一个 pending timer 报错。
  void _startOtpCountdown() {
    _otpTimer?.cancel();
    setState(() => _otpSecondsLeft = _otpResendCooldown);
    _otpTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _otpSecondsLeft--);
      if (_otpSecondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _login() => _run(() async {
    final outcome = await widget.flow.loginOtp(_phoneCtrl.text.trim(), _codeCtrl.text.trim());
    _enterPhaseFor(outcome);
  });

  Future<void> _loginApple() => _run(() async {
    await widget.flow.loginApple();
    _enterPhaseFor(widget.flow.lastOutcome ?? LoginOutcome.needsUnlock);
  });

  void _enterPhaseFor(LoginOutcome outcome) {
    if (outcome == LoginOutcome.needsKeySetup) {
      setState(() => _phase = _Phase.keySetup);
    } else if (outcome == LoginOutcome.needsUnlock) {
      setState(() => _phase = _Phase.unlock);
    } else {
      _enterReady();
    }
  }

  void _enterReady() {
    setState(() {
      _phase = _Phase.ready;
      // `..catchError` 是一个额外的、丢弃结果的旁路监听——只是为了让这个 Future
      // 从创建的那一刻起就"有人在听",不依赖 `FutureBuilder` 的 `initState`
      // 抢在它失败之前完成订阅(两者互不影响,Future 支持多个独立监听者;真正的
      // 加载中/成功/失败三态仍然由 `FutureBuilder` 自己的订阅决定)。
      _devicesFuture = widget.flow.api.getJson('/v1/devices').then((v) => v as List<dynamic>)
        ..catchError((_) => const <dynamic>[]);
      _grantsFuture = widget.flow.api.getJson('/v1/profiles').then((v) => v as List<dynamic>)
        ..catchError((_) => const <dynamic>[]);
      _myGrantsFuture = _loadMyGrants()..catchError((_) => const <Map<String, dynamic>>[]);
    });
  }

  /// 「我授权给谁」:遍历我拥有(role=='owner')的每个云档案,查它的 grantee 列表
  /// (`GET /v1/profiles/{pid}/grants`,owner-only,服务端不带手机号/姓名)。
  /// owner 自己那一行由服务端一并返回,这里过滤掉——这个列表只回答"我把这份
  /// 档案给了谁",不是"我在这份档案里是什么角色"(那是上面「授权」区块的事)。
  Future<List<Map<String, dynamic>>> _loadMyGrants() async {
    final profiles = ((await widget.flow.api.getJson('/v1/profiles')) as List).cast<Map<String, dynamic>>();
    final out = <Map<String, dynamic>>[];
    for (final p in profiles.where((p) => p['role'] == 'owner')) {
      final pid = p['profile_id'] as String;
      final grants = ((await widget.flow.api.getJson('/v1/profiles/$pid/grants')) as List).cast<Map<String, dynamic>>();
      for (final g in grants.where((g) => g['role'] != 'owner')) {
        out.add({...g, 'profile_id': pid});
      }
    }
    return out;
  }

  Future<void> _registerKeys() => _run(() async {
    final keys = await widget.flow.prepareKeys(_regPasswordCtrl.text);
    setState(() {
      _preparedKeys = keys;
      _recoveryCode = keys.recoveryCode;
      _phase = _Phase.showRecovery;
    });
  });

  /// 恢复码只在这一次显示。点了才算数——没有别的路能离开这一屏。这一步才真正
  /// 把密钥传上服务器、存进本机(`commitKeys`);失败(比如服务器 500)不清
  /// `_preparedKeys`/`_recoveryCode`,恢复码画面原样留着,允许直接重试。
  Future<void> _confirmRecovery() => _run(() async {
    await widget.flow.commitKeys(_preparedKeys!);
    setState(() {
      _preparedKeys = null;
      _recoveryCode = null;
    });
    _enterReady();
  });

  Future<void> _unlock() => _run(() async {
    if (_useRecoveryUnlock) {
      await widget.flow.unlockWithRecovery(_unlockRecoveryCtrl.text.trim());
    } else {
      await widget.flow.unlockWithPassword(_unlockPasswordCtrl.text);
    }
    _enterReady();
  });

  @override
  Widget build(BuildContext context) {
    // 恢复码只显示这一次,离开必须走「我已抄下」,不给系统返回键留后门。
    return PopScope(
      canPop: _phase != _Phase.showRecovery,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('账号'),
          automaticallyImplyLeading: _phase != _Phase.showRecovery,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              ..._phaseContent(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _phaseContent() {
    switch (_phase) {
      case _Phase.idle:
        return _idleContent();
      case _Phase.otpSent:
        return _otpContent();
      case _Phase.keySetup:
        return _keySetupContent();
      case _Phase.showRecovery:
        return _recoveryContent();
      case _Phase.unlock:
        return _unlockContent();
      case _Phase.ready:
        return _readyContent();
    }
  }

  List<Widget> _idleContent() => [
    const Text(
      '登录 MedMe 账号',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    const Text(
      '换机恢复病历、和家人共享、开启云端识别。不登录不影响本机使用。',
      style: TextStyle(color: MedMe.faint),
    ),
    const SizedBox(height: 20),
    TextField(
      key: const Key('phone'),
      controller: _phoneCtrl,
      keyboardType: TextInputType.phone,
      decoration: const InputDecoration(labelText: '手机号'),
    ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 16),
    _asyncButton(label: '发送验证码', onPressed: _sendOtp),
    if (Platform.isIOS) ...[
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: _busy ? null : _loginApple,
        icon: const Icon(Icons.apple),
        label: const Text('通过 Apple 登录'),
      ),
    ],
  ];

  List<Widget> _otpContent() => [
    const Text(
      '输入验证码',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text('已发送到 ${_phoneCtrl.text}', style: const TextStyle(color: MedMe.faint)),
    const SizedBox(height: 20),
    TextField(
      key: const Key('code'),
      controller: _codeCtrl,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: '验证码'),
    ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 16),
    _asyncButton(label: '登录', onPressed: _login),
    const SizedBox(height: 4),
    TextButton(
      key: const Key('otp_resend'),
      onPressed: (_busy || _otpSecondsLeft > 0) ? null : _sendOtp,
      child: Text(_otpSecondsLeft > 0 ? '$_otpSecondsLeft 秒后可重新发送' : '重新发送'),
    ),
  ];

  List<Widget> _keySetupContent() => [
    const Text('设置口令', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    const Text(
      '这个口令用来保护你的账号密钥,只存在你自己脑子里——我们不存储明文口令,'
      '也没有后门。设置好之后我们会给你一组恢复码,两者都要妥善保存:'
      '口令、恢复码、这个账号登录过的所有设备如果同时丢失,数据将无法恢复,'
      '我们也帮不了你。',
      style: TextStyle(color: MedMe.faint, height: 1.5),
    ),
    const SizedBox(height: 20),
    _passwordField(
      controller: _regPasswordCtrl,
      label: '设置一个口令',
      helper: '至少 $_minPasswordLen 位。记不住就写下来收好,别只记在脑子里。',
      visible: _showRegPassword,
      onToggle: () => setState(() => _showRegPassword = !_showRegPassword),
    ),
    if (_regPasswordCtrl.text.isNotEmpty && _regPasswordCtrl.text.length < _minPasswordLen)
      _errorText('还差 ${_minPasswordLen - _regPasswordCtrl.text.length} 位'),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 16),
    _asyncButton(
      label: '生成密钥',
      onPressed: _registerKeys,
      enabled: _regPasswordCtrl.text.length >= _minPasswordLen,
      busyHint: _kdfWaitHint,
    ),
  ];

  List<Widget> _recoveryContent() => [
    const Text('抄下你的恢复码', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    const Text(
      '万一忘记口令,恢复码是唯一还能找回账号密钥的办法。请立刻抄写或截图保存在'
      '别处(不要只存在这台手机上)。\n\n'
      '口令、这组恢复码、这个账号登录过的所有设备——三样如果同时丢失,'
      '我们没有办法帮你找回数据。',
      style: TextStyle(color: MedMe.danger, height: 1.5, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 20),
    Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: MedMe.tealSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            _recoveryCode!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1.2),
          ),
          const SizedBox(height: 8),
          // C6:原来只有「复制」—— 复制到剪贴板等于"存在这台手机上",而上面那段
          // 红字刚说了"不要只存在这台手机上"。**本机没有"存图到相册"的能力**
          // (全仓没有任何 gallery/截图保存的依赖或代码),所以给系统分享面板:
          // 发给自己的微信收藏、邮箱、备忘录 —— 那些才是"别处"。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: _recoveryCode!)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制'),
              ),
              TextButton.icon(
                key: const Key('recovery_share'),
                onPressed: _shareRecoveryCode,
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('分享给自己'),
              ),
            ],
          ),
        ],
      ),
    ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 20),
    _asyncButton(label: '我已抄下恢复码', onPressed: _confirmRecovery),
  ];

  /// C6。走系统分享面板,让用户把恢复码存到**这台手机之外**的地方(微信收藏、
  /// 邮箱、备忘录……)。分享的是恢复码本身加一句说明 —— 它就是钥匙,所以那段文字
  /// 必须带上"别人拿到它就能打开你的病历"。
  ///
  /// **先弹一句确认**(评审 Important 11):这是账号密钥唯一一条刻意离开这台设备的
  /// 路径,而原来点下去**直接**就是系统分享面板 —— 屏上没有任何一个字说"它正要
  /// 经第三方 App 传出去"。那句警告原来只跟着内容到达目的地,而不是在决定之前
  /// 到达用户。
  ///
  /// **整段包 try/catch**:`SharePlus` 会抛 `PlatformException`(iPad 锚点拿不到、
  /// 系统里没有可分享的目标),而这是一个 `onPressed` 里的 async —— 不接就是一个
  /// 未处理的异步错误,用户点了「分享给自己」什么都看不到。
  Future<void> _shareRecoveryCode() async {
    final code = _recoveryCode;
    if (code == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('要把恢复码发出去?'),
        content: const Text(
          '恢复码会经你选的那个 App 离开这台手机(微信、邮件、备忘录……)。'
          '它就是你账号的钥匙 —— 只发给自己,别发给任何人,也别发在群里。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('发给自己')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(ShareParams(
        text: 'MedMe 恢复码:$code\n\n'
            '忘记口令时用它找回账号密钥。请存在这台手机之外的地方;'
            '别人拿到它就能打开你的病历,不要发给任何人。',
        subject: 'MedMe 恢复码',
        // iPad 上 `share_plus` 要一个非零锚点,否则抛参数错误(同
        // `export_screen.dart` 里那条注释)。
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: Text('分享没打开:${friendlyApiError(e)}。可以改用上面的「复制」。')),
      );
    }
  }

  List<Widget> _unlockContent() => [
    const Text('输入口令解锁', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    const Text(
      '这台设备之前没解锁过这个账号,需要口令或恢复码解出账号密钥。',
      style: TextStyle(color: MedMe.faint),
    ),
    const SizedBox(height: 20),
    if (_useRecoveryUnlock)
      TextField(
        key: const Key('recovery_code'),
        controller: _unlockRecoveryCtrl,
        decoration: const InputDecoration(labelText: '输入恢复码'),
      )
    else
      _passwordField(
        controller: _unlockPasswordCtrl,
        label: '输入口令',
        visible: _showUnlockPassword,
        onToggle: () => setState(() => _showUnlockPassword = !_showUnlockPassword),
      ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 16),
    _asyncButton(
      label: _useRecoveryUnlock ? '用恢复码解锁' : '解锁',
      onPressed: _unlock,
      busyHint: _useRecoveryUnlock ? null : _kdfWaitHint,
    ),
    const SizedBox(height: 8),
    TextButton(
      onPressed: _busy
          ? null
          : () => setState(() {
              _useRecoveryUnlock = !_useRecoveryUnlock;
              _error = null;
            }),
      child: Text(_useRecoveryUnlock ? '改用口令解锁' : '口令忘了?改用恢复码解锁'),
    ),
    // A6:两样都丢了的人原来**卡死在这一屏**——注册时的警告到位,丢了之后反而
    // 一句话都没有、一个出口都没有。
    if (_logoutBusy)
      const Center(child: CircularProgressIndicator())
    else
      TextButton(
        key: const Key('lost_everything'),
        onPressed: _busy ? null : _lostEverything,
        child: const Text('口令和恢复码都丢了,怎么办?'),
      ),
  ];

  /// A6。照实说:我们不托管密钥,所以云端那份数据谁都解不开,我们也一样。
  /// 唯一真实存在的出路是退出登录、从头开始——取消则一切原样。
  Future<void> _lostEverything() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('两样都丢了的话'),
        content: const Text(
          '我们不托管你的密钥。口令和恢复码是唯一能解开账号密钥的两把钥匙——'
          '两样都没有了,云端那份数据谁都打不开,我们也没有任何办法帮你找回。\n\n'
          '还能做的事:退出登录、重新开始。这台手机上没开通云同步的病历不会被'
          '删除;已经开通过云同步的那些成员,在这台手机上会一直锁着。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: MedMe.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出登录,重新开始'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _logoutBusy = true);
    try {
      await widget.flow.logout();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _error = null;
        _useRecoveryUnlock = false;
        _showUnlockPassword = false;
      });
    } finally {
      if (mounted) setState(() => _logoutBusy = false);
    }
  }

  /// C7:**「云同步」排第一**。用户点进账号屏,十次里九次是为了"我的病历到底备上了
  /// 没有";而它原来排在第四个区块,要滚过设备、授权、家属三节才看得见。
  /// 「设备」排最后 —— 它是一年用一次的东西。
  List<Widget> _readyContent() => [
    const Text('已登录', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 4),
    Text(_accountLabel(), style: const TextStyle(color: MedMe.faint)),
    const SizedBox(height: 24),
    const Text('云同步', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _cloudSyncSection(),
    const SizedBox(height: 24),
    const Text('授权', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _grantsSection(),
    const SizedBox(height: 24),
    const Text('家属', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _familySection(),
    const SizedBox(height: 24),
    const Text('我授权给谁', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _myGrantsSection(),
    const SizedBox(height: 24),
    const Text('设备', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _devicesSection(),
    const SizedBox(height: 24),
    const Text('账号管理', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _accountManagementSection(),
    if (widget.debugModeOverride ?? kDebugMode) ...[
      const SizedBox(height: 16),
      // 内部 id 只在 debug 包里露出来(排查问题要用),正式包里一个字都没有。
      Text(
        'debug · accountId=${widget.flow.session.accountId ?? '-'}',
        style: const TextStyle(color: MedMe.faint, fontSize: 11),
      ),
    ],
  ];

  /// C1:这一行原来是 `账号:acc_7f3a…`(服务端内部 id)—— 对用户毫无意义。
  /// 改成他认得出的东西:脱敏手机号,或者「Apple 登录」。
  String _accountLabel() =>
      widget.flow.session.phoneMasked ??
      (widget.flow.session.loginMethod == 'apple' ? 'Apple 登录' : '已登录');

  /// 云档案 id → 本机那个成员的名字。对不上(刚授权、还没同步下来)时说
  /// 「一份共享档案」—— 绝不把 `prf_xxx` 摆给用户看。
  String _profileLabel(Object? cloudId) =>
      ProfileManager.instance.profiles.where((p) => p.cloudId == cloudId).firstOrNull?.name ?? '一份共享档案';

  // ---- 云同步:「开通云同步」(当前成员)+「立即同步」+ 上一次结果/错误 ----

  Widget _cloudSyncSection() {
    final profile = ProfileManager.instance.current;
    if (profile.cloudId == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '「${profile.name}」还没开通云同步——开通后可以换机恢复、分享给家属/医生。',
            style: const TextStyle(color: MedMe.faint),
          ),
          if (_cloudError != null) _errorText(_cloudError!),
          const SizedBox(height: 12),
          _cloudBusy
              ? const Center(child: CircularProgressIndicator())
              : FilledButton(onPressed: _enableCloud, child: const Text('开通云同步')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.cloud_done_outlined, color: MedMe.teal, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('「${profile.name}」已开通云同步', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_lastSyncReport != null)
          Text(_syncSummary(_lastSyncReport!), style: const TextStyle(color: MedMe.faint)),
        if (_syncError != null) _errorText(_syncError!),
        if (_cloudError != null) _errorText(_cloudError!),
        // C9:**一颗按钮。** 原来这里是两颗:上一次失败时多出一颗「已开通,点击
        // 重试同步」,旁边常驻一颗「立即同步」。两颗都叫"同步",差别只在前者顺手
        // 重开一次箱 —— 用户分不出该点哪个,而点错那颗恰恰是死路:箱子还没 keyed
        // 打开时「立即同步」每点一次撞一次 `VaultMismatch`(最终评审 M4)。
        //
        // 合成一颗「同步」,由 `_syncOrRecover` 挑路:上一次失败过就走可续做的
        // `enableCloud`(已有 cloudId 会跳过注册,直接重开箱 + 首同步),否则就是
        // 一次普通同步。用户只需要知道"点这里同步"。
        const SizedBox(height: 8),
        (_cloudBusy || _syncBusy)
            ? const Center(child: CircularProgressIndicator())
            : FilledButton(onPressed: _syncOrRecover, child: const Text('同步')),
        // B5 的**真正入口**(评审 Important 8)。原来「转为主人」只作为「我授权给谁」
        // 里的 per-grantee 行存在 —— 于是"把档案交给父母"要先:(1) 父母装 App 并走完
        // 口令 + 恢复码(正是 B4 那个卡点);(2) 子女按手机号把他加成家属;(3) 才会
        // 在那一行里出现按钮。而红队说的恰恰是把档案交给一个**还不是家属**的人。
        //
        // 只有 owner 能发转移邀请(服务端 `POST .../invites` 对 editor/viewer 一律
        // 403),所以这一条按角色挡住 —— 不摸黑试一次注定失败的请求。
        if (profile.role == 'owner') ...[
          const SizedBox(height: 4),
          // 忙的时候只是**禁用**,不换成进度圈:`_transferBusy` 在那张码的对话框开着
          // 的整段时间里都是 true,底下挂一个永不停的进度圈既无意义,也会让
          // `pumpAndSettle` 永远 settle 不下来(踩过)。同「我授权给谁」那一行的写法。
          TextButton(
            key: const Key('transfer_current_profile'),
            onPressed: _transferBusy ? null : () => _transferOwnership(profile),
            child: const Text('把这份档案转给家人(生成链接)'),
          ),
        ],
      ],
    );
  }

  /// 见 C9。上一次同步/开通失败过 → 走会重开箱的那条(`enableCloud` 可续做);
  /// 否则普通同步。
  Future<void> _syncOrRecover() =>
      (_cloudError != null || _syncError != null) ? _enableCloud() : _syncNow();

  String _syncSummary(SyncReport r) {
    final parts = ['推送 ${r.pushed} 条', '拉取 ${r.pulled} 条'];
    if (r.objectsFailed > 0) parts.add('${r.objectsFailed} 个附件失败');
    if (r.pushSkippedNoWatermark) parts.add('本次跳过推送(水位未就绪)');
    return '上次同步:${parts.join('、')}';
  }

  /// 「开通云同步」,**也是**上面那个「已开通,点击重试同步」按钮走的路径——
  /// `SyncEngine.enableCloud` 自己是可续做的(已有 cloudId 就跳过注册),所以这里
  /// 不需要分两个动作。
  Future<void> _enableCloud() async {
    setState(() {
      _cloudBusy = true;
      _cloudError = null;
      // 这次重试会重开箱 + 重跑一次同步,上一次同步的报错到此作废,不该继续挂在
      // 屏上(也是"重试入口该不该显示"的判据之一,见 `_cloudSyncSection`)。
      _syncError = null;
    });
    try {
      await _sync.enableCloud(ProfileManager.instance.current);
      if (!mounted) return;
      setState(() {}); // current 已写回 cloudId,重建切到"已开通"那半支
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已开通云同步')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _cloudError = friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  /// 「立即同步」;触发器(debounce push / app-resume pull,见 `sync_engine.dart`
  /// 的 `triggerBackgroundSync`)在没登录/没 cloudId 时已经 no-op 了,这里手点的
  /// 版本同样先挡一道——理论上按钮在 `profile.cloudId == null` 时根本不会画出来,
  /// 这道判断是双保险,不依赖 UI 没画错。
  Future<void> _syncNow() async {
    final profile = ProfileManager.instance.current;
    if (profile.cloudId == null) return;
    setState(() {
      _syncBusy = true;
      _syncError = null;
    });
    try {
      final rep = await _sync.syncProfile(profile);
      if (!mounted) return;
      setState(() => _lastSyncReport = rep);
    } catch (e) {
      if (!mounted) return;
      setState(() { _syncError = friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  // ---- 账号管理:退出登录 / 注销账号 ----

  Widget _accountManagementSection() {
    final children = <Widget>[
      _logoutBusy
          ? const Center(child: CircularProgressIndicator())
          : OutlinedButton(onPressed: _confirmLogout, child: const Text('退出登录')),
      const SizedBox(height: 12),
    ];
    if (_deleteFormOpen) {
      children.add(_deleteAccountForm());
    } else {
      children.add(
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: MedMe.danger, side: const BorderSide(color: MedMe.danger)),
          onPressed: _confirmDeleteAccount,
          child: const Text('注销账号'),
        ),
      );
    }
    if (widget.debugModeOverride ?? kDebugMode) {
      children.add(const SizedBox(height: 12));
      children.add(const Divider());
      children.add(_kdfBenchSection());
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  /// Task 14(a):debug-only 真机基准。只跑、只显示、只能复制——不落盘、不上传、
  /// 不碰 `AccountFlow.kdf`/`KDF_DEFAULT`(那两处的改动是 Task 14 后续步骤,
  /// 要等真机数字回来才能定,这里绝不能替用户猜一个)。
  Widget _kdfBenchSection() {
    final rows = <Widget>[
      const Text('KDF 基准测试(仅 debug)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        style: const TextStyle(color: MedMe.faint, fontSize: 12),
      ),
      const SizedBox(height: 8),
    ];
    if (_kdfBenchRunning || _kdfBenchResults.isNotEmpty) {
      rows.add(_kdfBenchTable());
      rows.add(const SizedBox(height: 8));
    }
    if (_kdfBenchRunning) {
      rows.add(const Center(child: CircularProgressIndicator()));
    } else {
      rows.add(
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('kdf_bench_run'),
                onPressed: _runKdfBench,
                child: Text(_kdfBenchResults.isEmpty ? '运行 KDF 基准测试' : '重新运行'),
              ),
            ),
            if (_kdfBenchResults.isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton(
                key: const Key('kdf_bench_copy'),
                onPressed: _copyKdfBenchResults,
                child: const Text('复制结果'),
              ),
            ],
          ],
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _kdfBenchTable() => Table(
    key: const Key('kdf_bench_table'),
    columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(2)},
    children: [
      const TableRow(
        children: [
          Text('m_kib', style: TextStyle(fontWeight: FontWeight.w600)),
          Text('t', style: TextStyle(fontWeight: FontWeight.w600)),
          Text('min ms', style: TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      for (final r in _kdfBenchResults)
        TableRow(
          children: [
            Text('${r.mKib}'),
            Text('${r.t}'),
            r.error != null
                ? Text('ERROR: ${r.error}', style: const TextStyle(color: MedMe.danger, fontSize: 12))
                : Text('${r.ms}'),
          ],
        ),
    ],
  );

  /// 顺序跑完 m_kib × t 梯度(p 固定 1),每格测 2 次取更小值——`await` 串行,
  /// 不并发:老机器本来就是这条路径要测的对象,并发跑只会互相抢内存/CPU,
  /// 量出来的数字没有意义。FRB 调用本身是 async(见 `vault_sync.dart` 顶部
  /// 注释),不会冻住 UI 线程;每格一 `setState`,进度看得见。单格报错(低于
  /// argon2 crate 自己的下限会抛)不中断整轮,其余格照跑。
  Future<void> _runKdfBench() async {
    final bench = widget.kdfBenchFn ?? syncKdfBenchMs;
    setState(() {
      _kdfBenchRunning = true;
      _kdfBenchResults.clear();
    });
    for (final mKib in _kdfBenchMKibLadder) {
      for (final t in _kdfBenchTLadder) {
        try {
          final a = (await bench(mKib: mKib, t: t, p: 1)).toInt();
          final b = (await bench(mKib: mKib, t: t, p: 1)).toInt();
          if (!mounted) return;
          setState(() => _kdfBenchResults.add(_KdfBenchResult(mKib: mKib, t: t, ms: a < b ? a : b)));
        } catch (e) {
          if (!mounted) return;
          setState(() => _kdfBenchResults.add(_KdfBenchResult(mKib: mKib, t: t, error: '$e')));
        }
      }
    }
    if (mounted) setState(() => _kdfBenchRunning = false);
  }

  void _copyKdfBenchResults() {
    final lines = [
      'KDF 基准测试 · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'm_kib\tt\tp\tmin_ms',
      for (final r in _kdfBenchResults) '${r.mKib}\t${r.t}\t1\t${r.error != null ? 'ERROR: ${r.error}' : r.ms}',
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已复制')));
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录?'),
        content: const Text(
          '退出后,已开通云同步的成员会在这台设备上锁定(需要重新登录才能打开)——'
          '我们不托管密钥,这台设备解不开它就是解不开。这台手机上的病历本身不会被删除。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('退出登录')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _logoutBusy = true);
    try {
      await widget.flow.logout();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _lastSyncReport = null;
        _cloudError = null;
        _syncError = null;
        _deleteFormOpen = false;
      });
    } finally {
      if (mounted) setState(() => _logoutBusy = false);
    }
  }

  /// 见 Task 15 review C1(3):这台手机上已开通云同步的成员,密钥在服务端和
  /// 本机(`AccountSession.clear()` 同一套 secure storage)一起销毁之后,**永远
  /// 打不开**——这不是"锁一下、重新登录就能自动补回来"那种(那是退出登录的
  /// 后果,`AccountFlow.restoreProfileKeys` 已经实现),账号本身没了,没有服务端
  /// 密钥可补。文案必须把这条说清楚,不能含糊成"锁定"两个字带过;也**不允许**
  /// 为了让它"看起来还能用"而把这个成员的 vault 从 keyed 降级成 unkeyed——
  /// 那等于悄悄丢弃了它本该有的加密完整性保证。
  Future<void> _confirmDeleteAccount() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: MedMe.danger, size: 44),
        title: const Text('注销账号?', textAlign: TextAlign.center),
        content: const Text(
          '注销后:账号里的云端病历、家属/医生的授权全部永久删除,他们会立刻'
          '失去访问权限。此操作不可撤销。\n\n'
          '这台手机上已开通云同步的成员,密钥会随账号一起在服务端和本机销毁——'
          '之后这个成员在这台手机上永远打不开,不是"重新登录就能恢复"那种锁定,'
          '我们不托管密钥,没有任何办法找回。\n\n'
          '这台手机上已保存的病历本身不会被删除——如果也要清空本机数据,'
          '请到「清空所有数据」里单独操作。建议先导出一份存档,再继续注销。',
          textAlign: TextAlign.center,
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ExportScreen()),
            ),
            child: const Text('先导出'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: MedMe.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续注销'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() {
      _deleteFormOpen = true;
      _deleteError = null;
    });
  }

  /// 注销前的重新鉴权——手机账号要一个刚发的验证码,Apple 账号要一个刚拿到的
  /// identity token(见 `services/api/app.py` 的 `DELETE /v1/account`)。走哪条
  /// 由 [AccountSession.loginMethod] 决定(登录时记的,不是猜的)。
  Widget _deleteAccountForm() {
    final isApple = widget.flow.session.loginMethod == 'apple';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isApple ? '需要重新用 Apple 验证一次,确认是本人操作。' : '需要重新验证手机号,确认是本人操作。',
          style: const TextStyle(color: MedMe.faint),
        ),
        const SizedBox(height: 8),
        if (!isApple) ...[
          TextField(
            key: const Key('delete_phone'),
            controller: _deletePhoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: '手机号'),
          ),
          const SizedBox(height: 8),
          _deleteOtpBusy
              ? const Center(child: CircularProgressIndicator())
              : TextButton(onPressed: _sendDeleteOtp, child: const Text('发送验证码')),
          TextField(
            key: const Key('delete_otp_code'),
            controller: _deleteOtpCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '验证码'),
          ),
        ],
        if (_deleteError != null) _errorText(_deleteError!),
        const SizedBox(height: 12),
        _deleteBusy
            ? const Center(child: CircularProgressIndicator())
            : FilledButton(
                style: FilledButton.styleFrom(backgroundColor: MedMe.danger),
                onPressed: isApple ? _submitDeleteAccountApple : _submitDeleteAccountOtp,
                child: const Text('确认注销'),
              ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _deleteBusy
              ? null
              : () => setState(() {
                  _deleteFormOpen = false;
                  _deleteError = null;
                }),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Future<void> _sendDeleteOtp() async {
    setState(() {
      _deleteOtpBusy = true;
      _deleteError = null;
    });
    try {
      await widget.flow.sendOtp(_deletePhoneCtrl.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('验证码已发送')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _deleteError = friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _deleteOtpBusy = false);
    }
  }

  Future<void> _submitDeleteAccountOtp() => _submitDeleteAccount(
    () => widget.flow.deleteAccountWithOtp(_deletePhoneCtrl.text.trim(), _deleteOtpCtrl.text.trim()),
  );

  Future<void> _submitDeleteAccountApple() => _submitDeleteAccount(widget.flow.deleteAccountWithApple);

  Future<void> _submitDeleteAccount(Future<void> Function() body) async {
    setState(() {
      _deleteBusy = true;
      _deleteError = null;
    });
    try {
      await body();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _deleteFormOpen = false;
        _lastSyncReport = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('账号已注销')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _deleteError = friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _deleteBusy = false);
    }
  }

  Widget _devicesSection() => FutureBuilder<List<dynamic>>(
    future: _devicesFuture,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snap.hasError) {
        return _errorText('设备列表加载失败:${friendlyApiError(snap.error!)}');
      }
      final devices = snap.data ?? const [];
      if (devices.isEmpty) return const Text('没有其它设备', style: TextStyle(color: MedMe.faint));
      return Column(
        children: [
          for (final d in devices.cast<Map<String, dynamic>>())
            Builder(builder: (context) {
              final row = deviceRow(d);
              return Card(
                child: ListTile(
                  leading: Icon(row.pending ? Icons.phonelink_setup_outlined : Icons.smartphone_outlined),
                  title: Text(row.name),
                  subtitle: Text(row.status),
                  trailing: row.pending
                      ? TextButton(onPressed: () => _approveDevice(d), child: const Text('批准'))
                      : null,
                ),
              );
            }),
        ],
      );
    },
  );

  Future<void> _approveDevice(Map<String, dynamic> device) async {
    final priv = widget.flow.session.privateKey;
    if (priv == null) return;
    try {
      final sealed = await widget.flow.crypto.sealTo(
        base64Decode(device['eph_public'] as String),
        priv,
      );
      await widget.flow.api.postJson(
        '/v1/devices/approve',
        {'device_id': device['device_id'], 'approved_priv': base64Encode(sealed)},
        headers: {'X-Device-Id': await deviceId()},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已批准该设备')));
      _enterReady();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('批准失败:${friendlyApiError(e)}')));
    }
  }

  Widget _grantsSection() => FutureBuilder<List<dynamic>>(
    future: _grantsFuture,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snap.hasError) {
        return _errorText('授权列表加载失败:${friendlyApiError(snap.error!)}');
      }
      final grants = snap.data ?? const [];
      if (grants.isEmpty) return const Text('没有共享档案', style: TextStyle(color: MedMe.faint));
      return Column(
        children: [
          for (final g in grants.cast<Map<String, dynamic>>())
            Card(
              child: ListTile(
                title: Text(_profileLabel(g['profile_id'])),
                subtitle: Text('${roleLabel(g['role'] as String?)} · ${expiryLabel(g['expires_at'])}'),
              ),
            ),
        ],
      );
    },
  );

  /// 「我授权给谁」——每个我拥有的云档案下面挂着的 grantee(见 `_loadMyGrants`),
  /// 每行一个真正能用的「撤销」(`DELETE /v1/profiles/{pid}/grants/{gid}`,后端
  /// 本身就拒绝删 owner 那一行,这里也从不会展示 owner 自己)。
  Widget _myGrantsSection() => FutureBuilder<List<Map<String, dynamic>>>(
    future: _myGrantsFuture,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snap.hasError) {
        return _errorText('加载失败:${friendlyApiError(snap.error!)}');
      }
      final rows = snap.data ?? const [];
      if (rows.isEmpty) return const Text('还没有授权给任何人', style: TextStyle(color: MedMe.faint));
      return Column(
        children: [
          for (final g in rows)
            Card(
              child: ListTile(
                // `grantee_kind`(account/invite)是服务端的实现细节,不露出来。
                title: Text(_profileLabel(g['profile_id'])),
                subtitle: Text(
                  [
                    roleLabel(g['role'] as String?),
                    expiryLabel(g['expires_at']),
                    ?createdLabel(g['created_at']),
                  ].join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: Key('transfer_${g['grant_id']}'),
                      onPressed: _transferBusy ? null : () => _transferOwnershipOf(g['profile_id']),
                      child: const Text('转为主人'),
                    ),
                    TextButton(
                      onPressed: _revokeBusy ? null : () => _revokeMyGrant(g),
                      child: const Text('撤销'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  /// B5:「把这份档案交给他」。
  ///
  /// `Grants.inviteTransfer` 在这之前**一个调用方都没有** —— 代拍那条路的
  /// `cloudProfile` 分支还没接线(见 `doctor_claim_link_dialog.dart` 的说明)。
  /// 也就是说"把档案交给父母/子女"这件事在产品里根本不存在,而它恰恰是「替父母
  /// 管病历」这条主线的终局:老人自己装了 App、自己成为主人,子女退回家人。
  ///
  /// 这一步只**生成一条链接**,不改变任何东西 —— 真正的转移发生在对方点开并接受
  /// 那一刻(服务端在兑换时把老 owner 自动降成 editor)。确认弹窗必须把这条说
  /// 清楚,否则用户会以为点下去就已经交出去了。
  Future<void> _transferOwnershipOf(Object? cloudId) async {
    final profile = ProfileManager.instance.profiles.where((p) => p.cloudId == cloudId).firstOrNull;
    if (profile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: const Text('这台手机上找不到这份档案,先同步一次再试')),
      );
      return;
    }
    await _transferOwnership(profile);
  }

  Future<void> _transferOwnership(Profile profile) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('把这份档案交给他?'),
        content: Text(
          '对方接受之后,「${profile.name}」这份档案就归他所有;'
          '你会降为可以一起录入的家人,不再能把它转给别人、也不能再收回别人的授权。\n\n'
          '现在这一步只生成一条链接,还不会改变任何东西 —— 对方点开并接受之后才真正生效。\n\n'
          '注意:拿到这个码的任何人都能接受(它不绑定某一个人),15 天内有效,'
          '而且生成之后没有办法收回 —— 只发给你真正要交给的那个人。',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('生成链接')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _transferBusy = true);
    try {
      final link = await _grants.inviteTransfer(profile);
      if (!mounted) return;
      await showLinkQrDialog(
        context,
        title: '请他扫这个码',
        url: link.toUrl(),
        body: '让对方用手机相机拍下这个码,或者把链接发给他。他点开并接受之后,'
            '「${profile.name}」这份档案就归他所有,你降为可以一起录入的家人。',
        // ⚠️ 这句原来写的是「在他接受之前,你随时可以不管它 —— 不接受就什么都没
        // 发生」。那是**误导**(评审 Important 9):服务端既没有列出 invite 的端点、
        // 也没有撤销的端点,所以你既没法"不管它"、也没法收回。照实说。
        footnote: '拿到这个码的任何人都能接受(它不绑定某一个人),15 天内有效,'
            '生成之后无法撤回。只发给你真正要交给的那个人。',
        shareSubject: '把这份病历档案交给你',
        shareLabel: '发给他',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: Text('生成转移链接失败:${friendlyApiError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _transferBusy = false);
    }
  }

  Future<void> _revokeMyGrant(Map<String, dynamic> grant) async {
    setState(() => _revokeBusy = true);
    try {
      await widget.flow.api.delete('/v1/profiles/${grant['profile_id']}/grants/${grant['grant_id']}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已撤销')));
      _enterReady();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('撤销失败:${friendlyApiError(e)}')));
    } finally {
      if (mounted) setState(() => _revokeBusy = false);
    }
  }

  /// 按手机号把**当前打开的成员**共享给家属:查号 → 封给对方公钥 → 永久 editor
  /// (见 `grants.dart` 的 `grantFamilyByPhone`)。这个成员必须已经开通云同步——
  /// 没有 cloudId 就没有档案密钥可封,`_familySection` 那边不显示表单,直接返回。
  Widget _familySection() {
    final profile = ProfileManager.instance.current;
    if (profile.cloudId == null) {
      return const Text('当前成员还没开通云同步,暂时不能添加家属', style: TextStyle(color: MedMe.faint));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('family_phone'),
          controller: _familyPhoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: '家属手机号'),
        ),
        if (_familyError != null) _errorText(_familyError!),
        const SizedBox(height: 8),
        _familyBusy
            ? const Center(child: CircularProgressIndicator())
            : SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _addFamily, child: const Text('按手机号添加家属')),
              ),
      ],
    );
  }

  Future<void> _addFamily() async {
    final profile = ProfileManager.instance.current;
    if (profile.cloudId == null) return;
    final phone = _familyPhoneCtrl.text.replaceAll(' ', '');
    setState(() {
      _familyBusy = true;
      _familyError = null;
    });
    try {
      await _grants.grantFamilyByPhone(profile, phone);
      if (!mounted) return;
      _familyPhoneCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已添加家属')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _familyError = _familyLookupError(e) ?? friendlyApiError(e); });
    } finally {
      if (mounted) setState(() => _familyBusy = false);
    }
  }

  /// 「按手机号加家属」这条路**自己**的解释。状态码的通用含义在
  /// [friendlyApiError] 里(全 App 一份),这里只说它管不到的那一层:这个 404
  /// 指的是"这个手机号没有账号",不是泛泛的"没找到"。认不出来返回 null,
  /// 交回通用那一层。
  String? _familyLookupError(Object e) => switch (e) {
    // B4:服务端把这两件事分开了(`services/api/app.py` 的 `account_lookup`)。
    // 在这之前两者都是 404,于是这里只能说一句「没有找到使用该手机号的账号」——
    // 而最常见的真实情况恰恰是下面这一条(父母装了 App、登录了、卡在设口令那一
    // 步),那句话是**错误归因**:家属会去确认手机号、重输、放弃,而真正要做的事
    // 在对方手机上。`404 + no_keys` 也认一下,免得新旧版本对不齐时又掉回错话。
    ApiFailed(status: 409, message: 'no_keys') ||
    ApiFailed(status: 404, message: 'no_keys') =>
      '对方已注册,但还没设置好账号口令 —— 请他在 MedMe 里打开 设置 → 账号,完成最后两步',
    ApiFailed(status: 404) => '没有找到使用该手机号的账号',
    ApiFailed(status: 400) => '手机号格式不对',
    _ => null,
  };

  Widget _errorText(String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: const TextStyle(color: MedMe.danger)),
  );

  /// 口令输入框 + A4 的「显示/隐藏」眼睛。注册与解锁共用(两屏不同时在,所以
  /// 共用 `Key('password')`——已有测试按这个键找它)。
  ///
  /// `onChanged` 里那一次 `setState` 不是多余的:注册屏的「还差几位」和「生成
  /// 密钥」能不能点,都得跟着每一次按键走。
  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required bool visible,
    required VoidCallback onToggle,
    String? helper,
  }) => TextField(
    key: const Key('password'),
    controller: controller,
    obscureText: !visible,
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 2,
      suffixIcon: IconButton(
        key: const Key('password_eye'),
        icon: Icon(visible ? Icons.visibility_off_outlined : Icons.visibility_outlined),
        tooltip: visible ? '隐藏口令' : '显示口令',
        onPressed: onToggle,
      ),
    ),
  );

  /// [enabled] 为 false 时按钮画出来但不可点(`onPressed: null`)——不是把它藏
  /// 起来:用户得看见下一步在哪、为什么还不能点(提示就在按钮上方)。
  /// [busyHint] 是转圈时那句话,见 [_kdfWaitHint]。
  Widget _asyncButton({
    required String label,
    required VoidCallback onPressed,
    bool enabled = true,
    String? busyHint,
  }) {
    if (_busy) {
      return Column(
        children: [
          const Center(child: CircularProgressIndicator()),
          if (busyHint != null) ...[
            const SizedBox(height: 12),
            Text(
              busyHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MedMe.faint, height: 1.5),
            ),
          ],
        ],
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(onPressed: enabled ? onPressed : null, child: Text(label)),
    );
  }
}
