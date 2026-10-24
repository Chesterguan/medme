// 档案行标题中文在前(2026-10-23 中文化 spec §2.1.3):`titleZh` 有值时顶替类型标签,
// 医院名照旧在前;没有 `titleZh` 时与之前逐字相同(类型标签)。
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

DocumentSummaryDto _dto({
  required String docType,
  String? title,
  String? titleZh,
  String? provider,
}) => DocumentSummaryDto(
  id: 1,
  docType: docType,
  docDate: '2025-06-14T00:00:00+00:00',
  pageCount: 1,
  title: title,
  titleZh: titleZh,
  provider: provider,
);

void main() {
  test('docDisplayTitle prefers titleZh over the type label and keeps the provider', () {
    final d = _dto(
      docType: 'discharge_summary',
      title: 'Discharge Summary Note',
      titleZh: '出院小结',
      provider: 'UF Health Shands',
    );
    expect(docDisplayTitle(d), 'UF Health Shands · 出院小结');
  });

  test('without titleZh the row falls back to the type label, as before', () {
    final plain = _dto(docType: 'discharge_summary', title: 'Discharge Summary Note');
    expect(docDisplayTitle(plain), '出院小结');
    final lab = _dto(docType: 'lab_report', title: '化验 2025-06-14', provider: 'UF Health Shands');
    expect(docDisplayTitle(lab), 'UF Health Shands · 化验');
  });

  test('an imaging titleZh keeps the modality and the original body part', () {
    final imaging = _dto(
      docType: 'imaging_report',
      title: 'CT CHEST W CONTRAST',
      titleZh: 'CT · CHEST W CONTRAST',
    );
    expect(docDisplayTitle(imaging), 'CT · CHEST W CONTRAST');
  });

  test('notes keep their own content title even if a titleZh were present', () {
    final note = _dto(docType: 'note', title: '今天头有点晕', titleZh: '不该发生');
    expect(docDisplayTitle(note), '今天头有点晕');
  });
}
