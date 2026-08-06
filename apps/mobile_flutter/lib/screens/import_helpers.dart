import 'package:mobile_flutter/src/rust/api/dto.dart';

/// 「导入导出」屏的纯逻辑小工具:与 Widget 树无关,方便单独看清楚。
/// 文档类型中文标签,与桌面 / 旧 Tauri 移动端 `DOC_LABEL` 保持一致
/// (见 `apps/mobile/src/App.tsx`),汇总弹窗里「归类为」文案用它。
const Map<String, String> kDocTypeLabel = {
  'lab_report': '化验',
  'imaging_report': '影像',
  'discharge_summary': '出院小结',
  'prescription': '处方',
  'clinical_note': '病历',
  'pathology': '病理',
  'surgery': '手术',
  'other': '其他',
  'unknown': '待归类',
};

/// 图片扩展名:拍照 / 相册天然是图片;「选择文件」里靠这些后缀判断是否也走
/// OCR 通道(与 Rust 端 `pipeline::mime_for` 按扩展名判 MIME 的思路一致)。
const Set<String> kImageExtensions = {'png', 'jpg', 'jpeg', 'tiff', 'heic'};

/// 按文件名后缀判断是否为图片(大小写不敏感)。
bool isImageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return kImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 一份待导入项:统一拍照 / 相册 / 文件选择器三种来源——三者在设备上都有
/// 真实文件路径(仅移动端,不考虑 web),据此读字节、跑 OCR。
class PendingImport {
  final String name;
  final String path;
  final bool isImage;

  const PendingImport({
    required this.name,
    required this.path,
    required this.isImage,
  });
}

/// 单份文件导入结果的展示态:区分「FFI 落库但状态非全新成功」与
/// 「处理过程中直接抛异常」,汇总弹窗按此分类计数。
///
/// `partial`:PDF 有部分页(混合页里有文本层的页,和/或移动端补 OCR 成功的页)
/// 识别成功,但还有页始终没能拿到文本——不同于 `success`(全部拿到)或
/// `storedNoText`(一点文本都没有),必须单独一档,不能塞进任一个都会让用户
/// 误判「已经全部识别完」或「什么都没识别到」。见 `import_flow.dart`
/// 的 `_rowForOutcome`。
enum ImportRowKind { success, duplicate, storedNoText, partial, failed }

class ImportResultRow {
  final String name;
  final String statusLabel;
  final ImportRowKind kind;

  const ImportResultRow({
    required this.name,
    required this.statusLabel,
    required this.kind,
  });
}

/// 把 `ImportOutcomeDto.status`(见 rust/src/api/dto.rs 注释:
/// new|backfilled|deduped|stored_no_text|instance_attached|failed)映射成
/// 老人能看懂的一行结果。
ImportResultRow rowFromOutcome(ImportOutcomeDto outcome) {
  final typeLabel = outcome.docType == null
      ? null
      : (kDocTypeLabel[outcome.docType] ?? outcome.docType);
  switch (outcome.status) {
    case 'new':
    case 'backfilled':
    case 'instance_attached':
      return ImportResultRow(
        name: outcome.name,
        statusLabel: typeLabel != null ? '已识别入库 · $typeLabel' : '已识别入库',
        kind: ImportRowKind.success,
      );
    case 'deduped':
      return ImportResultRow(
        name: outcome.name,
        statusLabel: '重复,已跳过',
        kind: ImportRowKind.duplicate,
      );
    case 'stored_no_text':
      return ImportResultRow(
        name: outcome.name,
        statusLabel: '仅存原件(未识别到文字)',
        kind: ImportRowKind.storedNoText,
      );
    default:
      return ImportResultRow(
        name: outcome.name,
        statusLabel: '未能处理',
        kind: ImportRowKind.failed,
      );
  }
}

/// 把 `outcome` + 移动端补 OCR 后**仍**缺文本的页数,映射成汇总行。
/// `stillMissingPages` 是 `outcome.pagesWithoutText`(落库时点名内容没进库的
/// 页——混合页 PDF 里没有文本层的那几页、全篇扫描 PDF 的所有页,或**多页图片
/// (多页 TIFF)里第 2 页起那些原生识别器压根没读过的页**)经调用方尽力补救后
/// 依然没拿到文本的页数;默认 0(绝大多数文件——单页图片,或 PDF 每页本就有
/// 文本层——都是这条路径,直接退化成 `rowFromOutcome`)。
///
/// **不能静默**是这个函数存在的唯一理由:哪怕补救之后仍有页没识别,也必须让
/// 用户在汇总弹窗里看到"不是全部",而不是回退成看起来完整的「已识别入库」——
/// 这正是混合页 PDF 曾经静默丢数据的用户可见症状(修复见
/// `pipeline::ingest_pdf` 与本文件调用方 `import_flow.dart::_runImport`)。
ImportResultRow rowForOutcome(
  ImportOutcomeDto outcome, {
  int stillMissingPages = 0,
}) {
  final totalPagesNeeded = outcome.pagesWithoutText.length;
  if (totalPagesNeeded == 0) {
    return rowFromOutcome(outcome);
  }
  if (stillMissingPages == 0) {
    // 缺文本层的页全部靠移动端 OCR 补上了。
    return ImportResultRow(
      name: outcome.name,
      statusLabel: '已识别入库(含扫描页 OCR 补全)',
      kind: ImportRowKind.success,
    );
  }
  // pipeline 落库时本就拿到一些文本(混合页部分成功),或这次补救恢复了部分
  // 页——只要有任何一点内容,就不是「仅存原件」那种彻底没有文字的状态。
  final recoveredAny = stillMissingPages < totalPagesNeeded;
  final hasAnyText = outcome.status != 'stored_no_text' || recoveredAny;
  if (!hasAnyText) {
    return ImportResultRow(
      name: outcome.name,
      statusLabel: '仅存原件(未识别到文字,共 $stillMissingPages 页)',
      kind: ImportRowKind.storedNoText,
    );
  }
  return ImportResultRow(
    name: outcome.name,
    statusLabel: '已识别入库,但 $stillMissingPages 页未能识别文字',
    kind: ImportRowKind.partial,
  );
}

/// 「这一批没收全」的提示文案 —— **唯一来源**。
///
/// 患者模式的导入汇总弹窗(`import_flow.dart::_showImportSummary`)和医生代拍
/// 采集完的提示条(`proxy_intake_flow.dart::_ingest`)都从这里取字符串。这个项目
/// 有一条硬约束:同一件事在不同屏上不能长成两个略微不同的意思 —— 「有几页没识别
/// 出来」在患者那儿叫「部分页未能识别」,在医生那儿就不许改口叫别的。要改文案,
/// 改这里一处,两屏一起变。
abstract final class ImportIncompleteNotice {
  /// 整份一个字都没识别出来(`ImportRowKind.storedNoText`)。
  static String storedNoText(int count) => '仅存原件(未识别到文字)$count 份';

  /// 识别到了内容,但还有页没拿到文字(`ImportRowKind.partial`)。
  static String partialPages(int count) => '部分页未能识别 $count 份';
}

/// 把一批结果行汇总成「没收全」的提示行,没有任何一份不完整时返回**空列表**。
///
/// 行序与患者模式汇总弹窗里的一致(先「仅存原件」后「部分页未能识别」),用的也是
/// [ImportIncompleteNotice] 里同一份字符串。失败份数**不在这里**:那是另一回事
/// (根本没落库,不是「落了但漏页」),各屏本来就各有自己的报法。
List<String> incompleteNoticesFor(Iterable<ImportResultRow> rows) {
  final storedNoText = rows
      .where((r) => r.kind == ImportRowKind.storedNoText)
      .length;
  final partial = rows.where((r) => r.kind == ImportRowKind.partial).length;
  return [
    if (storedNoText > 0) ImportIncompleteNotice.storedNoText(storedNoText),
    if (partial > 0) ImportIncompleteNotice.partialPages(partial),
  ];
}

/// 医生代拍采集完那一条提示条的全文;没有任何要说的事时返回 `null`(不弹)。
///
/// 代拍不弹患者模式那种汇总弹窗(诊室里多一次「知道了」是多一次点击),但
/// **「没收全」必须说出来**:医生当场拍完以为收全了,病人一走就再也补不上。
/// 「没能处理」(压根没落库)和「落库了但有页没识别」是两件事,分行各说各的,
/// 后者的措辞直接取自 [incompleteNoticesFor] —— 与患者模式同一份字符串。
String? proxyIntakeNotice({
  required Iterable<ImportResultRow> rows,
  required int failed,
}) {
  final lines = [
    if (failed > 0) '有 $failed 份未能处理,可重拍',
    ...incompleteNoticesFor(rows),
  ];
  return lines.isEmpty ? null : lines.join('\n');
}

/// 单份文件处理过程中直接抛异常(读文件失败、FFI 报错等),同样归入失败展示行,
/// 不让一份文件的问题中断整个批次。
ImportResultRow rowFromError(String name, Object error) => ImportResultRow(
  name: name,
  // 诊断期:直接把真实错误原因展示出来(而非笼统「格式不支持」),便于真机定位
  // 相册导入失败到底炸在哪(读文件 / FFI / 空文件 bail 等)。定位后再换回友好文案。
  statusLabel: '导入失败:$error',
  kind: ImportRowKind.failed,
);
