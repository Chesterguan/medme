import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:mobile_flutter/theme.dart';

/// 扫一张二维码,返回它的内容(取消/扫不到返回 null)。
///
/// 全仓唯一一处**读**码的地方(`qr_flutter` 只会画码),目前唯一的调用方是「旧手机
/// 扫码批准新设备」。所以这里只做最小的一件事:开相机、认出第一张码、立刻关掉 ——
/// 不连续扫、不做历史、不加手电筒/相册选图那些还没有人要的东西。
///
/// 相机本身的权限提示由系统弹(iOS `NSCameraUsageDescription` 已覆盖),拒绝之后
/// `MobileScanner` 自己会渲染一块错误区域,这里把它换成一句人话加一颗「返回」。
Future<String?> scanQrCode(BuildContext context) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(builder: (_) => const _QrScannerScreen()),
);

class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);

  /// 认出一张就够了。**这个标记是必需的**:`onDetect` 在同一帧里可能连报好几次,
  /// 不挡住就会 `pop` 两次(第二次把调用方的那一屏也弹掉)。
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .where((v) => v != null && v.isNotEmpty)
        .firstOrNull;
    if (raw == null) return;
    _done = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫码')),
    body: Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '打不开相机($error)。请在系统设置里允许 MedMe 使用相机,'
                '或者改用口令/恢复码那条路。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: MedMe.faint, height: 1.6),
              ),
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: Text(
            '对准新手机屏幕上那张码',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
