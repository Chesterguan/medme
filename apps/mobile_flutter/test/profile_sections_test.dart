// `ProfileSectionView`(`widgets/profile_sections.dart`)的看门测试——病程档案
// 渲染引擎按 `kind` 分派到 7 种卡片。这里钉住的都是硬规矩,不是外观细节:
//
//  1. **标题/空态文案一律来自包**,widget 里没有一句写死的病种文案(不然测
//     `2026 年的新病` 这句反证——同一份 widget 代码,换一个包传进来的 JSON,
//     不该出现任何 SLE/SLEDAI 字样);
//  2. **认不出的 kind 整块跳过**,不抛异常——给引擎以后加新 kind 留后路;
//  3. **未知就是未知**,不许塌成「未达标」/「失败」这类更重的结论;
//  4. **待核 / 需核对 / 换算表待核这类旗子必须原样举着**,不许被含糊成一句
//     看不出原因的「算不出来」;
//  5. 7 种 kind 各自吃真实的引擎产出(`packages/profile/testdata/
//     golden_profile_view.json`,合成 SLE 语料跑出来的 golden fixture)都不能
//     崩、在窄屏 + 2× 系统字号下都不能溢出。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';

/// 与 `test/identity_hero_card_test.dart` 同一个 `wrap` 写法:`MedMe.theme()` +
/// 可调 `textScale` 的 `MediaQuery` + 可滚动的 `Scaffold`。
Widget _wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  // section 的标题、顺序、空态文案**全部来自包** —— 这几条测试就是在钉住
  // 「App 里没有任何一句写死的病种文案」这件事。
  testWidgets('titles come from the package, not from the widget', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'score_card', 'title': '活动度(化验可算部分)', 'empty_hint': null,
      'body': {'score': 6, 'max': 18, 'label': '化验可算部分', 'window_days': 10,
               'as_of': '2026-09-16', 'hits': []},
    })));
    expect(find.text('活动度(化验可算部分)'), findsOneWidget);
    expect(find.textContaining('6'), findsWidgets);
    expect(find.textContaining('18'), findsWidgets);
  });

  testWidgets('an unknown section kind renders nothing instead of crashing', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'something_from_2027', 'title': 'x', 'body': {},
    })));
    expect(t.takeException(), isNull);
  });

  testWidgets('an empty section collapses to its package-supplied hint', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'timeline', 'title': '病程时间轴',
      'empty_hint': '还没有可以放上时间轴的记录',
      'body': {'years': []},
    })));
    expect(find.text('还没有可以放上时间轴的记录'), findsOneWidget);
  });

  testWidgets('the score card never renders the words SLEDAI total', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'score_card', 'title': '活动度(化验可算部分)',
      'body': {'score': 6, 'max': 18, 'label': '化验可算部分', 'window_days': 10,
               'as_of': '2026-09-16', 'hits': []},
    })));
    expect(find.textContaining('SLEDAI 总分'), findsNothing);
    expect(find.textContaining('计算 SLEDAI'), findsNothing);
  });

  testWidgets('a checklist renders unknown as unknown, not as a failure', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'checklist', 'title': '达标情况(逐条对照)',
      'body': {'states': [{'id': 'doris', 'label': 'DORIS', 'verdict': 'unknown', 'items': [
        {'id': 'phga', 'label': 'PhGA < 0.5', 'verdict': 'unknown', 'actual': null,
         'note': null, 'source': 'S5'}]}]},
    })));
    expect(find.text('未知'), findsOneWidget);
    expect(find.text('未达标'), findsNothing);
  });

  testWidgets('an unverified point is drawn hollow and labelled 需核对', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'series_chart', 'title': '指标趋势',
      'body': {'groups': [{'name': '补体', 'series': [{
        'analyte_key': 'complement_c3', 'name': '补体C3', 'unit': 'g/L',
        'ref_low': 0.9, 'ref_high': 1.8, 'values_converted': false,
        'needs_review_count': 1, 'dir': 'low_is_active', 'role': 'activity',
        'points': [{'date': '2026-09-01', 'value': 0.4, 'flag': 'L',
                    'unverified': true, 'document_index': 0}]}]}], 'missing': []},
    })));
    expect(find.textContaining('需核对'), findsOneWidget);
  });

  testWidgets('an unconvertible glucocorticoid says 换算表待核, not a vague failure', (t) async {
    // 缺的是**换算表**,不是缺药。含糊成「无法计算」会让人以为是 bug。
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'status_card', 'title': '现行方案',
      'body': {'gc': {'daily_pred_equiv_mg': null, 'drug': null, 'since': null,
                      'targets': [], 'unconvertible': [
                        {'name': '甲泼尼龙', 'dose': '8mg', 'reason': '换算表待核'}]},
               'hcq': null, 'others': [], 'last_visit': null},
    })));
    expect(find.textContaining('甲泼尼龙'), findsOneWidget);
    expect(find.text('换算表待核'), findsOneWidget);
  });

  testWidgets('every reminder shows its basis label', (t) async {
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'reminders', 'title': '待补 / 逾期',
      'body': {'items': [
        {'id': 'mmf_cbc', 'text': '血常规', 'state': 'overdue', 'overdue_days': 12,
         'basis': 'label', 'source': 'L1'},
        {'id': 'mtx_labs', 'text': '血常规 + 肝功', 'state': 'never',
         'basis': 'package_default', 'source': 'PKG'}]},
    })));
    expect(find.text('说明书'), findsOneWidget);
    expect(find.text('包默认'), findsOneWidget);   // 包默认必须看得见,不能冒充指南
  });

  testWidgets('values converted to a canonical unit say so', (t) async {
    // 用户在纸上找不到这个数字,不说就等于改写原文(AnalyteSeries.values_converted 的既有约定)。
    await t.pumpWidget(_wrap(ProfileSectionView({
      'kind': 'series_chart', 'title': '指标趋势',
      'body': {'groups': [{'name': '肾', 'series': [{
        'analyte_key': 'urine_pcr', 'name': '尿蛋白肌酐比值', 'unit': 'mg/g',
        'ref_low': null, 'ref_high': null, 'values_converted': true,
        'needs_review_count': 0, 'dir': 'high_is_active', 'role': 'organ:kidney',
        'points': [{'date': '2026-09-01', 'value': 884.0, 'flag': null,
                    'unverified': false, 'document_index': 0}]}]}], 'missing': []},
    })));
    expect(find.textContaining('已换算'), findsOneWidget);
  });

  // ---------------------------------------------------------------------
  // golden fixture:7 种 kind 各吃一遍真实引擎产出(`packages/profile/testdata/
  // golden_profile_view.json`,Task 20 的合成 SLE 语料),窄屏 + 2× 字号都不能
  // 崩、不能溢出。`analytics_catalog_test.dart` 已经示范过同一种「读仓库里另一
  // 个包的文件」的写法(CWD 是 `apps/mobile_flutter`,相对路径两层上到仓库根)。
  // ---------------------------------------------------------------------
  final goldenFile = File(
    '../../packages/profile/testdata/golden_profile_view.json',
  );
  final golden =
      jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  final goldenSections = (golden['sections'] as List)
      .map((s) => (s as Map).cast<String, dynamic>())
      .toList();

  // golden fixture 本身要有点东西,不然下面的循环悄悄跑 0 次、测试全绿但什么
  // 都没测——golden 目前覆盖 status_card/score_card/reminders/series_chart/
  // timeline/checklist(两块,达标表与里程碑),独缺 handoff(引擎还没有会产出
  // 这个 kind 的构建函数,见 `profile_sections.dart` 里 `_HandoffBody` 的文档)。
  test('golden fixture actually has sections to iterate (sanity)', () {
    expect(goldenSections, isNotEmpty);
    expect(goldenSections.map((s) => s['kind']).toSet(), {
      'status_card', 'score_card', 'reminders', 'series_chart', 'timeline',
      'checklist',
    });
  });

  Future<List<FlutterErrorDetails>> pumpAtSize(
    WidgetTester tester,
    Map<String, dynamic> section, {
    required double textScale,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // `RenderFlex` 溢出走 `FlutterError.reportError`,不是同步抛出的 Dart
    // 异常,`tester.takeException()` 接不住——与
    // `test/lab_line_row_overflow_test.dart::pumpLabRows` 同一处理,包括
    // 「必须在下面的 expect 之前恢复」那条理由。
    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = originalOnError);

    await tester.pumpWidget(
      _wrap(ProfileSectionView(section), textScale: textScale),
    );
    await tester.pump();
    FlutterError.onError = originalOnError;
    return errors;
  }

  for (var i = 0; i < goldenSections.length; i++) {
    final section = goldenSections[i];
    final label = '${section['kind']}${section['id'] != null ? '/${section['id']}' : ''}';

    testWidgets('golden $label renders at 400×800 without exceptions', (
      tester,
    ) async {
      final overflow = await pumpAtSize(tester, section, textScale: 1.0);
      expect(tester.takeException(), isNull, reason: label);
      expect(overflow, isEmpty, reason: label);
    });

    testWidgets('golden $label renders at 2.0 text scale without overflow', (
      tester,
    ) async {
      final overflow = await pumpAtSize(tester, section, textScale: 2.0);
      expect(tester.takeException(), isNull, reason: label);
      expect(overflow, isEmpty, reason: label);
    });
  }
}
