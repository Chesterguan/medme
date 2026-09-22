import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

/// 概览页顶部的身份 hero 卡:**你是谁,现在看的是谁**。
///
/// 品牌渐变 + 大字,视觉上明显区别于下方一叠白卡 —— 这不是装饰,是
/// 「切成员是有隐私含义的动作」这条要求的直接落地:切到家人档案后,这张卡
/// 要让人一眼确认「现在看的是谁」,不能在不知情的状态下把家人的病历当自己的
/// 给医生看(见需求第五条)。整张卡可点,点开即弹出成员切换器。
///
/// **不带骑缝线**(见 `MedCard` 类文档 §五):这是从许多份原件汇总算出来的
/// 派生卡,背后没有「一张纸」。所以没有用 `MedCard`,是 [HeroCard] 那层壳——
/// 骑缝线只在 `MedCard` 里画,不用它就不会被误加。
///
/// 渐变、阴影、右上光晕全部来自 [HeroCard](经 `BrandGradientBox` 收口的品牌
/// 渐变唯一出口,见 `widgets/brand_surfaces.dart`)——这张卡自己不再推导颜色。
/// 旧版本这里有一个独立用 HSL 算深色渐变的 `IdentityHeroPalette`,Stage 3
/// 视觉令牌 brief 把它替换成了全 app 统一的那三段品牌蓝,整个类删掉了。
///
/// 卡面上除了头像(白底衬 `seal` 色字母)之外,其余文字/图标一律 `Colors.white`
/// (按信息层级分几档透明度)——这条颜色规则是确定性的,不必每次改动都重新
/// 量一遍对比度,见 `test/identity_hero_card_test.dart` 里那组测试的注释。
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

  /// 最近一次就诊/添加的日期,`"YYYY-MM-DD"`。没有任何记录、或那条记录没识别到
  /// 日期时为 null —— 卡片显示「暂无」,**不许**当 0 或今天填。
  final String? recentVisitDate;

  final VoidCallback onSwitchMember;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0] : '我';
    // 与旧身份卡同一条取法:性别/年龄缺失就不写这一段,不编「未登记」——
    // 这条不是本次新加的信息,沿用既有行为。
    final subParts = [
      ...[gender, age].whereType<String>().where((x) => x.isNotEmpty),
      '$recordCount 份记录',
    ];
    // 「最近就诊」是本次新加的信息:必须来自真数据,缺失就明说「暂无」。
    final recentVisitText = fmtDate(recentVisitDate);

    return HeroCard(
      onTap: onSwitchMember,
      semanticLabel: '当前查看:$name。点击切换成员',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(initial: initial),
          const SizedBox(width: MedShape.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // **不设 maxLines/ellipsis** —— 大字号下姓名换行,
                // 不许被截断(需求第四条)。
                Text(
                  name,
                  style: MedType.subtitle.copyWith(fontSize: 21, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  subParts.join(' · '),
                  style: MedType.secondary.copyWith(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.88),
                    fontFeatures: MedType.tabular,
                  ),
                ),
                const SizedBox(height: MedShape.s2),
                Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                const SizedBox(height: MedShape.s2),
                // review fix round 1(Minor):标签和数值拆成两个 Text 后,读屏会
                // 停两次。MergeSemantics 把这一整行合并回一个语义节点,读起来还是
                // 一句话——不改字符串、不改布局,只改语义树。
                MergeSemantics(
                  // R20:标签本征宽度、数值靠右(mockup .rule 的 space-between)。
                  // 用 Wrap 而不是 Row:Row 里两个 Flexible 会把剩余空间 50/50
                  // 预分,393pt 宽下日期明明放得下也被截成「2026-09…」(实测);
                  // 而标签单独非 flex 又会在 360×640 @2× 溢出。Wrap 让数值在
                  // 放不下时折到下一行,永不溢出。
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_note_outlined,
                            size: 15,
                            color: Colors.white.withValues(alpha: 0.88),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '最近就诊 · ',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: MedType.secondary.copyWith(
                                fontSize: 14,
                                color: MedColors.of(context).onDarkMeta,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // R18:22/600 是 MedType.heroValue(mockup `.hero .rule b`)
                      // ——颜色不在令牌里,按卡面确定性白字规则(R11)在用处给。
                      Text(
                        recentVisitText.isEmpty ? '暂无' : recentVisitText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MedType.heroValue.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: MedShape.s1),
          // 切成员的可视提示,与档案屏 `_PatientHeader` 同一图标语汇。
          Icon(Icons.unfold_more, size: 20, color: Colors.white.withValues(alpha: 0.9)),
        ],
      ),
    );
  }
}

/// 头像方块:白底 54×54(`MedBrand.heroTileSize`)圆角 14
/// (`MedShape.radiusBlock`),首字母用 `seal` 色、28 / 600
/// (`MedBrand.heroTileLetterSize`,mockup `.tile` / `.tile.logo span`)。白块上
/// 放渐变文字在 Flutter 里要 `ShaderMask`,不值得,用实色 seal。
///
/// **R18 根因**:旧版本白底是 `Stack` 里一个没有 `child`、没有显式宽高的
/// `ColoredBox`。`Stack` 对非 `Positioned` 子项默认 `StackFit.loose`(约束松到
/// 0),`ColoredBox` 没有 `width`/`height` 参数、也没有 `child` 可借尺寸,只能
/// 收缩成 `constraints.smallest` = 0×0——白底从来没有真的画出来过,首字母直接
/// 落在 `HeroCard` 的品牌渐变上;唯一真正占到尺寸的是那道 `Positioned` 的
/// 底边(`left/right/bottom: 0` + 子项显式 `height: 2`,不受 `fit` 影响),
/// 于是看起来像「字母下面一道深线,其余都是渐变」。
///
/// 换成 `Container`(**不用 `Ink`**——`Ink` 的 decoration 不画在自己的
/// RenderObject 上,而是登记成最近祖先 `Material` 的一个 ink feature,和
/// `BrandGradientBox` 那面品牌渐变挤在同一张底层画布上,反而会被渐变盖住,
/// 见 `brand_gradient.dart` R13 的类似坑)显式给 `width`/`height`,不会再收缩;
/// `clipBehavior: Clip.antiAlias` 把子内容(那道底边)裁成圆角,`boxShadow` 画
/// 在 clip 之外,不受影响。
///
/// mockup 的 `inset 0 -2px 0 rgba(22,80,142,.12)` 用一道 2px 的底边代替(CSS
/// 的 inset box-shadow,Flutter 没有,贴一道实色边视觉等价),色值是
/// `MedBrand.heroTileInset`——取代旧版本借用的占位色 `glossBottom`(那是另一块
/// 光泽图标块的底部高光,rgba 对不上,当时 brief 没给这块头像的准确值)。投影
/// `0 8px 18px rgba(14,60,100,.35)` 是 `MedBrand.heroTileShadow`。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MedBrand.heroTileSize,
      height: MedBrand.heroTileSize,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.all(Radius.circular(MedShape.radiusBlock)),
        boxShadow: MedBrand.heroTileShadow,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: MedBrand.heroTileInset),
              child: const SizedBox(height: 2, width: double.infinity),
            ),
          ),
          Text(
            initial,
            style: MedType.title.copyWith(
              fontSize: MedBrand.heroTileLetterSize,
              color: MedColors.light.seal,
            ),
          ),
        ],
      ),
    );
  }
}
