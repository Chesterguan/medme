// 首页「待办」卡:档案到期提醒(FFI `vaultProfileDueReminders`)+ 30 天内异常化验
// 项数(FFI `viewAbnormal30D`)。装配逻辑(取数、兜底、拼 items)在
// `screens/archive_screen.dart`——这里只有纯展示部件、`DueReminder` 的 JSON 小
// 模型,和把一条提醒拼成卡片一行次要说明的纯函数。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart'
    show reminderBasisLabel, reminderOverdueNote, reminderStateLabel;

/// `vaultProfileDueReminders(dir:)` 那份 JSON 数组的一条。Rust 已经把 `pending`
/// (规则没核实,档案页里「只显示不到期」的东西)过滤掉了——`state` 到这里恒为
/// `'never'` 或 `'overdue'`,见该函数文档。
class DueReminder {
  const DueReminder({
    required this.packageId,
    required this.packageName,
    required this.id,
    required this.text,
    required this.state,
    this.dueAt,
    this.overdueDays,
    this.basis,
  });

  final String packageId;
  final String packageName;
  final String id;
  final String text;
  final String state;
  final String? dueAt;
  final int? overdueDays;
  final String? basis;

  factory DueReminder.fromJson(Map<String, dynamic> j) => DueReminder(
    packageId: j['package_id'] as String? ?? '',
    packageName: j['package_name'] as String? ?? '',
    id: j['id'] as String? ?? '',
    text: j['text'] as String? ?? '',
    state: j['state'] as String? ?? '',
    dueAt: j['due_at'] as String?,
    overdueDays: (j['overdue_days'] as num?)?.toInt(),
    basis: j['basis'] as String?,
  );
}

/// 一条提醒在待办卡上的次要说明:状态部分 + `依据`(fix round 1 Important 1,
/// spec §一/§五:「超期 N 天 / 从没查过 · 依据」)。状态部分超期的写「超期 N 天」
/// (与病程档案页 meta 行逐字同一句),其余(`never`)沿用档案页的状态标签;
/// `basis` 取不到(包没给)就只有状态部分,不留一个悬空的 ` · `——两处都不写
/// 第二份措辞,原样调用 `profile_sections.dart` 已有的三个函数。
String reminderNote(DueReminder r) {
  final statePart = (r.state == 'overdue' && r.overdueDays != null)
      ? reminderOverdueNote(r.overdueDays)
      : reminderStateLabel(r.state);
  final basis = reminderBasisLabel(r.basis);
  return [statePart, ?basis].join(' · ');
}

class HomeTodoItem {
  const HomeTodoItem({required this.title, this.note, this.titleColor, required this.onTap});
  final String title;
  final String? note;
  final Color? titleColor;
  final VoidCallback onTap;
}

/// 首页「待办」卡:一张白卡,一行一条,没有条目整块不画。
class HomeTodo extends StatelessWidget {
  const HomeTodo({super.key, required this.items});
  final List<HomeTodoItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final c = MedColors.of(context);
    return MedCard(
      child: Column(children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
          InkWell(
            onTap: items[i].onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(items[i].title, style: MedType.body.copyWith(
                      color: items[i].titleColor ?? c.ink, fontWeight: FontWeight.w500, fontVariations: MedType.w500)),
                  if (items[i].note case final n?) ...[
                    const SizedBox(height: 2),
                    Text(n, style: MedType.secondary.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                  ],
                ])),
                const SizedBox(width: MedShape.s1),
                Icon(Icons.chevron_right, size: 20, color: c.ink3),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
