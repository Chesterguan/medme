// 自测周(`TimelineGroupDto.selfWeek`)在「病历」时间线上的渲染:月卡里那一行
// 标题/说明的两个纯函数 + 展开后一行一份自测的子行列表([SelfWeekRows])。
//
// 「自测周」是投影层把同一自然周(周一到周日)的自测记录折成的一组——单次自测
// 没有意义,一周才看得出范围(`api/dto.dart` 的 `TimelineGroupDto.selfWeek` 头
// 部注释,用户 2026-09-23)。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/lab_status.dart' show fmtLabNumber;
import 'package:mobile_flutter/widgets/med_card.dart' show swipeDeleteBackground;

/// 月卡里那一行标题:「自测 · 4 月 27 日 – 5 月 3 日」。
String selfWeekTitle(String weekStart, String weekEnd) =>
    '自测 · ${fmtDayRange(weekStart, weekEnd)}';

/// 一段数值区间:`min == max` 只写一个数,否则用 en dash 连起来、不加空格 ——
/// 这里连的是紧挨着单位的两个数字,跟 [fmtDayRange] 连两个日子(给人读、两侧
/// 各留一个空格)不是同一种排法。
String _rangeStr(double min, double max) =>
    min == max ? fmtLabNumber(min) : '${fmtLabNumber(min)}–${fmtLabNumber(max)}';

/// 月卡里那一行说明:「血压 5 次 118–132 / 74–80 · 心率 5 次 66–74 · 血糖 1 次
/// 6.3」——收缩压/舒张压并成一项(两个数用 `/` 连、外面共用一个「N 次」),
/// 其余指标各自一项。**不显示单位**:这一行是列表里的概览,单位在展开后的
/// [selfValuesLine] 才出现。
String selfWeekDesc(List<SelfWeekItemDto> items) {
  final byKey = {for (final it in items) it.analyteKey: it};
  var bpDone = false;
  final parts = <String>[];
  for (final it in items) {
    final isBp = it.analyteKey == 'bp_systolic' || it.analyteKey == 'bp_diastolic';
    if (isBp) {
      if (bpDone) continue;
      bpDone = true;
      final sys = byKey['bp_systolic'];
      final dia = byKey['bp_diastolic'];
      final range = [sys, dia]
          .whereType<SelfWeekItemDto>()
          .map((d) => _rangeStr(d.min, d.max))
          .join(' / ');
      final count = (sys ?? dia)!.count;
      parts.add('${selfAnalyteLabel(it.analyteKey)} $count 次 $range');
      continue;
    }
    parts.add('${selfAnalyteLabel(it.analyteKey)} ${it.count} 次 ${_rangeStr(it.min, it.max)}');
  }
  return parts.join(' · ');
}

/// 展开行里一份自测的值:「血压 122/76 mmHg」「血糖 6.3 mmol/L」—— 血压两个数
/// 合成「收缩/舒张」,其余指标本来就只有一条,原样显示。
String selfValuesLine(List<SelfMeasuredValueDto> values) {
  final byKey = {for (final v in values) v.analyteKey: v};
  final sys = byKey['bp_systolic'];
  final dia = byKey['bp_diastolic'];
  if (sys != null && dia != null) {
    return '${selfAnalyteLabel(sys.analyteKey)} ${fmtLabNumber(sys.value)}/${fmtLabNumber(dia.value)} ${sys.unit}';
  }
  return values
      .map((v) => '${selfAnalyteLabel(v.analyteKey)} ${fmtLabNumber(v.value)} ${v.unit}')
      .join(' · ');
}

/// 自测周展开后的子行:一行一份自测(`fmtDate` + [selfValuesLine]),可点开
/// 原件、左滑删——排版照 `archive_screen.dart` 的 `_SubDocList`(就诊组展开后的
/// 子文档行),两处子行不该长得不一样。
class SelfWeekRows extends StatelessWidget {
  const SelfWeekRows({
    super.key,
    required this.docs,
    required this.onOpen,
    required this.onDelete,
  });

  final List<SelfWeekDocDto> docs;
  final void Function(int docId) onOpen;
  final Future<void> Function(int docId, String label) onDelete;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      children: [
        for (final d in docs)
          Dismissible(
            key: ValueKey('self-week-doc-${d.doc.id}'),
            direction: DismissDirection.endToStart,
            background: swipeDeleteBackground(context, rounded: false),
            confirmDismiss: (_) async {
              await onDelete(d.doc.id, selfValuesLine(d.values));
              return false;
            },
            child: Container(
              // 卡内行间用二级分隔线 `line-2`,与 `_SubDocList` 同一手法。
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line2)),
              ),
              child: InkWell(
                onTap: () => onOpen(d.doc.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MedShape.s3 + MedShape.s2,
                    vertical: MedShape.s2,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          selfValuesLine(d.values),
                          style: MedType.body.copyWith(color: c.ink),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: MedShape.s1),
                      Text(
                        fmtDate(d.doc.docDate),
                        style: MedType.caption.copyWith(
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                          fontFeatures: MedType.tabular,
                          color: c.ink3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
