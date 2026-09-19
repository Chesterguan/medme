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
          // R24:child 槽位统一垫一层透明 Material,卡内 ListTile/InkWell 才有
          // Material 祖先(否则墨水飞溅不可见,Flutter 文档里的经典坑)。调用方
          // 不必再各自手抄这一层——见 MedBanner 内同款用法。
          Material(type: MaterialType.transparency, child: child),
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

/// 一颗可点选的分类 chip(mockup `.chips span` / `.chips .on`):未选中是白底药丸 +
/// 小阴影,选中是 `seal` 实底白字 —— 与 [MedPill] 系的「前景 + 浅底」状态色不同,
/// 这里表达的是「可点选的一个开关」,不是化验状态。
///
/// 原是「趋势」页(`trends_screen.dart`)的私有 `_PanelChip`;「一份病历」页
/// `.tab2` 的三段切换与它同一形状,Task 10 提到这里两边共用,不复制第二份
/// (R8)。`trends_screen.dart` 内继续用 `PanelChipsRow` 管选中态与横向滚动布局,
/// 只是每一颗渲染换成这里。
class MedChip extends StatelessWidget {
  const MedChip({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MedShape.radiusPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: MedShape.s2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? c.seal : Colors.white,
          borderRadius: BorderRadius.circular(MedShape.radiusPill),
          // mockup `.chips span` 恒有这道小阴影,`.on` 只覆盖 background/color,
          // 阴影两态相同(不是只有未选中才有)。
          boxShadow: MedBrand.chipShadow,
        ),
        child: Text(
          // 计数直接跟在文案后面(「肾功能 6」),不用括号 —— 与卡头「最新值 +
          // 单位」同一套「数字紧挨着它描述的东西」的排法。
          '$label $count',
          style: MedType.secondary.copyWith(
            fontSize: 14,
            color: selected ? Colors.white : c.ink2,
            fontFeatures: MedType.tabular,
          ),
        ),
      ),
    );
  }
}

/// 「看懂」蓝横幅(mockup `.read`:底 `MedBrand.bannerBlue`、圆角
/// `MedShape.radiusBanner`,引用某份报告「提示」一栏的原文)。
///
/// **[text]/[source] 都不传时**仍然显示那句「还在做」的占位 —— 真内容(哪份报告、
/// 原文哪一段)由另一条线接,在那之前一个字都不许编,这两个参数因此默认 `null`,
/// 不默认成任何编出来的话。两个参数是为了视觉验收测试能喂样例文字去断言横幅的
/// 底色/圆角/字色,不代表生产环境已经接了真内容。
///
/// 原是「趋势」页的私有 `UnderstandBanner`,Task 10 提到这里改名共用(R8);
/// `trends_screen.dart` 用 `typedef UnderstandBanner = MedReadBanner` 保留原名,
/// 调用方一个字不用改。
class MedReadBanner extends StatelessWidget {
  const MedReadBanner({super.key, this.text, this.source});

  /// 报告「提示」一栏摘出来的原文。`null` → 占位那句「还在做」。
  final String? text;

  /// 原文出处的一句交代。`null` → 不画这一行(与 `SeriesCard` 的
  /// `refSourceCitation` 同一条「查不到出处就不画」的规矩)。
  final String? source;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MedShape.s3,
        vertical: MedShape.s2,
      ),
      decoration: BoxDecoration(
        color: MedBrand.bannerBlue,
        borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '看懂',
            style: MedType.caption.copyWith(
              color: MedBrand.bannerBlueInk,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text ?? '把报告上那段「提示」原文摘出来放这里 —— 还在做。',
            style: MedType.body.copyWith(fontSize: 15, height: 1.55),
          ),
          if (source case final s?) ...[
            const SizedBox(height: 4),
            // 不加任何前缀文案(比如「出处:」)——那会是这份文件里没出现过的新
            // 字。真内容接进来那天,这一行该怎么措辞是那条线的事,这里只给
            // 样式,原样显示调用方给的这句话。
            Text(
              s,
              style: MedType.caption.copyWith(
                color: c.ink2,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ],
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

/// 输入框/信息面板(mockup `.field`):白底、圆角 16、卡阴影、17 号字。
class MedFieldPanel extends StatelessWidget {
  const MedFieldPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      boxShadow: MedBrand.cardShadow),
    padding: const EdgeInsets.all(15),
    child: DefaultTextStyle.merge(
      style: MedType.body.copyWith(fontSize: 17, color: MedColors.of(context).ink3),
      child: child),
  );
}

/// 恢复码框(mockup `.code`):等宽 20 号、字距 .1em、paper 底、sealInk 字、圆角 14。
///
/// **字距单位是逻辑像素不是 em**(Flutter 的老坑):.1em × 20px = 2.0。
class RecoveryCodeBox extends StatelessWidget {
  const RecoveryCodeBox({super.key, required this.code});
  final String code;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: c.paper,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock)),
      padding: const EdgeInsets.all(13),
      child: Text(code, textAlign: TextAlign.center,
        style: TextStyle(fontFamily: 'monospace', fontSize: 20,
            letterSpacing: 2.0, color: c.sealInk)),
    );
  }
}

/// 二维码白框(mockup `.qr`):白底 + 10 内边距 + 圆角 16 + 专用阴影。
class MedQrFrame extends StatelessWidget {
  const MedQrFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      boxShadow: MedBrand.qrShadow),
    padding: const EdgeInsets.all(10),
    child: child,
  );
}

/// 「病历」首页 hero 下面那两颗方块(`s1`)与「换新手机」(`s15`)输口令/用恢复码
/// 两块共用的白块样式(mockup 的 `.qa`):白底 + 一枚光泽图标块 + 标题下的短标签。
///
/// R8:原是 `archive_screen.dart` 的私有 `_Tile`,只给 `HomeTiles` 用;Task 13
/// 把它提到这里改名共用(纯搬家改名,布局/参数一个字没变),`archive_screen.dart`
/// 的 `HomeTiles` 与 `account_screen.dart` 换新手机屏两处都调它,不再各写一份。
class MedEntryTile extends StatelessWidget {
  const MedEntryTile({super.key, required this.icon, required this.category, required this.label, this.onTap});

  final IconData icon;
  final GlossCategory category;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(MedShape.radiusEntry),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MedShape.radiusEntry),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(MedShape.radiusEntry),
          boxShadow: MedBrand.cardShadow,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GlossIconTile(icon: icon, category: category),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center,
            style: MedType.body.copyWith(fontWeight: FontWeight.w500,
                fontVariations: MedType.w500)),
        ]),
      ),
    ),
  );
}

/// 底部 sheet 里的一条选项(mockup `.opt`):paper 底圆角块 + 光泽图标块 + 17 号字
/// + 右侧一句灰色小注。[highlighted] 的那条换成蓝底 —— `s6` 用它标出推荐的那条。
class MedSheetOption extends StatelessWidget {
  const MedSheetOption({super.key, required this.icon, required this.category,
      required this.label, this.note, this.highlighted = false, this.onTap});
  final IconData icon; final GlossCategory category;
  final String label; final String? note;
  final bool highlighted; final VoidCallback? onTap;

  /// 圆角块自身的水平内边距(fix round 1,task-14-review Minor)。外部想让
  /// 别的内容(比如 `import_flow.dart` 的 `_SheetTile` 那句说明)跟标题左对齐,
  /// 要从这个值算起,不要另写一个数字——两处早晚会对不上。
  static const double hPad = 12;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(type: MaterialType.transparency, child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBanner),
        child: Container(
          decoration: BoxDecoration(
            color: highlighted ? MedBrand.bannerBlue : c.paper,
            borderRadius: BorderRadius.circular(MedShape.radiusBanner)),
          padding: const EdgeInsets.fromLTRB(hPad, 10, hPad, 10),
          child: Row(children: [
            GlossIconTile(icon: icon, category: category),
            const SizedBox(width: MedShape.s2),
            Expanded(child: Text(label, style: MedType.body.copyWith(fontSize: 17))),
            if (note != null) Text(note!, style: MedType.secondary.copyWith(color: c.ink3)),
          ]),
        ),
      )),
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
