import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'brand_logo.dart';
import 'med_card.dart';

/// 病程档案入口(减法稿):白卡一行 —— 30px 真 logo + 标题 + 一句说明 + 「活动度(化验
/// 可算部分) 0 / 18」这样的一行数字 + `›`。渐变书脊、右列大数都删了:入口要说的是
/// 「这是一本什么档案、现在什么状态」,不是一块颜色。
class RecordBookStrip extends StatelessWidget {
  const RecordBookStrip({
    super.key,
    required this.title,
    required this.subtitle,
    this.bigNumber,
    this.bigNumberSuffix,
    this.bigNumberCaption,
    this.titleTrailing,
    this.logo = const BrandLogo(size: BrandLogo.topBar),
    this.onTap,
  });

  final String title;
  final String subtitle;

  /// 那个数(「0 / 18」「2 项」)。没有就不画这一行 —— 不摆一个「—」占位。
  final String? bigNumber;
  final String? bigNumberSuffix;
  final String? bigNumberCaption;

  /// 标题后面那枚 pill(「示例」)。
  final Widget? titleTrailing;

  /// 真 logo,30px(与顶栏同一档)。传 `null` 则不画。
  final Widget? logo;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return MedCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s2, MedShape.s3, MedShape.s2),
          child: Row(
            children: [
              if (logo != null) ...[logo!, const SizedBox(width: MedShape.s2)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      // R21:标题可到两行 —— 病名是这条的主体,截成「系统性…」等于没说。
                      Flexible(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w500,
                              fontVariations: MedType.w500, height: 1.3))),
                      if (titleTrailing != null) ...[const SizedBox(width: 6), titleTrailing!],
                    ]),
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: MedType.secondary.copyWith(color: c.ink3)),
                    if (bigNumber != null) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 4,
                        children: [
                          if (bigNumberCaption != null)
                            Text(bigNumberCaption!, style: MedType.secondary.copyWith(color: c.ink3)),
                          Text(bigNumber!, style: MedType.value.copyWith(color: c.ink)),
                          if (bigNumberSuffix != null)
                            Text(bigNumberSuffix!, style: MedType.secondary.copyWith(color: c.ink3)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: MedShape.s1),
                Icon(Icons.chevron_right, size: 20, color: c.ink3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
