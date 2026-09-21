import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

/// 文档类型 / 就诊类型的中文标签与图标 —— 全 app **唯一**一份。
///
/// 这些映射原本私有在 `screens/archive_screen.dart` 里。「趋势」「给医生看」等
/// 好几个屏也要显示同样的「化验 / 影像 / 出院小结」,再抄一份就意味着同一份
/// 病历在不同屏上可能叫两个名字。挪到这里,改一处处处一致。
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

/// 档案行上那句「这是什么」。类型认得出就用 [docLabel];认不出(`unknown`)时
/// 再看云抽取三态([DocumentSummaryDto.extractionItemCount]),把「待归类」拆开:
///
/// - `null`(还没跑过 / 离线 / 被拒发)→ 「待归类」,如实说还没轮到它。
/// - `0`(跑过了,一条都没读出来)→ 「云端整理没有读出内容」。
/// - `>0` → 读出了东西却仍然分不出类型,这是分类本身的事,还是「待归类」。
///
/// 冒烟 friction 2:前两态原先都显示「待归类」,用户看到的是一份永远停在待归类
/// 的文档,分不清是还在跑、还是跑完白跑了。
String docRowLabel(DocumentSummaryDto doc) {
  if (doc.docType != 'unknown') return docLabel[doc.docType] ?? '记录';
  if (doc.extractionItemCount == 0) return '云端整理没有读出内容';
  return docLabel['unknown']!;
}

/// 这个文件名是**机器起的**(相册/相机/落库兜底),不是用户起的。
///
/// 相册和相机交给我们的是 `image_picker_1A2B….jpg`、`IMG_0042.JPG` 这类临时名,
/// 它一路被当成 `document.title` 存下来,于是档案里排着一列看不懂的字符串 ——
/// 这些名字**一个字的信息量都没有**,宁可显示「化验」也不显示它们。用户自己起的
/// 名(「出院小结扫描件.pdf」)反过来是有信息的,那种要留。
///
/// 只影响**显示**:存下来的文件名一个字节都不动(原件永远按原名躺在 CAS 里)。
bool isTempCaptureName(String name) {
  final n = name.trim();
  if (n.isEmpty) return true;
  // image_picker 的临时名,含 `scaled_` 前缀那种压缩产物。
  if (n.toLowerCase().contains('image_picker')) return true;
  return _tempNamePatterns.any((re) => re.hasMatch(n));
}

final List<RegExp> _tempNamePatterns = [
  // 相机/相册的序号名:iOS `IMG_0042`、安卓 `CAP_`/`PXL_`/`DSC`。
  RegExp(r'^(img|cap|pxl|dsc|dcim)[_-]?\d', caseSensitive: false),
  // `ingest_image_with_text` 拿不到文件名时的兜底(vault.rs)。
  RegExp(r'^capture\.', caseSensitive: false),
  // 裸 UUID(iOS 相册导出、部分安卓 ROM 就这么命名)。
  RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.\w+)?$',
    caseSensitive: false,
  ),
];

/// 档案行 / 详情页上这份文档**叫什么**。取名顺位(高的先):
///
/// 0. 笔记 / 自测记录的 `title` —— 那是 Rust 写的**内容**(笔记首行、「血压」),
///    不是文件名,谁也不该盖掉它。
///
/// 1. `<医院> · <类型>` —— 两样都认出来了,这是最有用的一行。
/// 2. `<类型>`(没有机构的自测记录、笔记)。
/// 3. `<医院> · <日期>` —— 认得出在哪看的,类型还没分出来。
/// 4. `<日期>` —— 只知道什么时候。
/// 5. 文件名,**且只在它是用户自己起的时候**(见 [isTempCaptureName])。
/// 6. [docRowLabel] 的三态说法(「待归类」/「云端整理没有读出内容」)。
///
/// 日期只在类型缺位时进标题:档案行本来就单独有一列日期(`_groupDate`),两边都
/// 印就成了「化验 · 2026-04-30    2026-04-30」。
String docDisplayTitle(DocumentSummaryDto doc) {
  final title = doc.title?.trim() ?? '';
  // 「记录」入口产出的两类文档,`title` **不是文件名,是内容**:`add_note` 写的是
  // 笔记首行前 30 字,`self_measured_title` 写的是「血压」/「血糖」。拿类型标签盖掉
  // 它,列表上所有笔记就都叫「笔记」、所有自测都叫「自测记录」,彼此再也分不开。
  // 这两类没有原件、没有机构,标题只有这一个来源。
  if (title.isNotEmpty &&
      (doc.docType == 'note' || doc.docType == 'self_measurement')) {
    return title;
  }
  final provider = doc.provider?.trim() ?? '';
  // `unknown` 不是一种类型,是「还没分出来」—— 它的说法归 [docRowLabel] 管。
  final label = doc.docType == 'unknown'
      ? ''
      : (docLabel[doc.docType] ?? '记录');
  final parts = [
    if (provider.isNotEmpty) provider,
    if (label.isNotEmpty) label else fmtDate(doc.docDate),
  ].where((p) => p.isNotEmpty);
  if (parts.isNotEmpty) return parts.join(' · ');

  if (title.isNotEmpty && !isTempCaptureName(title)) return title;
  return docRowLabel(doc);
}

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

/// 文档类型 → 光泽图标块的类别色(brief §色 的类别色表;R3:`GlossCategory` 只有
/// 九档,不为文档类型新增语义,这里只挑最贴切的既有档归类)。
///
/// · `lab_report` 直接对应 [GlossCategory.lab];`pathology`(病理)同归一档 ——
///   两者都是检验科出具的化验/病理报告。
/// · `imaging_report` → [GlossCategory.imaging];`prescription` → [GlossCategory.med]。
/// · `discharge_summary`(出院小结)、`clinical_note`(病历)、`surgery`(手术)
///   同归 [GlossCategory.clinic] —— 都是医疗机构就诊/操作留下的记录。
/// · `note`(笔记)、`self_measurement`(自测记录)同归 [GlossCategory.note] ——
///   两者都是「记录」入口手动录入、背后没有原件(见 [docLabel] 上方注释)。
/// · `other` / `unknown` 与任何认不出的类型一律 [GlossCategory.neutral]:
///   「还没分出来」不该借用某个具体类别的颜色。
///
/// Task 8(「病历」主页)与 Task 9(「趋势」页)共用同一份映射,不各写各的。
GlossCategory categoryForDocType(String docType) => switch (docType) {
  'lab_report' || 'pathology' => GlossCategory.lab,
  'imaging_report' => GlossCategory.imaging,
  'prescription' => GlossCategory.med,
  'discharge_summary' || 'clinical_note' || 'surgery' => GlossCategory.clinic,
  'note' || 'self_measurement' => GlossCategory.note,
  _ => GlossCategory.neutral, // other / unknown / 任何认不出的类型
};

/// `VisitRecordDto.kind` 的取值**跨了两个命名空间**:就诊组用 `inpatient` 这类,
/// 独立文档用 `lab_report` 这类(见 DTO 文档)。两张表都查一遍,都不中就原样透出
/// —— 编一个好看的名字不如把我们读到的原值给人看。
String visitKindLabel(String kind) => kindLabel[kind] ?? docLabel[kind] ?? kind;

IconData iconForVisitKind(String kind) =>
    _kindIcon[kind] ?? _docIcon[kind] ?? Icons.local_hospital_outlined;

/// `VisitRecordDto.kind` 的光泽图标块类别。同一条「两张表都查一遍」的思路:
/// 就诊组命名空间(住院/门诊/急诊/检查)一律 [GlossCategory.clinic]——都是「到
/// 医疗机构走了一趟」,九档里没有更细的桶(与 `archive_screen.dart` 的
/// `_categoryOf` 对 `TimelineGroupDto_Encounter` 的归类同一处理);独立文档命名
/// 空间(`lab_report` 这类)直接交给 [categoryForDocType](Task 8 已有、Task 9
/// 复用,R3 裁定:不再另写一份文档类型映射)。都不中的按 [categoryForDocType]
/// 自己的兜底走 [GlossCategory.neutral]。
GlossCategory categoryForVisitKind(String kind) => switch (kind) {
  'inpatient' || 'outpatient' || 'emergency' || 'exam' => GlossCategory.clinic,
  _ => categoryForDocType(kind),
};

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
