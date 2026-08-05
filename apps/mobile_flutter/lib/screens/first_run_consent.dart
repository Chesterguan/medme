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
///
/// **同意按钮在用户看到声明末尾之前不可点**(见 `_FirstRunConsentScreenState`
/// 的 `_scrolledToEnd`)。这不是装饰:声明与协议链接是本屏存在的全部理由,一个
/// 首屏就够着的按钮会让用户在没看过第四条、没点开过任何协议的情况下就点了同意。
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
  final ScrollController _scrollController = ScrollController();

  /// 是否已经看到声明区的末尾 —— 「我知道了,开始使用」的门槛。「不同意」不受
  /// 这个门槛限制,任何时候都能点(拒绝不需要读完)。
  ///
  /// 初值 false 是故意的:宁可开局的一帧按钮不可点,也不要反过来「万一没纠正回来
  /// 就等于没有门槛」。[_updateScrolledToEnd] 会在首帧布局一出来就立刻纠正 ——
  /// 用户在这一帧之内不可能已经完成一次点击,所以初值本身不会被感知到。
  bool _scrolledToEnd = false;

  /// 判「到底」留的容差:滚动物理停止时 `pixels` 与 `maxScrollExtent` 之间可能
  /// 有亚像素的浮点误差,卡在 99.9% 而不是 100% 会让按钮永远差一点点点不了。
  static const double _scrollEndSlop = 4;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrolledToEnd);
    // `ScrollController` 要等首帧布局完才有 `position`,构造函数里读不到。
    // 这一步同时是「内容本来就不到一屏」的兜底:那种情况下面不会有任何滚动事件,
    // 得靠这次主动查一遍才能把 `_scrolledToEnd` 从初值纠正过来。
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrolledToEnd());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_updateScrolledToEnd)
      ..dispose();
    super.dispose();
  }

  void _updateScrolledToEnd() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // 内容本来就不到一屏(大屏手机、横屏、平板)时 `maxScrollExtent` 是 0 ——
    // 不能因此要求用户滚一个滚不动的条,天然当作「已看到末尾」。
    final reached =
        position.maxScrollExtent <= 0 ||
        position.pixels >= position.maxScrollExtent - _scrollEndSlop;
    if (reached != _scrolledToEnd) {
      setState(() => _scrolledToEnd = reached);
    }
  }

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
              child: Stack(
                children: [
                  // `ScrollMetricsNotification` 在 metrics 变化时就发,不需要真的
                  // 发生过一次滚动 —— 首帧布局(含「内容本来就不到一屏」那种情况)
                  // 与之后的字号 / 横竖屏变化都会走到这里,是 `_updateScrolledToEnd`
                  // 之外再上一道保险。
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (notification) {
                      _updateScrolledToEnd();
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: _scrollController,
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
                          Text(
                            // 条数由 `_points` 派生,不是手写的数字 —— 见该列表
                            // 处的注释:硬编码的「四」在加删一条声明时会悄悄说错。
                            '开始之前,有${_chineseCount(_points.length)}件事',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: MedMe.tealDark,
                            ),
                          ),
                          const SizedBox(height: 22),
                          for (final point in _points)
                            _Point(
                              icon: point.icon,
                              title: point.title,
                              body: point.body,
                            ),
                          const SizedBox(height: 8),
                          Wrap(
                            children: [
                              const Text(
                                '详见 ',
                                style: TextStyle(color: MedMe.faint),
                              ),
                              _Link('用户协议', () => _open('terms.html')),
                              const Text(
                                ' 与 ',
                                style: TextStyle(color: MedMe.faint),
                              ),
                              _Link('隐私政策', () => _open('privacy.html')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 「下面还有」指示:渐隐遮罩 + 向下箭头。目标用户含老年人,纯渐变
                  // 未必能读出「还能往下滑」,箭头给一个不需要解释的明确动作提示;
                  // 渐变负责让内容不是硬切在遮罩边缘。滚到底后跟着 `_scrolledToEnd`
                  // 一起消失 —— 一个用不上的箭头等于没有,还会让人怀疑「是不是卡住了」。
                  if (!_scrolledToEnd)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          height: 56,
                          alignment: Alignment.bottomCenter,
                          padding: const EdgeInsets.only(bottom: 6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                MedMe.bg.withValues(alpha: 0),
                                MedMe.bg,
                              ],
                            ),
                          ),
                          child: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: MedMe.tealDark,
                            size: 26,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
              child: Column(
                children: [
                  if (!_scrolledToEnd)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '还没看完 —— 往下滑到底,才能点这个',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: MedMe.tealDark,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: (_busy || !_scrolledToEnd) ? null : _agree,
                      style: FilledButton.styleFrom(
                        backgroundColor: MedMe.teal,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        // 不用 Material 3 默认的禁用配色(onSurface 12% 底 / 38% 字
                        // —— 实测低于 WCAG AA 的 4.5:1)。这里的禁用态可能不是一闪
                        // 而过:要等用户读完才会解除,得撑得住被盯着看。
                        // `line` 底 + `tealDark` 字实测 5.21:1,过 4.5:1 门槛。
                        disabledBackgroundColor: MedMe.line,
                        disabledForegroundColor: MedMe.tealDark,
                      ),
                      child: const Text(
                        '我知道了,开始使用',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  TextButton(
                    // 「不同意」不受 `_scrolledToEnd` 限制 —— 拒绝任何时候都能点,
                    // 只有「同意」需要读完这道门槛。
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

/// 阿拉伯数字转中文数字,只覆盖 0–10 —— 声明条数现实中不会超出这个范围,
/// 真到了那个数量该拆屏,不是继续加数字。
const _chineseDigits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];

String _chineseCount(int n) =>
    (n >= 0 && n < _chineseDigits.length) ? _chineseDigits[n] : '$n';

/// 首屏四条声明的内容。**标题「有几件事」由这份列表的长度派生**(见上面
/// `_chineseCount` 的调用处),不是分开手写的数字 —— 以前标题和条目数各写各的,
/// 以后加删一条声明,标题会悄悄说错而不报错(没有任何编译检查或测试会因为「标题
/// 数字对不上条目数」而失败)。派生之后这类改动只需要动这一份列表。
const _points = [
  _PointData(
    icon: Icons.lock_outline,
    title: '你的病历只存在这台手机上',
    body: '没有账号,不需要注册。只有你主动分享时,内容才会以加密形式离开手机。',
  ),
  _PointData(
    icon: Icons.medical_information_outlined,
    title: 'MedMe 不是医生',
    body: '它不是医疗器械,不提供诊断或用药建议。文字识别可能出错 —— '
        '以原件和医师判断为准。',
  ),
  _PointData(
    icon: Icons.folder_shared_outlined,
    title: '数据在你手上,也只在你手上',
    body: '你随时可以删。但手机丢了、误删了我们也帮不上忙 —— '
        '我们那里本来就没有。',
  ),
  // 不按 `Analytics.isConfigured` 分支 —— **法律声明的内容不能随构建参数变化**,
  // 否则两个包对用户说的话不一样。没配 Key 的构建只是实际不采,声明照说。
  _PointData(
    icon: Icons.insights_outlined,
    title: '我们只看得到匿名的使用计数',
    body: '只上报「导入了几份、成没成」这类计数,不含病历内容,'
        '也不做能认出你的标识。设置里随时可关。',
  ),
];

class _PointData {
  const _PointData({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
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
