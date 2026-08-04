import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:google_api_availability/google_api_availability.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';

import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/vault_boot.dart';

/// 「健康档案」右上角「+ 导入」触发的采集流程:弹三选一(拍照 / 相册 / 选文件),
/// 选定后逐个采集→(图片先 ML Kit 中文 OCR)→落库,期间显示进度对话框,结束弹汇总,
/// 并 [bumpVaultRevision] 通知档案自动刷新看到新记录。
///
/// 采集/OCR/落库逻辑与原「导入导出」屏一致,只是进度改用模态对话框(从档案触发,
/// 不再挂在某个屏的持久状态上)。医疗判断全在 Rust core,这里只搬字节 + 调 FFI。
Future<void> showImportSheet(BuildContext context) async {
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
                '添加病历',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          _SheetTile(
            icon: Icons.photo_camera_outlined,
            title: '拍照',
            subtitle: '对着化验单、处方拍一张,自动识别上面的文字',
            choice: ImportChoice.camera,
          ),
          _SheetTile(
            icon: Icons.photo_library_outlined,
            title: '从相册选',
            subtitle: '选一张或多张已经拍好的病历照片',
            choice: ImportChoice.gallery,
          ),
          _SheetTile(
            icon: Icons.folder_open_outlined,
            title: '选择文件',
            subtitle: 'PDF、图片、TXT',
            choice: ImportChoice.files,
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  // 等 bottom sheet 的关闭动画播完再拉起原生采集器。文档扫描器
  // (VNDocumentCameraViewController)靠 rootViewController.present 弹出;若 sheet
  // 尚未完全消失,present 会被正在退场的 sheet 挡下、静默失败,method channel 永不
  // 回调 —— 表现就是「点了没反应」。ImagePicker 内部自己处理了这个时序,这个扫描器
  // 插件没有,所以在这里补一帧等待。
  await Future<void>.delayed(const Duration(milliseconds: 350));
  if (!context.mounted) return;

  // 屏上探针的出口。**在任何 await 之前同步取出**,之后就不再碰 context ——
  // 采集期间用户可能把这一屏推走,而 `ScaffoldMessengerState` 自己知道有没有 mounted。
  final probe = ScaffoldMessenger.of(context);

  final List<PendingImport> items;
  try {
    items = await pickImportItems(choice, probe: probe);
  } catch (e) {
    // 兜底。[pickImportItems] 内部每个分支都已自己 catch,所以这里理论上不可达 ——
    // 但「理论上不可达」正是前五版每次都栽的地方:一个漏网的异常从这里飘走,
    // 上面 `await` 的调用方什么都不做,屏上就是「点了没反应」。
    debugPrint('[import] 采集环节未捕获异常: $e');
    _report(probe, choice, ImportCaptureIssue.unknown, '采集没能开始:$e');
    return;
  }
  if (items.isEmpty || !context.mounted) return;
  await _runImport(context, items, choice);
}

/// 采集来源:拍照(含文档扫描器)/ 从相册选 / 选择文件。`public`——除了本文件的
/// [showImportSheet],「医生代拍」临时会话流程(`screens/doctor/proxy_intake_flow.dart`)
/// 也复用 [pickImportItems] 拿采集入口(自己另起一个只含「拍照/选择文件」的选择
/// 表,不复用 `showImportSheet` 的三选一 UI)。
enum ImportChoice { camera, gallery, files }

/// 按 [choice] 走对应的原生采集器,返回待导入项(用户取消为空列表)。**纯采集,
/// 不碰 OCR/落库**——OCR 识别文本、往哪个保险箱落库,都由调用方在拿到
/// [PendingImport] 列表后自己决定(见 [showImportSheet] 与
/// `proxy_intake_flow.dart` 两个不同的下游处理)。
///
/// **本函数不再向外抛异常。** 每个采集分支都自己 catch,失败一律「屏上说清 + 分类
/// 埋点 + 返回空」——因为这条链路上的每一种失败,在 UI 上都长得一模一样(什么都没
/// 发生),不主动说就只能靠猜。[probe] 是屏上探针的出口(`ScaffoldMessenger`),
/// 调用方在进入本函数**之前**同步取好;不传就只剩埋点和 `debugPrint`。
Future<List<PendingImport>> pickImportItems(
  ImportChoice choice, {
  ScaffoldMessengerState? probe,
}) async {
  switch (choice) {
    case ImportChoice.camera:
      // 文档扫描器(iOS VisionKit / 安卓 ML Kit Document Scanner)自动画框 + 透视
      // 校正,拿到已拉正的图 —— 斜着拍的表格变回横平竖直,OCR 才拼得回整行。
      //
      // **但安卓的 ML Kit 扫描器依赖 Google Play 服务(GMS)**:模型/UI 是 GMS 按需
      // 下载的模块。没有 GMS 的国产机(华为纯 HMS / 墙了 Google)上它起不来,cunning
      // 会转去自己的 fallback 裁剪器,而那个用设备相机、需要我们没声明的 CAMERA 权限
      // → 相机直接打不开。所以**开拍前先检测 GMS**:有 → 用 ML Kit 扫描器(自动
      // 拉正,体验好);无 → 退普通系统相机(image_picker 走系统相机 app 的 intent,
      // 不需要 CAMERA 权限,任何机器都能开)。歪拍质量由下游 OCR 的整页转正 + 切片
      // 兜底,拍照本身不再被 GMS 卡死。iOS 恒用 VisionKit(不涉及 GMS)。
      //
      // ⚠️ 这个检测此前是**裸 await**:`google_api_availability` 走 method channel,
      // 在 GMS 被裁掉/被停用的机器上它自己就可能抛 PlatformException,而异常从这里
      // 一路飘到调用方的 `await`,屏上什么都不显示 —— 又是一个「点了没反应」。
      // 现在检测失败**当作没有 GMS 处置**(与「检测到没有」同一条路),并在屏上说明。
      var useScanner = !Platform.isAndroid;
      if (Platform.isAndroid) {
        try {
          useScanner = (await GoogleApiAvailability.instance
                  .checkGooglePlayServicesAvailability()) ==
              GooglePlayServicesAvailability.success;
        } catch (e) {
          debugPrint('[import] GMS 检测失败,按无 GMS 处理: $e');
          _report(
            probe,
            choice,
            ImportCaptureIssue.gmsCheckThrew,
            '检测 Google Play 服务时出错,已改用普通相机:$e',
          );
          useScanner = false;
        }
      }
      if (useScanner) {
        // 不要给交互式扫描器加 wall-clock 超时:VisionKit 是多页扫描器,用户拍完一页
        // 后靠右上角「保存」结束,合理耗时远超十几秒(踩过:12s timeout 会在用户还在
        // 扫时提前抛出 → 落回退分支叠一个相机 → 点保存「不往后执行」)。取消由插件
        // 返回空处理。扫描器真抛异常(设备不支持等)也落到下面的普通相机。
        //
        // 这条教训仍然成立,**下面那个看门狗没有违反它**:它守的不是「扫完」,是
        // 「扫描器起没起来」,而且判据不是钟表 —— 见 [_scannerFailedToLaunch]。
        try {
          final scan = CunningDocumentScanner.getPictures(
            scannerSource: ScannerSource.camera,
          );
          if (await _scannerFailedToLaunch(scan)) {
            // 扫描器根本没起来。降级到普通相机 —— 注意这里**没有 return**,直接落到
            // 下面那段,与「检测到无 GMS」走同一条路。
            debugPrint('[import] 文档扫描器 ${_kScannerLaunchWatchdog.inSeconds}s 未启动,回退普通拍照');
            _report(
              probe,
              choice,
              ImportCaptureIssue.scannerStalled,
              '文档扫描器 ${_kScannerLaunchWatchdog.inSeconds} 秒没有打开'
              '(常见原因:Google Play 服务下载不到扫描模块),已改用普通相机',
            );
          } else {
            // 走到这里说明扫描器要么已经返回了,要么已经把自己的界面顶到了前台
            // (用户正在扫)—— 后者**不设任何时限**,老老实实等。
            final paths = await scan;
            if (paths == null || paths.isEmpty) {
              // ⚠️ 「用户取消」与「静默失败」在这里分家。插件的返回语义**两个平台
              // 恰好是反的**(2.6.0 源码实证):
              //   安卓 `RESULT_CANCELED` → `success(emptyList())` → 空列表 = 取消;
              //         ML Kit 回了结果但 `pages` 为 null → null = 一页都没有 = 静默失败。
              //   iOS  `documentCameraViewControllerDidCancel` → `nil` → null = 取消;
              //         扫完 0 页 → `processSelectedImages([])` → 空列表 = 静默失败。
              // 此前两者一律 `return const []`,于是「点拍照没反应」的分子分母糊在
              // 一起,永远算不出真实占比。
              final cancelled = Platform.isAndroid ? paths != null : paths == null;
              _report(
                probe,
                choice,
                cancelled
                    ? ImportCaptureIssue.userCancelled
                    : ImportCaptureIssue.emptyResult,
                // 取消是正常操作,**不打扰用户**;静默失败才是要说出来的那一种。
                cancelled ? null : '扫描器没有返回任何一页(既不是取消,也没有报错)',
              );
              return const [];
            }
            return [
              for (final p in paths)
                PendingImport(name: p.split('/').last, path: p, isImage: true),
            ];
          }
        } catch (e) {
          debugPrint('[import] 文档扫描器不可用,回退普通拍照: $e');
          _report(
            probe,
            choice,
            ImportCaptureIssue.scannerThrew,
            '文档扫描器不可用,已改用普通相机:$e',
          );
        }
      }
      try {
        final file = await ImagePicker().pickImage(source: ImageSource.camera);
        if (file == null) {
          // image_picker 的语义比扫描器干净:取消恒为 null,失败恒是抛异常。
          _report(probe, choice, ImportCaptureIssue.userCancelled, null);
          return const [];
        }
        return [PendingImport(name: file.name, path: file.path, isImage: true)];
      } catch (e) {
        // 此前也是**裸 await**。相机权限被拒、系统相机 app 被禁用都从这里抛
        // PlatformException —— 而这正是最可能真实发生的那一类,却完全不可见。
        debugPrint('[import] 普通相机打不开: $e');
        _report(probe, choice, ImportCaptureIssue.pickerThrew, '打不开相机:$e');
        return const [];
      }
    case ImportChoice.gallery:
      try {
        final files = await ImagePicker().pickMultiImage();
        if (files.isEmpty) {
          _report(probe, choice, ImportCaptureIssue.userCancelled, null);
          return const [];
        }
        return [
          for (final f in files)
            PendingImport(name: f.name, path: f.path, isImage: true),
        ];
      } catch (e) {
        debugPrint('[import] 相册打不开: $e');
        _report(probe, choice, ImportCaptureIssue.pickerThrew, '打不开相册:$e');
        return const [];
      }
    case ImportChoice.files:
      try {
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          type: FileType.custom,
          allowedExtensions: [
            'pdf', 'txt', 'png', 'jpg', 'jpeg', 'tiff', 'heic',
          ],
        );
        if (result == null) {
          _report(probe, choice, ImportCaptureIssue.userCancelled, null);
          return const [];
        }
        final picked = [
          for (final f in result.files)
            if (f.path != null)
              PendingImport(
                name: f.name,
                path: f.path!,
                isImage: isImageName(f.name),
              ),
        ];
        // 选了文件却一个 path 都没拿到(云盘上没下载下来的文件就是这样)——
        // 用户明明选了东西,屏上却毫无反应。这是静默失败,不是取消。
        if (picked.isEmpty && result.files.isNotEmpty) {
          _report(
            probe,
            choice,
            ImportCaptureIssue.emptyResult,
            '选中的文件在本机上取不到(可能还没从云端下载完)',
          );
        }
        return picked;
      } catch (e) {
        debugPrint('[import] 文件选择器打不开: $e');
        _report(probe, choice, ImportCaptureIssue.pickerThrew, '打不开文件选择器:$e');
        return const [];
      }
  }
}

/// 「启动到扫描器界面出现」这一段的看门狗时限。**只管启动,不管扫描。**
const Duration _kScannerLaunchWatchdog = Duration(seconds: 5);

/// 扫描器**是不是压根没起来**。`true` = 该降级了。
///
/// ## 为什么这不是 v24 那个 12 秒 wall-clock
///
/// v24 的错在于用「过了多久」推断「出没出事」,于是用户还在多页扫描时被提前打断
/// (→ 落回退分支叠一个相机 → 点保存不往后执行)。这里的判据**不是钟表,是
/// 应用生命周期**:
///
///   安卓的 ML Kit 扫描器是**另一个 Activity**(`startIntentSenderForResult`)。
///   它只要真的起来了,本 Activity 必然离开 `resumed`。所以「5 秒了,结果还没回来,
///   而 App 还稳稳停在前台 resumed」——这只可能意味着**没有任何原生界面被拉起来**,
///   不可能是「用户正在扫」(用户正在扫时,前台根本不是我们)。
///
/// 这正好覆盖已知的那个病因:GMS 在场但被门控,`getStartScanIntent` 返回的 Task
/// 既不 success 也不 failure → 两个 listener 都不触发 → method channel 永不回调
/// → future 永久 pending。此前唯一的兜底(build 29 的 12s 超时)在 `b6a9757` 被删掉,
/// 于是它变回了一个纯粹的静默挂起。
///
/// ## 只在安卓武装
///
/// iOS 的 VisionKit 是**同进程内 present 的 view controller**,前台一直是我们自己,
/// `resumed` 不会变 —— 这个判据在 iOS 上恒为「没起来」,会误伤。而 iOS 也根本没有
/// 模块下载这回事(VisionKit 是系统内置)。所以 iOS 上一秒都不等,行为一字不变。
Future<bool> _scannerFailedToLaunch(Future<List<String>?> scan) {
  if (!Platform.isAndroid) return Future<bool>.value(false);
  return Future.any<bool>([
    // 扫描器先返回(成功/取消/抛错)→ 没卡住。**成功路径不会因此多等一毫秒。**
    scan.then<bool>((_) => false, onError: (_) => false),
    Future<void>.delayed(_kScannerLaunchWatchdog).then((_) {
      // `lifecycleState` 在极早期可能是 null。读不到就**不判它有罪** ——
      // 宁可维持现状(继续等),也不能凭猜测把用户的扫描打断。
      return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    }),
  ]);
}

/// 屏上探针 + 分类埋点。**一个失败分支一行调用**,这是本次改动的全部产出形式。
///
/// 「屏上探针」是 2026-07-21 那次(相机权限,五版才修对)唯一奏效的手法:真机读不到
/// 日志(工具都要 USB 有线,用户无线连),于是让 App 把状态弹成 SnackBar,用户点一次
/// 就一击定位。见 `docs/log/2026-07-18-qr-share-security-and-community-prep.md` 的追记。
/// 这里把那一招从「临时诊断构建」固化成常驻能力。
///
/// ## 两条数据走两条路,绝不混
///
/// - [detail] 是**给人看的**,含异常字符串,只进 SnackBar 和 `debugPrint`,**不出设备**。
///   异常文本里常带文件名和绝对路径,那是病历内容。传 `null` 表示这一类不值得打扰用户
///   (例如用户主动取消)。
/// - [issue] 是**给后台看的**,只有枚举名一个词,进埋点。
void _report(
  ScaffoldMessengerState? probe,
  ImportChoice source,
  ImportCaptureIssue issue,
  String? detail,
) {
  Analytics.track(issue.event, {
    // 注意:这里的 `source` 是**采集器**(camera/gallery/files),与 `doc_import_*`
    // 的 `source`(那里代拍会报 `proxy`)口径不同 —— 坏掉的是哪个采集器才是这条
    // 事件要回答的。个人模式 vs 代拍由会话上下文的 `mode` 切开,不占这个字段。
    'source': source.name,
    'reason': issue.name,
  });
  if (detail == null) return;
  // 分析失败绝不影响功能,屏上探针同理:messenger 已经不在树上就安静放弃。
  if (probe == null || !probe.mounted) return;
  probe.showSnackBar(
    SnackBar(
      content: Text(detail),
      duration: const Duration(seconds: 8),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<void> _runImport(
  BuildContext context,
  List<PendingImport> items,
  ImportChoice source,
) async {
  // 埋点:只报「从哪来、开始了、几份」——**份数分桶**,不报文件名、不报内容。
  final startedAt = DateTime.now();
  // 导入前的库存:0 就是首次导入。**首次导入成功率是最重要的一个数**,而它端上
  // 就能判断,不需要任何 ID。读不到(冷启动早期)就不报,绝不猜。
  final sizeBefore = Analytics.librarySize;
  Analytics.track(AnalyticsEvent.docImportStarted, {
    'source': source.name,
    'count_bucket': Bucket.count(items.length),
  });
  final progress = ValueNotifier<String>('正在导入 1/${items.length}…');
  // 模态进度对话框(不可点走);导入结束后由本函数关闭。
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (context, text, _) => Text(text),
            ),
          ),
        ],
      ),
    ),
  );

  final rows = <ImportResultRow>[];
  // 本次新建文档 id → 报告里识别到的患者姓名(识别不到为 null),进「待确认」队列;
  // 姓名与当前成员不符者会被标红,识别到的姓名还用来自动命名默认档案。
  final newDocs = <int, String?>{};
  // 埋点用:整批里**第一次**失败发生在哪一步、归到哪个原因码。只留第一条 ——
  // 一次批量导入报一条事件,报第一个失败足以定位;报全部会把事件量和基数都吹起来。
  String? failStage;
  ImportFailReason? failReason;
  // 每份耗时的累计(仅成功的份),用来算单份平均 —— 那才是引擎质量指标。
  var okElapsedMs = 0;
  var okCount = 0;

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    progress.value = '正在导入 ${i + 1}/${items.length}…';
    // 每份从「采集完、待处理」开始;下面逐步推进,失败时它就是失败所在的步骤。
    var stage = 'capture';
    final itemStartedAt = DateTime.now();
    try {
      final ImportOutcomeDto outcome;
      var pdfBackfilled = false;
      if (item.isImage) {
        // 各平台原生最强 OCR:iOS Apple Vision / 安卓 ML Kit(见 ocr_bridge.dart)。
        stage = 'ocr';
        final ocr = await recognizeImageText(item.path);
        stage = 'save';
        final bytes = await File(item.path).readAsBytes();
        outcome = await ingestImageWithText(
          name: item.name,
          bytes: bytes,
          ocrText: ocr.text,
          confidence: ocr.confidence,
        );
      } else {
        stage = 'save';
        final bytes = await File(item.path).readAsBytes();
        outcome = await ingestBytes(filename: item.name, data: bytes);
        // 扫描版 PDF(无文本层 → 仅存原件):移动端未链接 Rust OCR 引擎,改用 pdfx
        // 逐页渲染成 PNG、走能用的原生图片 OCR(Vision/ML Kit)后回填,补齐文本。
        if (outcome.status == 'stored_no_text' &&
            outcome.documentId != null &&
            item.name.toLowerCase().endsWith('.pdf')) {
          final pdfOcr = await _ocrScannedPdf(item.path);
          if (pdfOcr.text.trim().isNotEmpty) {
            await backfillPdfText(
              documentId: outcome.documentId!,
              text: pdfOcr.text,
              confidence: pdfOcr.confidence,
            );
            pdfBackfilled = true;
          }
        }
      }
      if (outcome.documentId case final id?) newDocs[id] = outcome.detectedName;
      rows.add(
        pdfBackfilled
            ? ImportResultRow(
                name: outcome.name,
                statusLabel: '已识别入库(扫描件)',
                kind: ImportRowKind.success,
              )
            : rowFromOutcome(outcome),
      );
      okElapsedMs += DateTime.now().difference(itemStartedAt).inMilliseconds;
      okCount++;
    } catch (e) {
      // 原始错误留日志给开发者;用户看到的是 rowFromError 里的简单提示。
      debugPrint('[import] ${item.name} 导入失败: $e');
      rows.add(rowFromError(item.name, e));
      // ⚠️ 只记步骤和**原因码**,绝不记 `e` 本身 —— 异常文本里常带文件名和路径。
      failStage ??= stage;
      failReason ??= ImportFailReason.of(e);
    }
  }

  // 本次新建的文档显式加入「待确认」队列(健康档案顶部据此置顶让用户核对)。
  if (newDocs.isNotEmpty) {
    // 默认档案还没定过名字时,用识别到的第一个患者姓名自动命名它(迁移待确认键)。
    final detected = newDocs.values.firstWhere(
      (n) => n != null && n.trim().isNotEmpty,
      orElse: () => null,
    );
    await autoNameCurrentProfileFrom(detected);
    await ReviewState.instance.markPending(newDocs);
  }
  // 有任一份成功落库,通知「健康档案」屏自动刷新。
  if (rows.any((r) => r.kind != ImportRowKind.failed)) {
    bumpVaultRevision();
  }

  // 埋点:成功几份、失败几份、总共花了多久。**耗时是判断要不要优化 OCR 引擎的唯一
  // 客观依据**;失败只报计数,不报任何异常消息(那里面常有文件名和路径)。
  final failedCount = rows.where((r) => r.kind == ImportRowKind.failed).length;
  final allFailed = failedCount == rows.length;
  Analytics.track(
    allFailed ? AnalyticsEvent.docImportFailed : AnalyticsEvent.docImportCompleted,
    {
      'source': source.name,
      'count_bucket': Bucket.count(rows.length),
      'failed_bucket': Bucket.count(failedCount),
      // 总时长 = 用户要等多久(决定要不要做后台导入)。
      'duration_bucket': Bucket.duration(DateTime.now().difference(startedAt)),
      // 单份平均 = 引擎快不快(决定换不换 OCR)。两个数回答两个不同的决定,
      // 只报总时长的话前一个问题根本答不出来 —— 它被份数主导了。
      if (okCount > 0)
        'per_doc_duration_bucket': Bucket.perDoc(
          Duration(milliseconds: okElapsedMs ~/ okCount),
        ),
      // 首次导入成功率。库存读不到时**不报**,不猜。
      if (sizeBefore != null) 'is_first': sizeBefore == 0,
      if (allFailed) ...{
        'stage': failStage ?? 'capture',
        'reason_code': (failReason ?? ImportFailReason.unknown).name,
      },
    },
  );

  if (!context.mounted) return;
  Navigator.of(context).pop(); // 关进度对话框
  await _showImportSummary(context, rows);
  progress.dispose();
}

/// 扫描版 PDF 补 OCR:用 `pdfx` 逐页渲染成 PNG,走原生图片 OCR
/// ([recognizeImageText],iOS Vision / 安卓 ML Kit),合并各页文本 + 平均置信度。
/// 任何一步失败/无文本都安全返回(空文本 → 调用方不回填,保持「仅存原件」)。
/// 页数封顶 [_kMaxPdfOcrPages] 防超大 PDF 卡死。
const int _kMaxPdfOcrPages = 20;

/// 渲染放大倍数的候选,从清晰到保守**逐级降档**。
///
/// 分辨率越高 OCR 越准(笔画密的字在低解析度下会糊成一团),但设备内存有限:
/// 放大到一定程度 `render()` 会直接失败返回 null。此前写死单一倍数,一旦这台
/// 设备渲不出来就整篇零文本 —— 真机上就是这么炸的。所以不再赌一个常量,
/// 而是从高往低试,第一个渲得出来的就用。
///
/// 注意 pdfx 的 `page.width/height` 文档写明是 **像素**(不是 point),所以这里
/// 是相对原始尺寸的倍数,不能按 DPI 直接换算。
const List<double> _kRenderScales = [3.0, 2.0, 1.5];

Future<OcrResult> _ocrScannedPdf(String path) async {
  final buf = StringBuffer();
  final confs = <double>[];
  PdfDocument? doc;
  Directory? tmp;
  try {
    doc = await PdfDocument.openFile(path);
    tmp = await Directory.systemTemp.createTemp('medme_pdf_ocr');
    final pages = doc.pagesCount < _kMaxPdfOcrPages
        ? doc.pagesCount
        : _kMaxPdfOcrPages;
    for (var i = 1; i <= pages; i++) {
      final page = await doc.getPage(i);
      try {
        // 逐级降档:清晰优先,渲不出来就退一档,别让整页变成零文本。
        PdfPageImage? img;
        for (final scale in _kRenderScales) {
          try {
            img = await page.render(
              width: page.width * scale,
              height: page.height * scale,
              format: PdfPageImageFormat.png,
              // 必须给白底。PNG 默认透明背景,黑字压在透明底上被 OCR 加载时
              // 可能合成成黑底,变成黑字黑底、一个字都认不出。
              backgroundColor: '#FFFFFF',
            );
          } catch (e) {
            debugPrint('[import] 第 \$i 页 \$scale× 渲染异常: \$e');
          }
          if (img != null) {
            debugPrint('[import] 第 \$i 页以 \$scale× 渲染成功');
            break;
          }
          debugPrint('[import] 第 \$i 页 \$scale× 渲染失败,降档重试');
        }
        if (img == null) {
          debugPrint('[import] 第 $i 页所有倍数均渲染失败,跳过');
          continue;
        }
        final f = File('${tmp.path}/p$i.png');
        await f.writeAsBytes(img.bytes);
        final ocr = await recognizeImageText(f.path);
        if (ocr.text.trim().isNotEmpty) {
          // 页间必须空行分隔:OCR 已用 `\n\n` 分块(Layer-0),若这里只写一个
          // 换行,上一页的末块会和下一页的首块粘成同一块,下游按段分块就错位。
          if (buf.isNotEmpty) buf.write('\n\n');
          buf.write(ocr.text.trim());
          confs.add(ocr.confidence);
        }
      } finally {
        await page.close();
      }
    }
  } catch (e) {
    debugPrint('[import] 扫描 PDF 渲染/OCR 失败: $e');
  } finally {
    await doc?.close();
    if (tmp != null) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
  final conf = confs.isEmpty
      ? 0.0
      : confs.reduce((a, b) => a + b) / confs.length;
  return OcrResult(buf.toString().trim(), conf);
}

Future<void> _showImportSummary(
  BuildContext context,
  List<ImportResultRow> rows,
) async {
  final success = rows.where((r) => r.kind == ImportRowKind.success).length;
  final duplicate = rows.where((r) => r.kind == ImportRowKind.duplicate).length;
  final storedNoText = rows
      .where((r) => r.kind == ImportRowKind.storedNoText)
      .length;
  final failed = rows.where((r) => r.kind == ImportRowKind.failed).length;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(failed == rows.length ? '导入未成功' : '导入完成'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (success > 0)
              _summaryLine(Icons.check_circle, MedMe.teal, '成功识别入库 $success 份'),
            if (duplicate > 0)
              _summaryLine(
                Icons.content_copy,
                MedMe.faint,
                '重复,已跳过 $duplicate 份',
              ),
            if (storedNoText > 0)
              _summaryLine(
                Icons.warning_amber_rounded,
                Colors.orange,
                '仅存原件(未识别到文字)$storedNoText 份',
              ),
            if (failed > 0)
              _summaryLine(Icons.error_outline, MedMe.danger, '未能处理 $failed 份'),
            const SizedBox(height: 12),
            const Divider(height: 1, color: MedMe.line),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${row.name} —— ${row.statusLabel}',
                  style: const TextStyle(fontSize: 12.5, color: MedMe.faint),
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

Widget _summaryLine(IconData icon, Color color, String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  ),
);

class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.choice,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final ImportChoice choice;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: MedMe.teal, size: 28),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(color: MedMe.faint)),
      onTap: () => Navigator.of(context).pop(choice),
    );
  }
}
