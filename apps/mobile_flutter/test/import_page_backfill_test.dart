// 混合页 PDF 的「后续页缺文本层」在 Rust 侧已经修好,`ImportOutcomeDto.pagesWithoutText`
// 会如实点名哪些页没拿到文字。**但它只有被消费才有价值。**
//
// 患者模式(`import_flow.dart::_runImport`)一直在按页补 OCR、补不完就在汇总里说
// 「N 页未能识别文字」;医生代拍(`screens/doctor/proxy_intake_flow.dart::_ingest`)
// 却把 `pagesWithoutText` 整个丢弃 —— 既不补,也不说。医生当场拍完以为收全了,
// 病人一走就再也补不上,比患者事后自己发现贵得多。
//
// 这份测试钉三件事:
//   1. 抽出来的 `backfillPagesWithoutText` 与抽取前患者模式那段内联代码**行为逐条一致**
//      (那条路已经装机验证过,抽取不许改变它)。
//   2. 「没收全」的措辞只有**一份**:患者模式和代拍从同一个 `ImportIncompleteNotice`
//      取字符串,同一件事不许在两屏上长成两个略微不同的说法。
//   3. 代拍**真的接上了**这两样东西(接线本身)。
//
// 为什么第 3 组是读源码而不是跑 UI:代拍那条路要触碰原生取件器 + Rust FFI
// (`vault.ingestBytes` / `ingestImageWithText` / `backfillPdfText`),在 `flutter test`
// 的纯 dart 进程里没有实现绑定,整条 `_ingest` 起不来。而「函数写好了但没人调」正是
// 本次修复之前的真实状态 —— 只测函数会全绿,一个字都抓不到。仓库里
// `analytics_catalog_test.dart` 已经在用同样的手法把约定钉在源码上。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/import_flow.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

ImportOutcomeDto _outcome({
  String status = 'new',
  List<int> pagesWithoutText = const [],
  int? documentId = 7,
}) => ImportOutcomeDto(
  name: 'report.pdf',
  sourceFileId: 1,
  status: status,
  docType: 'lab_report',
  documentId: documentId,
  detectedName: null,
  pagesWithoutText: Int32List.fromList(pagesWithoutText),
);

/// 一次 `backfillPagesWithoutText` 调用里发生的全部可观察事件,用来逐条比对
/// 「抽取前后行为不变」。
class _Recorder {
  final stages = <String>[];
  final ocrCalls = <List<int>>[];
  final ocrPaths = <String>[];
  final backfills =
      <({int documentId, int pageNo, String text, double conf})>[];

  /// 每次回填发生时,`stage` 已经推进到哪一步 —— 抽取前的内联写法是先置
  /// `stage = 'save'` 再回填,埋点据此把回填期的失败归到 `save`。
  final stageAtBackfill = <String>[];

  PdfPageOcr ocrReturning(Map<int, OcrResult> result) => (path, pages) async {
    ocrPaths.add(path);
    ocrCalls.add(List.of(pages));
    return result;
  };

  Future<void> backfill({
    required int documentId,
    required int pageNo,
    required String text,
    required double confidence,
  }) async {
    backfills.add((
      documentId: documentId,
      pageNo: pageNo,
      text: text,
      conf: confidence,
    ));
    stageAtBackfill.add(stages.isEmpty ? '<none>' : stages.last);
  }
}

void main() {
  group('backfillPagesWithoutText —— 抽取自患者模式,行为逐条不变', () {
    test('没有缺文本层的页:直接返回 0,不渲染、不回填、不动 stage', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {}),
        backfill: rec.backfill,
      );
      expect(missing, 0);
      expect(rec.ocrCalls, isEmpty, reason: '绝大多数文件走这条路,不该多跑一轮渲染');
      expect(rec.backfills, isEmpty);
      expect(
        rec.stages,
        isEmpty,
        reason: 'stage 必须保持调用方原样(落库后就是 save),抽取前也没有动它',
      );
    });

    test('点名了缺页但文档没建起来(documentId 为 null):同样什么都不做', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [1, 2], documentId: null),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {2: OcrResult('x', 0.9)}),
        backfill: rec.backfill,
      );
      expect(missing, 0);
      expect(rec.ocrCalls, isEmpty);
      expect(rec.backfills, isEmpty);
    });

    test('只把被点名的那几页送去 OCR —— 混合页 PDF 里有文本层的页不重跑', () async {
      final rec = _Recorder();
      await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [3, 4, 7]),
        '/tmp/mixed.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {}),
        backfill: rec.backfill,
      );
      expect(rec.ocrCalls, [
        [3, 4, 7],
      ]);
      expect(rec.ocrPaths, ['/tmp/mixed.pdf']);
    });

    test('全部补上:返回 0,逐页回填(page_no 是真实页码,不是固定 1)', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [2, 3]),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {
          2: OcrResult('第二页', 0.81),
          3: OcrResult('第三页', 0.92),
        }),
        backfill: rec.backfill,
      );
      expect(missing, 0);
      expect(rec.backfills, [
        (documentId: 7, pageNo: 2, text: '第二页', conf: 0.81),
        (documentId: 7, pageNo: 3, text: '第三页', conf: 0.92),
      ]);
    });

    test('只补上一部分:返回**还差几页**,没恢复的页不回填空文本', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [2, 3, 4]),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {3: OcrResult('第三页', 0.9)}),
        backfill: rec.backfill,
      );
      expect(missing, 2);
      expect(rec.backfills.map((b) => b.pageNo), [3]);
    });

    test('一页都没补上:返回全部页数,绝不悄悄吞成 0', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(status: 'stored_no_text', pagesWithoutText: [1, 2, 3]),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {}),
        backfill: rec.backfill,
      );
      expect(missing, 3);
      expect(rec.backfills, isEmpty);
    });

    test('stage 推进顺序:渲染/OCR 前报 ocr,回填开始时已经是 save', () async {
      final rec = _Recorder();
      await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [2]),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {2: OcrResult('x', 0.9)}),
        backfill: rec.backfill,
      );
      expect(rec.stages, ['ocr', 'save']);
      expect(rec.stageAtBackfill, [
        'save',
      ], reason: '回填期的失败要归到 save —— 抽取前的内联写法就是先置 save 再回填');
    });

    test('返回值直接喂 rowForOutcome:补不完就是 partial,不是看起来完整的 success', () async {
      final outcome = _outcome(pagesWithoutText: [2, 3]);
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        outcome,
        '/tmp/a.pdf',
        ocrPages: rec.ocrReturning(const {2: OcrResult('x', 0.9)}),
        backfill: rec.backfill,
      );
      final row = rowForOutcome(outcome, stillMissingPages: missing);
      expect(row.kind, ImportRowKind.partial);
      expect(row.statusLabel, contains('1 页未能识别文字'));
    });
  });

  group('多页图片(多页 TIFF)—— 点名的页端上补不回来,必须照实报', () {
    // 原生识别器只认第一帧,所以 pipeline / ingest_image_with_text 会点名第 2 页
    // 起的所有页。它们不是 PDF,渲染补救这条路根本走不通。
    test('图片路径不去渲染 PDF,直接把点名的页数原样报回来', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [2, 3]),
        '/tmp/两页化验单.tiff',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {2: OcrResult('绝不该被用上', 0.9)}),
        backfill: rec.backfill,
      );
      expect(missing, 2, reason: '一页都补不回来,不许因为补救函数返回了东西就少报');
      expect(
        rec.ocrCalls,
        isEmpty,
        reason: '把 TIFF 交给 PdfDocument.openFile 是白跑一趟,不该发生',
      );
      expect(rec.backfills, isEmpty, reason: '没有任何新文本,不该回填');
      expect(rec.stages, isEmpty, reason: '没进渲染/回填,stage 不该被推进');
    });

    test('照实报出来的页数走 rowForOutcome 就是 partial —— 不是「已识别入库」', () {
      final outcome = _outcome(pagesWithoutText: [2]);
      final row = rowForOutcome(outcome, stillMissingPages: 1);
      expect(
        row.kind,
        ImportRowKind.partial,
        reason: '两页 TIFF 第 1 页认出来了、第 2 页整页没读 —— 用户必须看得见',
      );
      expect(row.statusLabel, contains('1 页未能识别文字'));
    });

    test('PDF 一如既往地走渲染补救 —— 图片这条岔路不许波及它', () async {
      final rec = _Recorder();
      final missing = await backfillPagesWithoutText(
        _outcome(pagesWithoutText: [2]),
        '/tmp/a.pdf',
        onStage: rec.stages.add,
        ocrPages: rec.ocrReturning(const {2: OcrResult('第二页', 0.9)}),
        backfill: rec.backfill,
      );
      expect(missing, 0);
      expect(rec.ocrCalls, [
        [2],
      ]);
      expect(rec.stages, ['ocr', 'save']);
    });
  });

  group('「没收全」的措辞只有一份 —— 两屏不许各说各的', () {
    test('incompleteNoticesFor 用的就是 ImportIncompleteNotice 的字符串', () {
      final rows = [
        const ImportResultRow(
          name: 'a.pdf',
          statusLabel: '',
          kind: ImportRowKind.storedNoText,
        ),
        const ImportResultRow(
          name: 'b.pdf',
          statusLabel: '',
          kind: ImportRowKind.partial,
        ),
        const ImportResultRow(
          name: 'c.pdf',
          statusLabel: '',
          kind: ImportRowKind.partial,
        ),
        const ImportResultRow(
          name: 'd.pdf',
          statusLabel: '',
          kind: ImportRowKind.success,
        ),
      ];
      expect(incompleteNoticesFor(rows), [
        ImportIncompleteNotice.storedNoText(1),
        ImportIncompleteNotice.partialPages(2),
      ]);
    });

    test('全都收全了:一句话都不说(空列表,调用方据此不弹提示)', () {
      expect(
        incompleteNoticesFor(const [
          ImportResultRow(
            name: 'a.pdf',
            statusLabel: '',
            kind: ImportRowKind.success,
          ),
          ImportResultRow(
            name: 'b.pdf',
            statusLabel: '',
            kind: ImportRowKind.duplicate,
          ),
        ]),
        isEmpty,
      );
    });

    test('这两句话在 lib/ 里只出现在 import_helpers.dart 一处', () {
      const phrases = ['部分页未能识别', '仅存原件(未识别到文字)'];
      for (final phrase in phrases) {
        final owners = Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => f.readAsStringSync().contains(phrase))
            .map((f) => f.path)
            .toList();
        expect(
          owners.length,
          1,
          reason:
              '「$phrase」出现在 $owners —— 措辞必须只有一个来源'
              '(ImportIncompleteNotice),否则两屏迟早说出两句不一样的话',
        );
      }
    });
  });

  group('proxyIntakeNotice —— 代拍采集完那条提示条', () {
    ImportResultRow row(ImportRowKind kind) =>
        ImportResultRow(name: 'x.pdf', statusLabel: '', kind: kind);

    test('全都收全、也没有失败:不弹(返回 null)', () {
      expect(
        proxyIntakeNotice(rows: [row(ImportRowKind.success)], failed: 0),
        isNull,
      );
    });

    test('只有失败:仍是原来那句话,一字未改', () {
      expect(proxyIntakeNotice(rows: const [], failed: 2), '有 2 份未能处理,可重拍');
    });

    test('落库了但有页没识别出来:必须说出来 —— 这正是修复前被丢掉的那件事', () {
      final notice = proxyIntakeNotice(
        rows: [row(ImportRowKind.partial)],
        failed: 0,
      );
      expect(notice, isNotNull);
      expect(notice, ImportIncompleteNotice.partialPages(1));
    });

    test('整份一个字都没识别出来:也要说,且用的是「仅存原件」那一档措辞', () {
      expect(
        proxyIntakeNotice(rows: [row(ImportRowKind.storedNoText)], failed: 0),
        ImportIncompleteNotice.storedNoText(1),
      );
    });

    test('三件事同时发生:一条提示条分行说完,失败在最前', () {
      expect(
        proxyIntakeNotice(
          rows: [
            row(ImportRowKind.storedNoText),
            row(ImportRowKind.partial),
            row(ImportRowKind.success),
          ],
          failed: 1,
        ),
        '有 1 份未能处理,可重拍\n'
        '${ImportIncompleteNotice.storedNoText(1)}\n'
        '${ImportIncompleteNotice.partialPages(1)}',
      );
    });
  });

  group('代拍确实接上了(接线本身,不只是函数存在)', () {
    final proxy = File('lib/screens/doctor/proxy_intake_flow.dart');

    test('源文件在', () {
      expect(proxy.existsSync(), isTrue, reason: '文件挪了位置就来改这里');
    });

    test('落库之后调 backfillPagesWithoutText —— 缺文本层的页要当场补', () {
      expect(
        proxy.readAsStringSync(),
        contains('backfillPagesWithoutText('),
        reason:
            '修复前这里拿到 outcome 就扔,pagesWithoutText 一眼都没看。'
            '医生当场漏页、病人走了补不回来,比患者事后漏页贵得多',
      );
    });

    test('把每份结果过 rowForOutcome —— 「还差几页」要变成用户看得见的东西', () {
      expect(proxy.readAsStringSync(), contains('rowForOutcome('));
    });

    test('采集完把「没收全」说出去 —— 走与患者模式同源的 proxyIntakeNotice', () {
      expect(
        proxy.readAsStringSync(),
        contains('proxyIntakeNotice('),
        reason: '补不完是常态(超单次上限/渲染失败),补不完还不说才是缺陷',
      );
    });
  });
}
