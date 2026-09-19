// 第一次出码前告知一次(创始人拍板)。
//
// 这条取代了「未登录不给出码」那个方案:诊室里那 30 秒是这个产品的全部价值,
// 用一道登录墙挡住它,代价比收益大。而「用户不知道发生了什么」这件事,一句话
// 就够,不需要一道墙。
//
// ⚠️ 那句话是**对外承诺**,与隐私政策第三节第 3 项(二维码中转)说的是同一件事。
// 改这里的文案 = 改对外说法,必须同步去看 `gh-pages` 的 `privacy.html`
// (CLAUDE.md 硬规矩 4)。`test/qr_notice_test.dart` 按逐字钉住它。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';

/// 逐字文案。**单独拎成常量**,让测试和这一屏引用同一份字符串 —— 两处各写一遍,
/// 改一处忘一处时测试反而是绿的。
const kQrNoticeText = '会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看;我们打不开。';

/// 这次该不该说。纯判断,方便单测。**不看登录状态** —— 登录与否都照常出码。
bool shouldShowQrNotice({required bool seen}) => !seen;

Future<bool> loadQrNoticeSeen() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(qrNoticeSeenKey) ?? false;
  } catch (_) {
    // 读不到就当说过 —— 宁可少说一次,也不要每次出码都弹一张挡在医生面前的纸。
    return true;
  }
}

/// 说一次,并记下「说过了」。返回**要不要继续出码**。
///
/// 「先不出」也记 seen:他已经看过这句话了,再问一遍只是烦人。
Future<bool> showQrNoticeSheet(BuildContext context) async {
  final go = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const SafeArea(child: QrNoticeBody()),
  );
  try {
    await (await SharedPreferences.getInstance()).setBool(qrNoticeSeenKey, true);
  } catch (_) {}
  return go ?? false;
}

/// sheet 的内容主体。**纯 widget,不碰 prefs** —— 这样 `flutter test` 测得到。
class QrNoticeBody extends StatelessWidget {
  const QrNoticeBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            // `s13` 逐字。
            '第一次出码,说一句',
            style: MedType.subtitle,
          ),
          const SizedBox(height: 12),
          Text(kQrNoticeText, style: MedType.body.copyWith(fontSize: 15, height: 1.6)),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: MedSecondaryButton(
                  label: '先不出',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MedPrimaryButton(
                  label: '好,出码',
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
