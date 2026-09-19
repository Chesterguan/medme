import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'gloss_tile.dart';

/// 设计系统 v1 的共用外壳:卡片、骑缝线、状态 pill、横幅。
///
/// 规范正本 `DESIGN-SYSTEM-v1.html`;色值/字号/圆角/间距一律取自
/// `design_tokens.dart`,这里只负责**怎么摆**,不新增任何裸色值。

/// 标准卡片:`surface` 底 + 圆角 20 + 阴影分层,**无边框**。
///
/// Stage 3 视觉令牌 brief §形把 v1 的分层规则整个翻过来了:v1 是「层次靠边框不靠
/// 阴影」,现在是「卡无边框,靠 `0 6px 18px rgba(16,26,35,.08)`
/// ([MedBrand.cardShadow]) 把卡从 `paper` 底上托起来分层」。
///
/// [perforated] 是签名元素「骑缝线」:卡顶一道齿孔纹,**只允许出现在「这条数据
/// 背后有一份原件、并且点得进去」的卡上**(规范 §五)。派生数据卡(身份卡、
/// 趋势汇总这类算出来的结论)一律不带 —— 它是「可溯源」这条铁律的视觉语言,
/// 当装饰用就把这句话说成了假话。
class MedCard extends StatelessWidget {
  const MedCard({
    super.key,
    required this.child,
    this.perforated = false,
    this.background,
  });

  /// 卡片内容。**不带内边距** —— 由调用方决定(有的卡整块要盖 InkWell)。
  final Widget child;

  /// 是否画骑缝线。见类文档:只给「背后有原件、点得进去」的卡。
  final bool perforated;

  /// 卡片底色,默认 `surface`。
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: background ?? c.surface,
        borderRadius: BorderRadius.circular(MedShape.radiusCard),
        boxShadow: MedBrand.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (perforated) const MedPerforation(),
          child,
        ],
      ),
    );
  }
}

/// 骑缝线本体:卡顶一道齿孔纹。左右按卡片内边距 `s4` 收进来,和内容对齐。
///
/// 规范里是 `radial-gradient` 平铺(9×4,半径 1.6),Flutter 侧用 `CustomPainter`
/// 画同一组圆点 —— **不引外链图片、不加依赖**(007 §2.4:无网络也全可用)。
class MedPerforation extends StatelessWidget {
  const MedPerforation({super.key});

  /// 齿孔间距与半径,逐字对齐规范的 `background-size:9px 4px` / `1.6px`。
  static const double dotSpacing = 9;
  static const double dotRadius = 1.6;
  static const double stripHeight = 4;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      // 上边距 10:规范是 `top:11px` 相对卡顶,这里卡顶还有 1px 边框,合起来一致。
      padding: const EdgeInsets.fromLTRB(MedShape.s4, 10, MedShape.s4, 0),
      child: SizedBox(
        height: stripHeight,
        child: CustomPaint(
          size: Size.infinite,
          painter: _PerforationPainter(c.line),
        ),
      ),
    );
  }
}

class _PerforationPainter extends CustomPainter {
  const _PerforationPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final cy = size.height / 2;
    // 从半格起画,两端留白对称,卡片宽度变化时齿孔不会贴边被切一半。
    for (
      var x = MedPerforation.dotSpacing / 2;
      x < size.width;
      x += MedPerforation.dotSpacing
    ) {
      canvas.drawCircle(Offset(x, cy), MedPerforation.dotRadius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PerforationPainter old) => old.color != color;
}

/// 状态 pill:圆角 999,`caption` 字阶(12·600),前景 + 极浅底一对色。
///
/// 化验状态**同时**编码在左侧色条和这个文字 pill 上 —— 色盲用户靠 pill 读语义,
/// 正常视力扫视靠色条(规范 §二)。所以 pill 的文字不能省成一个纯色点。
class MedPill extends StatelessWidget {
  const MedPill({
    super.key,
    required this.text,
    required this.foreground,
    required this.background,
  });

  /// 「需核对」/「看一眼」共用的中性配色(`MedBrand.checkInk` / `checkWash`)。
  /// R4:这枚配色只在这一处定义,`lab_status.dart` 与 `profile_sections.dart`
  /// 都调它,不许各写各的裸色值。
  factory MedPill.check(String text) => MedPill(
    text: text,
    foreground: MedBrand.checkInk,
    background: MedBrand.checkWash,
  );

  final String text;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
      ),
      child: Text(text, style: MedType.caption.copyWith(color: foreground)),
    );
  }
}

/// 横幅(mockup `.banner`):圆角 16,左边一枚光泽图标块,标题用对应的横幅文字色,
/// 副标用 ink2;右边一枚 `›`(**只在 [onTap] 非空时画** —— 沿用
/// `PendingReviewBanner` 既有那条规矩:没有去处就不画箭头)。
class MedBanner extends StatelessWidget {
  const MedBanner({
    super.key,
    required this.icon,
    required this.iconCategory,
    required this.title,
    this.subtitle,
    this.amber = false,
    this.onTap,
  });

  final IconData icon;
  final GlossCategory iconCategory;
  final String title;
  final String? subtitle;

  /// 蓝(默认)/ 琥珀两色,见 brief §色「横幅」。
  final bool amber;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final bg = amber ? MedBrand.bannerAmber : MedBrand.bannerBlue;
    final ink = amber ? MedBrand.bannerAmberInk : MedBrand.bannerBlueInk;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBanner),
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(MedShape.radiusBanner),
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              GlossIconTile(icon: icon, category: iconCategory),
              const SizedBox(width: MedShape.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: MedType.body.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w600,
                        fontVariations: MedType.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: MedType.secondary.copyWith(color: c.ink2),
                      ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, size: 18, color: ink),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「示例」标(mockup `.pill.demo`):白底 + 虚线框,**不是**实心 pill —— demo 数据
/// 需要一眼与真实数据区分开,用「只剩轮廓、没有实色底」的克制画法。
class MedDemoPill extends StatelessWidget {
  const MedDemoPill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _DashedBorderPainter(
        MedBrand.demoBorder,
        radius: MedShape.radiusPill,
        dash: 3,
        gap: 2,
        strokeWidth: 1,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.all(Radius.circular(MedShape.radiusPill)),
        ),
        child: Text(text, style: MedType.caption.copyWith(color: MedBrand.demoInk)),
      ),
    );
  }
}

/// 空态的虚线框(规范 §六:`1.5px dashed --line`,圆角取分块这一档 14)。
///
/// Flutter 没有虚线边框,自己画 —— 不为一条虚线加依赖(007 §2.4)。
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(MedColors.of(context).line),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: MedShape.s5,
          horizontal: MedShape.s3,
        ),
        child: child,
      ),
    );
  }
}

/// 沿圆角矩形轮廓画虚线,`DottedBorderBox`(空态大框)与 `MedDemoPill`(示例
/// pill 的小框)共用同一个画法,只是半径/线宽/疏密不同 —— 两套参数化,不写第
/// 二个近乎重复的 painter 类。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter(
    this.color, {
    this.radius = MedShape.radiusBlock,
    this.dash = 6,
    this.gap = 4,
    this.strokeWidth = 1.5,
  });

  final Color color;
  final double radius;
  final double dash;
  final double gap;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.dash != dash ||
      old.gap != gap ||
      old.strokeWidth != strokeWidth;
}
