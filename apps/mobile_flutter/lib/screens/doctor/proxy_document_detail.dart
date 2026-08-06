import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/screens/import_helpers.dart' show kDocTypeLabel;
import 'package:mobile_flutter/src/rust/api/vault.dart' as vault;
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/report_content.dart';

/// [ProxyDocumentDetailScreen] 弹出时告诉调用方(待确认列表屏)接下来该做什么:
/// [none] 什么都没变(用户直接返回);[changed] 确认或删除了这一份,列表需要重新拉
/// `loadPreview`/`summary`/`confirmedMap` 刷新;[retake] 这一份已被删除且调用方
/// 应紧接着重新弹「拍照/相册/文件」采集入口——由列表屏统一编排(复用它已有的采集
/// 方法),本屏自己不碰采集逻辑,避免两处维护同一套 `pickImportItems` 调用。
enum ProxyDetailResult { none, changed, retake }

/// 待确认列表「点进一份」的详情屏(医生代拍流程专用)——**与 `document_detail.dart`
/// 是独立副本,不是共享组件**。读的是同一套 `api::vault`,但此刻进程里打开的是**这
/// 个代拍病人的箱子**(见 `openProxyPatientVault`),不是医生自己的档案。宁可这份
/// 代码与 `document_detail.dart` 重复大半,也不去改那个文件抽公共组件——保持「不碰
/// 普通人模式一行代码」这条硬规矩在这两个文件上都显而易见成立。
///
/// 布局复用 `document_detail.dart` 的呈现方式:抬头卡(带骑缝线)+ 识别文本
/// (`ReportContent`)。底部按钮换成本流程要的三个动作:确认这一份 / 删除 / 重拍。
///
/// **视觉上与 `document_detail.dart` 逐处对齐,只把主色 `seal`(蓝)换成 `proxy`
/// (紫)** —— 结构、字阶、圆角、骑缝线、间距全部同源。识别文本区整块交给共用的
/// `ReportContent`,它一个字节都不为医生模式改:同一份化验值在两个模式下必须
/// 长得一模一样。
class ProxyDocumentDetailScreen extends StatefulWidget {
  const ProxyDocumentDetailScreen({
    super.key,
    required this.patientId,
    required this.docId,
    required this.initiallyConfirmed,
  });

  /// 这一份属于哪个代拍病人——「确认这一份」落在 [ProxyPatientManager] 的这个病人
  /// 名下(要跨 12 小时保留窗口和 app 重启存活,所以落盘,不放 Rust 进程内存)。
  final String patientId;

  final int docId;

  /// 打开详情页那一刻,列表屏已知的确认状态(列表屏已经从
  /// [ProxyPatientManager] 读过一次,这里不必再问一遍)。
  final bool initiallyConfirmed;

  @override
  State<ProxyDocumentDetailScreen> createState() =>
      _ProxyDocumentDetailScreenState();
}

class _ProxyDocumentDetailScreenState extends State<ProxyDocumentDetailScreen> {
  late final Future<DocumentDetailDto> _future = vault.getDocument(
    id: widget.docId,
  );
  late final bool _confirmed = widget.initiallyConfirmed;
  bool _busy = false;

  /// 删除这份文档(收错/拍花了)。确认后不可撤销。
  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份?'),
        content: const Text('会从这次代拍里移除,原始照片/文件一并删除,不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MedColors.of(context).critical,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await vault.deleteDocument(documentId: widget.docId);
      // 顺手撤掉这一份的「已确认」标记:文档没了,id 不该继续留在 confirmedIds 里
      // (否则会被当成已确认喂给 `createProxyShare`/`proxySummary`)。
      await ProxyPatientManager.instance.setConfirmed(
        widget.patientId,
        widget.docId,
        false,
      );
      await ProxyPatientManager.instance.setMismatch(
        widget.patientId,
        widget.docId,
        null,
      );
      if (mounted) Navigator.of(context).pop(ProxyDetailResult.changed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _showError('删除失败', '$e');
    }
  }

  /// 重拍:这一份拍得不好(糊/切歪/拍错页),删掉后回列表屏由它重新弹采集入口。
  Future<void> _retake() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新拍摄这一份?'),
        content: const Text('原有的这份会被删除,接下来会重新弹出拍照/选择入口。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重拍'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await vault.deleteDocument(documentId: widget.docId);
      // 顺手撤掉这一份的「已确认」标记:文档没了,id 不该继续留在 confirmedIds 里
      // (否则会被当成已确认喂给 `createProxyShare`/`proxySummary`)。
      await ProxyPatientManager.instance.setConfirmed(
        widget.patientId,
        widget.docId,
        false,
      );
      await ProxyPatientManager.instance.setMismatch(
        widget.patientId,
        widget.docId,
        null,
      );
      if (mounted) Navigator.of(context).pop(ProxyDetailResult.retake);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _showError('删除失败', '$e');
    }
  }

  /// 核对无误,确认这一份(整份确认,不细到每一项)。
  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await ProxyPatientManager.instance.setConfirmed(
        widget.patientId,
        widget.docId,
        true,
      );
      if (mounted) Navigator.of(context).pop(ProxyDetailResult.changed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _showError('确认失败', '$e');
    }
  }

  Future<void> _showError(String title, String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(ProxyDetailResult.none);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('核对这一份'),
          actions: [
            IconButton(
              icon: const Icon(Icons.camera_alt_outlined),
              tooltip: '重拍',
              onPressed: _busy ? null : _retake,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: _busy ? null : _delete,
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MedShape.s3,
              MedShape.s1,
              MedShape.s3,
              MedShape.s2,
            ),
            // 「按过了」= 同一个紫的**淡底版**(proxy-wash 底 + proxy-ink 字),
            // 「还要你按」= 同一个紫的**实心版**。同色系、不同分量,一眼分得清
            // 谁还需要动作。原先「已确认」是 emerald 绿 —— 绿不在规范色板里
            // (§二「正常不上色」的直接后果),而且它和这一屏其余颜色毫无亲缘。
            child: _confirmed
                ? Container(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      color: c.proxyWash,
                      borderRadius: BorderRadius.circular(
                        MedShape.radiusControl,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle, color: c.proxyInk, size: 18),
                        const SizedBox(width: MedShape.s1),
                        Text(
                          '已确认',
                          style: MedType.body.copyWith(
                            color: c.proxyInk,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : FilledButton.icon(
                    onPressed: _busy ? null : _confirm,
                    icon: const Icon(Icons.check),
                    label: const Text('确认这一份'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.proxy,
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
          ),
        ),
        body: FutureBuilder<DocumentDetailDto>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return Center(child: CircularProgressIndicator(color: c.proxy));
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
            return _ProxyDetailBody(detail: snap.data!);
          },
        ),
      ),
    );
  }
}

class _ProxyDetailBody extends StatelessWidget {
  final DocumentDetailDto detail;
  const _ProxyDetailBody({required this.detail});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final doc = detail.document;
    final sf = detail.sourceFile;
    final typeLabel = kDocTypeLabel[doc.docType] ?? doc.docType;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        MedShape.s3,
        MedShape.s3,
        MedShape.s6,
      ),
      children: [
        // 抬头卡带骑缝线:这一整屏讲的就是**某一份原件**,而且「查看原件」就在卡
        // 里 —— 「背后有原件、点得进去」两条都成立(规范 §五)。与个人模式的
        // `document_detail.dart` 同一处理,一道也不多、不少。
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
                        color: c.proxyWash,
                        borderRadius: BorderRadius.circular(
                          MedShape.radiusBlock,
                        ),
                      ),
                      child: Icon(Icons.description_outlined, color: c.proxy),
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

                const SizedBox(height: MedShape.s3),
                // 次级按钮(规范 §六 btn-2):proxy-wash 底 + proxy-ink 字。
                // 「原件永远可达」是 007 §2.1 的铁律,所以它不能是最弱的那一级;
                // 但本屏的主按钮位置留给底部的「确认这一份」,它就不该是纯色主按钮。
                // 原先它是紫(当时的橙)描边 + 同色字,与底部主按钮同分量 ——
                // 一屏两个「主」,医生在赶时间时得读文字才知道该按哪个。
                OutlinedButton.icon(
                  onPressed: () => _openOriginal(context, sf),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('查看原件'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: c.proxyWash,
                    foregroundColor: c.proxyInk,
                    side: BorderSide(color: c.line),
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ],
            ),
          ),
        ),

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
        ReportContent(text: detail.ocrText, docType: doc.docType),
      ],
    );
  }

  Future<void> _openOriginal(BuildContext context, SourceFileMetaDto sf) async {
    final mime = sf.mimeType;
    if (mime.startsWith('image/')) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ProxyImageViewerScreen(sourceFileId: sf.id),
        ),
      );
      return;
    }
    if (mime == 'application/pdf') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ProxyPdfViewerScreen(sourceFileId: sf.id),
        ),
      );
      return;
    }
    if (mime == 'application/dicom') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _ProxyDicomViewerScreen(sourceFileId: sf.id),
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
        content: Text('此格式($mime)暂不能在手机上预览,原件已安全保存。'),
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

/// "YYYY-MM-DD",与 `document_detail.dart`/`proxy_intake_flow.dart` 的同名私有
/// helper 同一格式(各文件私有,不跨文件共享——都很小,重复比新增公共 util 更简单)。
String _fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 图片原件全屏查看(可缩放),字节来自 `vault.readSourceBytes`(此刻打开的是代拍病人的
/// 会话箱,不经 iCloud 物化)。
class _ProxyImageViewerScreen extends StatelessWidget {
  final int sourceFileId;
  const _ProxyImageViewerScreen({required this.sourceFileId});

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
        future: vault.readSourceBytes(id: sourceFileId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(
                color: MedColors.of(context).proxy,
              ),
            );
          }
          if (snap.hasError || !snap.hasData) {
            return const _ProxyViewerFallback(message: '原件加载失败,可稍后重试。');
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

/// PDF 原件全屏查看(可翻页),字节来自 `vault.readSourceBytes`。
class _ProxyPdfViewerScreen extends StatefulWidget {
  final int sourceFileId;
  const _ProxyPdfViewerScreen({required this.sourceFileId});

  @override
  State<_ProxyPdfViewerScreen> createState() => _ProxyPdfViewerScreenState();
}

class _ProxyPdfViewerScreenState extends State<_ProxyPdfViewerScreen> {
  PdfController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await vault.readSourceBytes(id: widget.sourceFileId);
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
          ? const _ProxyViewerFallback(message: '此文件暂不能预览。')
          : _controller == null
          ? Center(
              child: CircularProgressIndicator(
                color: MedColors.of(context).proxy,
              ),
            )
          : PdfView(controller: _controller!, onDocumentError: (_) {}),
    );
  }
}

/// DICOM 原件:渲染锚点切片为 PNG;不支持的压缩格式优雅降级,不崩溃。
class _ProxyDicomViewerScreen extends StatelessWidget {
  final int sourceFileId;
  const _ProxyDicomViewerScreen({required this.sourceFileId});

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
        future: vault.renderDicomPng(id: sourceFileId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(
                color: MedColors.of(context).proxy,
              ),
            );
          }
          if (snap.hasError || !snap.hasData) {
            return const _ProxyViewerFallback(
              message: '此 DICOM 格式暂不能预览(可能是不支持的压缩方式)。',
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
class _ProxyViewerFallback extends StatelessWidget {
  final String message;
  final bool light;
  const _ProxyViewerFallback({required this.message, this.light = true});

  @override
  Widget build(BuildContext context) {
    // 全屏看片是黑底(`_ProxyImageViewerScreen` / DICOM),那一档只能用白系文字;
    // 浅底那一档走令牌 `ink2`。
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
