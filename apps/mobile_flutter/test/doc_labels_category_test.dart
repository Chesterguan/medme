// R3:`categoryForDocType` 覆盖 `doc_labels.dart` 认得的每一档文档类型,不漏一个、
// 不发明新的 GlossCategory。Task 9(「趋势」页)复用同一个函数,断在这里就够了,
// 不用在每一屏各测一遍。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';

void main() {
  test('categoryForDocType:docLabel 的每一档都有明确归类', () {
    expect(categoryForDocType('lab_report'), GlossCategory.lab);
    expect(categoryForDocType('pathology'), GlossCategory.lab);
    expect(categoryForDocType('imaging_report'), GlossCategory.imaging);
    expect(categoryForDocType('prescription'), GlossCategory.med);
    expect(categoryForDocType('discharge_summary'), GlossCategory.clinic);
    expect(categoryForDocType('clinical_note'), GlossCategory.clinic);
    expect(categoryForDocType('surgery'), GlossCategory.clinic);
    expect(categoryForDocType('note'), GlossCategory.note);
    expect(categoryForDocType('self_measurement'), GlossCategory.note);
    expect(categoryForDocType('other'), GlossCategory.neutral);
    expect(categoryForDocType('unknown'), GlossCategory.neutral);
    // docLabel 里没有的类型:认不出就中性,不借某个具体类别的颜色。
    expect(categoryForDocType('这是个从没见过的类型'), GlossCategory.neutral);
  });

  test('docLabel 的 key 一个不漏地被上面这组断言覆盖到', () {
    const covered = {
      'lab_report', 'pathology', 'imaging_report', 'prescription',
      'discharge_summary', 'clinical_note', 'surgery', 'note',
      'self_measurement', 'other', 'unknown',
    };
    expect(docLabel.keys.toSet(), covered,
        reason: 'doc_labels.dart 加了新文档类型时,这条测试先红,提醒去 categoryForDocType 补一档');
  });
}
