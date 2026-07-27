import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;

import 'package:mobile_flutter/src/rust/api/vault.dart' as rust_vault;

/// 一张图片的 OCR 结果:识别文本 + 平均置信度(0~1)。
class OcrResult {
  final String text;
  final double confidence;
  const OcrResult(this.text, this.confidence);
}

/// 置信度拿不到时的兜底值(空文本/引擎不给),让导入流程照常继续。
const double _confFallback = 0.9;

/// iOS 原生文档预处理 channel(`medme/ocr` 的 `rectifyDocument`,见
/// `ios/Runner/AppDelegate.swift`)。复用「recognize」同一个 channel 名——两者
/// 都是 iOS-only 的 Vision/Core Image 原生桥,不是识别文字,只处理画面。
const MethodChannel _iosOcrChannel = MethodChannel('medme/ocr');

/// 识别一张图片里的文字。
///
/// **iOS + 安卓都走 PP-OCRv5**(经 FRB `recognize_image_pp`,`packages/ocr` 的
/// `engine` 路径,走 `apps/mobile_flutter/rust/ocr-models/` 里编译进二进制的模型;
/// 高图纵向切片见 `packages/ocr` 的 `predict_lines`)。iOS 已合入 main(ADR 0006
/// 采纳);安卓侧 feat/android-pp-ocr —— 用户反馈 ML Kit 中文识别质量不够,拍板
/// 换成和 iOS 同引擎同模型。
/// - **iOS**:喂 PP 之前先经 `medme/ocr` 的「rectifyDocument」case 做一遍原生文档
///   检测+拉正+裁(见 [_rectifyDocument],`VNDetectDocumentSegmentation`,iOS-only)。
/// - **安卓**:没有那个原生 channel,跳过 rectify 直接喂 PP(相机采集本身走系统
///   文档扫描器已拉正;导入图不经 rectify)。
///
/// 早先留过一条 ML Kit 中文识别的回退路径,但它**不可达** —— 上面的 iOS/安卓分支
/// try 成功即返回、catch 也返回,永远走不到;而这个 app 只发 iOS/安卓。它带来的
/// 13 MB(so 11.1 + 中文模型 1.9)因此是纯死重,已随依赖一并删除。要真正的双引擎
/// 回退是另做一件事(得让 PP 失败时能接上),不是留着这些字节。
///
/// 返回 [OcrResult];引擎/路径异常时降级为空文本(上层据此走「仅存原件」),不抛。
Future<OcrResult> recognizeImageText(String path) async {
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      final original = await File(path).readAsBytes();
      // rectify 是 iOS 原生 Vision/Core Image 桥,安卓没有这个 channel,跳过。
      final bytes = Platform.isIOS
          ? await _rectifyDocument(path, original)
          : original;
      final res = await rust_vault.recognizeImagePp(bytes: bytes);
      return OcrResult(res.text, res.confidence);
    } catch (_) {
      return const OcrResult('', _confFallback);
    }
  }
  // 其它平台:这支 app 只发 iOS/安卓,走到这里说明是开发期的桌面调试。返回空文本
  // 让导入流程照常继续(上层走「仅存原件·未识别到文字」),不抛。
  return const OcrResult('', _confFallback);
}

/// 导入图在喂 PP-OCR 之前先过原生文档检测+透视拉正+裁+轻度增强(和相机走的系统
/// 文档扫描器同源,`VNDetectDocumentSegmentationRequest` + `CIPerspectiveCorrection`,
/// 见 `AppDelegate.swift` 的 `rectifyDocument(atPath:)`)。拍照本身走文档扫描器
/// 所以识别好;导入的原图没有这一步,直接喂 PP 识别差——这里把两条路径拉齐。
///
/// 原生侧检测不到文档/失败时已经回退返回原图字节;这里再兜一层——channel 调用本身
/// 失败(如返回 null/空字节)也回退到调用方已经读到的 [original] 字节,绝不让识别
/// 效果比现在差。
Future<Uint8List> _rectifyDocument(String path, Uint8List original) async {
  try {
    final result = await _iosOcrChannel.invokeMethod<Uint8List>(
      'rectifyDocument',
      {'path': path},
    );
    return (result != null && result.isNotEmpty) ? result : original;
  } catch (_) {
    return original;
  }
}
