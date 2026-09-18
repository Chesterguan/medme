// 面对面二维码分享:门诊里把手机递给医生扫,三十秒看懂当下病情。
//
// 与「加密分享文件」的分工:那个是整份病历(含原件、影像,医生带走);这个是
// **当下病情** —— 在治的病、关键指标最近几个点、在用的药。要看原件或阅片,
// 患者手机当场翻,不必把整份病历交出去。
//
// 载荷有界(Rust 侧 QrLimits),体积与病历总量无关,永远塞得进一张码。钥匙在
// URL 的 `#` 之后,按 HTTP 规范不会发给服务器 —— 医生扫码后只从静态页下载一个
// 空壳查看器,病历数据全程只在两台手机之间。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account.dart';
import '../analytics.dart';
import '../api_client.dart';
import '../claim_upload.dart';
import '../grants.dart';
import '../profile_manager.dart';
import '../src/rust/api/vault.dart';
import '../theme.dart';
import 'qr_notice_sheet.dart';

/// 医生扫码后打开的查看器地址。数据在 `#` 之后,不会随请求上行。
const _viewerBase = 'https://medmenow.com/viewer/';

class QrShareScreen extends StatefulWidget {
  const QrShareScreen({super.key, this.grants, this.qrShareBlobFn = qrShareBlob});

  /// 测试注入点,默认为 null——真正用的时候现取现建(见
  /// `_QrShareScreenState._grants`)。`flutter test` 不带原生库,注入一个带假
  /// `GrantsRust` 的 [Grants] 才能测"邀请创建失败要不要正确回退"这条分支,不必
  /// 真的跑到原路径的 FFI 调用。
  final Grants? grants;

  /// 原路径(加密上传)的密文生成函数,默认真实的 [qrShareBlob]。这是**真实
  /// FRB 调用**——`flutter test` 没有原生库时它不是抛异常,而是真的把整个测试
  /// 进程卡住退不出去(实测踩过)。测一条"回退确实发生了"的路时,注入一个
  /// 立即失败的假实现,不必也不能真的跑通这一步。
  final Future<(Uint8List, String, int)> Function({required int expiresDays}) qrShareBlobFn;

  @override
  State<QrShareScreen> createState() => _QrShareScreenState();
}

/// 授权链接那条路**能不能提供给用户选**——纯函数,不碰网络/FFI,方便在
/// `flutter test` 里单独钉住这道闸(见 `test/qr_share_screen_test.dart`)。
///
/// 三个条件都是硬要求:未登录/未开通云端备份没有档案钥匙可用;不是 owner 时,
/// 服务端 `POST .../invites` 本来就会 403(owner-only),不判就是摸黑试一次
/// 注定失败的请求。
///
/// **「已开通云端备份」= `cloudId != null && !cloudPaused`**(F2),与 `cloudRowStatus`
/// 同一个定义。把云端备份关掉的成员原来照样能拿到这个选项,而且真的会建出一条 15 天
/// 授权 —— 他刚刚明确关掉的恰恰是"让病历上云"这件事,这条路却绕过开关把密文送上去
/// (隐私政策里也是按"开通了云端备份才有这个选项"写的)。
///
/// ⚠️ **它不再决定走哪条路**(UX 第二轮,创始人拍板)。在这之前它一为真就**自动**
/// 切成授权链接,于是「开通云端备份」这件事顺带改掉了诊室里那条最关键的路:医生
/// 拿自己的手机扫一下就能看 → 变成医生必须先装 MedMe 并登录。那不是一个该由
/// "你登录了没"替用户做的决定。现在它只负责**有没有这个选项**,选哪个由
/// [_QrShareScreenState._grantChoice] 决定,默认旧路径。
@visibleForTesting
bool shouldTryGrantLink({required bool loggedIn, required Profile profile}) =>
    loggedIn && profile.cloudId != null && !profile.cloudPaused && profile.role == 'owner';

/// 上次在出码屏选了哪条路(shared_preferences)。记住它:同一个人大概率每次
/// 看病都用同一种方式,不该每次都重新选。
const _qrModePrefsKey = 'qr_share_grant_mode';

class _QrShareScreenState extends State<QrShareScreen> {
  String? _url;
  int _recordCount = 0;
  int _problemCount = 0;
  /// 码里装的是一条授权链接(医生扫了自己兑换),不是密文上传——文案与「医生
  /// 看到的是什么」那段说明都跟着换一套。这是**这一次实际出的码是哪种**;用户
  /// 选的是 [_grantChoice],授权链接创建失败时这里会退回 false。
  bool _grantMode = false;

  /// 用户选的那条路(`true` = 授权链接 / 「医生要长期看(15 天)」)。**默认 false**:
  /// 诊室里最常见的一步是医生拿自己的手机扫一下当场看,那条路不要求医生装任何
  /// 东西。上次的选择记在 shared_preferences(见 [_qrModePrefsKey])。
  bool _grantChoice = false;

  /// 这个成员有没有资格提供授权链接那条路(见 [shouldTryGrantLink])——决定顶部
  /// 那个二选一显不显示。未登录/非主人只有旧路径,连选项都不给。
  bool _canGrant = false;
  /// 上传没成功,退回了「只带摘要」的旧码。**必须在界面上说出来** —— 病人得知道
  /// 医生这次看不到原件,否则他会以为都给了。
  bool _degraded = false;
  String? _error;
  String? _stage;      // 当前在干嘛(准备 / 上传)
  double? _progress;   // 0.0–1.0,只在上传阶段有值
  int _uploadedBytes = 0;
  int _totalBytes = 0;
  /// 当前这次上传。**留着它才能续传** —— 失败后重试会跳过已成功的分片。
  ResumableUpload? _upload;
  /// 重试时要用的 (钥匙, 记录数) —— 加密只做一次,重试不重新加密。
  (String, int)? _pendingShare;
  /// 失败了但可以续传:此时给「继续上传 / 就用简版码」两个选择,而不是直接降级 ——
  /// 用户可能知道「再等一下就好,医生不急」,那不该由我们替他决定。
  String? _resumable;

  // 自动调亮是否成功:成功了就不用再提示患者手动调亮。失败(部分设备/权限
  // 限制)保持 false,页面照常显示二维码,退回原来的手动提示文案。
  bool _brightnessBoosted = false;

  @override
  void initState() {
    super.initState();
    _init();
    _boostBrightness();
  }

  /// 先把"有没有这个选项 / 上次选的是哪个"读回来,再出码。读 prefs 失败(测试
  /// 环境没挂这个 channel)不该挡住出码 —— 落回默认的旧路径就好。
  Future<void> _init() async {
    _canGrant = shouldTryGrantLink(
      loggedIn: AccountSession.instance.loggedIn.value,
      profile: ProfileManager.instance.current,
    );
    if (_canGrant) {
      try {
        _grantChoice = (await SharedPreferences.getInstance()).getBool(_qrModePrefsKey) ?? false;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {});
    // 第一次在这台设备上出码:先把「东西去哪了」说一句,他按了「好,出码」才继续。
    // **不看登录状态** —— 登录与否都照常出码(创始人拍板,取代「未登录不给出码」)。
    if (shouldShowQrNotice(seen: await loadQrNoticeSeen())) {
      if (!mounted) return;
      final go = await showQrNoticeSheet(context);
      if (!mounted) return;
      if (!go) {
        Navigator.of(context).pop(); // 「先不出」= 退出这一屏,什么都没传
        return;
      }
    }
    await _generate();
  }

  /// 用户拨了顶部那个二选一:记住选择,然后**重新出一张码**(两条路产出的码完全
  /// 不是一回事,不能只换文案)。
  Future<void> _pickMode(bool grant) async {
    if (grant == _grantChoice) return;
    setState(() {
      _grantChoice = grant;
      _url = null;
      _degraded = false;
      _resumable = null;
      _error = null;
      _upload = null;
      _pendingShare = null;
    });
    try {
      await (await SharedPreferences.getInstance()).setBool(_qrModePrefsKey, grant);
    } catch (_) {}
    await _generate();
  }

  @override
  void dispose() {
    // 只调了 app 内亮度,不影响系统亮度;离开页面时恢复,覆盖用户中途按
    // home 键切走再回来的情况(setApplicationScreenBrightness 只在此页
    // 生效,退到后台时插件自身也会按生命周期自动重置,双保险)。
    // dispose 是同步的,恢复调用不 await;失败也不阻塞退出,但要接住
    // 异常,不然是一个未处理的 Future 错误。
    if (_brightnessBoosted) {
      ScreenBrightness.instance
          .resetApplicationScreenBrightness()
          .catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _boostBrightness() async {
    try {
      await ScreenBrightness.instance.setApplicationScreenBrightness(1.0);
      if (mounted) setState(() => _brightnessBoosted = true);
    } catch (_) {
      // 调亮失败(部分设备/权限限制)不影响二维码本身显示,静默降级为
      // 手动提示即可,不弹错误打断医患当面这个流程。
    }
  }

  /// 出码 = 先把完整病历(含原件)加密传上瞬时云,再把 `q2.<id>.<钥匙>` 编成码。
  ///
  /// 上传要花几秒到几十秒,取决于原件多少 —— 这段时间医患本来就在说话,进度条是
  /// 为了让病人知道还要多久,而不是干等一个转圈。
  ///
  /// **失败就是失败,不给一个残缺的码。** 医生扫到一个打不开的码,比病人当场知道
  /// 「没传上、再试一次」糟糕得多 —— 前者浪费的是诊室里那几分钟。
  Future<void> _generate() async {
    // **用户选了「医生要长期看(15 天)」那条**,而且这个成员有资格(登录 + 已开通云端备份 +
    // 是这个档案的 owner):出授权链接,跳过整套「加密病历、上传瞬时云」——医生扫码
    // 兑换的是一份 15 天只读授权,内容走的是正常的云端备份拉取,不是这里的密文上传。
    //
    // owner 这道闸是硬要求,不是优化:发邀请是服务端 owner-only 的操作
    // (`POST /v1/profiles/{pid}/invites` 对 editor/viewer 一律 403),不判就摸黑
    // 试一次注定失败的请求。而**即使是 owner**,邀请创建仍可能失败(网络、服务端
    // 500……)——那种情况绝不能停在一个空白/报错的死胡同,必须退回原来的加密
    // 上传路径,像 `proxy_intake_flow.dart` 的 `_deliver` 上传失败退回本地加密
    // 文件那样,总有一条码能出。未登录/未开通云端备份/不是 owner,直接走原路径,
    // 一字不改。
    final profile = ProfileManager.instance.current;
    if (_grantChoice && shouldTryGrantLink(loggedIn: AccountSession.instance.loggedIn.value, profile: profile)) {
      try {
        setState(() {
          _error = null;
          _grantMode = true;
          _stage = '正在生成链接…';
          _progress = null;
        });
        final link = await (widget.grants ??
                Grants(
                  ApiClient.forSession(AccountSession.instance),
                  AccountSession.instance,
                ))
            .inviteDoctor(profile);
        if (!mounted) return;
        setState(() {
          _stage = null;
          _url = link.toUrl();
        });
        // 出码成功——同一个事件,授权链接这条路没有份数/体积可报,其余属性都是
        // 可选的(目录只钉住"允许出现哪些键",不要求每次都全带)。
        Analytics.track(AnalyticsEvent.shareQrShown, const {});
        return;
      } catch (_) {
        // 退回原路径,不留在这里报错——见上面的文档。
        if (mounted) setState(() => _grantMode = false);
      }
    }
    _grantMode = false;
    try {
      setState(() {
        _error = null;
        _degraded = false;
        _stage = '正在准备病历…';
        _progress = null;
      });
      final (blob, keyB64, recordCount) = await widget.qrShareBlobFn(expiresDays: 15);
      _upload = ResumableUpload(blob);
      _totalBytes = blob.length;
      _pendingShare = (keyB64, recordCount.toInt());
      await _runUpload(keyB64, recordCount.toInt());
      return;
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = null;
          _progress = null;
          _error = '$e';
        });
      }
    }
  }

  /// 跑(或继续跑)上传。可重复调用 —— 已成功的分片不会重传。
  Future<void> _runUpload(String keyB64, int recordCount) async {
    final up = _upload;
    if (up == null) return;
    setState(() {
      _resumable = null;
      _error = null;
      _stage = '正在上传(${_mb(_totalBytes)})…';
      _progress = up.progress;
      _uploadedBytes = up.uploadedBytes;
    });
    try {
      final id = await up.run(
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
              _uploadedBytes = up.uploadedBytes;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _stage = null;
        _progress = null;
        _url = '$_viewerBase#q2.$id.$keyB64';
        _recordCount = recordCount;
      });
      // 出码成功。份数与体积都分桶 —— 体积分布决定要不要担心大档案的上传时间。
      Analytics.track(AnalyticsEvent.shareQrShown, {
        'record_count_bucket': Bucket.count(recordCount),
        'size_bucket': Bucket.bytes(_totalBytes),
      });
    } on ClaimUploadCancelled {
      if (mounted) Navigator.of(context).pop();  // 取消不是错误,直接退回上一屏
    } catch (e) {
      // **不直接降级。** 已经传上去的分片还在,重试能接着传 —— 让用户自己选。
      if (mounted) {
        setState(() {
          _stage = null;
          _progress = null;
          _resumable = '$e';
        });
      }
      // 上传中断了。**这条是回答「断连有多常见」的唯一数据** —— 但只报「断在几成」,
      // 不报错误详情(异常消息可能带 URL 和对象 id)。
      Analytics.track(AnalyticsEvent.shareUploadRetry, {
        'choice': 'interrupted',
        'progress_bucket': Bucket.count(((_progress ?? 0) * 10).round()),
      });
    }
  }

  /// 用户选了「就用简版码」:退回内嵌载荷的旧码(只带摘要、不需要联网)。
  Future<void> _useFallback() async {
    // 用户选了简版码 = 云那条路这次没走通。与 retry 的比例能看出他们更愿意等还是更急。
    Analytics.track(AnalyticsEvent.shareQrDegraded, {'choice': 'fallback'});
    setState(() {
      _resumable = null;
      _stage = '正在生成简版码…';
    });
    try {
      final fallback = await buildQrShareUrl(baseUrl: _viewerBase);
      if (!mounted) return;
      setState(() {
        _stage = null;
        _degraded = true;
        _url = fallback.url;
        _problemCount = fallback.problemCount;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = null;
          _error = '$e';
        });
      }
    }
  }

  static String _pct(double p) => '${(p * 100).round()}%';

  /// 重试 = 继续传。已成功的分片由 [ResumableUpload] 跳过。
  Future<void> _retry() async {
    Analytics.track(AnalyticsEvent.shareUploadRetry, {'choice': 'retry'});
    final s = _pendingShare;
    if (s != null) await _runUpload(s.$1, s.$2);
  }

  static String _mb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        // `s13`:这一屏自己叫「出码」,「给医生看」是它的返回箭头指回去的那一页。
        title: const Text('出码'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 常驻在顶部(不在 `_body()` 里面):出码要花几十秒,而"我选错了"这件事
            // 正是在等的时候才想起来的 —— 那一刻选择器不能刚好不在屏上。
            if (_canGrant) _modePicker(),
            Expanded(child: Center(child: _body())),
          ],
        ),
      ),
    );
  }

  /// 二选一。**默认左边那个**(旧路径):医生拿自己的手机扫一下当场看,不装任何
  /// 东西;右边那条要求医生也装 MedMe 并登录,换来的是他能带走 15 天。
  ///
  /// 两段文案各自说准各自的代价 —— 这一屏唯一真正要帮用户做的判断就是这个。
  Widget _modePicker() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
    child: Column(
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment<bool>(
              value: false,
              label: Text('医生当场看(任何手机)', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
            ),
            ButtonSegment<bool>(
              value: true,
              // `s13` 逐字:一句主文 + 一行小字(小字说的是这条路的代价)。
              label: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('医生要长期看(15 天)',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                  Text('医生也要装 MedMe',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, color: MedMe.faint)),
                ],
              ),
            ),
          ],
          selected: {_grantChoice},
          onSelectionChanged: (s) => _pickMode(s.first),
        ),
        const SizedBox(height: 6),
        Text(
          _grantChoice
              ? '医生用他自己的 MedMe 扫码(需要他已经装了 App 并登录),这份病历进他的列表,只能看,15 天后自动看不到。'
              : '医生用任何手机的相机扫码,在浏览器里打开看 —— 他不用装 App、不用注册。看完收起手机即可。',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: MedMe.faint, height: 1.5),
        ),
      ],
    ),
  );

  Widget _body() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: MedMe.danger),
            const SizedBox(height: 12),
            const Text('生成失败', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: MedMe.faint),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _generate, child: const Text('重试')),
          ],
        ),
      );
    }
    // 传失败但还能接着传:给两个选择。用户可能知道「再等一下就好」,不该由我们
    // 替他判断;也可能急着给医生看,那就用简版码。已传的分片都还在,续传不重来。
    final resumable = _resumable;
    if (resumable != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: MedMe.faint),
            const SizedBox(height: 14),
            Text(resumable,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, height: 1.6)),
            const SizedBox(height: 6),
            Text('已传 ${_pct(_progress ?? 0)},继续会接着传,不用从头来。',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: MedMe.faint, height: 1.6)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _retry,
              style: FilledButton.styleFrom(
                  backgroundColor: MedMe.teal,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13)),
              child: const Text('继续上传'),
            ),
            TextButton(
              onPressed: _useFallback,
              child: const Text('就用简版码(不含原件)'),
            ),
          ],
        ),
      );
    }

    final url = _url;
    if (url == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 上传阶段给确定进度(病人在等,该知道还要多久);准备阶段给不定式转圈。
            if (_progress != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 7,
                  backgroundColor: MedMe.tealSoft,
                ),
              )
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              _stage ?? '正在准备…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: MedMe.faint, fontSize: 13),
            ),
            if (_progress != null) ...[
              const SizedBox(height: 6),
              // 只给百分比不够 —— 病人在诊室里等,得能判断「还要多久」。
              Text('${_pct(_progress!)} · ${_mb(_uploadedBytes)} / ${_mb(_totalBytes)}',
                  style: const TextStyle(color: MedMe.faint, fontSize: 12)),
              const SizedBox(height: 14),
              // 没有取消按钮的话,慢的时候只能退出页面,而退出等于白传。
              TextButton(
                onPressed: () => _upload?.cancel(),
                child: const Text('取消'),
              ),
            ],
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        children: [
          // `s13`:屏名(「出码」)在顶栏,正文第一行就是这句副标题 —— 不再在
          // 正文里把屏名重写一遍。
          Text(
            _grantMode
                ? '医生用他自己的 MedMe 扫码,15 天内都能看'
                // 自动调亮成功了就别再让患者做一遍已经做了的事。
                : (_brightnessBoosted ? '医生用手机扫一下就能看' : '把屏幕亮度调高,对着医生的手机相机'),
            style: const TextStyle(fontSize: 13.5, color: MedMe.faint),
          ),
          const SizedBox(height: 20),
          // 白底 + 留白是二维码可扫性的硬要求,别加装饰。
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: MedMe.line),
            ),
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 280,
              backgroundColor: Colors.white,
              // 医生隔着距离扫,纠错等级留高一点更容易扫上。
              // 注意:Rust 侧 `QR_BINARY_CAPACITY` 是按这个等级(M=2331 字节)定的,
              // 改这里必须同步改那个常量,否则守卫会比实际容量宽 27%。
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
          // `s13`:码下面那一行。**降级的简版码不显示它** —— 那种码的内容全在码里、
          // 没有上传,15 天这个期限说的是云上那份密文,对它不成立。
          if (!_degraded) ...[
            const SizedBox(height: 10),
            const Text(
              '15 天内有效;只有扫这个码的人能看',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: MedMe.faint),
            ),
          ],
          const SizedBox(height: 18),
          if (!_grantMode) _summaryChip(),
          if (!_grantMode) const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: MedMe.tealSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '医生看到的是什么',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
                const SizedBox(height: 6),
                Text(
                  _grantMode
                      ? '医生扫码后,这份病历会出现在他自己的 MedMe 里(他需要已经装了 MedMe 并登录)'
                          '——只能看,15 天后自动看不到。'
                      : (_degraded
                          ? '当前在治的疾病、关键指标趋势、正在吃的药。'
                          '这次没能上传,所以不含原件 —— 医生要看原件,请当场用手机翻给他。'
                          : '你的完整病历:在治的疾病、化验趋势、正在吃的药,以及每一份原件。'),
                  style: const TextStyle(fontSize: 12.5, height: 1.6, color: MedMe.ink),
                ),
                const SizedBox(height: 10),
                Text(
                  _grantMode
                      ? '这张码就是钥匙:被拍下就等于给了这份「只能看」的权限,15 天后自动失效,你随时可以提前收回。'
                      : (_degraded
                          ? '这张码就是钥匙:被拍下就等于把这份摘要给了对方,看完收起手机即可。'
                          '这次的内容全在码里,没有上传到任何地方。'
                          : '这张码就是钥匙:被拍下就等于把这份病历给了对方,看完收起手机即可。'
                          '内容已加密临时存放,保留期结束后自动删除 —— 钥匙只在这张码里,我们解不开。'),
                  style: const TextStyle(fontSize: 12.5, height: 1.6, color: MedMe.faint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryChip() {
    // 降级时必须说出来:病人得知道医生这次看不到原件,否则他会以为都给了。
    final text = _degraded
        ? '本码含 $_problemCount 个在治问题 · 这次没能带上原件'
        : '本码含 $_recordCount 份病历,含原件';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.lock_outline, size: 15, color: MedMe.faint),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12.5, color: MedMe.faint),
          ),
        ),
      ],
    );
  }
}
