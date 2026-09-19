import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'brand_logo.dart';

/// 病历本条(brief §形「病历本条」;mockup `.book`)。
///
/// **形状故意和主页那张成员主卡不一样**:主卡是整面渐变,这里是白卡 + 左侧一条
/// 34px 的渐变书脊。两个都是「入口」,但一个是「你是谁」,一个是「一本病程档案」——
/// 长得一样就分不出点进去会到哪。
class RecordBookStrip extends StatelessWidget {
  const RecordBookStrip({
    super.key,
    required this.title,
    required this.subtitle,
    this.bigNumber,
    this.bigNumberSuffix,
    this.bigNumberCaption,
    this.titleTrailing,
    this.logo = const BrandLogo(size: BrandLogo.bookSpine),
    this.onTap,
  });

  final String title;
  final String subtitle;

  /// 右列那个大数。没有就整列不画 —— 不摆一个「—」占位。
  final String? bigNumber;
  final String? bigNumberSuffix;
  final String? bigNumberCaption;

  /// 标题后面那枚 pill(「示例」)。
  final Widget? titleTrailing;

  /// 书脊旁的真 logo,40px(brief §品牌)。默认就是 `BrandLogo(size: BrandLogo.bookSpine)`,
  /// 调用方不用每次传;传 `null` 则不画 logo。
  final Widget? logo;

  final VoidCallback? onTap;

  /// 右列大数那一列的右内边距 —— 独立命名成常量,只为了测试能引用同一个数字断言
  /// 「大数靠右贴边」,不是为了给调用方调。
  static const double bigNumberEndPadding = 14;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusEntry),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(MedShape.radiusEntry),
            boxShadow: MedBrand.cardShadow,
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const _Spine(),
              if (logo != null) Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Center(child: logo!),
              ) else const SizedBox(width: 12),
              Expanded(child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: MedType.body.copyWith(fontWeight: FontWeight.w600,
                            fontVariations: MedType.w600, height: 1.25))),
                      if (titleTrailing != null) ...[const SizedBox(width: 6), titleTrailing!],
                    ]),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: MedType.caption.copyWith(color: c.ink3, fontWeight: FontWeight.w400)),
                  ],
                ),
              )),
              if (bigNumber != null) Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, bigNumberEndPadding, 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        // 两个独立的 Text(不用 Text.rich/TextSpan 拼)——大数要单独
                        // 承接自己的样式断言(22·600·seal),拼进一棵 span 树里就
                        // 找不到了。
                        Text(bigNumber!, style: MedType.value.copyWith(fontSize: 22,
                            fontWeight: FontWeight.w600, fontVariations: MedType.w600,
                            color: c.seal, height: 1)),
                        if (bigNumberSuffix != null)
                          Text(bigNumberSuffix!, style: MedType.caption.copyWith(
                              color: c.ink3, fontWeight: FontWeight.w400)),
                      ],
                    ),
                    if (bigNumberCaption != null)
                      Text(bigNumberCaption!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: MedType.caption.copyWith(color: c.ink3, fontSize: 11,
                            fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 34px 书脊:180° 两段渐变 + 细横纹(2px 实 / 9px 周期)。
///
/// 横纹用 `CustomPainter` 画,不用 `Image`、不加依赖 —— 就是一组等距的横条。
class _Spine extends StatelessWidget {
  const _Spine();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('record-book-spine'),
    decoration: const BoxDecoration(gradient: LinearGradient(
      colors: MedBrand.spineColors,
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
    )),
    child: CustomPaint(
      painter: _StripePainter(),
      child: const SizedBox(width: MedBrand.spineWidth, height: double.infinity),
    ),
  );
}

class _StripePainter extends CustomPainter {
  const _StripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // mockup:`repeating-linear-gradient(180deg, rgba(255,255,255,.14) 0 2px,
    // transparent 2px 9px)`。R1(预检裁定):颜色就是 `spineStripe` 原值,不
    // 再乘 0.6 —— brief 原稿那一乘是错的,已被裁定否掉。
    final paint = Paint()..color = MedBrand.spineStripe;
    for (var y = 0.0; y < size.height; y += MedBrand.spineStripePeriod) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, MedBrand.spineStripeOn), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StripePainter old) => false;
}
