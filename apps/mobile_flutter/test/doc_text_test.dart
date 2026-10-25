// 文档正文纯函数(checkpoint 1 F6 / F7 / F10)。
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/doc_text.dart';

const _header = 'SHANDS HOSPITAL\nHealth Information Department\nPO Box 100\nGainesville FL\nDoe, Jane\nMRN: 000\n';

void main() {
  test('foldRepeatedHeaders:首页页眉保留,后页逐字相同的页眉行与 (continued) 行折掉', () {
    final text = '${_header}Adm: 2026-10-05\n\nH&P Notes\nline a\n\n${_header}H&P Notes (continued)\nline b\n\n${_header}line c\n';
    final out = foldRepeatedHeaders(text);
    expect(out.startsWith(_header), isTrue);
    expect('SHANDS HOSPITAL'.allMatches(out).length, 1);
    expect(out.contains('(continued)'), isFalse);
    expect(out.contains('line a'), isTrue);
    expect(out.contains('line b'), isTrue);
    expect(out.contains('line c'), isTrue);
    expect(out.contains('\n\n\n'), isFalse, reason: '折掉之后不留一串空行');
  });

  test('docAnchors:出院诊断 / 住院经过 / 出院用药 / 随访,中英文,按行号排,正文里的句子不算', () {
    const text = 'Header\nDischarge Diagnoses:\nAortic stenosis\nHospital Course:\nWe will follow up on the labs next week after discharge from the unit.\nDischarge Medications:\nWarfarin\nFollow-up:\nClinic in 2 weeks\n';
    final a = docAnchors(text);
    expect(a.map((x) => x.label), ['出院诊断', '住院经过', '出院用药', '随访']);
    expect(a.map((x) => x.line), [1, 3, 5, 7]);
    final zh = docAnchors('出院诊断:主动脉瓣狭窄\n住院经过:…\n出院带药:华法林\n随访:两周\n');
    expect(zh.map((x) => x.label), ['出院诊断', '住院经过', '出院用药', '随访']);
    expect(docAnchors('just text'), isEmpty);
  });

  test('findLineWith:同时含项目名与数值的第一行;只有名字时退回只按名字', () {
    const text = 'Creatinine 1.20 mg/dL\nCreatinine 0.88 mg/dL\nSodium 137\n';
    final hit = findLineWith(text, ['Creatinine', '0.88'])!;
    expect(hit.line, 'Creatinine 0.88 mg/dL');
    expect(hit.start, 'Creatinine 1.20 mg/dL\n'.length);
    expect(findLineWith(text, ['creatinine', '9.99'])!.line, 'Creatinine 1.20 mg/dL');
    expect(findLineWith(text, ['Glucose']), isNull);
  });
}
