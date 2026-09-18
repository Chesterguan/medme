import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/link_qr_dialog.dart';

/// 代拍交付成功后的结果:**一条取件链接,直接显示成二维码**。
///
/// 为什么是二维码而不是「发文件」:代拍面对的病人常常没有微信、加不上好友、也不会
/// 收文件。屏幕上摆一张码,他自己或家人**用任何相机拍一下**就带走了 —— 不需要建立
/// 任何传输通道。旁边再给一条可复制的链接,方便能用微信/短信的人。
///
/// 与「病人自己出码给医生看」(`qr_share_screen.dart`)方向相反:那是给医生**当场看**,
/// 这是给病人**带走**。所以这里必须给可复制的链接,那边不需要。
///
/// **代拍永远只出取件码这一条路。** 这里曾经有一条 `cloudProfile` 分支,想在医生
/// 已登录、且代拍档案已开通云端备份时改发 `role=owner` 的转移邀请 —— 但「把代拍
/// 病人的临时病历箱注册成云档案」那一步从来没接线,所以没有任何调用方会传那个
/// 参数,分支一次都没跑过。删掉:没跑过的分支不是前向兼容,是一份读者每次都要
/// 重新判断「这条到底走不走」的负担。
Future<void> showDoctorClaimLinkDialog(
  BuildContext context,
  String url,
  int recordCount, {
  required Rect Function() shareOrigin,
}) async {
  if (!context.mounted) return;
  // 展示本身(码 + 复制 + 分享)共用 `showLinkQrDialog` —— 「交给他」那条路
  // (`account_screen.dart` 的 B5)要的是同一套东西,不该重写一遍。
  await showLinkQrDialog(
    context,
    title: '好了,请病人扫这个码',
    url: url,
    body: '共 $recordCount 份记录。请病人本人(或家人)用手机相机拍下这个码,带走后随时能看。',
    footnote: '只有拿到这个码的人能打开,医生和我们都看不到里面的内容。15 天后自动失效。',
    shareSubject: '你的病历',
    shareLabel: '发给病人',
    copiedMessage: '链接已复制,可以发给病人',
    shareOrigin: shareOrigin,
    accent: MedColors.of(context).proxy,
  );
}
