// `doc_labels.dart` 的日期区间格式与自测指标标签——`fmtDay`/`fmtDayRange`/
// `selfAnalyteLabel`,Task 3 brief Step 4。
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/doc_labels.dart';

void main() {
  group('fmtDay', () {
    test('不补零,与 monthLabel 同一习惯', () {
      expect(fmtDay('2026-04-27'), '4 月 27 日');
    });

    test('解析失败原样返回', () {
      expect(fmtDay('不是日期'), '不是日期');
    });
  });

  group('fmtDayRange', () {
    test('两个日期用 en dash 连起来,两侧空格', () {
      expect(fmtDayRange('2026-04-27', '2026-05-03'), '4 月 27 日 – 5 月 3 日');
    });
  });

  group('selfAnalyteLabel', () {
    test('bp_systolic/bp_diastolic 都叫「血压」——界面把两者并成一行', () {
      expect(selfAnalyteLabel('bp_systolic'), '血压');
      expect(selfAnalyteLabel('bp_diastolic'), '血压');
    });

    test('heart_rate → 心率', () => expect(selfAnalyteLabel('heart_rate'), '心率'));
    test('body_weight → 体重', () => expect(selfAnalyteLabel('body_weight'), '体重'));
    test('body_temperature → 体温', () => expect(selfAnalyteLabel('body_temperature'), '体温'));
    test('glucose → 血糖', () => expect(selfAnalyteLabel('glucose'), '血糖'));
  });
}
