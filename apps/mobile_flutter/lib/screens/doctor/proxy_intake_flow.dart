import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/import_flow.dart' show ImportChoice, pickImportItems;
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/screens/doctor/consent_screen.dart';
import 'package:mobile_flutter/screens/doctor/doctor_delivery_count.dart';
import 'package:mobile_flutter/claim_link.dart';
import 'package:mobile_flutter/claim_upload.dart';
import 'package:mobile_flutter/screens/doctor/doctor_claim_link_dialog.dart';
import 'package:mobile_flutter/screens/doctor/doctor_share_result_dialog.dart';
import 'package:mobile_flutter/screens/doctor/proxy_document_detail.dart';
import 'package:mobile_flutter/screens/doctor/proxy_summary_card.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart' as vault;
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_boot.dart'
    show ensureProxyVaultOpen, openCurrentProfileVault, openProxyPatientVault;

/// 代拍交付的有效期(天)。与本机那 12 小时保留是两回事:这个天数约束「病人手里那条
/// 认领链接还能用多久」。
///
/// **必须与桶上 `c/` 前缀的生命周期规则一致(15 天)** —— 早先写的是 30,而云端对象
/// 15 天就被删了,于是链接第 16 天起就是死的,载荷里却还写着「建议 30 天内复阅」。
/// 改这个数就要同时改那条桶规则(见 `services/claim-signer/handler.py:42`)。
const int kProxyShareExpiresDays = 15;

enum _ProxyPhase { consent, capture, preview, delivering }

/// 「为病人代建档」全屏流程(医生/护士专用,Phase 1:本地交付,不含云)。
/// 同意(签名/按住确认)→ 为这个病人建一个**独立保险箱** → 采集(拍照/相册/文件,
/// 可多轮混合来源累加)→ **待确认列表**(每份一行,点进去核对原件+识别内容、逐份点
/// 「确认这一份」;可随时「继续采集」再累加更多)→ 生成加密文件交付给病人(摘要只
/// 统计已确认的文档,未确认的原件仍全部进分享包并标注待确认)。
///
/// **交付后不即焚**:病人留在本机最多 12 小时(医生通常要几小时内写完病历,期间可
/// 回来补拍/重发),到点由 [ProxyPatientManager] 自动删——与同意告知里那句话对齐。
/// 病人数据落在 [ProxyPatientManager] 的独立命名空间,**绝不写入医生自己的档案**;
/// 橙色 chrome + 顶部常驻横幅是每一屏都在的信号,提醒「这不是我的箱」。
///
/// [patientId] 为 null = 新病人(从同意屏开始);非 null = 从主页「今日病历表」点回
/// 一个已建档的病人(同意已签过,直接进待确认列表继续核对/交付)。
///
/// 打开代拍病人的箱子会**顶掉进程级 vault**(医生自己的档案)。这件事不靠调用顺序的
/// 约定来保证正确:所有开箱走 `vault_boot` 的 FIFO 队列(先发出先生效),并且每次落库
/// /交付前都过 `ensureProxyVaultOpen` 硬校验(开着的不是这个病人的箱子就重开,重开还
/// 不对就中止写入)。[dispose] 里换回医生自己的档案因此可以安全地不 await。
///
/// **采集走与患者模式完全相同的那条链路**:`pickImportItems` + `recognizeImageText`
/// (`ocr_bridge.dart`,iOS/安卓各自原生 OCR)+ `vault.ingestImageWithText` —— 本文件
/// 不重写任何 OCR/入库逻辑,唯一差别是此刻进程里打开的是这个病人的箱子(见
/// `openProxyPatientVault`)。
class ProxyIntakeFlow extends StatefulWidget {
  const ProxyIntakeFlow({super.key, this.patientId});

  /// 续拍已有病人时传其 id;新病人传 null。
  final String? patientId;

  @override
  State<ProxyIntakeFlow> createState() => _ProxyIntakeFlowState();
}

class _ProxyIntakeFlowState extends State<ProxyIntakeFlow> {
  _ProxyPhase _phase = _ProxyPhase.consent;
  String? _patientId;
  // 这一屏是否顶掉过进程级 vault。与 `_patientId` 分开记:放弃一个空病人时
  // `_patientId` 会被清成 null,但箱子已经开过了,dispose 仍必须换回医生自己的档案
  // (否则进程会攥着一个刚被删掉的目录,切回个人模式就读不到自己的病历)。
  bool _openedProxyVault = false;
  ConsentDto? _consent;
  // 报告上姓名与本病人不一致的文档(docId → 报告上的名字),这一屏的快照。等价于患者
  // 模式档案屏那条「姓名不匹配」红条,但**不走 `ReviewState`** —— 那套状态以
  // `ProfileManager.current` 为键,是患者模式的命名空间,代拍不该往里写。真相落在
  // `ProxyPatientManager`(跨重启保留,12 小时里重进 app 还看得见这条提醒)。
  Map<int, String> _mismatch = const {};
  List<TimelineGroupDto> _preview = const [];
  ProxySummaryDto? _summary;
  // 文档 id → 是否已确认(待确认列表用它渲染「待确认/已确认」标签)。真相在
  // `ProxyPatientManager`(落盘),这里只是这一屏的快照;查不到的 id 按「待确认」处理。
  Map<int, bool> _confirmedMap = const {};
  int _capturedCount = 0;
  bool _busy = false;
  String? _progress;

  /// 这次代拍从什么时候开始 —— 交付时用来算「一次代拍要多久」。
  /// **医生愿不愿意有第二次,基本由这个数决定。**
  late final DateTime _sessionStartedAt;

  @override
  void initState() {
    super.initState();
    _sessionStartedAt = DateTime.now();
    // 代拍是赌注最大的功能,此前一个事件都没有 —— 用没用、在哪一步掉、要多久,
    // 全是盲的。`resumed` 区分「新病人」和「回到 12 小时内的旧病人补拍」。
    Analytics.track(AnalyticsEvent.proxySessionStarted, {
      'resumed': widget.patientId != null,
    });
    if (widget.patientId != null) unawaited(_resume(widget.patientId!));
  }

  @override
  void dispose() {
    // 把进程级 vault 换回医生自己的档案。不 await 也安全:开箱都排在 `vault_boot` 的
    // FIFO 队列里,这次「换回」先发出就一定先生效;万一仍有意外,写入前的
    // `ensureProxyVaultOpen` 还会再挡一道。
    if (_openedProxyVault) unawaited(openCurrentProfileVault());
    super.dispose();
  }

  /// 从主页点回一个已建档的病人:开它的箱子,直接进待确认列表(同意早签过了)。
  Future<void> _resume(String id) async {
    setState(() {
      _busy = true;
      _progress = '正在打开…';
    });
    try {
      await ProxyPatientManager.instance.ensureLoaded();
      final p = ProxyPatientManager.instance.byId(id);
      if (p == null) {
        // 12 小时到了、在主页点进来之前刚被清掉:直接退出,别开一个空箱子。
        if (mounted) Navigator.of(context).pop();
        return;
      }
      // 先记 id 再开箱:开箱这段 await 里若用户退出了,主页那边靠「push 返回后一定
      // 换回医生自己的档案」兜底,状态必须已经是「进过代拍」。
      _patientId = id;
      _openedProxyVault = true;
      await openProxyPatientVault(id);
      _consent = p.consent;
      if (!mounted) return;
      await _goToPreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      await _showError('打开病人档案失败', '$e');
    }
  }

  /// 系统分享面板(尤其 iPad)需要非零锚点矩形,与 `export_screen.dart` 同一理由。
  Rect _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && !box.size.isEmpty) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return const Rect.fromLTWH(0, 0, 1, 1);
  }

  Future<void> _onConsentGiven(ConsentDto consent) async {
    // 同意书是这条流程里最可能的流失点。单独埋一条,`proxy_session_started` 与它
    // 的差就是「病人在同意环节走掉了」——不拆开就只知道掉了、不知道掉在哪。
    // **不带同意书里的任何内容**(签名、姓名都在加密包里,不出设备)。
    Analytics.track(AnalyticsEvent.proxyConsentSigned);
    setState(() {
      _busy = true;
      _progress = '正在准备…';
    });
    try {
      final id = await ProxyPatientManager.instance.create();
      _patientId = id;
      _openedProxyVault = true;
      await openProxyPatientVault(id);
      _consent = consent;
      await ProxyPatientManager.instance.setConsent(id, consent);
      if (!mounted) {
        // 组件已在这段 await 期间被卸载:这个病人一份都没采集,不该留在今日病历表里。
        await ProxyPatientManager.instance.remove(id);
        return;
      }
      setState(() {
        _busy = false;
        _progress = null;
        _phase = _ProxyPhase.capture;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      await _showError('新建病人档案失败', '$e');
    }
  }

  /// 退出这一屏。**不删数据**——已采集的病人留在今日病历表里(12 小时内可回来续拍
  /// /交付),这正是「不再用完即焚」的意思。一份都没采集的空病人不留(不然主页会
  /// 攒一堆空条目)。进程级 vault 由主页在本路由返回后换回(见类注释)。
  Future<void> _cancelAndExit() async {
    final id = _patientId;
    if (id != null && _capturedCount == 0) {
      await ProxyPatientManager.instance.remove(id);
      _patientId = null;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// AppBar 返回箭头点了先确认再退出。已经采集过东西的:退出**不会**丢数据(病人
  /// 留在今日病历表),所以不必吓唬人;一份都没拍的:退出就是放弃这个病人。
  Future<void> _confirmExit() async {
    if (_capturedCount == 0) {
      await _cancelAndExit();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('先退出?'),
        content: const Text('已经拍好的会留在「今日病历表」里,12 小时内可以随时回来继续。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _cancelAndExit();
  }

  Future<void> _pickCaptureSource() async {
    final choice = await showModalBottomSheet<ImportChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '拍摄病历材料',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: MedMe.proxyOrange,
                size: 28,
              ),
              title: const Text('拍照', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                '对着化验单、处方拍一张,自动识别上面的文字',
                style: TextStyle(color: MedMe.faint),
              ),
              onTap: () => Navigator.of(context).pop(ImportChoice.camera),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: MedMe.proxyOrange,
                size: 28,
              ),
              title: const Text('从相册选', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                '选一张或多张已经拍好的病历照片',
                style: TextStyle(color: MedMe.faint),
              ),
              onTap: () => Navigator.of(context).pop(ImportChoice.gallery),
            ),
            ListTile(
              leading: const Icon(
                Icons.folder_open_outlined,
                color: MedMe.proxyOrange,
                size: 28,
              ),
              title: const Text('选择文件', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('已有的 PDF、图片', style: TextStyle(color: MedMe.faint)),
              onTap: () => Navigator.of(context).pop(ImportChoice.files),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    // 等 bottom sheet 关闭动画播完——与 `import_flow.showImportSheet` 同一时序
    // 理由(文档扫描器靠 `rootViewController.present`,sheet 未完全退场会被挡下、
    // 静默失败)。
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    // 屏上探针的出口,在 await 之前同步取好(与 `import_flow.showImportSheet` 同一手法)。
    final probe = ScaffoldMessenger.of(context);

    final List<PendingImport> items;
    try {
      items = await pickImportItems(choice, probe: probe);
    } catch (e) {
      // 兜底:[pickImportItems] 内部每个分支都已自己 catch,这里理论上不可达。
      // 但诊室里「点了没反应」比在家更贵 —— 医生当着病人的面无从判断,只能重来。
      debugPrint('[proxy] 采集环节未捕获异常: $e');
      if (mounted) await _showError('采集没能开始', '$e');
      return;
    }
    if (items.isEmpty || !mounted) return;
    await _ingest(items);
  }

  /// 采集落库——走**与患者模式同一条**链路(`vault.ingestImageWithText` /
  /// `vault.ingestBytes`),此刻进程里打开的是这个病人的箱子,所以东西落进他自己的
  /// vault。OCR 仍是未改动的 [recognizeImageText](`ocr_bridge.dart`,iOS/安卓各自
  /// 原生引擎)。Phase 1 范围内不做扫描版 PDF 的 OCR 回填(仅存原件),不在诊室现场
  /// 为个别扫描版 PDF 多等一轮渲染。
  ///
  /// 顺手拿 Rust 回传的 `detectedName`:第一份识别到姓名就给这个病人命名(主页
  /// 「今日病历表」按名字列);之后再识别到**别的**名字就记进 [_mismatch],在待确认
  /// 列表顶上提醒「可能拍到了别人的单子」。
  Future<void> _ingest(List<PendingImport> items) async {
    final patientId = _patientId;
    if (patientId == null) return;
    try {
      // 动手前确认此刻开着的确实是这个病人的箱子(见 `ensureProxyVaultOpen`)。
      await ensureProxyVaultOpen(patientId);
    } catch (e) {
      if (mounted) await _showError('采集已中止', '$e');
      return;
    }
    setState(() {
      _busy = true;
      _progress = '正在处理 1/${items.length}…';
    });
    // 埋点:代拍的采集**也走 doc_import_***。早先只有患者模式的导入有埋点,于是
    // 「拍纸质件的 OCR 要多久」——最需要这个数的那条路——反而完全测不到。
    // `source: proxy` 把两条路分开,好知道拍纸和导入截图的耗时差多少。
    final startedAt = DateTime.now();
    Analytics.track(AnalyticsEvent.docImportStarted, {
      'source': 'proxy',
      'count_bucket': Bucket.count(items.length),
    });
    var okElapsedMs = 0;
    var okCount = 0;
    String? failStage;
    ImportFailReason? failReason;

    var failed = 0;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (mounted) {
        setState(() => _progress = '正在处理 ${i + 1}/${items.length}…');
      }
      var stage = 'capture';
      final itemStartedAt = DateTime.now();
      try {
        final ImportOutcomeDto outcome;
        if (item.isImage) {
          stage = 'ocr';
          final ocr = await recognizeImageText(item.path);
          stage = 'save';
          final bytes = await File(item.path).readAsBytes();
          outcome = await vault.ingestImageWithText(
            name: item.name,
            bytes: bytes,
            ocrText: ocr.text,
            confidence: ocr.confidence,
          );
        } else {
          stage = 'save';
          final bytes = await File(item.path).readAsBytes();
          outcome = await vault.ingestBytes(filename: item.name, data: bytes);
        }
        await _noteDetectedName(patientId, outcome);
        _capturedCount++;
        okElapsedMs += DateTime.now().difference(itemStartedAt).inMilliseconds;
        okCount++;
      } catch (e) {
        debugPrint('[doctor-proxy] ${item.name} 采集失败: $e');
        failed++;
        // 只记步骤和原因码,**绝不记 `e`** —— 异常文本里常带文件名和路径。
        failStage ??= stage;
        failReason ??= ImportFailReason.of(e);
      }
    }

    final allFailed = failed == items.length;
    Analytics.track(
      allFailed ? AnalyticsEvent.docImportFailed : AnalyticsEvent.docImportCompleted,
      {
        'source': 'proxy',
        'count_bucket': Bucket.count(items.length),
        'failed_bucket': Bucket.count(failed),
        'duration_bucket': Bucket.duration(DateTime.now().difference(startedAt)),
        if (okCount > 0)
          'per_doc_duration_bucket': Bucket.perDoc(
            Duration(milliseconds: okElapsedMs ~/ okCount),
          ),
        if (allFailed) ...{
          'stage': failStage ?? 'capture',
          'reason_code': (failReason ?? ImportFailReason.unknown).name,
        },
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
    });
    if (failed > 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('有 $failed 份未能处理,可重拍')));
    }
    // 采集完直接进审阅屏(病情摘要 + 逐份识别内容摊开),不再停在采集屏问「继续 / 去
    // 预览」——「继续拍摄」是审阅屏上的一个按钮。让「拍完 → 看到审阅」一步到位。
    if (mounted && _capturedCount > 0) {
      await _goToPreview();
    }
  }

  /// 记下这份文档识别到的患者姓名:病人还没名字就用它命名;与已有名字不同则记进
  /// [_mismatch](等价患者模式的「姓名不匹配」红条,提醒别把两个人的单子拍进一份)。
  Future<void> _noteDetectedName(String patientId, ImportOutcomeDto outcome) async {
    final detected = outcome.detectedName?.trim() ?? '';
    if (detected.isEmpty) return;
    final current = ProxyPatientManager.instance.byId(patientId)?.name;
    if (current == null || current.isEmpty) {
      await ProxyPatientManager.instance.autoName(patientId, detected);
    } else if (current != detected) {
      if (outcome.documentId case final id?) {
        await ProxyPatientManager.instance.setMismatch(patientId, id, detected);
      }
    }
  }

  /// 加载/刷新待确认列表:就诊时间线(铺平成文档清单)+ 病情摘要卡(只统计已确认
  /// 文档)+ 每份文档的确认状态。采集完成后、以及每次从详情页返回(确认/删除/重拍)
  /// 后都调这个来刷新——单一数据源,不另维护一套局部更新逻辑。`_capturedCount`
  /// 顺带用这次拿到的真实文档数覆盖,不再靠调用方手动加减去维持同步。
  ///
  /// 确认状态来自 [ProxyPatientManager](落盘,跨 12 小时保留窗口存活),不再是 Rust
  /// 侧的进程内存 map。
  Future<void> _goToPreview() async {
    setState(() {
      _busy = true;
      _progress = '正在整理…';
    });
    try {
      final p = ProxyPatientManager.instance.byId(_patientId ?? '');
      final confirmed = p?.confirmedIds ?? const <int>{};
      final groups = await vault.loadArchive();
      final docs = _PendingListStep.flatten(groups);
      final summary = await vault.proxySummary(
        confirmedIds: Int64List.fromList(confirmed.toList()),
      );
      final confirmedMap = <int, bool>{for (final id in confirmed) id: true};
      if (!mounted) return;
      setState(() {
        _preview = groups;
        _summary = summary;
        _confirmedMap = confirmedMap;
        // 只留还存在的文档:删掉的那份不该继续在顶上报警。
        _mismatch = {
          for (final e in (p?.mismatch ?? const <int, String>{}).entries)
            if (docs.any((d) => d.id == e.key)) e.key: e.value,
        };
        _capturedCount = docs.length;
        _busy = false;
        _progress = null;
        _phase = _ProxyPhase.preview;
      });
      // 回填份数,主页「今日病历表」列表直接读它,不必为了数数把每个箱子都开一遍。
      if (_patientId case final id?) {
        await ProxyPatientManager.instance.setDocCount(id, docs.length);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      await _showError('加载预览失败', '$e');
    }
  }

  /// 点进一份的详情页:核对原件 + 识别内容,「确认这一份」/ 删除 / 重拍都在那一屏
  /// 完成(见 `proxy_document_detail.dart`)。回来后按详情页汇报的结果决定下一步:
  /// 有变化(确认或删除)就刷新列表;是「重拍」则刷新后紧接着重新弹采集入口——
  /// 复用现有的 [_pickCaptureSource]/[_ingest] 链路,不在详情页重复一遍采集逻辑。
  Future<void> _openDocument(DocumentSummaryDto doc) async {
    final patientId = _patientId;
    if (patientId == null) return;
    final result = await Navigator.of(context).push<ProxyDetailResult>(
      MaterialPageRoute(
        builder: (_) => ProxyDocumentDetailScreen(
          patientId: patientId,
          docId: doc.id,
          initiallyConfirmed: _confirmedMap[doc.id] ?? false,
        ),
      ),
    );
    if (!mounted || result == null || result == ProxyDetailResult.none) {
      return;
    }
    await _goToPreview();
    if (result == ProxyDetailResult.retake) {
      await _pickCaptureSource();
    }
  }

  Future<void> _deliver() async {
    final consent = _consent;
    if (consent == null) return;
    setState(() {
      _busy = true;
      _progress = '正在生成认领链接…';
      _phase = _ProxyPhase.delivering;
    });
    try {
      // 交付读的也是这个箱子(而且会往里写一份 share 记录):同样先校验再动手。
      if (_patientId case final id?) await ensureProxyVaultOpen(id);
      final confirmed =
          ProxyPatientManager.instance.byId(_patientId ?? '')?.confirmedIds ??
          const <int>{};
      // **先走链接**:密文上瞬时云,把 `#c1.<id>.<key>` 交给病人。
      // 为什么不再直接发文件:代拍面对的病人常常没微信、加不上好友、也不会收文件 ——
      // 发文件要求两台手机当场能建起一条传输通道,而那正是这些病人不具备的。
      // 一条码,他用任何相机拍走就行。
      final linkUrl = await _deliverAsLink(consent, confirmed);
      if (linkUrl != null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _progress = null;
        });
        await DoctorDeliveryCount.instance.increment();
        if (!mounted) return;
        await showDoctorClaimLinkDialog(
          context,
          linkUrl.$1,
          linkUrl.$2,
          shareOrigin: _shareOrigin,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }
      // 上传没成功(网络/云端出问题)。**不让医生空手** —— 退回原来的本地加密文件 +
      // 口令那条路,它不依赖网络,一定交得出去。
      setState(() => _progress = '网络不畅,改为生成加密文件…');
      final result = await vault.createProxyShare(
        expiresDays: kProxyShareExpiresDays,
        consent: consent,
        confirmedIds: Int64List.fromList(confirmed.toList()),
      );
      // 交付成功。份数分桶 + 整场耗时 —— 一次代拍要五分钟就不会有第二次。
      //
      // ⚠️ 份数取 `result.recordCount`(**实际打进包里的**),不是
      // `confirmed.length`。早先用后者,于是医生没逐份点「确认」就交付时(常态),
      // 明明交了 1 份却上报 `count_bucket: 0` —— 真机实测就是这么错的。
      // 「确认了几份」是另一个问题,要测得单独一个属性。
      Analytics.track(AnalyticsEvent.proxyShareShown, {
        'count_bucket': Bucket.count(result.recordCount.toInt()),
        'confirmed_bucket': Bucket.count(confirmed.length),
        'size_bucket': Bucket.bytes(result.byteSize.toInt()),
        'duration_bucket': Bucket.duration(
          DateTime.now().difference(_sessionStartedAt),
        ),
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      // 纯本地计数 +1(不存任何病人数据),见 `doctor_delivery_count.dart`——文件已
      // 生成即算「交付」,不管用户接下来是否还留在这一屏,计数都该 +1。
      await DoctorDeliveryCount.instance.increment();
      if (!mounted) return;
      await showDoctorShareResultDialog(context, result, shareOrigin: _shareOrigin);
      if (!mounted) return;
      // **交付后不删**:病人留在今日病历表里,12 小时内医生可以回来补拍/重发,到点
      // 由 `ProxyPatientManager` 自动清(与同意告知里的口径一致)。
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _phase = _ProxyPhase.preview;
      });
      await _showError('生成分享失败', '$e');
    }
  }

  /// 把这次代拍打成密文传上瞬时云,返回 `(认领链接, 记录数)`;传不上去返回 null。
  ///
  /// **密钥不上传** —— 它只进链接 `#` 之后那一段,云上那份我们自己也解不开。
  /// 用的是与病人出码同一条上传通道([ResumableUpload],断了能续),同一种密文格式,
  /// 查看器那边也只有一套解密逻辑。
  Future<(String, int)?> _deliverAsLink(
    ConsentDto consent,
    Set<int> confirmed,
  ) async {
    try {
      setState(() => _progress = '正在加密…');
      final (blob, keyB64, recordCount) = await vault.proxyClaimBlob(
        expiresDays: kProxyShareExpiresDays,
        consent: consent,
        confirmedIds: Int64List.fromList(confirmed.toList()),
      );
      final up = ResumableUpload(blob);
      final total = blob.length;
      if (mounted) {
        setState(() => _progress = '正在上传(${(total / 1048576).toStringAsFixed(1)} MB)…');
      }
      final id = await up.run(
        onProgress: (p) {
          if (mounted) {
            setState(() => _progress = '正在上传… ${(p * 100).toStringAsFixed(0)}%');
          }
        },
      );
      return ('${ClaimLink.pageUrl}#c1.$id.$keyB64', recordCount.toInt());
    } catch (e) {
      // 传不上去不是错误路径的终点 —— 调用方会退回本地文件。这里只记日志。
      debugPrint('[doctor-proxy] 认领链接生成失败,将退回本地文件: $e');
      return null;
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _cancelAndExit();
      },
      child: Scaffold(
        backgroundColor: MedMe.bg,
        // 退出入口:左上返回箭头,点了弹确认(见 `_confirmExit`)。横幅不再兼职
        // 退出按钮(见 `_ProxyBanner`),避免「看个声明顺手关掉」误触跳回首页。
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '退出代拍',
            onPressed: _busy ? null : _confirmExit,
          ),
        ),
        // top: false —— 顶部安全区已经由 AppBar 撑开,SafeArea 只需再护住底部
        // (home indicator 等),不然会在 AppBar 下面多挤出一截空白。
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              const _ProxyBanner(),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_phase) {
      case _ProxyPhase.consent:
        return ConsentScreen(onAgreed: _onConsentGiven, onCancel: _cancelAndExit);
      case _ProxyPhase.capture:
        return _CaptureStep(
          busy: _busy,
          progress: _progress,
          capturedCount: _capturedCount,
          onCapture: _pickCaptureSource,
          onDone: _capturedCount > 0 ? _goToPreview : null,
        );
      case _ProxyPhase.preview:
        return _PendingListStep(
          groups: _preview,
          summary: _summary,
          confirmedMap: _confirmedMap,
          patientName:
              ProxyPatientManager.instance.byId(_patientId ?? '')?.displayName ??
              ProxyPatientManager.unnamed,
          mismatch: _mismatch,
          busy: _busy,
          progress: _progress,
          onCaptureMore: _pickCaptureSource,
          onDeliver: _deliver,
          onOpenDocument: _openDocument,
        );
      case _ProxyPhase.delivering:
        return const Center(
          child: CircularProgressIndicator(color: MedMe.proxyOrange),
        );
    }
  }
}

/// 顶部常驻声明横幅:每一屏都在,一眼分清「这不是我的箱」。**不可关闭**——它是
/// 声明,不是退出入口(退出走 AppBar 左上返回箭头,见 [_ProxyIntakeFlowState._confirmExit])。
/// 之前版本横幅带个 X,点了会直接取消整个代拍回首页,用户觉得「看个声明顺手关
/// 掉」不该跳页——去掉 X,声明和退出两件事分开。
class _ProxyBanner extends StatelessWidget {
  const _ProxyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: MedMe.proxyOrange,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '为病人代建档 · 本机最多留 12 小时 · 不进你自己的档案',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureStep extends StatelessWidget {
  const _CaptureStep({
    required this.busy,
    required this.progress,
    required this.capturedCount,
    required this.onCapture,
    required this.onDone,
  });

  final bool busy;
  final String? progress;
  final int capturedCount;
  final VoidCallback onCapture;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.document_scanner_outlined,
                  color: MedMe.proxyOrange,
                  size: 56,
                ),
                const SizedBox(height: 16),
                Text(
                  capturedCount == 0 ? '拍下病人的纸质病历' : '已拍 $capturedCount 份',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  '化验单、处方、检查报告都可以,可以分多次拍摄',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: MedMe.faint),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: MedMe.proxyOrange),
                    onPressed: busy ? null : onCapture,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(capturedCount == 0 ? '开始拍摄' : '继续拍摄'),
                  ),
                ),
                if (onDone != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: busy ? null : onDone,
                      child: const Text('拍完了,去预览'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black26,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        const SizedBox(width: 16),
                        Text(progress ?? '处理中…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 待确认列表:采集完进这一屏。渲染风格复用 `archive_screen.dart` 的时间线
/// 列表(图标+类型色块、标题、日期、副标题),每份一行,不再像上一版那样把识别
/// 内容摊开在列表里——点进一份才看原件 + 识别内容(见 `proxy_document_detail.dart`),
/// 列表本身只负责「核对拍了什么、哪些还没点开确认」。
class _PendingListStep extends StatelessWidget {
  const _PendingListStep({
    required this.groups,
    required this.summary,
    required this.confirmedMap,
    required this.patientName,
    required this.mismatch,
    required this.busy,
    required this.progress,
    required this.onCaptureMore,
    required this.onDeliver,
    required this.onOpenDocument,
  });

  final List<TimelineGroupDto> groups;
  final ProxySummaryDto? summary;
  final Map<int, bool> confirmedMap;

  /// 这个代拍病人的名字(从报告识别;还没识别到是占位名)。
  final String patientName;

  /// 报告上姓名与本病人不一致的文档(docId → 报告上的名字),见 [_MismatchBanner]。
  final Map<int, String> mismatch;
  final bool busy;
  final String? progress;
  final VoidCallback onCaptureMore;
  final VoidCallback onDeliver;
  final ValueChanged<DocumentSummaryDto> onOpenDocument;

  /// 铺平就诊组/独立文档为一份纯清单——待确认列表只需要「拍了什么」,不需要档案屏
  /// 那套就诊分组展示。与 `archive_screen.dart` 的展开模式同一匹配写法。
  static List<DocumentSummaryDto> flatten(List<TimelineGroupDto> groups) {
    final out = <DocumentSummaryDto>[];
    for (final g in groups) {
      switch (g) {
        case TimelineGroupDto_Encounter(:final docs):
          out.addAll(docs);
        case TimelineGroupDto_Document(:final doc):
          out.add(doc);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final docs = flatten(groups);
    final confirmedCount = docs.where((d) => confirmedMap[d.id] ?? false).length;
    final s = summary;
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '共 ${docs.length} 份 · 已确认 $confirmedCount 份',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            Expanded(
              child: docs.isEmpty
                  ? const Center(
                      child: Text('还没有拍摄任何内容', style: TextStyle(color: MedMe.faint)),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        // 病情摘要卡:在治的病/关键化验/在用药,只统计「已确认」的
                        // 文档(见 `EphemeralSession.summary`)。没有任何结构化问题
                        // (尚无文档被确认,或全是原始未分类图片)时组件自身收起为
                        // 零高度,不占地方。
                        if (s != null) ProxySummaryCard(summary: s),
                        if (mismatch.isNotEmpty)
                          _MismatchBanner(
                            patientName: patientName,
                            others: mismatch.values.toSet(),
                          ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Text(
                            '逐份核对',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: MedMe.faint,
                            ),
                          ),
                        ),
                        for (final d in docs)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: _PendingRow(
                              doc: d,
                              confirmed: confirmedMap[d.id] ?? false,
                              onTap: busy ? null : () => onOpenDocument(d),
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : onCaptureMore,
                      child: const Text('继续采集'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: MedMe.proxyOrange),
                      onPressed: busy || docs.isEmpty ? null : onDeliver,
                      child: const Text('生成认领码,交给病人'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black26,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        const SizedBox(width: 16),
                        Text(progress ?? '处理中…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 待确认列表一行:类型图标 + 标题/日期/类型 + 「待确认/已确认」状态标签。样式
/// 参照 `archive_screen.dart` 的时间线行(图标底色块 + 标题/副标题两行),状态标签
/// 配色沿用该文件 `_PendingCard`(待确认=danger 红)与 `document_detail.dart`
/// `_ConfBadge` 高档(已确认=绿,`#047857`/`#ECFDF5`)的既有色值,不另发明一套。
class _PendingRow extends StatelessWidget {
  const _PendingRow({
    required this.doc,
    required this.confirmed,
    required this.onTap,
  });

  final DocumentSummaryDto doc;
  final bool confirmed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = kDocTypeLabel[doc.docType] ?? doc.docType;
    final date = _fmtDate(doc.docDate);
    return Material(
      color: MedMe.panel,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: confirmed ? MedMe.line : MedMe.danger.withValues(alpha: 0.5),
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: MedMe.proxyOrangeSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.description_outlined,
                  size: 19,
                  color: MedMe.proxyOrange,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.title ?? label,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      date.isEmpty ? label : '$label · $date',
                      style: const TextStyle(fontSize: 12.5, color: MedMe.faint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(confirmed: confirmed),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 20, color: MedMe.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「这份单子上的名字不是这个病人」提醒。等价于患者模式档案屏那条橙色红条
/// (`archive_screen.dart` 的 `_MismatchBanner`,同一配色与语气),只是这里的对照
/// 对象是代拍病人而不是家庭成员 —— 诊室里一叠单子容易混进隔壁病人的,这条就是防它。
/// 只提醒、不自动移动任何东西:该删哪份由医生点进详情自己判断。
class _MismatchBanner extends StatelessWidget {
  const _MismatchBanner({required this.patientName, required this.others});

  final String patientName;
  final Set<String> others;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MedMe.proxyOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: MedMe.proxyOrange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有单子上的姓名是「${others.join('、')}」,与本病人「$patientName」不一致,'
              '请核对是不是拍到了别人的材料。',
              style: const TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.confirmed});

  final bool confirmed;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, text) = confirmed
        ? (const Color(0xFFECFDF5), const Color(0xFF047857), '已确认')
        : (MedMe.danger.withValues(alpha: 0.1), MedMe.danger, '待确认');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// "YYYY-MM-DD",与 `document_detail.dart` 的同名私有 helper 同一格式(各文件私有,
/// 不跨文件共享——两处都很小,重复比新增一个公共 util 文件更简单)。
String _fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
