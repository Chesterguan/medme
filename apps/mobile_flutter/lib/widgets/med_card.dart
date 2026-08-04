import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 设计系统 v1 的三个共用外壳:卡片、骑缝线、状态 pill。
///
/// 规范正本 `DESIGN-SYSTEM-v1.html`;色值/字号/圆角/间距一律取自
/// `design_tokens.dart`,这里只负责**怎么摆**,不新增任何裸色值。

/// 标准卡片:`surface` 底 + 一像素 `line` 边框 + 圆角 20 + 全 app 唯一那一档阴影。
///
/// 层次靠**边框**不靠阴影(规范 §四)——所以这里的阴影极浅,只是把卡从 `paper`
/// 底上轻轻托起半格,不叠第二档。
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
    this.borderColor,
    this.borderWidth = 1,
    this.background,
  });

  /// 卡片内容。**不带内边距** —— 由调用方决定(有的卡整块要盖 InkWell)。
  final Widget child;

  /// 是否画骑缝线。见类文档:只给「背后有原件、点得进去」的卡。
  final bool perforated;

  /// 边框色,默认 `line`。用于「待确认」这类需要整卡变色的状态。
  final Color? borderColor;

  /// 边框宽度,默认 1。状态卡可加粗到 1.5。
  final double borderWidth;

  /// 卡片底色,默认 `surface`。
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: background ?? c.surface,
        borderRadius: BorderRadius.circular(MedShape.radiusCard),
        border: Border.all(color: borderColor ?? c.line, width: borderWidth),
        boxShadow: c.shadow,
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

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(MedShape.radiusBlock),
    );
    // 沿圆角矩形轮廓按 6 实 / 4 虚切段。
    const dash = 6.0, gap = 4.0;
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
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color;
}
