import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 「一条链接 → 摆成一张码,旁边给复制和分享」。
///
/// **两条路共用**:代拍交付的取件码(`doctor_claim_link_dialog.dart`)、以及
/// 「把这份病历交给他」的转移链接(`account_screen.dart` 的 B5)。抽出来之前
/// 只有前者有这套展示,后者要么重写一遍、要么只给一行纯文本链接 —— 而收链接的
/// 人常常是"手机递过来,你扫一下"这种场景,码比链接管用。
///
/// 为什么既给码又给链接:对方没微信、加不上好友、不会收文件时,**用任何相机拍一下**
/// 就带走了,不需要建立任何传输通道;能用微信/短信的人则走复制/分享。
Future<void> showLinkQrDialog(
  BuildContext context, {
  required String title,
  required String url,

  /// 码上方那段说明:这是什么、对方该做什么。
  required String body,

  /// 码下方那段小字:有效期、谁能打开。
  String? footnote,

  /// 系统分享面板的主题行。
  String shareSubject = '',

  /// 分享按钮的文字(代拍那条是「发给病人」)。
  String shareLabel = '分享',

  /// iPad 上系统分享面板的锚点。拿不到就不给(`share_plus` 接受 null)。
  Rect Function()? shareOrigin,

  /// 主按钮颜色。代拍模式传紫色,个人模式不传(走主题默认)。
  Color? accent,

  /// 复制成功后那句 SnackBar。代拍那条路原本是「链接已复制,可以发给病人」——
  /// 抽取这个对话框时它退化成了通用的「链接已复制」(评审 Minor 18),做成参数
  /// 传回去,而不是默默丢掉一句已经写好的话。
  String copiedMessage = '链接已复制',

  /// R27(mockup `s14`「替病人代拍」的 `.hero`):码 + 说明 + 脚注整块包进一张
  /// `HeroCard`,「复制链接」换成 `MedSecondaryButton`(mockup `.btn.ghost`)。
  /// **只有代拍那条调用方传 `true`**——`account_screen.dart`/
  /// `member_detail_screen.dart` 的「交给他」还没轮到 Stage 3,不能被这里的
  /// 改动捎带着变(那两条路的品牌渐变预算至今是 0)。
  bool hero = false,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) {
      final c = MedColors.of(context);

      // **不 await 那次写剪贴板**(同仓库里其它复制按钮的一贯写法,比如
      // 恢复码那颗)。`Clipboard.setData` 在 `flutter test` 里压根不会
      // resolve(没有 `flutter/platform` 的处理者,它就那么吊着),于是
      // `await` 一写,SnackBar 在测试里永远出不来 —— 那句文案也就永远
      // 没人钉得住,而它正是评审 Minor 18 丢掉过一次的东西。
      // 真机上这次写入不会失败,代价可以忽略。
      void copyLink() {
        Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          appSnackBar(content: Text(copiedMessage)),
        );
      }

      final qr = Center(
        child: MedQrFrame(
          // **这个 `SizedBox` 不是多余的。** `QrImageView` 内部是
          // `LayoutBuilder`,而 `AlertDialog` 会向内容要固有高度
          // (intrinsic height)—— `LayoutBuilder` 不支持那件事,于是
          // 在 `flutter test` 里 pump 这个对话框会直接断言失败
          // ("LayoutBuilder does not support returning intrinsic
          // dimensions")。一个**紧约束**的 `SizedBox` 在
          // `RenderConstrainedBox.computeMaxIntrinsicHeight` 里走
          // `hasTightHeight` 那条短路,压根不去问孩子,链条就断在这儿。
          // 这也是它本来就该有的布局:码的边长是定的(220),不需要测量内容。
          child: SizedBox(
            width: 220,
            height: 220,
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
      );

      // mockup `s14`「替病人代拍」的 `.hero`:说明 + 码 + 脚注这一整块。`hero`
      // 为真时文字换白字系 token(HeroCard 全卡白字的确定性规则),`hero` 为假
      // 时(个人模式「交给他」)颜色与结构原样不变。
      final block = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            body,
            style: MedType.body.copyWith(color: hero ? c.onDarkMeta : c.ink2, height: 1.5),
          ),
          const SizedBox(height: MedShape.s2),
          qr,
          if (footnote != null) ...[
            const SizedBox(height: MedShape.s2),
            Text(
              footnote,
              style: MedType.secondary.copyWith(color: hero ? c.onDarkFaint : c.ink3, height: 1.5),
            ),
          ],
        ],
      );

      // mockup `.btn.ghost`「再拍几张」——这个对话框里唯一的 outline/ghost 形状
      // 按钮是「复制链接」,`hero` 为真时换成 `MedSecondaryButton`。
      final copyButton = hero
          ? MedSecondaryButton(label: '复制链接', icon: Icons.link, onPressed: copyLink)
          : OutlinedButton.icon(
              onPressed: copyLink,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('复制链接'),
            );

      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              hero ? HeroCard(child: block) : block,
              const SizedBox(height: MedShape.s2),
              copyButton,
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
          FilledButton.icon(
            style: accent == null ? null : FilledButton.styleFrom(backgroundColor: accent),
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                text: url,
                subject: shareSubject,
                sharePositionOrigin: shareOrigin?.call(),
              ),
            ),
            icon: const Icon(Icons.ios_share, size: 18),
            label: Text(shareLabel),
          ),
        ],
      );
    },
  );
}
