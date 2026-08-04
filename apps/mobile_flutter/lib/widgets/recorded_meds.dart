import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';

/// 「在用药」这个词在 MedMe 里是**假的**,这个文件负责不让它出现在屏幕上。
///
/// ## 事实
///
/// `parser` 的 `MedSpan.status` 目前**恒为 `"active"`** —— 它不推断停药,任何一次
/// 在任何一份记录里被提到过的药,都会以 `active` 出现在 `EmergencyCardDto.activeMeds`
/// 与 `VisitSummaryDto.activeMeds` 里。DTO 的字段名叫 `activeMeds`,但它真正的语义是
/// **「记录中出现过的药物」**,不是「当前医嘱」。
///
/// 五年前一次门诊开的三天头孢,和今天早上还在吃的降压药,在这个列表里长得一模一样。
///
/// ## 为什么这件事必须在代码里挡住
///
/// 因为读它的人会当真。**应急卡上尤其危险**:急救医生看到「在用药:美托洛尔」,
/// 会据此判断心率、调整用药——而那可能是三年前一张出院小结上的一行字。这不是
/// 措辞洁癖,是会改变处置决定的事实错误。
///
/// 所以:
/// 1. 标题一律用 [kRecordedMedsTitle](「记录中出现的药物」),**不许**出现「在用药」
///    「正在服用」「当前用药」这类暗示当前医嘱的说法;
/// 2. 每一条都必须带 [recordedMedTiming] —— 最后一次出现的日期,这是读者判断
///    「这条还算不算数」的唯一依据;
/// 3. 列表旁必须有 [RecordedMedsCaveat],把「我们不知道停没停」说出口。
///
/// 等 `parser` 真能推断停药那天,改的是这个文件,不是四个屏。
const String kRecordedMedsTitle = '记录中出现的药物';

/// 列表旁那句话。**不要改软。** 它的作用是拦住一个会改变处置决定的误读。
const String kRecordedMedsCaveat =
    '以下药名是从已导入的病历里读到的,不代表当前医嘱 —— MedMe 无法判断是否已停药。'
    '请以病人本人、家属或原始处方为准。';

/// 急救场景下的同一句话,更短更硬 —— 急诊医生没有时间读三行。
const String kRecordedMedsCaveatUrgent = '这不是当前医嘱,只是既往病历里提到过的药。请向本人或家属确认。';

/// 一条药的时间与剂量说明:`0.5g bid · 最后一次出现 2024-03-12`。
///
/// 「最后一次出现」用 [ActiveMedDto.until] —— 最晚一次**带日期**的提及。整条记录
/// 都没有日期时(`until == null`)明说「记录里没有日期」,而不是留白:留白会被读成
/// 「最近」,那正好是最危险的一种误读。
String recordedMedTiming(ActiveMedDto m) {
  final parts = <String>[
    if (m.dose case final d? when d.trim().isNotEmpty) d.trim(),
    if (m.until case final u? when u.isNotEmpty)
      '最后一次出现 $u'
    else
      '记录里没有日期',
  ];
  return parts.join(' · ');
}

/// 「记录中出现的药物」列表旁的说明块。规范 §warn 的样式:左侧 3px 竖条 + 极浅底。
///
/// 用琥珀 `high` 而不是红 `critical`:这不是事故,是**我们能力的边界**——红色留给
/// 「可能导错了人」那一级(见 `archive_screen.dart` 的两级警告)。
class RecordedMedsCaveat extends StatelessWidget {
  const RecordedMedsCaveat({super.key, this.text = kRecordedMedsCaveat});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: MedShape.s2,
        vertical: MedShape.s1,
      ),
      decoration: BoxDecoration(
        color: c.highWash,
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(MedShape.radiusBlock),
        ),
        border: Border(left: BorderSide(color: c.high, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: c.high),
          const SizedBox(width: MedShape.s1),
          Expanded(
            child: Text(
              text,
              style: MedType.secondary.copyWith(color: c.ink, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
