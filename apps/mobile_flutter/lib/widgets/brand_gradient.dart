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

    // R13(review fix round 1):这层原来是 Container——不透明的渐变整个盖在
    // InkWell 的水波纹上面,水波纹画了也看不见(Flutter `Ink`类文档原话:opaque
    // 的 Container/DecoratedBox 画在 Material 上层会把水波纹整个遮住)。换成
    // Ink:它把 decoration 交给最近的祖先 Material 去画,和水波纹同一张画布,
    // 水波纹才叠在渐变上面。
    //
    // Ink 没有 clipBehavior(不像 Container),所以外面套一层 ClipRRect——它裁的
    // 是 Ink 的**子内容**(这里是光晕那个故意画出边界的圆),不是 Ink 自己的
    // decoration:decoration 画在祖先 Material 的画布上,在 ClipRRect 裁剪范围
    // 之外(`Ink` 类文档写明的限制),但那份 decoration 自带 borderRadius,
    // BoxDecoration 画自己的圆角形状本就不需要外部裁剪。
    final box = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Ink(
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
        child: content,
      ),
    );

    final tappable = onTap == null
        ? box
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            splashColor: Colors.white.withValues(alpha: 0.08),
            highlightColor: Colors.white.withValues(alpha: 0.04),
            child: box,
          );

    // `Ink` 无论有没有 onTap 都要有祖先 Material(`debugCheckHasMaterial`)——
    // 原来只在 onTap != null 分支里包 Material,onTap 为 null(PrimaryEntryTile/
    // MedPrimaryButton 常见的静态展示场景,以及 HeroCard 没传 onTap 时)会在
    // 真机上直接 assert 炸掉,所以这里挪到两个分支外面统一包一层。
    return _semantics(Material(type: MaterialType.transparency, child: tappable));
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
///
/// **禁用态**(`onPressed == null`)不画渐变(fix round 1,task-14-review R29):
/// 换成 `line2` 底 + `ink2` 字的纯色药丸,同一档圆角/内边距,无阴影、无光晕、
/// 无水波纹。原因:`BrandGradientBox` 的渐变最浅一段压白字实测只有 2.60:1,
/// 过不了 WCAG AA——但那是渐变边缘,标签实际压在渐变中段(`#1789C1` ≈
/// 3.9:1,与全 app 每一颗启用态主按钮相同,R11 hero 规则已经接受这个数,不
/// 在本次改动范围)。真正的缺口只在禁用态:disabled 之前和 enabled 画得一模
/// 一样,用户分不出还能不能点。
///
/// **字色是 `ink2` 不是 `ink3`**(fix round 2,R30):「这是禁用态」这件事由
/// 「纯色底、无渐变、无阴影、无水波纹」这一整套来表达,不是靠字变浅——round 1
/// 量出 `ink3`/`line2` 只有 4.23:1,没到 WCAG AA 4.5:1;`ink2`/`line2` ≈
/// 7.9:1,两者都在 `test/brand_gradient_test.dart` 里实测钉住。
/// **启用态渲染一个字没动。**
class MedPrimaryButton extends StatelessWidget {
  const MedPrimaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (onPressed == null) {
      final c = MedColors.of(context);
      return Container(
        decoration: BoxDecoration(
          color: c.line2,
          borderRadius: BorderRadius.circular(MedShape.radiusPill),
        ),
        padding: const EdgeInsets.all(13),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[Icon(icon, size: 20, color: c.ink2), const SizedBox(width: 8)],
          Flexible(child: Text(label, textAlign: TextAlign.center,
            style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                fontVariations: MedType.w500, color: c.ink2))),
        ]),
      );
    }
    return BrandGradientBox(
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
        // R13:同上——白底改用 Ink,水波纹才不会被这层不透明白底盖住。这里没有
        // 光晕那类会溢出的子内容,不需要额外的 ClipRRect。
        child: Ink(
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
