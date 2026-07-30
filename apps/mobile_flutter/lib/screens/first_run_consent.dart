import 'package:flutter/material.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_boot.dart' show vaultOpenedOkThisLaunch;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// 首次启动的告知与同意。**这是合规要求,不是引导流程。**
///
/// 一个带「医」字的 App,在用户交出任何病历之前必须先把几件事说清楚:这是什么、
/// 不是什么(不是医疗器械、不做诊断)、数据去哪、我们能看到什么。国内应用商店与
/// 《个人信息保护法》都要求首次启动以显著方式告知并取得同意,不能藏在设置里事后补。
///
/// 一个声明、一个按钮。匿名使用统计在声明里写明,随同意一并开启;
/// 不想要的人在「设置 → 帮助改进 MedMe」里随时关。
class FirstRunConsent {
  FirstRunConsent._();

  static const _prefAgreed = 'consent_agreed_v1';

  /// 是否已经同意过。版本号在键里:将来协议有实质变更时改成 `_v2`,会重新征求同意。
  static Future<bool> hasAgreed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefAgreed) ?? false;
    } catch (_) {
      // 读不到就当没同意过 —— 多问一次,好过在没同意的情况下继续。
      return false;
    }
  }

  static Future<void> markAgreed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAgreed, true);
    } catch (_) {}
  }
}

class FirstRunConsentScreen extends StatefulWidget {
  const FirstRunConsentScreen({super.key, required this.onAgreed});

  /// 用户同意之后调。调用方据此切到正常界面。
  final VoidCallback onAgreed;

  @override
  State<FirstRunConsentScreen> createState() => _FirstRunConsentScreenState();
}

class _FirstRunConsentScreenState extends State<FirstRunConsentScreen> {
  bool _busy = false;

  Future<void> _agree() async {
    setState(() => _busy = true);
    await FirstRunConsent.markAgreed();
    // 匿名统计随同意一并开启 —— 声明里已写明采什么,设置里随时可关。
    if (Analytics.isConfigured) {
      await Analytics.setEnabled(true);
      await Analytics.markAsked();
      // 补一条 `app_open`:本次启动的那条发在同意门之前,那时统计还是关的,被丢了。
      // 不补的话**首次运行永远看不到**,而那恰恰是最想看的一次(装完到第一次用)。
      //
      // ⚠️ `vault_ok` 必须读本次启动的真实结果。这里曾硬编码 `true` ——
      // 于是首启开箱失败在数据里也是「好的」,而 `app_open × vault_ok` 那张图正是
      // 为了看见开箱失败才建的,首启这一档因此永远偏乐观。
      Analytics.track(AnalyticsEvent.appOpen, {
        'vault_ok': vaultOpenedOkThisLaunch,
      });
    }
    widget.onAgreed();
  }

  /// 不同意。**不调 `exit(0)`** —— 苹果明确不建议 App 自行退出,那是拒审理由。
  /// 停在本屏,并说清楚为什么。
  Future<void> _decline() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('需要你的同意才能使用'),
      content: const Text(
        'MedMe 会把你的病历保存在这台手机上。在你同意之前,我们不会创建任何档案。\n\n'
        '如果不同意,请直接关闭 App。',
        style: TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('再看看'),
        ),
      ],
    ),
  );

  Future<void> _open(String path) => launchUrl(
    Uri.parse('https://medmenow.com/$path'),
    mode: LaunchMode.externalApplication,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MedMe.bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.asset(
                        'assets/icon/app_icon.png',
                        width: 64,
                        height: 64,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '开始之前,有四件事',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: MedMe.tealDark,
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _Point(
                      icon: Icons.lock_outline,
                      title: '你的病历只存在这台手机上',
                      body: '没有账号,不需要注册。只有你主动分享时,内容才会以加密形式离开手机。',
                    ),
                    const _Point(
                      icon: Icons.medical_information_outlined,
                      title: 'MedMe 不是医生',
                      body: '它不是医疗器械,不提供诊断或用药建议。文字识别可能出错 —— '
                          '以原件和医师判断为准。',
                    ),
                    const _Point(
                      icon: Icons.folder_shared_outlined,
                      title: '数据在你手上,也只在你手上',
                      body: '你随时可以删。但手机丢了、误删了我们也帮不上忙 —— '
                          '我们那里本来就没有。',
                    ),
                    // 不按 `Analytics.isConfigured` 分支 —— **法律声明的内容不能随
                    // 构建参数变化**,否则两个包对用户说的话不一样。没配 Key 的构建
                    // 只是实际不采,声明照说。
                    const _Point(
                      icon: Icons.insights_outlined,
                      title: '我们只看得到匿名的使用计数',
                      body: '只上报「导入了几份、成没成」这类计数,不含病历内容,'
                          '也不做能认出你的标识。设置里随时可关。',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      children: [
                        const Text('详见 ', style: TextStyle(color: MedMe.faint)),
                        _Link('用户协议', () => _open('terms.html')),
                        const Text(' 与 ', style: TextStyle(color: MedMe.faint)),
                        _Link('隐私政策', () => _open('privacy.html')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _agree,
                      style: FilledButton.styleFrom(
                        backgroundColor: MedMe.teal,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text(
                        '我知道了,开始使用',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _decline,
                    child: const Text(
                      '不同意',
                      style: TextStyle(color: MedMe.faint),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 21, color: MedMe.teal),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  body,
                  style: const TextStyle(fontSize: 13.5, color: MedMe.faint, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Text(
      label,
      style: const TextStyle(
        color: MedMe.teal,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline,
        decorationColor: MedMe.teal,
      ),
    ),
  );
}
