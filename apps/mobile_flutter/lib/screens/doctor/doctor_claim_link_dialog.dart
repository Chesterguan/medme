import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart' show Profile;
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 代拍交付成功后的结果:**一条认领链接,直接显示成二维码**。
///
/// 为什么是二维码而不是「发文件」:代拍面对的病人常常没有微信、加不上好友、也不会
/// 收文件。屏幕上摆一张码,他自己或家属**用任何相机拍一下**就带走了 —— 不需要建立
/// 任何传输通道。旁边再给一条可复制的链接,方便能用微信/短信的人。
///
/// 与「病人自己出码给医生看」(`qr_share_screen.dart`)方向相反:那是给医生**当场看**,
/// 这是给病人**带走**。所以这里必须给可复制的链接,那边不需要。
///
/// [cloudProfile] 有值(且医生已登录)时,认领链接改发一条 `role=owner` 的授权
/// 邀请——这是一次真正的所有权转移(服务端在兑换时把老 owner 自动降成
/// editor),不再是"密文躺在瞬时云、谁截到密钥谁能看"那种链接。调用方目前还没有
/// 任何一条路径会把已开通云同步的代拍档案传进来(那需要先把代拍病人的临时保险箱
/// 注册成云档案,是另一块尚未接线的工作),所以这个分支眼下是**前向兼容但还没被
/// 触发**——保留 `cloudProfile` 为 null 时,行为与改动前逐字节一致。
Future<void> showDoctorClaimLinkDialog(
  BuildContext context,
  String url,
  int recordCount, {
  required Rect Function() shareOrigin,
  Profile? cloudProfile,
}) async {
  if (!context.mounted) return;
  if (AccountSession.instance.loggedIn.value && cloudProfile?.cloudId != null) {
    try {
      final link = await Grants(
        ApiClient(bearer: () async => AccountSession.instance.access),
        AccountSession.instance,
      ).inviteTransfer(cloudProfile!);
      url = link.toUrl();
    } catch (_) {
      // 转移链接生成失败:退回调用方传来的原始链接,不让医生空手——那条链接
      // 依旧有效,只是这一次不是所有权转移。
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) {
      final c = MedColors.of(context);
      return AlertDialog(
        title: const Text('好了,请病人扫这个码'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '共 $recordCount 份记录。请病人本人(或家属)用手机相机拍下这个码,'
                '带走后随时能看。',
                style: MedType.body.copyWith(color: c.ink2, height: 1.5),
              ),
              const SizedBox(height: MedShape.s2),
              Center(
                child: Container(
                  // 码本身**不上主题**:白底黑码是相机能扫的前提,深色主题也不能动。
                  padding: const EdgeInsets.all(MedShape.s1),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(MedShape.radiusBlock),
                    border: Border.all(color: c.line),
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
              const SizedBox(height: MedShape.s2),
              Text(
                '只有拿到这个码的人能打开,医生和我们都看不到里面的内容。'
                '15 天后自动失效。',
                style: MedType.secondary.copyWith(color: c.ink3, height: 1.5),
              ),
              const SizedBox(height: MedShape.s2),
              // 能用微信/短信的病人走这条:复制链接直接发。
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      appSnackBar(content: Text('链接已复制,可以发给病人')),
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
            style: FilledButton.styleFrom(backgroundColor: c.proxy),
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
      );
    },
  );
}
