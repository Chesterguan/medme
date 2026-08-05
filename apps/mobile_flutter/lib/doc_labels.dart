import 'package:flutter/material.dart';

/// 文档类型 / 就诊类型的中文标签与图标 —— 全 app **唯一**一份。
///
/// 这些映射原本私有在 `screens/archive_screen.dart` 里。信息架构改成五个 tab 之后,
/// 概览、「看病带这个」浮层也要显示同样的「化验 / 影像 / 出院小结」,再抄一份就
/// 意味着同一份病历在两个 tab 上可能叫两个名字。挪到这里,改一处四处一致。
///
/// 与 core-model `types.rs`、旧 `App.tsx` 的取值保持一致。

/// `doc_type` → 中文标签。
const Map<String, String> docLabel = {
  'lab_report': '化验',
  'imaging_report': '影像',
  'discharge_summary': '出院小结',
  'prescription': '处方',
  'clinical_note': '病历',
  'pathology': '病理',
  'surgery': '手术',
  // 手动录入(「记录」入口产出,没有原件——见 MANUAL-ENTRY-DESIGN.md)。
  'self_measurement': '自测记录',
  'note': '笔记',
  'other': '其他',
  'unknown': '待归类',
};

/// 就诊组 `kind` → 中文标签。
const Map<String, String> kindLabel = {
  'inpatient': '住院',
  'outpatient': '门诊',
  'emergency': '急诊',
  'exam': '检查',
};

// 文档类型/就诊类型 → 图标。
//
// **配色表整张删掉了。** 原先每种文档类型一个颜色(化验蓝 #1D4ED8、影像橙
// #B45309、病理红 #BE123C、处方绿、出院靛、手术紫……九色),问题不是花,是
// **撞语义**:那三个色值正是设计系统里「偏低 / 偏高 / 危急值」的化验状态色。
// 一枚 #1D4ED8 的「化验」徽标和一行 #1D4ED8 的「偏低」在同一屏上,颜色在讲
// 两件毫不相干的事 —— 而这一屏的用户正在学「蓝=偏低」。
//
// 现在类型只靠**图标形状**区分,底色统一用主色 `seal` 的极浅底。三个状态色
// 从此在个人模式里只有一个含义:化验值不正常。
const Map<String, IconData> _docIcon = {
  'lab_report': Icons.science_outlined,
  'imaging_report': Icons.document_scanner_outlined,
  'prescription': Icons.medication_outlined,
  'discharge_summary': Icons.bed_outlined,
  'clinical_note': Icons.medical_services_outlined,
  'pathology': Icons.biotech_outlined,
  'surgery': Icons.content_cut,
  'self_measurement': Icons.monitor_heart_outlined,
  'note': Icons.sticky_note_2_outlined,
  'other': Icons.description_outlined,
  'unknown': Icons.help_outline,
};

const Map<String, IconData> _kindIcon = {
  'outpatient': Icons.medical_services_outlined,
  'inpatient': Icons.bed_outlined,
};

IconData iconForDoc(String docType) =>
    _docIcon[docType] ?? Icons.description_outlined;

IconData iconForKind(String kind) =>
    _kindIcon[kind] ?? Icons.local_hospital_outlined;

/// `VisitRecordDto.kind` 的取值**跨了两个命名空间**:就诊组用 `inpatient` 这类,
/// 独立文档用 `lab_report` 这类(见 DTO 文档)。两张表都查一遍,都不中就原样透出
/// —— 编一个好看的名字不如把我们读到的原值给人看。
String visitKindLabel(String kind) => kindLabel[kind] ?? docLabel[kind] ?? kind;

IconData iconForVisitKind(String kind) =>
    _kindIcon[kind] ?? _docIcon[kind] ?? Icons.local_hospital_outlined;

/// 一条信息的**最后一份**来源文档 id;没有来源时返回 null。
///
/// 三个投影 DTO 的 `documentIds` 类型是 flutter_rust_bridge 的 `Int64List`,元素是
/// `BigInt`(为了 64 位在 web 上也不丢精度),而 `getDocument` 这条 FFI 收的是
/// `int` —— 中间这步 `toInt()` 是必须的,不是多余的。
///
/// 取**最后一份**:一条信息常被好几份病历提到(同一个药开过三次),最后一份就是
/// 最近一次提到它的那张纸,也是追问时最想看的那张。想看全部提及,走档案。
int? lastDocumentId(List<BigInt> ids) => ids.isEmpty ? null : ids.last.toInt();

/// ISO 日期串 → `YYYY-MM-DD`。解析不出来时返回空串(调用方自行决定怎么留白)。
String fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
