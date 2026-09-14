// 冒烟里连着抓到的两句「屏幕在骗人」:
//
//  1. 云抽取跑完什么都没读出来,档案行照样写「待归类」—— 和「还没轮到它」
//     一模一样,用户看到的是一份永远停在待归类的文档。
//  2. 一页纸只认出红章那一行、14 个字,详情页写「识别质量:高」—— 因为
//     `confidence` 是逐行均值,那一行确实认得很准。
//
// 两条都测判据本身,不拉起整个档案屏(那需要 Rust FFI;同 `visit_card_dedup_test`
// 的做法)。徽标那条额外真的 pump 一次,钉住用户读到的是哪句话。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
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

  group('识别质量:置信度高挡不住「几乎没认出字」', () {
    // 冒烟那批坏掉的三份就是这个样子:只剩红章一行,十来个字,均值置信度很高。
    const barelyAnything = '北京协和医院';

    test('置信度 0.98 但只认出十来个字 → 低,不是高', () {
      expect(confTierFor(0.98, barelyAnything), ConfTier.lowYield);
    });

    test('字数够但行数不够(两行)→ 仍然低', () {
      expect(
        confTierFor(0.98, '${'白细胞计数 11.8 10^9/L 4.0-10.0' * 2}\n再来一行凑够四十个字符的文本'),
        ConfTier.lowYield,
      );
    });

    test('产出正常时,档位仍然按置信度走', () {
      final full = List.generate(
        6,
        (i) => '白细胞计数 11.$i 10^9/L 参考区间 4.0-10.0',
      ).join('\n');
      expect(confTierFor(0.95, full), ConfTier.high);
      expect(confTierFor(0.80, full), ConfTier.mid);
      expect(confTierFor(0.50, full), ConfTier.low);
    });

    test('手动录入没有 OCR(置信度 null)→ 不画徽标', () {
      expect(confTierFor(null, ''), isNull);
    });
  });

  testWidgets('低产出徽标写的是「几乎没认出字,建议重拍」', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ConfBadge(tier: ConfTier.lowYield)),
      ),
    );
    expect(find.text('识别质量:低 · 几乎没认出字,建议重拍'), findsOneWidget);
  });
}
