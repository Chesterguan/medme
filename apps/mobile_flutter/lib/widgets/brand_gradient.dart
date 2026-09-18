import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// **全 app 唯一画品牌渐变的 widget。**
///
/// brief §品牌「一屏只一处品牌渐变」只有在渐变有唯一出口时才数得清。所以任何地方
/// 想要那三段蓝,都必须经过这里;`MedBrand.gradientColors` 出现在别的文件里就是 bug
/// (`test/no_raw_colors_test.dart` 挡不住这个,靠 code review 和屏测试的计数)。
///
/// 三个用法各有各的圆角与阴影:主卡 22 / 主入口块 18 / 主按钮 999。
class BrandGradientBox extends StatelessWidget {
  const BrandGradientBox({
    super.key,
    required this.child,
    required this.radius,
    required this.shadow,
    this.glow = false,
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final double radius;
  final List<BoxShadow> shadow;

  /// 右上那团弱光晕。**只有主卡有**(brief §色)。
  final bool glow;

  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    if (glow) {
      content = Stack(children: [
        // 装饰性,不承载信息,不受对比度规则约束。
        Positioned(
          right: -60, top: -80,
          child: IgnorePointer(child: Container(
            width: 220, height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                // 终点全透明:brief 原文用 `Color(0x00FFFFFF)`,但那是 lib/ 里的裸
                // 色值,会被 `no_raw_colors_test.dart` 挡住。`Colors.white.withValues
                // (alpha: 0)` 是同一个颜色(RGB FFFFFF、alpha 0)的令牌写法,逐位
                // 相同——不用 `Colors.transparent`(RGB 000000):渐变插值是否按
                // 预乘 alpha 处理会决定中间那些半透明像素的 RGB 怎么混,不确定
                // Skia 的插值方式时,选"同色不同写法"比选"同 alpha 不同 RGB"更保险。
                colors: [MedBrand.heroGlow, Colors.white.withValues(alpha: 0)],
                stops: const [0.0, 0.62],
              ),
            ),
          )),
        ),
        content,
      ]);
    }

    final box = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          colors: MedBrand.gradientColors,
          stops: MedBrand.gradientStops,
          begin: MedBrand.gradientBegin,
          end: MedBrand.gradientEnd,
        ),
        boxShadow: shadow,
      ),
      // 裁住光晕那团故意画到边界外的圆。
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    if (onTap == null) return _semantics(box);
    return _semantics(Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: box,
      ),
    ));
  }

  Widget _semantics(Widget w) => semanticLabel == null
      ? w
      : Semantics(button: onTap != null, label: semanticLabel, child: w);
}

/// 主卡。**一屏至多一张**(见计划的「每屏品牌渐变预算」表)。
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.child, this.onTap, this.semanticLabel});

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => BrandGradientBox(
    radius: MedShape.radiusHero,
    shadow: MedBrand.heroShadow,
    glow: true,
    onTap: onTap,
    semanticLabel: semanticLabel,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),  // mockup `.hero`
      child: child,
    ),
  );
}

/// 主入口块(`s1` 的「添加」)。**一屏至多一个。**
class PrimaryEntryTile extends StatelessWidget {
  const PrimaryEntryTile({super.key, required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => BrandGradientBox(
    radius: MedShape.radiusEntry,
    shadow: MedBrand.entryShadow,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 11),   // mockup `.qa`
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 34, color: Colors.white),
        const SizedBox(height: 6),
        Text(label, textAlign: TextAlign.center,
          style: MedType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w500,
              fontVariations: MedType.w500)),
      ]),
    ),
  );
}

/// 主按钮(mockup `.btn`):药丸、渐变、17·w500 白字。
class MedPrimaryButton extends StatelessWidget {
  const MedPrimaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => BrandGradientBox(
    radius: MedShape.radiusPill,
    shadow: MedBrand.buttonShadow,
    onTap: onPressed,
    child: Padding(
      padding: const EdgeInsets.all(13),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (icon != null) ...[Icon(icon, size: 20, color: Colors.white), const SizedBox(width: 8)],
        Flexible(child: Text(label, textAlign: TextAlign.center,
          style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
              fontVariations: MedType.w500, color: Colors.white))),
      ]),
    ),
  );
}

/// 次按钮(mockup `.btn.sec`):白底 + 1.5px seal 描边 + sealInk 字,**无阴影、无渐变**。
class MedSecondaryButton extends StatelessWidget {
  const MedSecondaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(MedShape.radiusPill),
            border: Border.all(color: c.seal, width: 1.5),
          ),
          padding: const EdgeInsets.all(13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20, color: c.sealInk), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center,
              style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                  fontVariations: MedType.w500, color: c.sealInk))),
          ]),
        ),
      ),
    );
  }
}
