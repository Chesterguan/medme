import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';

/// 概览页顶部的身份 hero 卡:**你是谁,现在看的是谁**。
///
/// 深色渐变 + 大字,视觉上明显区别于下方一叠白卡 —— 这不是装饰,是
/// 「切成员是有隐私含义的动作」这条要求的直接落地:切到家人档案后,这张卡
/// 要让人一眼确认「现在看的是谁」,不能在不知情的状态下把家人的病历当自己的
/// 给医生看(见需求第五条)。整张卡可点,点开即弹出成员切换器。
///
/// **不带骑缝线**(见 `MedCard` 类文档 §五):这是从许多份原件汇总算出来的
/// 派生卡,背后没有「一张纸」。所以没有用 `MedCard`,是手写的容器 —— 骑缝线
/// 只在 `MedCard` 里画,不用它就不会被误加。
///
/// 深色固定不随主题(app 目前只有浅色主题):渐变两端都从设计系统自己的令牌
/// 推出来,不是抄 demo 的 slate/sky 十六进制 —— 起点是浅色套的 `ink`
/// (#101A23,本就是接近纯黑的深藏青),终点是把 `seal` 的色相在 HSL 里压到
/// 低明度。深底上的文字全部取自 `MedColors.dark`(设计系统本来就为深底场景
/// 备好的一套令牌,对比度已经过验证,不是新配的色)。
///
/// 这套推导独立放进 [IdentityHeroPalette],不是内联在 `build()` 里——
/// `test/identity_hero_card_test.dart` 的对比度断言直接导入这个类算,不重抄
/// 一遍公式。两处各写一份同样的 HSL 算式,谁改了其中一处而没改另一处,
/// 对比度测试就会悄悄测着一个卡片实际不用的颜色,红不了真正的回归。
class IdentityHeroPalette {
  IdentityHeroPalette._();

  /// 渐变起点:浅色套的 `ink`,本就是接近纯黑的深藏青,直接当深底用。
  static final Color gradientStart = MedColors.light.ink;

  /// 渐变终点:把主色 `seal` 的色相在 HSL 里压到低明度——同一个主色,只是
  /// 换个亮度,不是另配一个颜色。
  static final Color gradientEnd = HSLColor.fromColor(
    MedColors.light.seal,
  ).withLightness(0.16).toColor();

  /// 深底主文字(姓名):设计系统里为深色场景准备的令牌,对比度已过 AA。
  ///
  /// 用 `static final` 不用 `const` —— dart 的常量求值器不支持对
  /// `ThemeExtension` 子类的 const 实例做字段访问(`MedColors.dark.ink` 在
  /// const 上下文里会被分析器拒掉),运行时取值不受影响。
  static final Color textPrimary = MedColors.dark.ink;

  /// 深底次级文字/图标(份数、最近就诊、切换图标)。
  static final Color textSecondary = MedColors.dark.ink2;

  /// 头像底色:与浅色套「身份卡」头像同一个 `sealInk`——配白字已经是这个
  /// 项目验过的安全组合(`seal` 配白字只有 3.90:1,`sealInk` 才够)。
  static final Color avatarBackground = MedColors.light.sealInk;
}

class IdentityHeroCard extends StatelessWidget {
  const IdentityHeroCard({
    super.key,
    required this.name,
    required this.gender,
    required this.age,
    required this.recordCount,
    required this.recentVisitDate,
    required this.onSwitchMember,
  });

  /// 显示名。取的是当前成员标签(调用方已经在 `ProfileManager.displayName` 与
  /// 报告识别名之间做过选择),这里只管显示。
  final String name;

  final String? gender;
  final String? age;
  final int recordCount;

  /// 最近一次就诊/归档的日期,`"YYYY-MM-DD"`。没有任何记录、或那条记录没识别到
  /// 日期时为 null —— 卡片显示「暂无」,**不许**当 0 或今天填。
  final String? recentVisitDate;

  final VoidCallback onSwitchMember;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final initial = name.isNotEmpty ? name[0] : '我';
    // 与旧身份卡同一条取法:性别/年龄缺失就不写这一段,不编「未登记」——
    // 这条不是本次新加的信息,沿用既有行为。
    final subParts = [
      ...[gender, age].whereType<String>().where((x) => x.isNotEmpty),
      '$recordCount 份记录',
    ];
    // 「最近就诊」是本次新加的信息:必须来自真数据,缺失就明说「暂无」。
    final recentVisitText = fmtDate(recentVisitDate);

    final heroInk = IdentityHeroPalette.textPrimary;
    final heroInk2 = IdentityHeroPalette.textSecondary;

    return Semantics(
      button: true,
      label: '当前查看:$name。点击切换成员',
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MedShape.radiusCard),
            boxShadow: c.shadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MedShape.radiusCard),
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    IdentityHeroPalette.gradientStart,
                    IdentityHeroPalette.gradientEnd,
                  ],
                ),
              ),
              child: InkWell(
                onTap: onSwitchMember,
                splashColor: Colors.white.withValues(alpha: 0.08),
                highlightColor: Colors.white.withValues(alpha: 0.04),
                child: Stack(
                  children: [
                    // 装饰性光晕:纯视觉,不承载信息,不受对比度规则约束。
                    Positioned(
                      right: -40,
                      bottom: -40,
                      child: IgnorePointer(
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                MedColors.light.seal.withValues(alpha: 0.28),
                                MedColors.light.seal.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(MedShape.s4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(
                              MedShape.radiusBlock,
                            ),
                            child: Container(
                              width: 52,
                              height: 52,
                              alignment: Alignment.center,
                              color: IdentityHeroPalette.avatarBackground,
                              child: Text(
                                initial,
                                style: MedType.title.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: MedShape.s3),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // **不设 maxLines/ellipsis** —— 大字号下姓名换行,
                                // 不许被截断(需求第四条)。
                                Text(
                                  name,
                                  style: MedType.title.copyWith(
                                    color: heroInk,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  subParts.join(' · '),
                                  style: MedType.secondary.copyWith(
                                    color: heroInk2,
                                    fontFeatures: MedType.tabular,
                                  ),
                                ),
                                const SizedBox(height: MedShape.s2),
                                Container(
                                  height: 1,
                                  color: heroInk2.withValues(alpha: 0.25),
                                ),
                                const SizedBox(height: MedShape.s2),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.event_note_outlined,
                                      size: 15,
                                      color: heroInk2,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        '最近就诊 · ${recentVisitText.isEmpty ? '暂无' : recentVisitText}',
                                        style: MedType.secondary.copyWith(
                                          color: heroInk2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: MedShape.s1),
                          // 切成员的可视提示,与档案屏 `_PatientHeader` 同一图标语汇。
                          Icon(Icons.unfold_more, size: 20, color: heroInk2),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
