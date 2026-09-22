import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';

/// 主页顶部那一行:**你是谁,现在看的是谁**。名字一行,下面一行元数据(性别 · 年龄 ·
/// N 份记录 · 最近就诊 · 日期),右边一对 `⌃⌄` —— 整行可点,弹出成员切换器。
///
/// 减法稿 2026-09-22:原来是一张品牌渐变主卡 + 头像块(`IdentityHeroCard`)。切成员的
/// 隐私含义靠**名字本身**说清楚,不靠一块深色面;主页第一眼该落在「有没有要我做的」
/// 那一行上。
class MemberHeader extends StatelessWidget {
  const MemberHeader({
    super.key,
    required this.name,
    required this.gender,
    required this.age,
    required this.recordCount,
    required this.recentVisitDate,
    required this.onSwitchMember,
  });

  /// 显示名。取的是当前成员标签(调用方已经在 `ProfileManager.displayName` 与
  /// 报告识别名之间做过选择),这里只管显示。
  final String name;
  final String? gender;
  final String? age;
  final int recordCount;

  /// 最近一次就诊/添加的日期,`"YYYY-MM-DD"`。没有任何记录、或那条记录没识别到
  /// 日期时为 null —— 显示「暂无」,**不许**当 0 或今天填。
  final String? recentVisitDate;
  final VoidCallback onSwitchMember;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 性别/年龄缺失就不写这一段,不编「未登记」——沿用既有行为。
    final subParts = [
      ...[gender, age].whereType<String>().where((x) => x.isNotEmpty),
      '$recordCount 份记录',
    ];
    final recentVisitText = fmtDate(recentVisitDate);
    final meta = '${subParts.join(' · ')} · 最近就诊 · ${recentVisitText.isEmpty ? '暂无' : recentVisitText}';
    return Semantics(
      button: true,
      label: '当前查看:$name。点击切换成员',
      child: InkWell(
        onTap: onSwitchMember,
        borderRadius: BorderRadius.circular(MedShape.radiusControl),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, MedShape.s1, 4, MedShape.s1),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // **不设 maxLines/ellipsis** —— 大字号下姓名换行,不许被截断。
                    Text(name, style: MedType.body.copyWith(
                        color: c.ink, fontWeight: FontWeight.w600, fontVariations: MedType.w600)),
                    const SizedBox(height: 2),
                    Text(meta, style: MedType.secondary.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                  ],
                ),
              ),
              const SizedBox(width: MedShape.s1),
              // 切成员的可视提示,与档案屏 `_PatientHeader` 同一图标语汇。
              Icon(Icons.unfold_more, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
