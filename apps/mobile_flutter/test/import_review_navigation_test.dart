// 产品反馈:「存档/拍照之后为什么不跳转到档案页,还停留在首页」。核实后根因
// 不是缺一个跳转,是 `review_state.dart` 那一整套「新导入待确认」质量闸门在
// 概览页这条路径上从未被触发过 —— 导入完只原地刷新,复核提示对所有从首页
// 导入的人不可见。见 `lib/import_flow.dart` 的 `ImportRunResult` /
// `reviewDestinationFor` 类文档。
//
// 这里测的是**该不该跳、跳去哪**这层纯判断,不是把调用方那一整屏拉起来
// 跑一遍真实导入 —— 那条链路要触碰原生取件器 + Rust FFI(`ingestBytes` /
// `ingestImageWithText`),在 `flutter test` 的纯 dart 进程里都没有实现绑定,
// 这个仓库里没有任何测试触碰过它们(`import_flow.dart` 之前也没有专门测试)。
//
// ⚠️ Task 17:原来这里还测 `dispatchImportReview`——把「决定去哪」包成两个
// 回调(`openArchive`/`openSingleDocument`)、由调用方决定怎么导航的一层薄
// 封装。概览整屏解散(Task 9)之后它**一直没有生产调用方**(「病历」首页的
// 「添加」排进后台队列,靠「还没核对」横幅接人,不再当场跳转)——禁词闸合拢
// 时把这层没人用的封装删掉了,只留下面这层真正被复用的纯判断。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/import_flow.dart';

void main() {
  group('取消导入不跳转', () {
    test('reviewDestinationFor(null) == none', () {
      expect(reviewDestinationFor(null), ImportReviewDestination.none);
    });
  });

  group('全部失败(或全部重复)不跳转', () {
    test('ImportRunResult([]).hasNewDocs 为 false', () {
      expect(const ImportRunResult([]).hasNewDocs, isFalse);
      expect(
        reviewDestinationFor(const ImportRunResult([])),
        ImportReviewDestination.none,
      );
    });
  });

  group('成功后能到达复核入口', () {
    // 患者模式的导入现在一律走后台队列(task-24 A27):`runImport` 在添加一结束
    // 就返回,那时一份都还没识别完,所以 `newDocumentIds` 恒为空 —— 该不该带用户
    // 去核对改由 `queuedCount` 说了算。这两条钉住那个改动:排了队就去档案(那儿
    // 有「识别中」和置顶的待确认),一份都没排上就照旧不跳。
    test('排进了后台队列 → 去档案(哪怕此刻还没有任何新文档 id)', () {
      expect(
        reviewDestinationFor(const ImportRunResult([], queuedCount: 1)),
        ImportReviewDestination.archive,
      );
    });

    test('一份都没排上(取消/读不到病历箱)→ 不跳', () {
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
