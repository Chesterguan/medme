// 产品反馈:「存档/拍照之后为什么不跳转到档案页,还停留在首页」。核实后根因
// 不是缺一个跳转,是 `review_state.dart` 那一整套「新导入待确认」质量闸门在
// 概览页这条路径上从未被触发过 —— 导入完只原地刷新,复核提示对所有从首页
// 导入的人不可见。见 `lib/import_flow.dart` 的 `ImportRunResult` /
// `reviewDestinationFor` / `dispatchImportReview` 类文档。
//
// 这里测的是**该不该跳、跳去哪**这层纯判断,不是把 `OverviewScreen` 整个拉起来
// 跑一遍真实导入 —— 那条链路要触碰原生取件器 + Rust FFI(`ingestBytes` /
// `ingestImageWithText`),在 `flutter test` 的纯 dart 进程里都没有实现绑定,
// 这个仓库里没有任何测试触碰过它们(`import_flow.dart` 之前也没有专门测试)。
// `dispatchImportReview` 正是为此把「决定去哪」从「怎么导航」里剥出来:
// 生产代码里 `openArchive`/`openSingleDocument` 两个回调各自去 `Navigator.push`
// 什么,由 `overview_screen.dart` 决定;这里只断言**该结果触发了哪个回调**,
// 这正是「取消不跳」「全部失败不跳」「成功能到达复核入口」这三条要守住的地方。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/import_flow.dart';

void main() {
  group('取消导入不跳转', () {
    test('showImportSheet/runImport 在取消时返回 null —— dispatchImportReview 收到 null 不跳', () {
      // null 就是 runImport/showImportSheet 在「用户没选、context 失效」时
      // 真正返回的值(见 import_flow.dart 里两处 `if (... ) return null;`)——
      // 不是为了测试专门编的形状。
      var openedDoc = false;
      var openedArchive = false;
      dispatchImportReview(
        null,
        openSingleDocument: (_) => openedDoc = true,
        openArchive: () => openedArchive = true,
      );
      expect(openedDoc, isFalse);
      expect(openedArchive, isFalse);
    });

    test('reviewDestinationFor(null) == none', () {
      expect(reviewDestinationFor(null), ImportReviewDestination.none);
    });
  });

  group('全部失败(或全部重复)不跳转', () {
    // `_runImport` 只在 `outcome.documentId` 非空时才把 id 塞进 `newDocs`
    // (import_flow.dart:602 附近)——失败的条目走 catch 分支,重复的条目
    // Rust 侧回的 outcome 不带 documentId,两种都不会出现在这个列表里。
    // 所以「全部失败/全部重复」在这一层的形状就是一个空的 newDocumentIds。
    test('空 newDocumentIds → none,两个回调都不触发', () {
      var openedDoc = false;
      var openedArchive = false;
      dispatchImportReview(
        const ImportRunResult([]),
        openSingleDocument: (_) => openedDoc = true,
        openArchive: () => openedArchive = true,
      );
      expect(openedDoc, isFalse);
      expect(openedArchive, isFalse);
    });

    test('ImportRunResult([]).hasNewDocs 为 false', () {
      expect(const ImportRunResult([]).hasNewDocs, isFalse);
      expect(
        reviewDestinationFor(const ImportRunResult([])),
        ImportReviewDestination.none,
      );
    });
  });

  group('成功后能到达复核入口', () {
    test('恰好一份新文档 → 直接进那一份详情,不开档案屏', () {
      int? openedId;
      dispatchImportReview(
        const ImportRunResult([42]),
        openSingleDocument: (id) => openedId = id,
        openArchive: () => fail('单份新文档不该走档案屏这条路'),
      );
      expect(openedId, 42);
    });

    test('多份新文档 → 开档案屏,不进任何单份详情', () {
      var openedArchive = false;
      dispatchImportReview(
        const ImportRunResult([42, 43]),
        openSingleDocument: (_) => fail('多份新文档不该直接进某一份详情'),
        openArchive: () => openedArchive = true,
      );
      expect(openedArchive, isTrue);
    });

    // 患者模式的导入现在一律走后台队列(task-24 A27):`runImport` 在采集一结束
    // 就返回,那时一份都还没识别完,所以 `newDocumentIds` 恒为空 —— 该不该带用户
    // 去核对改由 `queuedCount` 说了算。这两条钉住那个改动:排了队就去档案(那儿
    // 有「识别中」和置顶的待确认),一份都没排上就照旧不跳。
    test('排进了后台队列 → 去档案(哪怕此刻还没有任何新文档 id)', () {
      var openedArchive = false;
      dispatchImportReview(
        const ImportRunResult([], queuedCount: 3),
        openSingleDocument: (_) => fail('此刻一份都还没识别完,没有"那一份"可进'),
        openArchive: () => openedArchive = true,
      );
      expect(openedArchive, isTrue);
      expect(
        reviewDestinationFor(const ImportRunResult([], queuedCount: 1)),
        ImportReviewDestination.archive,
      );
    });

    test('一份都没排上(取消/读不到保险箱)→ 不跳', () {
      expect(
        reviewDestinationFor(const ImportRunResult([], queuedCount: 0)),
        ImportReviewDestination.none,
      );
    });

    test('reviewDestinationFor 与份数一一对应', () {
      expect(
        reviewDestinationFor(const ImportRunResult([1])),
        ImportReviewDestination.singleDocument,
      );
      expect(
        reviewDestinationFor(const ImportRunResult([1, 2, 3])),
        ImportReviewDestination.archive,
      );
    });
  });
}
