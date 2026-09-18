/// 导入的**后台队列**:添加完就走人,识别在后台一份一份跑。
///
/// 为什么存在:此前 `import_flow` 在一个模态进度框里逐张跑 OCR,用户得盯着
/// 「正在导入 3/12…」等完每一页(创始人原话:「导入识别的时间过长」)。现在添加
/// 一结束就把这批交给这条队列,对话框立刻关掉;屏上剩下的只是档案顶部几行
/// 「识别中」,每识别完一份,那份文档就自己长到时间线上
/// ([bumpVaultRevision])。
///
/// **一条队列,串行,全进程唯一**([importJobs] 是模块级单例):
/// * 串行是因为 OCR 吃 CPU,并发只会一起变慢,而且落库要碰同一个进程级 vault;
/// * 单例是因为队列状态不能挂在某一屏的 state 上 —— 用户切去概览再切回档案,
///   这几行必须还在;第二次导入也只是往同一条队列尾巴上追加,不会另起一条。
///
/// **进程一死,排着的就没了。** 这是刻意的:一份文档只有在 OCR 出文字之后才落库
/// (`ingest_image_with_text` 的分类/日期/姓名全取自 OCR 文本,落库后没有重新分类
/// 这条路),所以中途被杀掉时**没有任何东西半落地** —— 与改造前逐份同步导入的
/// 语义完全一样,用户重新导一次即可,不需要"重新排队"。
///
/// 云抽取仍然排在整批之后(见 `cloud_extract.runCloudExtractions`),与改造前一致。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/cloud_extract.dart';
import 'package:mobile_flutter/doc_labels.dart' show isTempCaptureName;
// `backfillPagesWithoutText` 住在 import_flow 里(医生代拍那条路也用它)。两个文件
// 互相 import 是有意的:取件 UI 在那边,跑批在这边,同一件事不该有两份实现。
import 'package:mobile_flutter/import_flow.dart'
    show ImportChoice, backfillPagesWithoutText;
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/vault_boot.dart' show autoNameCurrentProfileFrom;
import 'package:mobile_flutter/vault_events.dart';

/// 屏上那一行的状态。
enum ImportJobState {
  /// 排着,还没轮到。
  queued,

  /// 正在识别这一份。
  running,

  /// 已经进库了。行随即从 [importJobs] 里撤掉,除非 [ImportJob.row] 说这份还有话
  /// 要交代(仅存原件 / 有页没识别出来)。
  done,

  /// 这一份没进去。行留在屏上,带一个「重试」——**静默丢掉一份病历是不可接受的**。
  failed,
}

/// 排队中的一份文件。
class ImportJob {
  ImportJob._(this.item, this._batch);

  final PendingImport item;
  final _Batch _batch;

  ImportJobState state = ImportJobState.queued;

  /// 处理完之后这一份的结果行(复用导入汇总那套措辞);还没跑完为 null。
  ImportResultRow? row;

  /// 失败原因,给人看的一句话。`state != failed` 时为 null。
  String? error;

  /// 本机识别产出太少,这一份**没送云端整理**(见 `cloud_extract.isLowOcrYield`)。
  /// 改造前这件事只在导入汇总弹窗里报一个总数;现在弹窗没了,就报在它自己这一行上
  /// —— 更准,用户知道是哪一张要重拍。
  bool lowOcrYield = false;

  /// 屏上这一行叫什么。相册/相机给的临时名一个字的信息量都没有
  /// (见 [isTempCaptureName]),那种就报「照片」/「文件」。
  String get label =>
      isTempCaptureName(item.name) ? (item.isImage ? '照片' : '文件') : item.name;

  /// 跑完了还值不值得占着一行:失败的当然要,「仅存原件」「有页没识别」也要
  /// (那是让用户回头补拍的唯一提示),识别成功和重复的就撤掉 —— 文档自己已经
  /// 长在时间线上了,那才是最好的回执。
  bool get needsAttention =>
      state == ImportJobState.failed ||
      lowOcrYield ||
      switch (row?.kind) {
        ImportRowKind.storedNoText || ImportRowKind.partial => true,
        _ => false,
      };
}

/// 队列里**全部**的行(排队中 / 正在跑 / 跑完了还有话说的)。档案屏监听它。
final ValueNotifier<List<ImportJob>> importJobs =
    ValueNotifier<List<ImportJob>>(const []);

/// 合并失败这类「整批层面」的坏消息 —— 它不属于任何一行(源文档那几行早就撤了)。
/// 档案屏把它显示成一条可关掉的提示;`null` = 没话说。
final ValueNotifier<String?> importQueueNotice = ValueNotifier<String?>(null);

/// [ImportJob] 是可变对象,改它的字段不会让 `ValueNotifier` 觉得值变了 ——
/// 每次都换一份新列表,监听者才收得到。
void _notify() => importJobs.value = List<ImportJob>.of(importJobs.value);

/// **当前**那条 drain 的身份牌;`null` = 没人在跑。
///
/// 为什么不是一个布尔、也不是那条 Future:[resetImportQueueForTest] 要能把上一个
/// 用例遗留的 drain **就地作废**(那个 drain 可能正卡在一个永不返回的替身里)。
/// 拿着旧牌的 drain 每轮循环都会发现自己已经不是当前那条,然后自己退出 —— 于是
/// 「一条队列、串行」这条不变量在换牌前后都成立。生产里永远只有一次发牌。
Object? _drainToken;

/// 一批(一次添加)共享的账本:埋点、「还没核对」队列、合并、云抽取都按批算。
class _Batch {
  _Batch({
    required this.profile,
    required this.vaultRoot,
    required this.source,
    required this.mergePhotos,
    required this.total,
    required this.imageTotal,
    required this.countInAnalytics,
    required this.sizeBefore,
  });

  /// 添加那一刻的成员与箱子 —— 整批都认它们,过程中一次都不重读「当前成员」
  /// (同 `cloud_extract.PendingCloudExtraction` 的两个字段,理由一模一样:
  /// 队列要跑好几分钟,中途切成员/医生代拍会把箱子换掉)。
  final Profile profile;
  final String vaultRoot;
  final ImportChoice source;

  /// 用户在添加结束时答应过「合并成一份」。**问在前面**:识别是后台跑的,人早
  /// 就走了,没法等识别完再弹一个框问他。
  final bool mergePhotos;
  final int total;

  /// 这一批里**照片**有几张。合并要拿它跟真正入库的份数比:少一张就不合(见
  /// [_finishBatch])。
  final int imageTotal;

  /// 这一批算不算一次「导入」。重试是**同一次导入的续命**,不是新的一次 ——
  /// 再发一遍 `doc_import_started/completed` 会把份数和 `is_first` 灌水。
  final bool countInAnalytics;
  final int? sizeBefore;
  final DateTime startedAt = DateTime.now();

  final List<ImportResultRow> rows = [];
  final Map<int, String?> newDocs = {};
  final List<int> imageDocIds = [];
  final List<PendingCloudExtraction> pending = [];
  int okElapsedMs = 0;
  int okCount = 0;
  int finished = 0;
  String? failStage;
  ImportFailReason? failReason;
}

/// 把这一批交给队列,**立刻返回**排了几份。
///
/// [profile] / [vaultRoot] 必须是调用方在添加结束时就地捕获的那一对(见 [_Batch])。
int enqueueImport({
  required List<PendingImport> items,
  required Profile profile,
  required String vaultRoot,
  required ImportChoice source,
  required bool mergePhotos,
  bool countInAnalytics = true,
}) {
  if (items.isEmpty) return 0;
  // 埋点:只报「从哪来、开始了、几份」——**份数分桶**,不报文件名、不报内容。
  if (countInAnalytics) {
    Analytics.track(AnalyticsEvent.docImportStarted, {
      'source': source.name,
      'count_bucket': Bucket.count(items.length),
    });
  }
  final batch = _Batch(
    profile: profile,
    vaultRoot: vaultRoot,
    source: source,
    mergePhotos: mergePhotos,
    total: items.length,
    imageTotal: items.where((i) => i.isImage).length,
    countInAnalytics: countInAnalytics,
    // 导入前的库存:0 就是首次导入。读不到(冷启动早期)就不报,绝不猜。
    sizeBefore: Analytics.librarySize,
  );
  importJobs.value = [
    ...importJobs.value,
    for (final item in items) ImportJob._(item, batch),
  ];
  _startDrain();
  return items.length;
}

/// 失败的那一份再来一次:**另起一个单份批次**,不回原来那批。原批的账
/// (合并、云抽取)早就结了,把一份塞回去只会让它再结一次。
///
/// **不发埋点**:重试是同一次导入的续命,不是新的一次导入 —— 再报一次
/// `doc_import_started` 会让「一次导入几份」和「是不是首次导入」两个数被重试次数
/// 灌水,而那两个数正是这条埋点存在的理由。
void retryImportJob(ImportJob job) {
  dismissImportJob(job);
  enqueueImport(
    items: [job.item],
    profile: job._batch.profile,
    vaultRoot: job._batch.vaultRoot,
    source: job._batch.source,
    mergePhotos: false,
    countInAnalytics: false,
  );
}

/// 用户把这一行划掉/点掉。只撤屏上的行,不动已经落库的东西。
void dismissImportJob(ImportJob job) =>
    importJobs.value = importJobs.value.where((j) => j != job).toList();

/// 一份文件的真正处理(识别 → 落库 → 按页补 OCR)。**只给测试注入替身**:
/// host 上没有 Rust 库,`recognizeImageText` / `ingest*` 一调就抛。
@visibleForTesting
Future<ImportItemOutcome> Function(
  ImportJob job,
  void Function(String stage) onStage,
)
importItemProcessor = _processImportItem;

/// [importItemProcessor] 的产出:展示用的结果行 + 后面排云抽取要用的原料。
class ImportItemOutcome {
  const ImportItemOutcome(this.row, {this.outcome, this.ocr});

  final ImportResultRow row;

  /// 落库结果;没建文档(重复/失败)时其 `documentId` 为 null。
  final ImportOutcomeDto? outcome;

  /// 这一份**当次**的 OCR 结果(涂黑要用它的 bytes/lines,拿不到第二次);
  /// 非图片为 null。
  final OcrResult? ocr;
}

/// 没人在跑就开一条。**第二次导入只是往队列尾巴上追加**,不会另起一条并行的。
void _startDrain() {
  if (_drainToken != null) return;
  final token = Object();
  _drainToken = token;
  _drain(token).whenComplete(() {
    if (identical(_drainToken, token)) _drainToken = null;
  });
}

Future<void> _drain(Object token) async {
  // 每轮都验一次牌:被作废了就立刻收手,别再去动已经属于下一条队列的行。
  while (identical(_drainToken, token)) {
    ImportJob? job;
    for (final j in importJobs.value) {
      if (j.state == ImportJobState.queued) {
        job = j;
        break;
      }
    }
    if (job == null) return;
    job.state = ImportJobState.running;
    _notify();
    await _runJob(job);
    final batch = job._batch;
    batch.finished++;
    if (batch.finished == batch.total) {
      // 收尾出任何岔子都**不许把队列本身带走** —— 后面还排着别人的照片,而
      // drain 一旦抛出来就再也没人推进了(异常只会掉进 zone,屏上一片安静)。
      try {
        await _finishBatch(batch);
      } catch (e) {
        debugPrint('[import-queue] 收尾失败(文档已入库): $e');
      }
    }
  }
}

Future<void> _runJob(ImportJob job) async {
  final batch = job._batch;
  final startedAt = DateTime.now();
  // 每份从「添加完、待处理」开始;下面逐步推进,失败时它就是失败所在的步骤。
  var stage = 'capture';
  try {
    // 便宜的预检:成员/箱子已经换了就别白跑一趟 OCR。**挡住写错库的不是这一行**,
    // 是落库那一步排在 vault 队列里的 `ifVaultUnchanged` —— 这里只是早点说清楚。
    if (ProfileManager.instance.current.id != batch.profile.id) {
      throw const ImportVaultSwitched();
    }
    final result = await importItemProcessor(job, (s) => stage = s);
    job.row = result.row;
    batch.rows.add(result.row);
    if (result.outcome?.documentId case final id?) {
      batch.newDocs[id] = result.outcome!.detectedName;
      if (job.item.isImage) batch.imageDocIds.add(id);
      if (result.ocr case final ocr?) {
        job.lowOcrYield = isLowOcrYield(ocr.text);
        // 云抽取只**排队**,不在这里跑:每份一次 LLM 往返,串在队列里会把后面
        // 等着识别的照片堵上好几分钟。整批识别完再一起跑(见 [_finishBatch])。
        batch.pending.add((
          outcome: result.outcome!,
          ocr: ocr,
          profile: batch.profile,
          vaultRoot: batch.vaultRoot,
        ));
      }
    }
    batch.okElapsedMs += DateTime.now().difference(startedAt).inMilliseconds;
    batch.okCount++;
    job.state = ImportJobState.done;
    // 一份一份长出来:这一份识别完就让档案屏看见它,不等整批。
    bumpVaultRevision();
  } catch (e) {
    // 原始错误留日志给开发者;用户看到的是一句人话。
    debugPrint('[import-queue] ${job.label} 导入失败: $e');
    job.state = ImportJobState.failed;
    // 切成员那一条要说**怎么办**:重试仍然认捕获的那个成员(闸就是这么设计的),
    // 不切回去点多少次都还是这一行。
    job.error = e is ImportVaultSwitched
        ? '已经切换了成员,这一份没有导入 —— 切回原来那位成员再试'
        : '没能处理这一份';
    batch.rows.add(rowFromError(job.item.name, e));
    // ⚠️ 只记步骤和**原因码**,绝不记 `e` 本身 —— 异常文本里常带文件名和路径。
    batch.failStage ??= stage;
    batch.failReason ??= ImportFailReason.of(e);
  }
  if (job.state == ImportJobState.done && !job.needsAttention) {
    dismissImportJob(job);
  }
  _notify();
}

Future<void> _finishBatch(_Batch batch) async {
  // 成员已经切走 → 「还没核对」队列和档案自动命名都是**写在当前成员名下**的,
  // 写下去就是把甲的新文档记进乙的待办。不写,文档本身照常在它自己的箱子里。
  //
  // **每一步之前都重新问一次**,不是开头问一次就一路用到底:下面每个 `await`
  // 都是一个可以切成员的窗口(窄,但它就在用户眼前的 tab 条上)。
  bool sameProfile() => ProfileManager.instance.current.id == batch.profile.id;
  if (batch.newDocs.isNotEmpty && sameProfile()) {
    // 默认档案还没定过名字时,用识别到的第一个患者姓名自动命名它。
    final detected = batch.newDocs.values.firstWhere(
      (n) => n != null && n.trim().isNotEmpty,
      orElse: () => null,
    );
    await autoNameCurrentProfileFrom(detected);
    if (sameProfile()) await ReviewState.instance.markPending(batch.newDocs);
  }
  if (batch.mergePhotos && sameProfile()) {
    // **少一张就不合。** 合并不可撤销(见 `import_flow.askPhotoMerge`):拿剩下
    // 那几张合出来的是一份**少一页**的多页 PDF,修不回来;而失败那张重试产出的
    // 是另一份独立文档,永远进不了那份合并件。宁可让它们分开躺着 —— 一页不少,
    // 用户想合就重新导入这几张再合一次。
    if (batch.imageDocIds.length == batch.imageTotal && batch.imageTotal >= 2) {
      await _mergeBatchPhotos(batch);
    } else {
      final missing = batch.imageTotal - batch.imageDocIds.length;
      importQueueNotice.value =
          '刚才那 ${batch.imageTotal} 张里有 $missing 张没能入库,所以没有合并成一份'
          ' —— 合并不可撤销,少一页不如不合。已入库的都在档案里。';
    }
  }
  bumpVaultRevision();

  // 埋点:成功几份、失败几份、总共花了多久。失败只报计数,不报任何异常消息
  // (那里面常有文件名和路径)。
  final failedCount = batch.rows
      .where((r) => r.kind == ImportRowKind.failed)
      .length;
  final allFailed = failedCount == batch.rows.length;
  if (batch.countInAnalytics) {
    Analytics.track(
      allFailed
          ? AnalyticsEvent.docImportFailed
          : AnalyticsEvent.docImportCompleted,
      {
        'source': batch.source.name,
        'count_bucket': Bucket.count(batch.rows.length),
        'failed_bucket': Bucket.count(failedCount),
        // 改造后这个数**不再是「用户要等多久」**(用户点完就走了),而是「这批在
        // 后台跑了多久」,含排在别的批次后面干等的时间。要判断引擎快不快看下面
        // 那个单份平均,那个仍然只含 OCR + 落库。
        'duration_bucket': Bucket.duration(
          DateTime.now().difference(batch.startedAt),
        ),
        // 单份平均 = 引擎快不快(决定换不换 OCR)。口径与改造前逐字一致:只含
        // OCR + 落库,不含云抽取。
        if (batch.okCount > 0)
          'per_doc_duration_bucket': Bucket.perDoc(
            Duration(milliseconds: batch.okElapsedMs ~/ batch.okCount),
          ),
        // 首次导入成功率。库存读不到时**不报**,不猜。
        if (batch.sizeBefore != null) 'is_first': batch.sizeBefore == 0,
        if (allFailed) ...{
          'stage': batch.failStage ?? 'capture',
          'reason_code': (batch.failReason ?? ImportFailReason.unknown).name,
        },
      },
    );
  }

  // 云抽取从这里开始,**不等它**:整批已经全部落库,摘要有正则版本可看;抽取
  // 成功的那几份会各自 bump 一次,屏上自己换成更好的结果。失败(没登录/没网/
  // 闸拒发)全部在 `runCloudExtraction` 里吞掉。
  //
  // **排在合并之后**:合并会把原来那几份墓碑掉,先跑只会打在不存在的文档上。
  unawaited(runCloudExtractions(batch.pending));
}

/// 把这批照片合并成一份多页文档,并把「还没核对」和云抽取都改挂到新文档上。
///
/// 合并失败时原来那几份**一份不少**(保证来自 Rust 侧
/// `merge_documents_into_pdf`:任何校验/解码失败都发生在删除任何原文档之前),
/// 所以这里只报一句、不回滚任何东西。
Future<void> _mergeBatchPhotos(_Batch batch) async {
  final ids = batch.imageDocIds;
  final int? mergedId;
  try {
    mergedId = await ifVaultUnchanged(
      batch.profile,
      batch.vaultRoot,
      '合并 ${ids.length} 张照片',
      () async => (await mergePhotosIntoDocument(
        name: mergedDocumentName,
        documentIds: Int64List.fromList(ids),
      )).documentId,
    );
  } catch (e) {
    debugPrint('[import-queue] 合并失败: $e');
    importQueueNotice.value = '刚才那 ${ids.length} 张没能合并成一份,它们都还在,可以分开看。';
    return;
  }
  if (mergedId == null) return;

  // 姓名核对(「导错人」标红)要接着起作用:合并前几份里第一个识别到的姓名带到
  // 合并后这一份上 —— 内容是同一批照片的文字,姓名不会因为合并变化,但
  // `ReviewState` 是按文档 id 记的,原 id 已经不存在了,必须显式搬一次。
  final mergedDetectedName = ids
      .map((id) => batch.newDocs[id])
      .firstWhere((n) => n != null && n.trim().isNotEmpty, orElse: () => null);
  for (final id in ids) {
    batch.newDocs.remove(id);
    await ReviewState.instance.markReviewed(id);
  }
  batch.newDocs[mergedId] = mergedDetectedName;
  await ReviewState.instance.markPending({mergedId: mergedDetectedName});

  // 云抽取改成跑合并出来的这一份:原来那几份已经墓碑掉了,排着的请求只会打在
  // 不存在的文档上(见 `cloud_extract.pendingForMergedDocument`)。
  final merged = pendingForMergedDocument(
    documentId: mergedId,
    detectedName: mergedDetectedName,
    sources: batch.pending
        .where((p) => ids.contains(p.outcome.documentId))
        .toList(),
  );
  batch.pending.removeWhere((p) => ids.contains(p.outcome.documentId));
  if (merged != null) batch.pending.add(merged);
}

/// 成员/箱子在这一份排队等着的时候被换掉了 —— 这一份没有导入。
class ImportVaultSwitched implements Exception {
  const ImportVaultSwitched();

  @override
  String toString() => 'ImportVaultSwitched';
}

/// [importItemProcessor] 的生产实现:识别 → 落库 → 按页补 OCR。逐字沿用改造前
/// `import_flow._runImport` 循环体里的那几步,只是从模态进度框里搬到了后台。
Future<ImportItemOutcome> _processImportItem(
  ImportJob job,
  void Function(String stage) onStage,
) async {
  final item = job.item;
  final batch = job._batch;
  final ImportOutcomeDto outcome;
  OcrResult? ocr;
  if (item.isImage) {
    // iOS + 安卓统一 PP-OCRv5(见 ocr_bridge.dart;iOS 多一步 Vision 拉正)。
    // 这一步**留在 vault 队列外**:它最慢,塞进去会把开箱/同步/代拍全堵住。
    onStage('ocr');
    ocr = await recognizeImageText(item.path);
    onStage('save');
    final bytes = await File(item.path).readAsBytes();
    final text = ocr.text;
    final confidence = ocr.confidence;
    outcome =
        await ifVaultUnchanged(
          batch.profile,
          batch.vaultRoot,
          job.label,
          () => ingestImageWithText(
            name: item.name,
            bytes: bytes,
            ocrText: text,
            confidence: confidence,
          ),
        ) ??
        (throw const ImportVaultSwitched());
  } else {
    onStage('save');
    final bytes = await File(item.path).readAsBytes();
    outcome =
        await ifVaultUnchanged(
          batch.profile,
          batch.vaultRoot,
          job.label,
          () => ingestBytes(filename: item.name, data: bytes),
        ) ??
        (throw const ImportVaultSwitched());
  }

  // 按页补 OCR:哪些页缺文本层由 `outcome.pagesWithoutText` 点名。逻辑本身见
  // `import_flow.backfillPagesWithoutText` —— 医生代拍共用同一个函数,两条路
  // 不许各写一份。
  final stillMissingPages = await backfillPagesWithoutText(
    outcome,
    item.path,
    // 回填是**写事件**,同样只认添加那一刻的成员和箱子(见那边的 ⚠️)。
    profile: batch.profile,
    vaultRoot: batch.vaultRoot,
    onStage: onStage,
  );
  return ImportItemOutcome(
    rowForOutcome(outcome, stillMissingPages: stillMissingPages),
    outcome: outcome,
    ocr: ocr,
  );
}

/// 用例之间把这条模块级队列清干净(它是单例,上一个用例排剩的东西会漏进下一个)。
@visibleForTesting
void resetImportQueueForTest() {
  importJobs.value = const [];
  importQueueNotice.value = null;
  // 发新牌 = 把上一个用例还卡着的那条 drain 作废(见 [_drainToken])。
  _drainToken = null;
  importItemProcessor = _processImportItem;
}
