import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/manual_entry_sheet.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/icloud_bridge.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/report_content.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobile_flutter/import_flow.dart';

// doc_type → 中文标签,与 archive_screen.dart 保持同一份映射(桌面/旧移动端
// 同构,来自 core-model types.rs)。
const Map<String, String> _docLabel = {
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

/// 手动录入的两个 doc_type(与 `doc.dart`/`core_model::DocType` 的取值一致)——
/// 这两类文档没有原件(合成文本本身当"文件"存进 CAS),详情页要换一套展示。
bool _isManualEntry(String docType) =>
    docType == 'self_measurement' || docType == 'note';

/// 自测记录的 `ocrText` 是"人类可读的几行 + 空行 + 结构化载荷"
/// (`parser::render_self_measurement_text` 的格式),后半段是给机器读的 JSON,
/// 不该直接糊给用户看。空行是这两段之间**唯一**的契约(不依赖具体的标记字符串,
/// 那是 Rust 侧的实现细节),取空行之前的部分即可。笔记文档没有这层编码,原样
/// 显示。
String _displayText(String ocrText, String docType) {
  if (docType != 'self_measurement') return ocrText;
  final idx = ocrText.indexOf('\n\n');
  return idx == -1 ? ocrText : ocrText.substring(0, idx);
}

String _fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// iOS-only:读盘前先确保对象已从 iCloud 下载到本地。开启 iCloud 同步后,`objects/`
/// 里的对象可能被 iCloud 逐出(只剩 `.icloud` 占位符),直接读会失败。先经 Rust 拿
/// 对象绝对路径,再让原生触发按需下载并等待,然后再读。安卓/其它平台无 iCloud,
/// 跳过物化直接读(保持快路径)。物化失败也照常尝试读,由调用方做优雅降级。
Future<void> _ensureMaterialized(int sourceFileId) async {
  if (!Platform.isIOS) return;
  try {
    final path = await sourceFileObjectPath(id: sourceFileId);
    await IcloudBridge.ensureDownloaded(path);
  } catch (_) {
    // 拿路径/下载失败不阻断:继续读盘,失败时上层已有「原件加载失败」降级。
  }
}

/// 「查看原件」读原始字节:iOS 上先物化(防 iCloud 逐出),再 `readSourceBytes`。
Future<Uint8List> _readSourceMaterialized(int sourceFileId) async {
  await _ensureMaterialized(sourceFileId);
  return readSourceBytes(id: sourceFileId);
}

/// 「查看原件」渲染 DICOM:iOS 上先物化(防 iCloud 逐出),再 `renderDicomPng`。
Future<Uint8List> _renderDicomMaterialized(int sourceFileId) async {
  await _ensureMaterialized(sourceFileId);
  return renderDicomPng(id: sourceFileId);
}

/// 文档详情屏:类型/日期/来源 + 识别文本(复用 ReportContent 内容感知渲染)+
/// 查看原件(图片/PDF/DICOM 各自渲染,其余格式优雅降级不崩)。
class DocumentDetailScreen extends StatefulWidget {
  final int docId;
  const DocumentDetailScreen({super.key, required this.docId});

  @override
  State<DocumentDetailScreen> createState() => _DocumentDetailScreenState();
}

class _DocumentDetailScreenState extends State<DocumentDetailScreen> {
  // `late final` → 可重建:「重新识别」补完页之后要重新拉一次详情,否则屏幕上
  // 还挂着补之前的旧文本和旧页码,用户会以为没生效。
  late Future<DocumentDetailDto> _future = getDocument(id: widget.docId);

  /// 正在重新识别 —— 期间禁掉按钮并显示进度,别让用户以为点了没反应
  /// (端上渲染 + OCR 一页要几秒,多页可能十几秒)。
  bool _reindexing = false;

  /// 正在识别第几页 / 共几页 —— 与导入流程同一个理由:一页扫描件在低端机上要
  /// 几秒到几十秒,只说「正在重新识别…」等于给用户一个不动的转圈。
  (int, int)? _reindexPage;

  /// 重新识别这份文档里还没有文字的那几页。
  ///
  /// 为什么这个按钮必须存在:漏页此前**只在导入那一刻的结果框里说过一次**,框一关
  /// 就永远消失 —— 用户过一周回来看到的是一份「正常」的病历,而里面有几页是空的。
  /// #193 让「再导一次同一份文件」能补页,但那要求用户自己想到去重新选文件,
  /// 而且他根本不知道有页缺着。
  ///
  /// 走的是导入流程同一段回填代码([backfillPagesForDocument]),不在这里重写:
  /// 渲染降档梯、单次页数上限、补不完如实计回,三条路必须同一份行为。
  Future<void> _reindex(DocumentDetailDto detail) async {
    setState(() => _reindexing = true);
    try {
      // 原件字节在 CAS 里(Raw Never Dies),但回填要的是**文件路径**(pdfx 按页
      // 渲染)。iOS 上先物化防 iCloud 逐出 —— 与「查看原件」同一条前置。
      final bytes = await _readSourceMaterialized(detail.sourceFile.id);
      final dir = await getTemporaryDirectory();
      // 临时文件名**必须保留原始扩展名**:`backfillPagesForDocument` 拿同一个
      // path 干两件事 —— `isImageName` 判是不是多页图片(图片端上补不回来,
      // 要如实计回而不是白跑一趟渲染),以及交给 pdfx 打开。丢了后缀,一份
      // 扫描 PDF 会被判成非图片没错,但一份多页 TIFF 就会被误判成 PDF,
      // 白白渲染一轮再返回空表。
      final tmp = File(
        '${dir.path}/reindex_${widget.docId}_${detail.sourceFile.originalName}',
      );
      await tmp.writeAsBytes(bytes, flush: true);
      final before = detail.pagesWithoutText.length;
      int stillMissing;
      try {
        stillMissing = await backfillPagesForDocument(
          documentId: widget.docId,
          pages: detail.pagesWithoutText,
          path: tmp.path,
          onPage: (done, total) {
            if (mounted) setState(() => _reindexPage = (done + 1, total));
          },
        );
      } finally {
        // 临时文件即用即删:原件本体一直在 CAS 里,这份只是给渲染器看的副本,
        // 留在 tmp 目录等于把病历明文多摊一份在磁盘上。
        try {
          await tmp.delete();
        } catch (_) {}
      }
      final recovered = before - stillMissing;
      if (!mounted) return;
      setState(() {
        _reindexing = false;
        _reindexPage = null;
        _future = getDocument(id: widget.docId);
      });
      bumpVaultRevision();
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(
          content: Text(
            recovered > 0
                ? (stillMissing > 0
                      ? '补上了 $recovered 页,还有 $stillMissing 页没能识别'
                      : '补上了 $recovered 页,这份已经完整')
                : '这次仍然没能识别出文字 —— 可能是原件太模糊或不是文字页',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reindexing = false;
        _reindexPage = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(appSnackBar(content: Text('重新识别失败:$e')));
    }
  }

  /// 删除这份文档:确认 → FFI 删除 → 通知档案刷新 → 退回上一屏。
  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份记录?'),
        content: const Text('将从健康档案移除,此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MedColors.of(context).critical,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await deleteDocument(documentId: widget.docId);
      bumpVaultRevision();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(appSnackBar(content: Text('删除失败:$e')));
      }
    }
  }

  /// 确认这份待确认文档无误:移出待确认(去掉红框)→ 通知档案刷新 → 退回。
  Future<void> _confirm() async {
    await ReviewState.instance.markReviewed(widget.docId);
    bumpVaultRevision();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final pending = ReviewState.instance.isPending(widget.docId);
    return Scaffold(
      appBar: AppBar(
        title: const Text('文档详情'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            onPressed: _delete,
          ),
        ],
      ),
      // 待确认文档:底部「确认无误」栏,核对后一键归档(去掉琥珀框、进标准时间线)。
      // 这是本屏**唯一**的主按钮:seal 纯色不用渐变(规范 §六:一屏只允许一个)。
      bottomNavigationBar: pending
          ? Container(
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MedShape.s3,
                    MedShape.s2,
                    MedShape.s3,
                    MedShape.s2,
                  ),
                  child: FilledButton.icon(
                    onPressed: _confirm,
                    icon: const Icon(Icons.check),
                    label: const Text('确认无误,归入档案'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.sealInk,
                      foregroundColor: c.surface,
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: FutureBuilder<DocumentDetailDto>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(MedShape.s6),
                child: Text(
                  '打开失败:\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: MedType.body.copyWith(color: c.ink2, height: 1.6),
                ),
              ),
            );
          }
          return _DetailBody(
            detail: snap.data!,
            reindexing: _reindexing,
            reindexPage: _reindexPage,
            onReindex: () => _reindex(snap.data!),
          );
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final DocumentDetailDto detail;
  final bool reindexing;
  final (int, int)? reindexPage;
  final VoidCallback onReindex;
  const _DetailBody({
    required this.detail,
    required this.reindexing,
    required this.reindexPage,
    required this.onReindex,
  });

  @override
  Widget build(BuildContext context) {
    final doc = detail.document;
    final sf = detail.sourceFile;
    final typeLabel = _docLabel[doc.docType] ?? doc.docType;
    final isManualEntry = _isManualEntry(doc.docType);

    // OCR 置信度:换算成患者能看懂的三档,而非裸百分比(与旧 App.tsx 一致)。
    // 手动录入没有 OCR 这一步,`ocrConfidence` 恒为 null,这里自然算不出档位,
    // 不需要额外判断。
    final conf = detail.ocrConfidence;
    final confTier = conf == null
        ? null
        : conf >= 0.9
        ? _ConfTier.high
        : conf >= 0.75
        ? _ConfTier.mid
        : _ConfTier.low;

    final c = MedColors.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        MedShape.s3,
        MedShape.s3,
        MedShape.s6,
      ),
      children: [
        // 抬头卡带骑缝线:这一整屏讲的就是**某一份原件**,而且「查看原件」就在
        // 卡里 —— 「背后有原件、点得进去」两条都成立(规范 §五)。全屏只有这
        // 一道骑缝线,下面的识别文本是从它派生出来的,不重复。
        MedCard(
          perforated: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MedShape.s4,
              MedShape.s2,
              MedShape.s4,
              MedShape.s4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.sealWash,
                        borderRadius: BorderRadius.circular(
                          MedShape.radiusBlock,
                        ),
                      ),
                      child: Icon(Icons.description_outlined, color: c.seal),
                    ),
                    const SizedBox(width: MedShape.s2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            doc.title ?? typeLabel,
                            style: MedType.title.copyWith(color: c.ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              typeLabel,
                              if (doc.docDate != null) _fmtDate(doc.docDate),
                            ].join(' · '),
                            style: MedType.secondary.copyWith(
                              color: c.ink2,
                              fontFeatures: MedType.tabular,
                            ),
                          ),
                          Text(
                            '来源:${sf.originalName}',
                            style: MedType.secondary.copyWith(color: c.ink3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                if (confTier != null) ...[
                  const SizedBox(height: MedShape.s3),
                  _ConfBadge(tier: confTier),
                ],

                const SizedBox(height: MedShape.s3),
                if (isManualEntry) ...[
                  // 手动录入没有"被拍下来的原件"——合成文本本身当"文件"存进
                  // CAS(见 MANUAL-ENTRY-DESIGN.md),如实说清楚,而不是让用户
                  // 点「查看原件」看到一句"此格式暂不能预览"的困惑提示。
                  Text(
                    '这是你手动填写的记录,没有原件照片。',
                    style: MedType.secondary.copyWith(color: c.ink3),
                  ),
                  const SizedBox(height: MedShape.s2),
                  // 次级按钮(规范 §六 btn-2):seal-wash 底 + seal-ink 字,与
                  // 其它文档类型「查看原件」同一视觉分量——编辑对这类文档而言
                  // 就是它的「原件永远可达」等价物:能回去改。
                  OutlinedButton.icon(
                    onPressed: () => _editManualEntry(context),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: c.sealWash,
                      foregroundColor: c.sealInk,
                      side: BorderSide(color: c.line),
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ] else
                  // 次级按钮(规范 §六 btn-2):seal-wash 底 + seal-ink 字。
                  // 「原件永远可达」是 007 §2.1 的铁律,所以它不能是最弱的那一级;
                  // 但本屏的主按钮位置留给底部的「确认无误」,它就不该是纯色主按钮。
                  OutlinedButton.icon(
                    onPressed: () => _openOriginal(context, sf),
                    icon: const Icon(Icons.visibility_outlined, size: 18),
                    label: const Text('查看原件'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: c.sealWash,
                      foregroundColor: c.sealInk,
                      side: BorderSide(color: c.line),
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // 缺页横幅放在正文**之前** —— 它说的正是「你下面看到的内容是不完整的」。
        // 放在正文后面等于让用户先把一份残缺的文本当完整的读完。
        if (detail.pagesWithoutText.isNotEmpty) ...[
          const SizedBox(height: MedShape.s5),
          MissingPagesBanner(
            pages: detail.pagesWithoutText,
            reindexing: reindexing,
            reindexPage: reindexPage,
            onReindex: onReindex,
          ),
        ],

        const SizedBox(height: MedShape.s5),
        Row(
          children: [
            Icon(Icons.article_outlined, size: 15, color: c.ink3),
            const SizedBox(width: MedShape.s1),
            Text(
              sf.mimeType.startsWith('image/') ? '识别文本' : '文档内容',
              style: MedType.caption.copyWith(color: c.ink3),
            ),
          ],
        ),
        const SizedBox(height: MedShape.s2),
        ReportContent(
          text: _displayText(detail.ocrText, doc.docType),
          docType: doc.docType,
        ),
      ],
    );
  }

  /// 「编辑」——预填录入弹层,保存后原文档已被删除重建(§3.6),身份不再是
  /// `doc.id`,退回上一屏(时间线/档案会因 `bumpVaultRevision` 自动刷新)。
  Future<void> _editManualEntry(BuildContext context) async {
    final doc = detail.document;
    final measuredAt = doc.docDate != null
        ? DateTime.tryParse(doc.docDate!)
        : null;
    final ManualEntryEditing editing;
    if (doc.docType == 'note') {
      editing = ManualEntryEditing(
        documentId: doc.id,
        kind: ManualEntryKind.note,
        noteText: detail.ocrText,
        measuredAt: measuredAt,
      );
    } else {
      final values = await selfMeasurementValues(documentId: doc.id);
      editing = ManualEntryEditing(
        documentId: doc.id,
        kind: manualEntryKindForKeys(values.map((v) => v.analyteKey).toList()),
        values: values,
        measuredAt: measuredAt,
      );
    }
    if (!context.mounted) return;
    final saved = await showManualEntrySheet(context, editing: editing);
    if (saved == true && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openOriginal(BuildContext context, SourceFileMetaDto sf) async {
    final mime = sf.mimeType;
    if (mime.startsWith('image/')) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ImageViewerScreen(sourceFileId: sf.id),
        ),
      );
      return;
    }
    if (mime == 'application/pdf') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _PdfViewerScreen(sourceFileId: sf.id),
        ),
      );
      return;
    }
    if (mime == 'application/dicom') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _DicomViewerScreen(sourceFileId: sf.id),
        ),
      );
      return;
    }
    // 其余格式手机端无法内联预览——如实告知,原件仍安全保存,不静默空白。
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('暂不能预览'),
        content: Text('此格式($mime)暂不能在手机上预览,原件已安全保存在健康档案里。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

enum _ConfTier { high, mid, low }

/// 识别质量徽标:高/中/低三档,比裸百分比更易懂(与旧 App.tsx .conf 一致)。
///
/// 「高」原先是 emerald 绿(#ECFDF5/#047857)。绿不在规范色板里,而且规范 §二
/// 明确不要「绿=没问题」这层暗示 —— 识别质量高**不代表**化验结果正常,两件事
/// 用同一种「放心色」讲容易混。改成主色的极浅底:是一条中性的状态说明,不是
/// 一句安慰。中/低两档接规范的 `high` / `critical`。
class _ConfBadge extends StatelessWidget {
  final _ConfTier tier;
  const _ConfBadge({required this.tier});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final (bg, fg, icon, text) = switch (tier) {
      _ConfTier.high => (
        c.sealWash,
        c.sealInk,
        Icons.check_circle_outline,
        '识别质量:高',
      ),
      _ConfTier.mid => (
        c.highWash,
        c.high,
        Icons.error_outline,
        '识别质量:中 · 个别字可能有误,可核对原件',
      ),
      _ConfTier.low => (
        c.criticalWash,
        c.critical,
        Icons.error_outline,
        '识别质量:低 · 建议重新拍摄',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MedShape.s2,
        vertical: MedShape.s1,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: fg),
          const SizedBox(width: MedShape.s1),
          Expanded(
            child: Text(text, style: MedType.secondary.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}

/// 图片原件全屏查看(可缩放),字节来自 `readSourceBytes`。
class _ImageViewerScreen extends StatelessWidget {
  final int sourceFileId;
  const _ImageViewerScreen({required this.sourceFileId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('原件'),
      ),
      body: FutureBuilder<Uint8List>(
        future: _readSourceMaterialized(sourceFileId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return const _ViewerFallback(message: '原件加载失败,已安全保存在档案里,可稍后重试。');
          }
          return PhotoView(
            imageProvider: MemoryImage(snap.data!),
            backgroundDecoration: const BoxDecoration(color: Colors.black),
          );
        },
      ),
    );
  }
}

/// PDF 原件全屏查看(可翻页),字节来自 `readSourceBytes` → `PdfDocument.openData`。
class _PdfViewerScreen extends StatefulWidget {
  final int sourceFileId;
  const _PdfViewerScreen({required this.sourceFileId});

  @override
  State<_PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<_PdfViewerScreen> {
  PdfController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await _readSourceMaterialized(widget.sourceFileId);
      if (!mounted) return;
      setState(() {
        _controller = PdfController(document: PdfDocument.openData(bytes));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('原件')),
      body: _error != null
          ? const _ViewerFallback(message: '此文件暂不能预览,原件已安全保存在档案里。')
          : _controller == null
          ? const Center(child: CircularProgressIndicator())
          : PdfView(controller: _controller!, onDocumentError: (_) {}),
    );
  }
}

/// DICOM 原件:渲染锚点切片为 PNG;不支持的压缩格式优雅降级,不崩溃。
class _DicomViewerScreen extends StatelessWidget {
  final int sourceFileId;
  const _DicomViewerScreen({required this.sourceFileId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('影像原件'),
      ),
      body: FutureBuilder<Uint8List>(
        future: _renderDicomMaterialized(sourceFileId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData) {
            return const _ViewerFallback(
              message: '此 DICOM 格式暂不能预览(可能是不支持的压缩方式),原件已安全保存。',
              light: false,
            );
          }
          return PhotoView(
            imageProvider: MemoryImage(snap.data!),
            backgroundDecoration: const BoxDecoration(color: Colors.black),
          );
        },
      ),
    );
  }
}

/// 查看原件失败/不支持时的统一降级提示——永远给出如实文案,不留空白。
class _ViewerFallback extends StatelessWidget {
  final String message;
  final bool light;
  const _ViewerFallback({required this.message, this.light = true});

  @override
  Widget build(BuildContext context) {
    // 深色查看器(图片/DICOM 是黑底)上用 white70;浅底上用 ink-2 ——
    // 原先浅底用的是最浅的 faint,一段要认真读的告知文案不该是最低对比度。
    final color = light ? MedColors.of(context).ink2 : Colors.white70;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MedShape.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined, size: 40, color: color),
            const SizedBox(height: MedShape.s2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: color, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「这份里有几页没识别出文字」+ 一个能当场补的按钮。
///
/// **为什么要有这块。** 漏页此前只在导入那一刻的结果框里说过一次:
/// 「已识别入库,但 3 页未能识别文字」。框一关,这句话就永远消失了 —— 详情页不说、
/// 档案列表不说。用户过一周回来,看到的是一份**看起来正常**的病历,而里面有 3 页
/// 是空的;他不知道要补,也不知道给医生看的摘要少了那几页的内容。
///
/// 用 `high`(偏高那档的橙)而不是 `critical` 的红:缺页是「需要你处理一下」,
/// 不是「出人命」。红色在这个 app 里留给临床危急值和过敏,滥用会让红色贬值。
class MissingPagesBanner extends StatelessWidget {
  final List<int> pages;
  final bool reindexing;

  /// 正在识别第几页 / 共几页。`null` = 还没开始报(刚点下、还在读原件字节)。
  /// 一页扫描件在低端机上要几秒到几十秒,只说「正在重新识别…」等于给用户一个
  /// 不动的转圈 —— 与导入流程按页报进度是同一条理由。
  final (int, int)? reindexPage;
  final VoidCallback onReindex;

  const MissingPagesBanner({
    super.key,
    required this.pages,
    required this.reindexing,
    this.reindexPage,
    required this.onReindex,
  });

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 页码要列出来,不能只说「3 页」——用户得能拿着原件对上是哪几页,
    // 才知道丢的是化验结果那页还是封面那页。多了就省略,别把横幅撑成一屏。
    final shown = pages.take(8).join('、');
    final more = pages.length > 8 ? ' 等' : '';
    return Container(
      padding: const EdgeInsets.all(MedShape.s3),
      decoration: BoxDecoration(
        color: c.highWash,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        border: Border.all(color: c.high.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.image_not_supported_outlined, size: 18, color: c.high),
              const SizedBox(width: MedShape.s2),
              Expanded(
                child: Text(
                  '有 ${pages.length} 页没有识别出文字(第 $shown$more 页)',
                  style: MedType.body.copyWith(
                    color: c.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MedShape.s2),
          Text(
            '下面的「文档内容」缺这几页 —— 给医生看的摘要也一样缺。原件是完整的,'
            '可以再识别一次试试。',
            style: MedType.secondary.copyWith(color: c.ink2, height: 1.5),
          ),
          const SizedBox(height: MedShape.s3),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              // 正在跑时禁掉:端上渲染 + OCR 一页要几秒,连点会叠着跑。
              onPressed: reindexing ? null : onReindex,
              icon: reindexing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(
                !reindexing
                    ? '重新识别这几页'
                    : reindexPage == null
                    ? '正在重新识别…'
                    : '正在识别第 ${reindexPage!.$1}/${reindexPage!.$2} 页…',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
