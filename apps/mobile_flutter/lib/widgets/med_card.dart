import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'gloss_tile.dart';

/// 设计系统 v1 的共用外壳:卡片、状态 pill、横幅。
///
/// 规范正本 `DESIGN-SYSTEM-v1.html`;色值/字号/圆角/间距一律取自
/// `design_tokens.dart`,这里只负责**怎么摆**,不新增任何裸色值。

/// 标准卡片:`surface` 底 + 圆角 16 + 1px `line` 细边,**无阴影**(减法稿 2026-09-22:
/// 层次靠字号和留白,不靠阴影)。骑缝线已删——没人读得出那排点在说「可溯源」。
class MedCard extends StatelessWidget {
  const MedCard({super.key, required this.child, this.background});

  /// 卡片内容。**不带内边距** —— 由调用方决定(有的卡整块要盖 InkWell)。
  final Widget child;

  /// 卡片底色,默认 `surface`。
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: background ?? c.surface,
        borderRadius: BorderRadius.circular(MedShape.radiusCard),
        border: Border.all(color: c.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // R24:child 槽位统一垫一层透明 Material,卡内 ListTile/InkWell 才有 Material 祖先。
          Material(type: MaterialType.transparency, child: child),
        ],
      ),
    );
  }
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

/// 一个上了色的状态词(12·600,无底):化验行的「偏高」「偏低」、还没核对卡片的
/// 「还没核对」。减法稿:状态 = 一个词 + 颜色,不再是 pill。
Widget statusWord(String text, Color color) => Text(
  text,
  style: MedType.caption.copyWith(color: color, fontWeight: FontWeight.w600, fontVariations: MedType.w600),
);

/// 横幅(mockup `.banner`):圆角 16,左边一枚图标,标题用对应的横幅文字色,
/// 副标用 ink2;右边一枚 `›`(**只在 [onTap] 非空时画** —— 沿用
/// `PendingReviewBanner` 既有那条规矩:没有去处就不画箭头)。
class MedBanner extends StatelessWidget {
  const MedBanner({super.key, required this.icon, required this.title, this.subtitle, this.amber = false, this.onTap});

  final IconData icon;
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
              Icon(icon, size: 20, color: ink),
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

/// 一颗可点选的分类 chip(mockup `.chips span` / `.chips .on`):白底 + 描边药丸,
/// 未选中 `line` 描边、`ink2` 字,选中 `seal` 描边、`sealInk` 字 —— 与 [MedPill] 系
/// 的「前景 + 浅底」状态色不同,这里表达的是「可点选的一个开关」,不是化验状态。
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
          color: c.surface,
          borderRadius: BorderRadius.circular(MedShape.radiusPill),
          border: Border.all(color: selected ? c.seal : c.line),
        ),
        child: Text(
          // 计数直接跟在文案后面(「肾功能 6」),不用括号 —— 与卡头「最新值 +
          // 单位」同一套「数字紧挨着它描述的东西」的排法。
          '$label $count',
          style: MedType.secondary.copyWith(
            fontSize: 14,
            color: selected ? c.sealInk : c.ink2,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            fontVariations: selected ? MedType.w600 : null,
            fontFeatures: MedType.tabular,
          ),
        ),
      ),
    );
  }
}

/// 输入框/信息面板(mockup `.field`):白底、圆角 16、1px line 细边、17 号字。
class MedFieldPanel extends StatelessWidget {
  const MedFieldPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      border: Border.all(color: MedColors.of(context).line)),
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

/// 二维码白框(mockup `.qr`):白底 + 10 内边距 + 圆角 16 + 1px line 细边。
class MedQrFrame extends StatelessWidget {
  const MedQrFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      border: Border.all(color: MedColors.of(context).line)),
    padding: const EdgeInsets.all(10),
    child: child,
  );
}

/// 「病历」首页 hero 下面那两颗药丸(`s1`)与「换新手机」(`s15`)输口令/用恢复码
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
          border: Border.all(color: MedColors.of(context).line),
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

/// 沿圆角矩形轮廓画虚线,`DottedBorderBox`(空态大框)用它画 1.5px 虚线描边
/// (唯一调用方,半径/疏密不再对外开放参数)。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter(this.color);

  final Color color;

  static const double _radius = MedShape.radiusBlock;
  static const double _dash = 6;
  static const double _gap = 4;
  static const double _strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(_radius),
    );
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color;
}
