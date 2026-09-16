import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

/// 档案行/详情页的标题此前直接显示 `document.title`,而那是**落库时的文件名** ——
/// 相册和相机给的是 `image_picker_1A2B.jpg` 这种临时名,于是用户的档案里排着一列
/// 看不懂的字符串。这组用例钉住 `docDisplayTitle` 的取名顺位。
DocumentSummaryDto _doc({
  String docType = 'lab_report',
  String? title,
  String? provider,
  String? docDate,
  int? extractionItemCount,
}) => DocumentSummaryDto(
  id: 1,
  docType: docType,
  title: title,
  provider: provider,
  docDate: docDate,
  pageCount: 1,
  extractionItemCount: extractionItemCount,
);

void main() {
  group('docDisplayTitle', () {
    test('院名 + 类型:认得出来的都说出来', () {
      expect(
        docDisplayTitle(
          _doc(
            provider: '北京协和医院',
            docType: 'lab_report',
            title: 'image_picker_1A2B.jpg',
          ),
        ),
        '北京协和医院 · 化验',
      );
    });

    test('文档里没有机构(自测记录)→ 只报类型', () {
      expect(
        docDisplayTitle(_doc(docType: 'self_measurement', title: 'IMG_0042.JPG')),
        '自测记录',
      );
    });

    test('类型都没分出来 → 退日期,而不是退临时文件名', () {
      expect(
        docDisplayTitle(
          _doc(
            docType: 'unknown',
            title: 'image_picker_1A2B.jpg',
            docDate: '2026-04-30T00:00:00+00:00',
          ),
        ),
        '2026-04-30',
      );
    });

    test('用户自己起的文件名是最后一档,但它比「待归类」强', () {
      expect(
        docDisplayTitle(_doc(docType: 'unknown', title: '出院小结扫描件.pdf')),
        '出院小结扫描件.pdf',
      );
    });

    test('什么都没有 —— 连日期都没有的临时名 → 退 docRowLabel 的三态说法', () {
      expect(
        docDisplayTitle(_doc(docType: 'unknown', title: 'image_picker_1A2B.jpg')),
        '待归类',
      );
      expect(
        docDisplayTitle(
          _doc(
            docType: 'unknown',
            title: 'image_picker_1A2B.jpg',
            extractionItemCount: 0,
          ),
        ),
        '云端整理没有读出内容',
      );
    });

    test('院名在,类型没分出来 → 院名 + 日期,不掺临时文件名', () {
      expect(
        docDisplayTitle(
          _doc(
            docType: 'unknown',
            provider: '北京协和医院',
            title: 'image_picker_1A2B.jpg',
            docDate: '2026-04-30T00:00:00+00:00',
          ),
        ),
        '北京协和医院 · 2026-04-30',
      );
    });
  });

  group('isTempCaptureName —— 这些名字一个都不许端给用户', () {
    for (final name in const [
      'image_picker_1A2B-3C4D-5E6F.jpg',
      'scaled_image_picker_9F8E.jpg',
      'IMG_0042.JPG',
      'capture.jpg',
      'CAP_20260430_120000.jpg',
      '1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D.heic',
    ]) {
      test(name, () => expect(isTempCaptureName(name), isTrue));
    }

    for (final name in const [
      '出院小结扫描件.pdf',
      '2026-04-30 血常规.jpg',
      'discharge-summary.pdf',
    ]) {
      test('$name 是用户自己的名字,留着', () {
        expect(isTempCaptureName(name), isFalse);
      });
    }
  });
}
