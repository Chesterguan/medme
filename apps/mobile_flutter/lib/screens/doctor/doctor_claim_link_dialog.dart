import 'package:flutter/material.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart' show Profile;
import 'package:mobile_flutter/widgets/link_qr_dialog.dart';

/// 决定这个对话框最终该显示哪条链接:登录且传入了已开通云端备份的档案时,尝试
/// 换成一条 `role=owner` 的转移邀请;没登录、没传档案、或者换取失败,一律用
/// [fallbackUrl](调用方原来就准备好的那条,一直有效)。**永不返回空/坏链接**——
/// 转移失败不该让医生对着一个没法用的码交差。
@visibleForTesting
Future<String> resolveDoctorClaimUrl({
  required String fallbackUrl,
  required bool loggedIn,
  required Profile? cloudProfile,
  required Grants grants,
}) async {
  if (!loggedIn || cloudProfile?.cloudId == null) return fallbackUrl;
  try {
    final link = await grants.inviteTransfer(cloudProfile!);
    return link.toUrl();
  } catch (_) {
    return fallbackUrl;
  }
}

/// 代拍交付成功后的结果:**一条认领链接,直接显示成二维码**。
///
/// 为什么是二维码而不是「发文件」:代拍面对的病人常常没有微信、加不上好友、也不会
/// 收文件。屏幕上摆一张码,他自己或家人**用任何相机拍一下**就带走了 —— 不需要建立
/// 任何传输通道。旁边再给一条可复制的链接,方便能用微信/短信的人。
///
/// 与「病人自己出码给医生看」(`qr_share_screen.dart`)方向相反:那是给医生**当场看**,
/// 这是给病人**带走**。所以这里必须给可复制的链接,那边不需要。
///
/// [cloudProfile] 有值(且医生已登录)时,认领链接改发一条 `role=owner` 的授权
/// 邀请——这是一次真正的所有权转移(服务端在兑换时把老 owner 自动降成
/// editor),不再是"密文躺在瞬时云、谁截到钥匙谁能看"那种链接。调用方目前还没有
/// 任何一条路径会把已开通云端备份的代拍档案传进来(那需要先把代拍病人的临时病历箱
/// 注册成云档案,是另一块尚未接线的工作),所以这个分支眼下是**前向兼容但还没被
/// 触发**——保留 `cloudProfile` 为 null 时,行为与改动前逐字节一致。
///
/// [grants] 是测试注入点,默认为 null——真正用的时候现取现建。`Grants.inviteTransfer`
/// 碰真实 Rust 原生库,`flutter test` 传一个假实现进来测"转移失败要不要正确回退"。
///
/// 决定最终显示哪条链接的逻辑抽成 [resolveDoctorClaimUrl]——纯粹是异步计算,
/// 不碰 `BuildContext`/Widget 树,方便单独测试(`AlertDialog` 内嵌 `QrImageView`
/// 用了 `LayoutBuilder`,在 `flutter test` 里 pump 这个对话框会踩一个已知的
/// Flutter 渲染坑("intrinsic dimensions"),与本文件的逻辑无关,见
/// `test/doctor_claim_link_dialog_test.dart` 顶部说明)。
Future<void> showDoctorClaimLinkDialog(
  BuildContext context,
  String url,
  int recordCount, {
  required Rect Function() shareOrigin,
  Profile? cloudProfile,
  Grants? grants,
}) async {
  if (!context.mounted) return;
  final resolvedUrl = await resolveDoctorClaimUrl(
    fallbackUrl: url,
    loggedIn: AccountSession.instance.loggedIn.value,
    cloudProfile: cloudProfile,
    grants: grants ??
        Grants(
          ApiClient.forSession(AccountSession.instance),
          AccountSession.instance,
        ),
  );
  if (!context.mounted) return;
  // 展示本身(码 + 复制 + 分享)共用 `showLinkQrDialog` —— 「转为主人」那条路
  // (`account_screen.dart` 的 B5)要的是同一套东西,不该重写一遍。
  await showLinkQrDialog(
    context,
    title: '好了,请病人扫这个码',
    url: resolvedUrl,
    body: '共 $recordCount 份记录。请病人本人(或家人)用手机相机拍下这个码,带走后随时能看。',
    footnote: '只有拿到这个码的人能打开,医生和我们都看不到里面的内容。15 天后自动失效。',
    shareSubject: '你的病历',
    shareLabel: '发给病人',
    copiedMessage: '链接已复制,可以发给病人',
    shareOrigin: shareOrigin,
    accent: MedColors.of(context).proxy,
  );
}
