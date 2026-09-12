import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/export_screen.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 账号屏的状态机:手机号登录 → OTP → (首次)设口令 + 展示恢复码 / (换设备)口令或
/// 恢复码解锁 → 就绪(设备批准 + 授权列表 + 云同步 + 退出/注销)。切状态的判断逻辑全在
/// [AccountFlow],本屏只负责按返回值/异常显示对应界面。
enum _Phase { idle, otpSent, keySetup, showRecovery, unlock, ready }

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.flow, this.grants, this.syncEngine});
  final AccountFlow flow;

  /// 测试注入点,默认为 null——真正用的时候按 [flow] 现取现建(见
  /// `_AccountScreenState._grants`)。`Grants` 内部按需碰 FRB(`grantFamilyByPhone`
  /// 的 `sealTo`),测试传一个带假 `GrantsRust` 的实例进来,不碰真实原生库。
  final Grants? grants;

  /// 测试注入点,同 [grants]——「开通云同步」「立即同步」用得到,默认为 null,
  /// 真正用的时候按 [flow] 现取现建(见 `_AccountScreenState._sync`)。
  final SyncEngine? syncEngine;

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

  bool _familyBusy = false;
  String? _familyError;

  Grants get _grants => widget.grants ?? Grants(widget.flow.api, widget.flow.session);
  SyncEngine get _sync => widget.syncEngine ?? SyncEngine(widget.flow.api, widget.flow.session);

  Future<List<dynamic>>? _devicesFuture;
  Future<List<dynamic>>? _grantsFuture;

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
          setState(() => _error = e.toString());
        });
  }

  @override
  void dispose() {
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

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendOtp() => _run(() async {
    await widget.flow.sendOtp(_phoneCtrl.text.trim());
    setState(() => _phase = _Phase.otpSent);
  });

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
    });
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
    TextField(
      key: const Key('password'),
      controller: _regPasswordCtrl,
      obscureText: true,
      decoration: const InputDecoration(labelText: '设置一个口令'),
    ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 16),
    _asyncButton(label: '生成密钥', onPressed: _registerKeys),
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
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: _recoveryCode!)),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
          ),
        ],
      ),
    ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 20),
    _asyncButton(label: '我已抄下恢复码', onPressed: _confirmRecovery),
  ];

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
      TextField(
        key: const Key('password'),
        controller: _unlockPasswordCtrl,
        obscureText: true,
        decoration: const InputDecoration(labelText: '输入口令'),
      ),
    if (_error != null) _errorText(_error!),
    const SizedBox(height: 16),
    _asyncButton(label: _useRecoveryUnlock ? '用恢复码解锁' : '解锁', onPressed: _unlock),
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
  ];

  List<Widget> _readyContent() => [
    const Text('已登录', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 4),
    Text('账号:${widget.flow.session.accountId ?? ''}', style: const TextStyle(color: MedMe.faint)),
    const SizedBox(height: 24),
    const Text('设备', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _devicesSection(),
    const SizedBox(height: 24),
    const Text('授权', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _grantsSection(),
    const SizedBox(height: 24),
    const Text('家属', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _familySection(),
    const SizedBox(height: 24),
    const Text('云同步', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _cloudSyncSection(),
    const SizedBox(height: 24),
    const Text('账号管理', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    _accountManagementSection(),
  ];

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
        const SizedBox(height: 8),
        _syncBusy
            ? const Center(child: CircularProgressIndicator())
            : OutlinedButton(onPressed: _syncNow, child: const Text('立即同步')),
      ],
    );
  }

  String _syncSummary(SyncReport r) {
    final parts = ['推送 ${r.pushed} 条', '拉取 ${r.pulled} 条'];
    if (r.objectsFailed > 0) parts.add('${r.objectsFailed} 个附件失败');
    if (r.pushSkippedNoWatermark) parts.add('本次跳过推送(水位未就绪)');
    return '上次同步:${parts.join('、')}';
  }

  Future<void> _enableCloud() async {
    setState(() {
      _cloudBusy = true;
      _cloudError = null;
    });
    try {
      await _sync.enableCloud(ProfileManager.instance.current);
      if (!mounted) return;
      setState(() {}); // current 已写回 cloudId,重建切到"已开通"那半支
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已开通云同步')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _cloudError = '$e');
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
      setState(() => _syncError = '$e');
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
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
      setState(() => _deleteError = '$e');
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
      setState(() => _deleteError = '$e');
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
        return _errorText('设备列表加载失败:${snap.error}');
      }
      final devices = snap.data ?? const [];
      if (devices.isEmpty) return const Text('没有其它设备', style: TextStyle(color: MedMe.faint));
      return Column(
        children: [
          for (final d in devices.cast<Map<String, dynamic>>())
            Card(
              child: ListTile(
                leading: const Icon(Icons.smartphone_outlined),
                title: Text(d['name']?.toString() ?? d['device_id'].toString()),
                subtitle: Text((d['approved'] as bool? ?? false) ? '已批准' : '等待批准'),
                trailing: (d['eph_public'] != null && d['approved'] != true)
                    ? TextButton(onPressed: () => _approveDevice(d), child: const Text('批准'))
                    : null,
              ),
            ),
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
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('批准失败:$e')));
    }
  }

  Widget _grantsSection() => FutureBuilder<List<dynamic>>(
    future: _grantsFuture,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snap.hasError) {
        return _errorText('授权列表加载失败:${snap.error}');
      }
      final grants = snap.data ?? const [];
      if (grants.isEmpty) return const Text('没有共享档案', style: TextStyle(color: MedMe.faint));
      return Column(
        children: [
          for (final g in grants.cast<Map<String, dynamic>>())
            Card(
              child: ListTile(
                title: Text('档案 ${g['profile_id']}'),
                subtitle: Text('角色:${g['role']}${g['expires_at'] != null ? ' · 到期 ${g['expires_at']}' : ''}'),
                trailing: g['role'] == 'owner'
                    ? TextButton(onPressed: () => _revokeGrant(g), child: const Text('撤销'))
                    : null,
              ),
            ),
        ],
      );
    },
  );

  Future<void> _revokeGrant(Map<String, dynamic> grant) async {
    try {
      await widget.flow.api.delete('/v1/profiles/${grant['profile_id']}/grants/${grant['grant_id']}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: const Text('已撤销')));
      _enterReady();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text('撤销失败:$e')));
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
      setState(() {
        _familyError = switch (e) {
          ApiFailed(status: 404) => '没有找到使用该手机号的账号',
          ApiFailed(status: 429) => '查询太频繁,稍后再试',
          ApiFailed(status: 400) => '手机号格式不对',
          _ => '$e',
        };
      });
    } finally {
      if (mounted) setState(() => _familyBusy = false);
    }
  }

  Widget _errorText(String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: const TextStyle(color: MedMe.danger)),
  );

  Widget _asyncButton({required String label, required VoidCallback onPressed}) {
    if (_busy) return const Center(child: CircularProgressIndicator());
    return SizedBox(
      width: double.infinity,
      child: FilledButton(onPressed: onPressed, child: Text(label)),
    );
  }
}
