// 面对面二维码分享:门诊里把手机递给医生扫,三十秒看懂当下病情。
//
// 与「加密分享文件」的分工:那个是整份病历(含原件、影像,医生带走);这个是
// **当下病情** —— 在治的病、关键指标最近几个点、在用的药。要看原件或阅片,
// 患者手机当场翻,不必把整份病历交出去。
//
// 载荷有界(Rust 侧 QrLimits),体积与病历总量无关,永远塞得进一张码。密钥在
// URL 的 `#` 之后,按 HTTP 规范不会发给服务器 —— 医生扫码后只从静态页下载一个
// 空壳查看器,病历数据全程只在两台手机之间。
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../claim_storage.dart';
import '../src/rust/api/vault.dart';
import '../theme.dart';

/// 医生扫码后打开的查看器地址。数据在 `#` 之后,不会随请求上行。
const _viewerBase = 'https://medmenow.com/viewer/';

class QrShareScreen extends StatefulWidget {
  const QrShareScreen({super.key});

  @override
  State<QrShareScreen> createState() => _QrShareScreenState();
}

class _QrShareScreenState extends State<QrShareScreen> {
  String? _url;
  int _recordCount = 0;
  int _problemCount = 0;
  /// 上传没成功,退回了「只带摘要」的旧码。**必须在界面上说出来** —— 病人得知道
  /// 医生这次看不到原件,否则他会以为都给了。
  bool _degraded = false;
  String? _error;
  String? _stage;      // 当前在干嘛(准备 / 上传)
  double? _progress;   // 0.0–1.0,只在上传阶段有值

  // 自动调亮是否成功:成功了就不用再提示患者手动调亮。失败(部分设备/权限
  // 限制)保持 false,页面照常显示二维码,退回原来的手动提示文案。
  bool _brightnessBoosted = false;

  @override
  void initState() {
    super.initState();
    _generate();
    _boostBrightness();
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

  /// 出码 = 先把完整病历(含原件)加密传上瞬时云,再把 `q2.<id>.<密钥>` 编成码。
  ///
  /// 上传要花几秒到几十秒,取决于原件多少 —— 这段时间医患本来就在说话,进度条是
  /// 为了让病人知道还要多久,而不是干等一个转圈。
  ///
  /// **失败就是失败,不给一个残缺的码。** 医生扫到一个打不开的码,比病人当场知道
  /// 「没传上、再试一次」糟糕得多 —— 前者浪费的是诊室里那几分钟。
  Future<void> _generate() async {
    try {
      setState(() {
        _error = null;
        _degraded = false;
        _stage = '正在准备病历…';
        _progress = null;
      });
      final (blob, keyB64, recordCount) = await qrShareBlob(expiresDays: 15);

      if (!mounted) return;
      setState(() {
        _stage = '正在上传(${_mb(blob.length)})…';
        _progress = 0;
      });

      String? id;
      try {
        id = await ClaimStorage().upload(
          blob,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        );
      } catch (_) {
        // **传不上去也要给码。** 医院信号差、桶抽风、欠费——任何一样都会让病人
        // 在医生面前拿不出东西。退回「只带摘要」的旧码(载荷内嵌、不需要联网),
        // 并在界面上如实说明这次没带原件。正常路径一个字不改。
        id = null;
      }

      if (id == null) {
        final fallback = await buildQrShareUrl(baseUrl: _viewerBase);
        if (!mounted) return;
        setState(() {
          _stage = null;
          _progress = null;
          _degraded = true;
          _url = fallback.url;
          _problemCount = fallback.problemCount;
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _stage = null;
        _progress = null;
        _url = '$_viewerBase#q2.$id.$keyB64';
        _recordCount = recordCount.toInt();
      });
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

  static String _mb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('给医生看'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(child: Center(child: _body())),
    );
  }

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
              Text('${(_progress! * 100).round()}%',
                  style: const TextStyle(color: MedMe.faint, fontSize: 12)),
            ],
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        children: [
          const Text(
            '请医生扫这个码',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            // 自动调亮成功了就别再让患者做一遍已经做了的事。
            _brightnessBoosted ? '对着医生的手机相机' : '把屏幕亮度调高,对着医生的手机相机',
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
          const SizedBox(height: 18),
          _summaryChip(),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: MedMe.tealSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '医生看到的是什么',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
                SizedBox(height: 6),
                Text(
                  _degraded
                      ? '当前在治的疾病、关键指标趋势、正在吃的药。'
                      '这次没能上传,所以不含原件 —— 医生要看原件,请当场用手机翻给他。'
                      : '你的完整病历:在治的疾病、化验趋势、正在吃的药,以及每一份原件。',
                  style: const TextStyle(fontSize: 12.5, height: 1.6, color: MedMe.ink),
                ),
                const SizedBox(height: 10),
                Text(
                  _degraded
                      ? '这张码就是钥匙:被拍下就等于把这份摘要给了对方,看完收起手机即可。'
                      '这次的内容全在码里,没有上传到任何地方。'
                      : '这张码就是钥匙:被拍下就等于把这份病历给了对方,看完收起手机即可。'
                      '内容已加密临时存放,保留期结束后自动删除 —— 密钥只在这张码里,我们解不开。',
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
