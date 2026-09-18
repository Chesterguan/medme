import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'gloss_tile.dart';

/// 长文本行(brief §形:图标块 + 全宽一项一行,**不用两栏**;mockup `.blk`)。
///
/// 为什么不用两栏:`s4` 故意塞了 12 种药和 6 个诊断,两栏会把「氯吡格雷 75 mg
/// 每日,至 2027 年 7 月」这种句子从中间切断。一项一行,说明靠右且不换行,挤不下
/// 时整条折到下一行 —— 折行比截断好。
class LongTextRow extends StatelessWidget {
  const LongTextRow({
    super.key,
    required this.category,
    required this.icon,
    required this.items,
  });

  final GlossCategory category;
  final IconData icon;

  /// `text` 是内容(可换行),`meta` 是右边那截说明(不换行,可以整条折下去)。
  final List<({String text, String? meta})> items;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GlossIconTile(icon: icon, category: category),
        const SizedBox(width: MedShape.s2),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              // Wrap:说明挤不下时整条掉到下一行,而不是把左边的内容压成一列字。
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 10,
                runSpacing: 2,
                children: [
                  Text(item.text, style: MedType.body.copyWith(fontSize: 15, height: 1.5)),
                  if (item.meta != null)
                    Text(item.meta!, softWrap: false,
                      style: MedType.secondary.copyWith(color: c.ink3)),
                ],
              ),
            ),
        ])),
      ]),
    );
  }
}
