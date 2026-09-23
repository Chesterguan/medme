// `widgets/self_week.dart` 的纯函数(`selfWeekTitle`/`selfWeekDesc`/
// `selfValuesLine`)+ [SelfWeekRows] 展开列表的最小渲染/点击验收。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/self_week.dart';

void main() {
  test('selfWeekDesc:血压并成一项,范围用 en dash,单次只写一个数', () {
    final items = [
      SelfWeekItemDto(analyteKey: 'bp_systolic', count: 5, min: 118, max: 132, unit: 'mmHg'),
      SelfWeekItemDto(analyteKey: 'bp_diastolic', count: 5, min: 74, max: 80, unit: 'mmHg'),
      SelfWeekItemDto(analyteKey: 'heart_rate', count: 5, min: 66, max: 74, unit: '/min'),
      SelfWeekItemDto(analyteKey: 'glucose', count: 1, min: 6.3, max: 6.3, unit: 'mmol/L'),
    ];
    expect(selfWeekDesc(items), '血压 5 次 118–132 / 74–80 · 心率 5 次 66–74 · 血糖 1 次 6.3');
  });

  test('selfWeekTitle', () => expect(selfWeekTitle('2026-04-27', '2026-05-03'), '自测 · 4 月 27 日 – 5 月 3 日'));

  test('selfValuesLine:血压合成 122/76', () {
    expect(selfValuesLine([
      SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 122, unit: 'mmHg'),
      SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 76, unit: 'mmHg'),
    ]), '血压 122/76 mmHg');
  });

  test('selfValuesLine:单一指标(非血压)原样带单位', () {
    expect(
      selfValuesLine([SelfMeasuredValueDto(analyteKey: 'glucose', value: 6.3, unit: 'mmol/L')]),
      '血糖 6.3 mmol/L',
    );
  });

  // fix round 1 Minor 3:血压凑成一项之前不许把同一份 values 里其余的值丢掉。
  test('selfValuesLine:血压 + 其余指标同框,血压合成一项后其余原样跟上', () {
    expect(
      selfValuesLine([
        SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 122, unit: 'mmHg'),
        SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 76, unit: 'mmHg'),
        SelfMeasuredValueDto(analyteKey: 'heart_rate', value: 70, unit: '/min'),
      ]),
      '血压 122/76 mmHg · 心率 70 /min',
    );
  });

  DocumentSummaryDto doc(int id, String? docDate) =>
      DocumentSummaryDto(id: id, docType: 'self_measurement', docDate: docDate, pageCount: 1);

  testWidgets('SelfWeekRows:一行一份自测,可点开、左滑删', (tester) async {
    var opened = -1;
    var deleted = -1;
    String? deleteLabel;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
      width: 400,
      child: SelfWeekRows(
        docs: [
          SelfWeekDocDto(doc: doc(1, '2026-04-27'), values: const [
            SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 122, unit: 'mmHg'),
            SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 76, unit: 'mmHg'),
          ]),
          SelfWeekDocDto(doc: doc(2, '2026-04-29'), values: const [
            SelfMeasuredValueDto(analyteKey: 'glucose', value: 6.3, unit: 'mmol/L'),
          ]),
        ],
        onOpen: (id) => opened = id,
        onDelete: (id, label) async {
          deleted = id;
          deleteLabel = label;
        },
      ),
    ))));

    expect(find.text('血压 122/76 mmHg'), findsOneWidget);
    expect(find.text('血糖 6.3 mmol/L'), findsOneWidget);
    expect(find.text('2026-04-27'), findsOneWidget);
    expect(find.text('2026-04-29'), findsOneWidget);

    await tester.tap(find.text('血糖 6.3 mmol/L'));
    expect(opened, 2);

    // 左滑第一行触发删除(与 `_SubDocList` 同一手法:`confirmDismiss` 里调
    // `onDelete`,自己回 false 让数据重载去移除,不与 Dismissible 自身移除冲突)。
    await tester.drag(find.text('血压 122/76 mmHg'), const Offset(-380, 0));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(deleteLabel, '血压 122/76 mmHg');
  });
}
