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
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

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

/// 记「问过了」。**两处调用**:[showCloudExtractAskSheet] 本身,以及
/// `account_screen.dart` 的 `_cloudExtractSwitch`——用户在账号屏手动拨这个开关
/// 时(不管拨成开还是关)也算做过一次明确选择,必须一起置真,否则会出现「开关
/// 已经拨成开,副标题却还在说『第一次添加病历时会问你』」的自相矛盾界面,而且
/// 下一次 `runImport` 里的 `shouldAskCloudExtract` 还会再弹一次 ask sheet,把用户
/// 刚拨的选择覆盖掉(task-20b 复核 Important)。
Future<void> saveCloudExtractAsked() async {
  try {
    await (await SharedPreferences.getInstance()).setBool(cloudExtractAskedKey, true);
  } catch (_) {}
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
  await saveCloudExtractAsked();
}

/// sheet 的内容主体。**纯 widget,不碰 prefs** —— 这样 `flutter test` 测得到。
///
/// Stage 3(task-14):两颗按钮换成 `MedPrimaryButton`/`MedSecondaryButton`
/// (s17 渐变预算 = 1 颗主按钮)。**顺序照现有代码**——「不开」在左、
/// 「开,帮我整理」在右;mockup `s17` 画的是反过来的左右,但调换按钮位置是
/// 结构改动,越了 Stage 3 的界,这里不跟(记在 task-14-report.md)。决定权重
/// 仍然只在用户读完这句话之后自己按:两颗按钮点击行为不变,「开,帮我整理」
/// 只是视觉上多一点重量(brief 明确点名的那颗主按钮),不是预设的默认答案。
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
            style: MedType.subtitle,
          ),
          const SizedBox(height: 12),
          Text(
            '开了以后,每次添加的病历照片会先在手机上把姓名、证件号、医院名涂黑,'
            '再送到云端整理成表格。不开就只用手机自己识别,能认出来的字段少一点。'
            '以后在「我 → 云端」随时改。',
            style: MedType.body.copyWith(fontSize: 15, height: 1.6),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: MedSecondaryButton(
                  label: '不开',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MedPrimaryButton(
                  label: '开,帮我整理',
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
