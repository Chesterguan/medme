// 「拍一份三页化验单变成三条独立记录」——`_runImport` 现在在导入完成后,如果
// 这批里有 ≥2 张照片各自建了文档,会弹一次「合并成一份?」确认(见
// `import_flow.dart` 里 `_offerPhotoMerge` 的文档注释)。**故意不自动合并**:
// 一批照片不保证真的是同一份文件的连续页,合并又是不可逆操作,错误合并的代价
// 比多问一次大得多。
//
// 这里只测「该不该问」这层纯判断(`shouldOfferPhotoMerge`),不是把整条导入链路
// 拉起来跑一遍——那条链路要触碰原生取件器 + Rust FFI(`ingestImageWithText` /
// `mergePhotosIntoDocument`),`flutter test` 的纯 dart 进程里没有实现绑定,与
// `import_review_navigation_test.dart` 测 `dispatchImportReview` 是同一个理由。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/import_flow.dart';

void main() {
  group('shouldOfferPhotoMerge', () {
    test('0 张(全部失败/全部非图片)不问', () {
      expect(shouldOfferPhotoMerge(0), isFalse);
    });

    test('1 张不问——只有一张不存在"合并"这回事', () {
      expect(shouldOfferPhotoMerge(1), isFalse);
    });

    test('2 张及以上要问', () {
      expect(shouldOfferPhotoMerge(2), isTrue);
      expect(shouldOfferPhotoMerge(3), isTrue);
      expect(shouldOfferPhotoMerge(20), isTrue);
    });
  });
}
