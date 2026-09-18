// 第一次添加病历时问一次「云端整理」(ia-proposal §7 决定 5,创始人拍板)。
//
// 为什么不是默认开:默认开省一次点击,但 App Store 描述、`Info.plist`、隐私政策
// 三处都要写「照片会送云端」—— 有一次明确同意,这三处才站得住(CLAUDE.md 硬规矩 4)。
//
// 为什么在第一次添加时问、不在登录时问:登录那一刻用户脑子里是「我要备份」,
// 云端整理跟备份不是一件事;而第一次添加病历时,他刚刚交出去的就是那张照片。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/cloud_extract.dart';

/// 这次该不该问。纯判断,方便单测。
///
/// 没登录不问:没有账号就没有云端,云端整理根本跑不起来(见 `cloud_extract.dart`
/// 的 `runCloudExtraction`,未登录一律静默退回本地正则)。
bool shouldAskCloudExtract({required bool loggedIn, required bool asked}) =>
    loggedIn && !asked;

Future<bool> loadCloudExtractAsked() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(cloudExtractAskedKey) ?? false;
  } catch (_) {
    // 读不到就当问过 —— 宁可少问一次,也不要每次导入都弹。
    return true;
  }
}

/// 问一次,把答案和「问过了」一起写下去。
///
/// `isDismissible: false`/`enableDrag: false` 挡掉点外面、下滑两条路;系统返回
/// 手势仍可能绕过它们关掉 sheet(路由被 pop 但没经过任何一颗按钮)——那种情况
/// `showModalBottomSheet` 返回 `null`,`on ?? false` 按「不开」记。两种「没有明确
/// 同意」的退出路径(下滑、系统返回)因此归到同一个结果:算「先不开」,也算问过,
/// 不会再被追问。写「问过了」这一步**不看 [on] 是什么**,任何退出路径都执行。
Future<void> showCloudExtractAskSheet(BuildContext context) async {
  final on = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const SafeArea(child: CloudExtractAskBody()),
  );
  await saveCloudExtractEnabled(on ?? false);
  try {
    await (await SharedPreferences.getInstance()).setBool(cloudExtractAskedKey, true);
  } catch (_) {}
}

/// sheet 的内容主体。**纯 widget,不碰 prefs** —— 这样 `flutter test` 测得到。
/// 两颗按钮都用 `FilledButton`:**默认值不预设**,不给任何一边额外的视觉权重。
class CloudExtractAskBody extends StatelessWidget {
  const CloudExtractAskBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            // 下面这三段逐字照 mockup `s17`,改字 = 改对外说法,要同步隐私政策。
            '要不要让云端帮你整理?',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          const Text(
            '开了以后,每次添加的单子会先在手机上把名字、证件号、医院名涂黑,'
            '再送到云端整理成表格。不开就只用手机自己识别,能认出来的字段少一点。'
            '以后在「我 → 云端」随时改。',
            style: TextStyle(height: 1.6),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('不开'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('开,帮我整理'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
