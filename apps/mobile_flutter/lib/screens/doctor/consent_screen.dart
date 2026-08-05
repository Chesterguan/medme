import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 同意告知文案的版本号。文案改了就升这个号——落进加密包(`ConsentDto.consentTextVersion`),
/// 便于日后区分「病人是在哪版文案下同意的」。
const String kConsentTextVersion = 'v1';

/// 拍前同意大屏(医生代拍病人纸质材料流程的**第一屏、任何采集之前**)。大字白话
/// 告知:拍什么 · 为什么 · 给谁 · 存多久 · 我们解不开 · 你能删能撤。病人签名确认;
/// 签不了字时「按住 3 秒确认」兜底(画押式手势,不用写字)。
///
/// 产出 [ConsentDto] 经 [onAgreed] 交给外层流程——本屏自己不碰 Rust FFI,只负责
/// 采集「谁、以何种方式、何时同意」这一件事。
///
/// ⚠️ **这是法务文案屏,一个字都不改。** 文案变了要升 [kConsentTextVersion]。视觉
/// 上走设计系统令牌:强调色是医生模式的 `proxy`(紫),正文字号从 13.5 提到 15
/// (`MedType.body`)—— 读这一屏的是**病人**,常常是老人,而他要在这里签字。
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({
    super.key,
    required this.onAgreed,
    required this.onCancel,
  });

  final ValueChanged<ConsentDto> onAgreed;
  final VoidCallback onCancel;

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen>
    with SingleTickerProviderStateMixin {
  // 笔色写死浅色一套的 `ink`,不跟主题走:签名要导出成**白底 PNG** 落进加密包
  // (`exportBackgroundColor: white`),深色主题下的浅墨色画在白底上等于没签。
  late final SignatureController _sigController = SignatureController(
    penStrokeWidth: 3,
    penColor: MedColors.light.ink,
    exportBackgroundColor: Colors.white,
  );
  late final AnimationController _holdController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  // 本次代建档会话的人类可读标识(落进 ConsentDto.sessionId,供医生/病人事后核对
  // 「哪一次代拍」;不是安全边界——临时会话本身的随机 device_id 才是,见
  // `rust/src/api/vault_ephemeral.rs`)。
  late final String _sessionId =
      'sess-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0xFFFFFF).toRadixString(16)}';

  bool _useSignature = true;
  bool _submitting = false;
  // 一次性开关,与 `_submitting`(签名提交中的 UI 忙态)分开:签名按钮已被
  // `_submitting` 挡了重复点击,但按住确认手势没有——若用户在签名提交的 await
  // 期间又按住满 3 秒,会触发第二次 `onAgreed` → 第二次开始会话,把第一个(空)
  // 会话晾在那儿。两条路径都先查这个再往下走,保证 onAgreed 全程只触发一次。
  bool _confirmed = false;

  @override
  void initState() {
    super.initState();
    _holdController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _emit(method: 'press_hold');
      }
    });
  }

  @override
  void dispose() {
    _sigController.dispose();
    _holdController.dispose();
    super.dispose();
  }

  Future<void> _confirmWithSignature() async {
    if (_sigController.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(appSnackBar(content: Text('请先在下方签名')));
      return;
    }
    setState(() => _submitting = true);
    final Uint8List? png = await _sigController.toPngBytes();
    if (!mounted) return;
    if (png == null) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(appSnackBar(content: Text('签名保存失败,请重试')));
      return;
    }
    _emit(method: 'signature', signaturePngBase64: base64Encode(png));
  }

  void _emit({required String method, String? signaturePngBase64}) {
    if (_confirmed) return; // 见字段声明处的说明:保证 onAgreed 全程只触发一次。
    _confirmed = true;
    widget.onAgreed(
      ConsentDto(
        utcTs: DateTime.now().toUtc().toIso8601String(),
        consentTextVersion: kConsentTextVersion,
        signaturePngBase64: signaturePngBase64,
        method: method,
        sessionId: _sessionId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 不是独立 Scaffold——composes 进 `ProxyIntakeFlow` 的 Scaffold(顶部常驻紫色
    // 横幅在外层,任何阶段都在),这里只是内容区。
    return ColoredBox(
      color: c.paper,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            MedShape.s4,
            MedShape.s3,
            MedShape.s4,
            MedShape.s5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.privacy_tip_outlined, color: c.proxy, size: 44),
              const SizedBox(height: MedShape.s2),
              Text(
                '在拍之前,请告诉对方这几件事',
                style: MedType.title.copyWith(color: c.ink),
              ),
              const SizedBox(height: MedShape.s3),
              const _ConsentPoint(
                icon: Icons.camera_alt_outlined,
                title: '拍什么',
                body: '拍您的化验单、处方、检查报告这些纸。',
              ),
              const _ConsentPoint(
                icon: Icons.favorite_border,
                title: '做什么用',
                body: '整理成一份电子病历,您以后看病、复查带着方便。',
              ),
              const _ConsentPoint(
                icon: Icons.person_outline,
                title: '交给谁',
                body: '当场给您一个码,您用手机拍下来带走;只交给您本人,不会自动发给别人。',
              ),
              const _ConsentPoint(
                icon: Icons.schedule_outlined,
                title: '在这台手机上存多久',
                body: '最多存 12 小时,方便医生给您写病历;超时后医生下次打开 App 时清掉。',
              ),
              const _ConsentPoint(
                icon: Icons.lock_outline,
                title: '谁能打开',
                body:
                    '只有拿到这个码的人能打开。医生和我们都看不到里面的内容。'
                    '这个码 15 天后自动失效。',
              ),
              const SizedBox(height: MedShape.s5),
              Divider(height: 1, color: c.line),
              const SizedBox(height: MedShape.s3),
              Text(
                _useSignature ? '请在下方签名确认' : '请按住下方按钮 3 秒确认',
                style: MedType.subtitle.copyWith(color: c.ink),
              ),
              const SizedBox(height: MedShape.s1),
              if (_useSignature) ...[
                Container(
                  height: 180,
                  // 签名板底色写死白:导出的 PNG 也是白底,画布和成品要一致。
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(MedShape.radiusBlock),
                    border: Border.all(color: c.line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Signature(
                    controller: _sigController,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => _sigController.clear(),
                      child: const Text('重签'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => setState(() => _useSignature = false),
                      child: const Text('不方便签名?'),
                    ),
                  ],
                ),
                const SizedBox(height: MedShape.s1),
                SizedBox(
                  height: 50,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: c.proxy),
                    onPressed: _submitting ? null : _confirmWithSignature,
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text('已签名,同意开始'),
                  ),
                ),
              ] else ...[
                Text(
                  '手指按住不放,进度环转满一圈即视为同意确认',
                  style: MedType.secondary.copyWith(color: c.ink2),
                ),
                const SizedBox(height: MedShape.s2),
                Center(
                  child: GestureDetector(
                    onTapDown: (_) => _holdController.forward(from: 0),
                    onTapCancel: () => _holdController.reverse(),
                    onTapUp: (_) => _holdController.reverse(),
                    child: AnimatedBuilder(
                      animation: _holdController,
                      builder: (context, child) => SizedBox(
                        width: 120,
                        height: 120,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 120,
                              height: 120,
                              child: CircularProgressIndicator(
                                value: _holdController.value,
                                strokeWidth: 8,
                                backgroundColor: c.line,
                                valueColor: AlwaysStoppedAnimation(c.proxy),
                              ),
                            ),
                            Text(
                              '按住\n确认',
                              textAlign: TextAlign.center,
                              style: MedType.body.copyWith(
                                fontWeight: FontWeight.w600,
                                color: c.proxyInk,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: MedShape.s2),
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _useSignature = true),
                    child: const Text('改用签名'),
                  ),
                ),
              ],
              const SizedBox(height: MedShape.s1),
              Center(
                child: TextButton(
                  onPressed: _submitting ? null : widget.onCancel,
                  child: Text('不同意,退出', style: TextStyle(color: c.ink3)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsentPoint extends StatelessWidget {
  const _ConsentPoint({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c.proxy, size: 22),
          const SizedBox(width: MedShape.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: MedType.subtitle.copyWith(color: c.ink)),
                const SizedBox(height: 2),
                // 正文从 13.5 提到 15(`body`),颜色从 faint 提到 ink2 —— 读这几行
                // 的是病人本人,读完要签字。这一屏没有「读不清也无所谓」的字。
                Text(
                  body,
                  style: MedType.body.copyWith(color: c.ink2, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
