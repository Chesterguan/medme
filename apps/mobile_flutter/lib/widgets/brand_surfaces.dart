import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 品牌色的三个出口:主卡、主按钮、次按钮。**没有渐变、没有阴影、没有光晕**
/// (减法稿 2026-09-22)。一屏至多一张 [HeroCard]、至多一颗 [MedPrimaryButton]——
/// 那是这一屏唯一的一块颜色面,`test/stage3_visual_helpers.dart` 按屏数。
///
/// 卡面白字压 `sealInk`(#0E6285)6.76:1,过 WCAG AA;不用 `seal`(3.9:1)——
/// 目标用户含老年人,`theme.dart` 早已定了填充面一律 sealInk。
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.child, this.color, this.onTap, this.semanticLabel});

  final Widget child;

  /// 卡面实色,默认 `sealInk`。代拍首页传 `proxyInk`(R31:代拍模式保持紫)。
  final Color? color;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final card = Material(
      color: color ?? c.sealInk,
      borderRadius: BorderRadius.circular(MedShape.radiusCard),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 14), child: child),
      ),
    );
    return semanticLabel == null
        ? card
        : Semantics(button: onTap != null, label: semanticLabel, child: card);
  }
}

/// 主按钮:药丸、实色 `sealInk`、17·w500 白字。
///
/// **禁用态**(`onPressed == null`):`line2` 底 + `ink2` 字(R29/R30,ink2/line2 ≈ 7.9:1),
/// 无水波纹——「还能不能点」由底色说,不靠字变浅。
class MedPrimaryButton extends StatelessWidget {
  const MedPrimaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final enabled = onPressed != null;
    final fg = enabled ? Colors.white : c.ink2;
    return Material(
      color: enabled ? c.sealInk : c.line2,
      borderRadius: BorderRadius.circular(MedShape.radiusPill),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center,
              style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                  fontVariations: MedType.w500, color: fg))),
          ]),
        ),
      ),
    );
  }
}

/// 次按钮:白底 + 1.5px `seal` 描边 + `sealInk` 字。禁用态:`line` 描边 + `ink3` 字。
class MedSecondaryButton extends StatelessWidget {
  const MedSecondaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final enabled = onPressed != null;
    final fg = enabled ? c.sealInk : c.ink3;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
        // R13:白底用 Ink,水波纹才不会被这层不透明白底盖住。
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(MedShape.radiusPill),
            border: Border.all(color: enabled ? c.seal : c.line, width: 1.5),
          ),
          padding: const EdgeInsets.all(13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center,
              style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                  fontVariations: MedType.w500, color: fg))),
          ]),
        ),
      ),
    );
  }
}
