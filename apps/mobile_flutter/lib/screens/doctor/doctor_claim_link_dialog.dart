import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:mobile_flutter/theme.dart';

/// 代拍交付成功后的结果:**一条认领链接,直接显示成二维码**。
///
/// 为什么是二维码而不是「发文件」:代拍面对的病人常常没有微信、加不上好友、也不会
/// 收文件。屏幕上摆一张码,他自己或家属**用任何相机拍一下**就带走了 —— 不需要建立
/// 任何传输通道。旁边再给一条可复制的链接,方便能用微信/短信的人。
///
/// 与「病人自己出码给医生看」(`qr_share_screen.dart`)方向相反:那是给医生**当场看**,
/// 这是给病人**带走**。所以这里必须给可复制的链接,那边不需要。
Future<void> showDoctorClaimLinkDialog(
  BuildContext context,
  String url,
  int recordCount, {
  required Rect Function() shareOrigin,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('好了,请病人扫这个码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '共 $recordCount 份记录。请病人本人(或家属)用手机相机拍下这个码,'
              '带走后随时能看。',
              style: const TextStyle(fontSize: 13.5, color: MedMe.faint, height: 1.5),
            ),
            const SizedBox(height: 14),
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: MedMe.line),
                ),
                child: QrImageView(
                  data: url,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '只有拿到这个码的人能打开,医生和我们都看不到里面的内容。'
              '15 天后自动失效。',
              style: TextStyle(fontSize: 12.5, color: MedMe.faint, height: 1.5),
            ),
            const SizedBox(height: 14),
            // 能用微信/短信的病人走这条:复制链接直接发。
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('链接已复制,可以发给病人')),
                  );
                }
              },
              icon: const Icon(Icons.link, size: 18),
              label: const Text('复制链接'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: MedMe.proxyOrange),
          onPressed: () => SharePlus.instance.share(
            ShareParams(
              text: url,
              subject: '你的病历',
              sharePositionOrigin: shareOrigin(),
            ),
          ),
          icon: const Icon(Icons.ios_share, size: 18),
          label: const Text('发给病人'),
        ),
      ],
    ),
  );
}
