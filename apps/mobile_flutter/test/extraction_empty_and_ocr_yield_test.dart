// 冒烟里抓到的一句「屏幕在骗人」:
//
// 云抽取跑完什么都没读出来,档案行照样写「待归类」—— 和「还没轮到它」
// 一模一样,用户看到的是一份永远停在待归类的文档。测判据本身,不拉起整个
// 档案屏(那需要 Rust FFI;同 `visit_card_dedup_test` 的做法)。
//
// 这份文件原先还钉了第二句「屏幕在骗人」:一页纸只认出红章那一行、14 个字,
// 详情页却写「识别质量:高」。Task 7 把那块徽标连 `confTierFor`/`ConfBadge`
// 一起从 `document_detail.dart` 删掉了(ia-proposal §3 第 7 簇),不再有徽标
// 会说这句话,这份测试也就没有再钉住它的必要。产出闸本身([isLowOcrYield])
// 还在,测试在 `cloud_extract_test.dart`。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

DocumentSummaryDto _doc({required String docType, int? extractionItemCount}) =>
    DocumentSummaryDto(
      id: 1,
      docType: docType,
      pageCount: 1,
      extractionItemCount: extractionItemCount,
    );

void main() {
  group('档案行:「待归类」拆成两句话', () {
    test('还没跑过云抽取 → 待归类', () {
      expect(
        docRowLabel(_doc(docType: 'unknown', extractionItemCount: null)),
        '待归类',
      );
    });

    test('跑过了、一条都没读出来 → 明说没读出内容', () {
      expect(
        docRowLabel(_doc(docType: 'unknown', extractionItemCount: 0)),
        '云端整理没有读出内容',
      );
    });

    test('读出了内容但类型仍未知 → 仍是待归类(那是分类的事)', () {
      expect(
        docRowLabel(_doc(docType: 'unknown', extractionItemCount: 3)),
        '待归类',
      );
    });

    test('类型认得出时,抽取状态不参与——照常显示类型', () {
      expect(
        docRowLabel(_doc(docType: 'lab_report', extractionItemCount: 0)),
        '化验',
      );
    });
  });
}
