// 导入改后台队列(task-24 A27)。这里钉的是**队列本身**的行为:顺序、身份闸、
// 失败态与重试、第二次导入追加到同一条队列。
//
// 真正落库那一步(`recognizeImageText` / `ingestImageWithText` / `backfillPdfText`)
// 要碰 Rust FFI,`flutter test` 的纯 dart 进程里没有实现绑定 —— 所以它经
// `importItemProcessor` 注入替身,与 `cloud_extract` 那边注入 `readCurrentVaultRoot`
// 是同一个套路。被替掉的只有「一份文件怎么处理」,队列的编排、身份核对、账本全是
// 生产代码本身。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/cloud_extract.dart' show readCurrentVaultRoot;
import 'package:mobile_flutter/import_flow.dart' show ImportChoice;
import 'package:mobile_flutter/import_queue.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/vault_boot.dart' show resetVaultQueueForTest;
import 'package:shared_preferences/shared_preferences.dart';

const _root = '/docs/profiles/p-1/vault';

/// 一份识别正常的 OCR 结果(够长,不会撞上低产出闸 [isLowOcrYield])。
const _ocr = OcrResult(
  '北京协和医院\n检验科血常规检验报告单\n姓名:张建国 性别:男 年龄:60岁\n'
  'WBC 白细胞计数 11.8 10^9/L 3.5-9.5 ↑\nHGB 血红蛋白 139 g/L 130-175 正常\n'
  'PLT 血小板计数 203 10^9/L 125-350 正常\n',
  0.9,
);

PendingImport _photo(String name) =>
    PendingImport(name: name, path: '/tmp/$name', isImage: true);

ImportItemOutcome _ok(String name, int docId) => ImportItemOutcome(
  ImportResultRow(
    name: name,
    statusLabel: '已识别入库',
    kind: ImportRowKind.success,
  ),
  outcome: ImportOutcomeDto(
    name: name,
    sourceFileId: docId,
    status: 'new',
    documentId: docId,
    pagesWithoutText: Int32List(0),
  ),
  ocr: _ocr,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Profile profile;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resetVaultQueueForTest();
    resetImportQueueForTest();
    await ProfileManager.instance.ensureLoaded();
    profile = ProfileManager.instance.current;
    readCurrentVaultRoot = () async => _root;
  });

  tearDown(() {
    resetImportQueueForTest();
    resetVaultQueueForTest();
  });

  /// 排一批并等队列跑干净。队列是「发了就走」的,测试得自己等 ——
  /// 等到没有任何一行还在排队/正在跑为止。
  Future<void> enqueueAndSettle(
    List<PendingImport> items, {
    bool mergePhotos = false,
  }) async {
    enqueueImport(
      items: items,
      profile: profile,
      vaultRoot: _root,
      source: ImportChoice.gallery,
      mergePhotos: mergePhotos,
    );
    for (var i = 0; i < 200; i++) {
      final busy = importJobs.value.any(
        (j) =>
            j.state == ImportJobState.queued ||
            j.state == ImportJobState.running,
      );
      if (!busy) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('队列没跑完:${importJobs.value.map((j) => j.state).toList()}');
  }

  test('串行、按排队顺序跑,一次只跑一份', () async {
    final started = <String>[];
    var concurrent = 0;
    var maxConcurrent = 0;
    var docId = 1;
    importItemProcessor = (job, onStage) async {
      started.add(job.item.name);
      concurrent++;
      maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
      await Future<void>.delayed(Duration.zero);
      concurrent--;
      return _ok(job.item.name, docId++);
    };

    await enqueueAndSettle([_photo('a.jpg'), _photo('b.jpg'), _photo('c.jpg')]);

    expect(started, ['a.jpg', 'b.jpg', 'c.jpg']);
    expect(maxConcurrent, 1, reason: '串行:同一时刻只许跑一份');
    // 全都干干净净地成功了 → 屏上一行不留(文档自己长在时间线上就是回执)。
    expect(importJobs.value, isEmpty);
  });

  test('第二次导入追加到同一条队列,不另起一条并行的', () async {
    final started = <String>[];
    var concurrent = 0;
    var maxConcurrent = 0;
    var docId = 1;
    final gate = Completer<void>();
    importItemProcessor = (job, onStage) async {
      started.add(job.item.name);
      concurrent++;
      maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
      // 第一份卡住不返回,期间第二批插进来 —— 它必须排队,不许自己跑起来。
      if (job.item.name == 'a.jpg') await gate.future;
      await Future<void>.delayed(Duration.zero);
      concurrent--;
      return _ok(job.item.name, docId++);
    };

    enqueueImport(
      items: [_photo('a.jpg')],
      profile: profile,
      vaultRoot: _root,
      source: ImportChoice.gallery,
      mergePhotos: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a.jpg']);

    enqueueImport(
      items: [_photo('b.jpg')],
      profile: profile,
      vaultRoot: _root,
      source: ImportChoice.camera,
      mergePhotos: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a.jpg'], reason: '第一份还卡着,第二批只能排队');
    expect(importJobs.value.length, 2);

    gate.complete();
    for (var i = 0; i < 200 && importJobs.value.isNotEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(started, ['a.jpg', 'b.jpg']);
    expect(maxConcurrent, 1);
  });

  test('成员被切走 → 这一份不导入,失败态留在屏上,一个字节都没碰 vault', () async {
    var processed = 0;
    importItemProcessor = (job, onStage) async {
      processed++;
      return _ok(job.item.name, 1);
    };
    // 排队时捕获的是另一个成员 —— 等价于「排着队的时候用户切了成员」。
    enqueueImport(
      items: [_photo('a.jpg')],
      profile: const Profile(id: 'someone-else', name: '别人'),
      vaultRoot: _root,
      source: ImportChoice.gallery,
      mergePhotos: false,
    );
    for (var i = 0; i < 200; i++) {
      if (importJobs.value.every((j) => j.state == ImportJobState.failed)) break;
      await Future<void>.delayed(Duration.zero);
    }

    expect(processed, 0, reason: '身份不对就连 OCR 都不该跑');
    expect(importJobs.value.single.state, ImportJobState.failed);
    expect(importJobs.value.single.error, contains('切换'));
  });

  test('失败的那一份留着 + 重试;重试成功后行自己撤掉', () async {
    var attempts = 0;
    importItemProcessor = (job, onStage) async {
      attempts++;
      if (attempts == 1) throw StateError('第一次故意炸');
      return _ok(job.item.name, 7);
    };

    await enqueueAndSettle([_photo('a.jpg')]);
    final failed = importJobs.value.single;
    expect(failed.state, ImportJobState.failed);
    expect(failed.error, isNotNull);

    retryImportJob(failed);
    for (var i = 0; i < 200 && importJobs.value.isNotEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(attempts, 2);
    expect(importJobs.value, isEmpty);
  });

  test('一份失败不打断后面的', () async {
    final done = <String>[];
    var docId = 1;
    importItemProcessor = (job, onStage) async {
      if (job.item.name == 'b.jpg') throw StateError('这一份坏了');
      done.add(job.item.name);
      return _ok(job.item.name, docId++);
    };

    await enqueueAndSettle([_photo('a.jpg'), _photo('b.jpg'), _photo('c.jpg')]);
    expect(done, ['a.jpg', 'c.jpg']);
    expect(importJobs.value.single.item.name, 'b.jpg');
    expect(importJobs.value.single.state, ImportJobState.failed);
  });

  test('本机识别太少的那一份:入了库,但行留着说「建议重拍」', () async {
    importItemProcessor = (job, onStage) async => ImportItemOutcome(
      const ImportResultRow(
        name: 'a.jpg',
        statusLabel: '已识别入库',
        kind: ImportRowKind.success,
      ),
      outcome: ImportOutcomeDto(
        name: 'a.jpg',
        sourceFileId: 1,
        status: 'new',
        documentId: 1,
        pagesWithoutText: Int32List(0),
      ),
      // 只剩一行红章 —— 正是 `isLowOcrYield` 要挡的那种。
      ocr: const OcrResult('北京协和医院', 0.9),
    );

    await enqueueAndSettle([_photo('a.jpg')]);
    final job = importJobs.value.single;
    expect(job.state, ImportJobState.done);
    expect(job.lowOcrYield, isTrue);
    expect(job.needsAttention, isTrue);
  });

}
