// 「看病带这个」(`screens/visit_summary_sheet.dart`,2026-08-05 改版,原名
// 「就诊单」)的多视口回归测试 + 三条新规则的钉子测试。
//
// 不能直接 `pumpWidget` `showVisitSummarySheet`/`_VisitSummarySheet`——那条路径
// 在字段初始化那一刻就调 `viewVisitSummary()`(FFI),`flutter test` 不带 Rust
// 原生库会直接崩(与 `manual_entry_sheet_test.dart` 顶部注释同一条限制)。这里测
// 的是拆出来的公开 widget `VisitSummaryBody`——它只吃一份手造的 [VisitSummaryDto],
// 不碰 FFI,正好是这次改版真正要验的"数据怎么显示"那一半。
//
// 华为 Mate 9(逻辑分辨率约 360×640)这类矮屏 + 长名字组合是本项目反复踩过的坑
// (`first_run_consent_test.dart`、`overview_screen.dart` 的 `Wrap` 注释都提过),
// 所以这里额外压了 360×800 与一个宽视口,每种都叠 2× 字号。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/visit_summary_sheet.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';

void useViewport(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// `VisitSummaryBody` 用 `ListView(children: ...)`,底层是
/// `SliverChildListDelegate`——只有落在视口 + 缓存区内的子节点才会被挂载
/// (没挂载的 widget `find` 不到)。「医生可能要问的」排在最后一节,矮屏 + 2×
/// 字号下经常还没被滚到,常规的 `tester.ensureVisible()` 对还没挂载的 widget
/// 无能为力(它得先在树里找到目标,才知道要滚多远)——一次 `jumpTo(maxScrollExtent)`
/// 也不够:懒加载的 sliver 在后面的子节点还没挂载时,`maxScrollExtent` 只是按
/// 已挂载的子节点估出来的,可能比真实值小,一次跳跃跳不到位。`scrollUntilVisible`
/// 就是为这个场景写的:一点点滚、每滚一点就重新查找,直到目标出现。
///
/// `scrollUntilVisible` 满足的是"挂载了"(在树里能找到),不是"整块都在可视
/// 区内"——懒加载的 sliver 缓存区(默认约 250 逻辑像素)会先把目标挂载在视口
/// 下边缘之外一点点的地方,这时候直接 `tap()` 会因为算出来的点击坐标落在屏幕
/// 外而打不中。挂载之后再补一次 `ensureVisible`(这时候它已经在树里,
/// `ensureVisible` 才有能力把它往回拉),两步缺一不可。
Future<void> scrollToMedsToggle(WidgetTester tester) async {
  final finder = find.text('记录中出现的药物');
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// 一份"内容丰富"的摘要单——每一节都至少有一条,且专挑长名字/长文本,用来压
/// 多视口溢出。数值与日期不追求临床意义,只追求"字够长、够真实"。
VisitSummaryDto richSummary() => VisitSummaryDto(
  patient: const PatientProfileDto(
    name: '张建国',
    gender: '男',
    age: '58',
    recordCount: 12,
  ),
  allergies: [
    AllergyItemDto(
      substance: '复方磺胺甲噁唑(SMZ-TMP,俗称新诺明)',
      reaction: '全身皮疹伴瘙痒,曾一度呼吸困难需急诊处理',
      documentIds: Int64List.fromList([100]),
    ),
  ],
  activeMeds: [
    ActiveMedDto(
      name: '硝苯地平控释片(拜新同/欣然,长效钙通道阻滞剂)',
      dose: '30mg qd,早餐后半小时整片吞服不可掰开',
      since: '2023-05-10',
      until: '2026-06-20',
      documentIds: Int64List.fromList([100, 101, 102]),
    ),
    ActiveMedDto(
      name: '二甲双胍',
      dose: '0.5g bid',
      since: '2024-01-01',
      until: '2026-06-20',
      documentIds: Int64List(0),
    ),
  ],
  recentLabs: const [],
  recentChanges: [
    const VisitLabDto(
      name: '收缩压',
      date: '2026-08-01',
      value: 128,
      unit: 'mmHg',
      valuesConverted: false,
      documentId: 200,
      selfMeasured: true,
    ),
    const VisitLabDto(
      name: '糖化血红蛋白',
      date: '2026-06-20',
      value: 7.9,
      unit: '%',
      valuesConverted: false,
      flag: 'H',
      refLow: 4.0,
      refHigh: 6.5,
      documentId: 201,
      selfMeasured: false,
    ),
  ],
  recentVisits: const [],
  recentNotes: [
    VisitNoteDto(
      text:
          '这周开始有点头晕,尤其是早上起床的时候,不知道是不是降压药量太大了,'
          '想问问王医生要不要调整一下剂量,另外上次拍的胸片报告还没跟我说结果',
      date: '2026-08-01',
      documentId: 300,
    ),
    const VisitNoteDto(text: '问问能不能用医保', date: '2026-07-20', documentId: 301),
  ],
  plainText: '【基本信息】\n姓名:张建国\n',
);

VisitSummaryDto emptySummary() => const VisitSummaryDto(
  patient: PatientProfileDto(recordCount: 0),
  allergies: [],
  activeMeds: [],
  recentLabs: [],
  recentChanges: [],
  recentVisits: [],
  recentNotes: [],
  plainText: '',
);

Widget wrap(VisitSummaryDto summary, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: VisitSummaryBody(
        summary: summary,
        onOpenDoc: (_) {},
        onAddNote: () {},
      ),
    ),
  ),
);

void main() {
  group('多视口不溢出', () {
    const viewports = {
      '360×640(华为 Mate 9)': (360.0, 640.0),
      '360×800': (360.0, 800.0),
      '宽视口(414×896)': (414.0, 896.0),
    };

    for (final entry in viewports.entries) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${entry.key} @$scale× · 内容丰富', (tester) async {
          useViewport(tester, entry.value.$1, entry.value.$2);
          await tester.pumpWidget(wrap(richSummary(), textScale: scale));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });

        testWidgets('${entry.key} @$scale× · 全部空态', (tester) async {
          useViewport(tester, entry.value.$1, entry.value.$2);
          await tester.pumpWidget(wrap(emptySummary(), textScale: scale));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });

        testWidgets('${entry.key} @$scale× · 用药展开后不溢出', (tester) async {
          useViewport(tester, entry.value.$1, entry.value.$2);
          await tester.pumpWidget(wrap(richSummary(), textScale: scale));
          await tester.pumpAndSettle();
          await scrollToMedsToggle(tester);
          await tester.tap(find.text('记录中出现的药物'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('段落顺序与标题', () {
    testWidgets('标题是「看病带这个」,不是「就诊单」', (tester) async {
      useViewport(tester, 390, 844);
      await tester.pumpWidget(wrap(richSummary()));
      expect(find.text('看病带这个'), findsOneWidget);
      expect(find.text('就诊单'), findsNothing);
    });

    testWidgets('四节按「我想问医生的→我最近的变化→医生可能要问的」出现,且顺序如此', (tester) async {
      useViewport(tester, 390, 844);
      await tester.pumpWidget(wrap(richSummary()));

      final order = [
        tester.getTopLeft(find.text('我想问医生的')).dy,
        tester.getTopLeft(find.text('我最近的变化')).dy,
        tester.getTopLeft(find.text('医生可能要问的')).dy,
      ];
      expect(
        order,
        [order[0], order[1], order[2]]..sort(),
        reason: '三节必须自上而下按这个顺序出现,不能是别的排法',
      );
    });

    testWidgets('过敏史默认展开(能看到过敏物质),用药默认折叠(看不到药名)', (tester) async {
      useViewport(tester, 390, 844);
      await tester.pumpWidget(wrap(richSummary()));

      expect(find.textContaining('复方磺胺甲噁唑'), findsOneWidget, reason: '过敏史不该折叠');
      expect(
        find.textContaining('硝苯地平'),
        findsNothing,
        reason: '用药默认折叠,药名不该一开始就看得见',
      );

      await scrollToMedsToggle(tester);
      await tester.tap(find.text('记录中出现的药物'));
      await tester.pumpAndSettle();
      expect(find.textContaining('硝苯地平'), findsOneWidget, reason: '点开之后应该看得见');
    });
  });

  group('三条新规则', () {
    testWidgets('自测数值带「· 家测」标记,医院化验不带', (tester) async {
      useViewport(tester, 390, 844);
      await tester.pumpWidget(wrap(richSummary()));

      expect(
        find.textContaining('· 家测'),
        findsOneWidget,
        reason: '自测收缩压应该带这个标记',
      );
      // 糖化血红蛋白(医院值)日期旁不该出现"家测"字样。
      expect(find.text('2026-06-20 · 家测'), findsNothing);
    });

    testWidgets('同名药合并后显示最新那条记录的用量与日期,不是出现次数', (tester) async {
      useViewport(tester, 390, 844);
      await tester.pumpWidget(wrap(richSummary()));

      await scrollToMedsToggle(tester);
      await tester.tap(find.text('记录中出现的药物'));
      await tester.pumpAndSettle();

      // `recordedMedTiming` 拼出的是"剂量 · 最后一次出现 日期",这里断言这条
      // 拼接结果整行出现——如果哪天有人把它改成"共出现 N 次"这类计数,这条会先炸。
      expect(
        find.text('30mg qd,早餐后半小时整片吞服不可掰开 · 最后一次出现 2026-06-20'),
        findsOneWidget,
      );
      expect(find.textContaining('共出现'), findsNothing, reason: '不该按出现次数计数');
      expect(
        find.textContaining('共'),
        findsNothing,
        reason: '不该有"共 N 条/次"这类计数文案',
      );
    });

    testWidgets('笔记原文逐字显示在「我想问医生的」里,且不出现在别处标题旁', (tester) async {
      useViewport(tester, 390, 844);
      await tester.pumpWidget(wrap(richSummary()));

      expect(find.textContaining('问问能不能用医保'), findsOneWidget);
      expect(find.textContaining('王医生'), findsOneWidget);
    });

    testWidgets('「我想问医生的」空态给出「加一条」的出路,且点击调用回调', (tester) async {
      useViewport(tester, 390, 844);
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: Scaffold(
            body: VisitSummaryBody(
              summary: emptySummary(),
              onOpenDoc: (_) {},
              onAddNote: () => tapped = true,
            ),
          ),
        ),
      );

      // 精确匹配「加一条」这颗按钮本身——空态说明文字里也提到了这三个字
      // (「想到什么随时点右上角「加一条」」),用 textContaining 会连它一起数进去。
      expect(find.text('加一条'), findsOneWidget);
      await tester.tap(find.text('加一条'));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  // ── BUG-4 ──────────────────────────────────────────────────────────────────
  //
  // 这一组测的是浮层**本体**(`VisitSummarySheet`,上面几组测的是它里面那层无状态的
  // `VisitSummaryBody`),盯的是它自己的文档承诺的那件事:「存完刷新这一屏的数据,
  // 不需要用户自己关掉浮层再重开」。
  //
  // 它曾经写的是 `setState(() => _future = viewVisitSummary())` —— **箭头体**。
  // `State.setState` 先执行回调(赋值已经发生),再在断言里发现回调返回了一个
  // `Future` 并抛出,而那一抛发生在 `markNeedsBuild()` **之前**:`_future` 换成了
  // 新的,却没有任何一次重建被调度。用户看着自己刚写的笔记没出现,自然会再写一遍。
  // 这一处还更狠 —— 它在一个 `async` 方法里、由 `VoidCallback` 调起,异常直接逃成
  // **未捕获的 zone 错误**,连控制台上都只是一条与现象对不上的噪音。
  //
  // release 里断言被剥掉 → 正常;**debug/profile 必现**,而 `flutter test` 与 debug
  // 同侧(断言开着),所以这条测试正好站在能看见它的那一边。
  //
  // 数据源与「加一条」都要走 FFI,所以两处都注入假的(见文件顶部同一条限制)。
  group('存完笔记要当场刷新', () {
    testWidgets('「加一条」存完之后,浮层重新拉一次数据并把新笔记显示出来', (tester) async {
      useViewport(tester, 390, 844);

      var summary = emptySummary();
      var loads = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: Scaffold(
            body: VisitSummarySheet(
              load: () async {
                loads++;
                return summary;
              },
              // 录入弹层的替身:用户写完一句、点了保存。
              onRequestAddNote: (_) async {
                summary = summaryWithNote('降压药是不是要减量');
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(loads, 1);
      expect(find.textContaining('降压药是不是要减量'), findsNothing);

      await tester.tap(find.text('加一条'));
      await tester.pumpAndSettle();

      expect(loads, 2, reason: '存完必须重新拉一次');
      expect(
        find.textContaining('降压药是不是要减量'),
        findsOneWidget,
        reason: 'BUG-4:重建没被调度,用户看着自己刚写的东西没出现,只能关掉浮层再重开',
      );
    });

    testWidgets('用户中途放弃(没存)就不该白拉一次', (tester) async {
      useViewport(tester, 390, 844);
      var loads = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: Scaffold(
            body: VisitSummarySheet(
              load: () async {
                loads++;
                return emptySummary();
              },
              onRequestAddNote: (_) async => null, // 划掉弹层,什么也没存
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('加一条'));
      await tester.pumpAndSettle();
      expect(loads, 1);
    });

    testWidgets('刷新路径上没有任何未捕获的异常', (tester) async {
      // 箭头体那版在这里抛的是**未捕获的 zone 错误**(`async` 方法里、由
      // `VoidCallback` 调起),`flutter_test` 会把它记成用例的 pending exception。
      useViewport(tester, 390, 844);

      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: Scaffold(
            body: VisitSummarySheet(
              load: () async => emptySummary(),
              onRequestAddNote: (_) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加一条'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}

/// 只有一条笔记的摘要 —— 用来看「存完之后这一屏有没有变」。
VisitSummaryDto summaryWithNote(String text) => VisitSummaryDto(
  patient: const PatientProfileDto(recordCount: 1),
  allergies: const [],
  activeMeds: const [],
  recentLabs: const [],
  recentChanges: const [],
  recentVisits: const [],
  recentNotes: [VisitNoteDto(text: text, date: '2026-08-05', documentId: 1)],
  plainText: '',
);
