import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 光泽图标块 —— brief §形 里的「我们的 3D 图标语言」,**全 app 的图标底块只此一家**。
///
/// 44×44、圆角 12、150° 类别渐变,加三层光:顶部一道白色内高光、底部一道黑色内暗边、
/// 外面一团同色投影。CSS 那边是 `inset box-shadow`,Flutter 没有这个东西,所以两道
/// 内光用 1px 高的 `DecoratedBox` 贴在上下沿 —— 视觉等价,不用 `CustomPainter`。
///
/// [size] 可调只为首启那一屏:`s16` 的场景里三个小块是 52 / 56 / 40。别的地方一律用
/// 默认的 44,**不要**为了「这里挤一点」就调小它。
class GlossIconTile extends StatelessWidget {
  const GlossIconTile({
    super.key,
    required IconData this.icon,
    this.category = GlossCategory.brand,
    this.size = MedBrand.tileSize,
  }) : letter = null;

  /// 字母款:成员头像。底色固定走品牌渐变(brief §色:成员头像 = 品牌渐变)。
  const GlossIconTile.letter({
    super.key,
    required String this.letter,
    this.category = GlossCategory.brand,
    this.size = MedBrand.tileSize,
  }) : icon = null;

  final IconData? icon;
  final String? letter;
  final GlossCategory category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (a, b, shadow) = MedBrand.tile(category);
    // CSS 的 `linear-gradient(150deg, …)`:0° 朝上、顺时针。Flutter 的
    // topCenter→bottomCenter 是 180°,所以要旋转 (150-180) = -30°。
    const rotation = -30 * math.pi / 180;
    final radius = MedShape.radiusTile * (size / MedBrand.tileSize);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          colors: [a, b],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          transform: const GradientRotation(rotation),
        ),
        boxShadow: MedBrand.tileShadow(shadow),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 顶部内高光。
            Positioned(top: 0, left: 0, right: 0, child: DecoratedBox(
              decoration: const BoxDecoration(color: MedBrand.glossTop),
              child: const SizedBox(height: 1, width: double.infinity),
            )),
            // 底部内暗边。
            Positioned(bottom: 0, left: 0, right: 0, child: DecoratedBox(
              decoration: const BoxDecoration(color: MedBrand.glossBottom),
              child: const SizedBox(height: 1, width: double.infinity),
            )),
            if (icon != null)
              Icon(icon, size: MedBrand.tileIconSize * (size / MedBrand.tileSize), color: Colors.white)
            else
              // **不跟系统字号放大**:块是固定尺寸,字放大就溢出。见
              // design_tokens.dart MedType 文档里的唯一例外。
              MediaQuery.withNoTextScaling(
                child: Text(
                  letter!,
                  style: MedType.subtitle.copyWith(color: Colors.white, fontSize: size * 0.41),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
