// 动效闸。brief §品牌:「只有折线描画一次(reduced-motion 下关闭);无逐卡淡入」。
//
// 「无逐卡淡入」是这条里最容易被违反的一半 —— 列表进场加淡入是每个人的肌肉记忆,
// 而 MedMe 的列表一屏能有十几张卡,逐卡淡入会让整屏抖一下。所以用扫源码的方式挡,
// 跟 glossary_guard 同一手法:只有扫源码拦得住「有人又写了一个」。
//
// 「折线只描一次」这一半靠 widget 测试挡:默认描一次不循环、reduced-motion 下
// 直接给终态、`animate: false` 同样直接给终态、重建(切面板、换成员)不重播。
// controller ruling R9:reduced-motion 断言必须落在 `_TrendPainter.progress ==
// 1.0`(画完,不是没画)—— 只看 `hasScheduledFrame == false` 分不清这两种情况。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

TrendPointDto _pt(String date, double v) =>
    TrendPointDto(date: date, value: v, documentId: 1, unverified: false);

TrendSeriesDto _series() => TrendSeriesDto(
  name: '肌酐',
  unit: 'umol/L',
  valuesConverted: false,
  anyAbnormal: false,
  points: [_pt('2024-01-01', 1), _pt('2024-02-01', 2), _pt('2024-03-01', 3), _pt('2024-04-01', 4)],
  selfMeasured: false,
);

/// 带参考区间的序列——用来验证 compact 模式跳过参考带(`_series()` 没配
/// refLow/refHigh,非 compact 时本来就不画带,测不出「跳过」这件事)。
TrendSeriesDto _seriesWithBand() => TrendSeriesDto(
  name: '肌酐',
  unit: 'umol/L',
  valuesConverted: false,
  anyAbnormal: false,
  points: [_pt('2024-01-01', 1), _pt('2024-02-01', 2), _pt('2024-03-01', 3), _pt('2024-04-01', 4)],
  selfMeasured: false,
  refLow: 0.5,
  refHigh: 3.5,
);

Widget _host(Widget chart) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 300, child: chart)));

/// `_TrendPainter` 是私有类,测试拼不出它的类名 —— 但它的字段 `progress`/`compact`
/// 不带下划线,借 `dynamic` 动态取值不需要点名类型,和 `glossary_guard` 一样只借
/// 扫描/反射挡行为,不越权改私有边界。
dynamic _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(of: find.byType(TrendChart), matching: find.byType(CustomPaint)),
    )
    .painter;

double _paintedProgress(WidgetTester tester) => _painter(tester).progress as double;

void main() {
  test('屏与 widget 里没有任何进场淡入', () {
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('//')) continue;
          // 上一行若声明了「不是进场淡入」,这一行是状态切换动画,不算数
          // (Task 15 brief Step 4:真正需要的状态过渡不因为这条闸被删掉)。
          if (i > 0 && lines[i - 1].trimLeft().startsWith('// 不是进场淡入:')) {
            continue;
          }
          for (final banned in [
            'AnimatedOpacity',
            'FadeTransition',
            'FadeInImage',
            'AnimatedSlide',
            'SlideTransition',
          ]) {
            if (lines[i].contains(banned)) offenders.add('${f.path}:${i + 1}  $banned');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'brief §品牌:无逐卡淡入。若确有必要,先改 brief:\n${offenders.join('\n')}',
    );
  });

  testWidgets('折线默认描画一次,不循环', (tester) async {
    await tester.pumpWidget(_host(TrendChart(series: _series())));
    await tester.pump(const Duration(milliseconds: 100));
    // 动画跑完后 pumpAndSettle 必须能停下来 —— 停不下来就是循环动画。
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(_paintedProgress(tester), 1.0, reason: '描完之后应停在终态');
  });

  testWidgets('系统开了「减弱动态效果」时,折线直接画完不描', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: SizedBox(width: 300, child: TrendChart(series: _series()))),
        ),
      ),
    );
    // `pumpWidget` 本身会在返回前排一帧(测试框架的记账,与是否有动画无关)——
    // 再空 pump 一次,让这一帧过去,剩下的才是「有没有动画在排队」的真实信号。
    await tester.pump();
    // 第一帧就是终态:没有排队的动画帧。
    expect(tester.binding.hasScheduledFrame, isFalse);
    // R9:光「没有排队的帧」分不清「没画」和「直接画完」—— 必须钉住 progress
    // 本身就是画完的 1.0,不是停在 0(那样就是「关掉了动效但线也没了」)。
    expect(_paintedProgress(tester), 1.0, reason: 'reduced-motion 下线仍须画完,只是不描');
  });

  testWidgets('animate:false 时,不靠系统开关也直接画完', (tester) async {
    await tester.pumpWidget(_host(TrendChart(series: _series(), animate: false)));
    await tester.pump(); // 同上:让 `pumpWidget` 自带的记账帧先过去。
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(_paintedProgress(tester), 1.0);
  });

  testWidgets('描完一次之后,原地换一份新数据重建,不会从头再描', (tester) async {
    await tester.pumpWidget(_host(TrendChart(series: _series())));
    await tester.pumpAndSettle();
    expect(_paintedProgress(tester), 1.0, reason: '首次应已描完');

    // 同一个位置换一份「不同但一样能画」的数据(切面板、换成员的真实场景):
    // 这是同一个 Element/State 收到新 widget 配置,不是新建一个 TrendChart。
    final other = TrendSeriesDto(
      name: '肌酐',
      unit: 'umol/L',
      valuesConverted: false,
      anyAbnormal: false,
      points: [_pt('2024-05-01', 9), _pt('2024-06-01', 8), _pt('2024-07-01', 7)],
      selfMeasured: false,
    );
    await tester.pumpWidget(_host(TrendChart(series: other)));
    // 这一次 pump() 只为清掉 `pumpWidget` 自带的记账帧(见上面两个 reduced-motion/
    // animate:false 用例的注释)—— 如果动画真的重播了,清完之后仍会有一帧排着队。
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse, reason: '重建不该重新排队动画帧');
    expect(_paintedProgress(tester), 1.0, reason: '换数据不reset「已经描过一次」的状态');
  });

  testWidgets('reduced-motion 开了又关,不会把已经描完的线重播一次', (tester) async {
    // 这是 `_played` 真正要挡住的场景 —— 换 `series`(上一个用例)只触发
    // `didUpdateWidget`,根本碰不到 `_played` 那条分支;而 `disableAnimations`
    // 是 `MediaQuery` 的一个 aspect,它的值改变会让 `didChangeDependencies`
    // 真的重新跑一次。没有 `_played` 卫兵的话,这里会在「关」的那一帧重新
    // forward(),把已经描完的线拉回去重描一遍。
    Widget host(bool disableAnimations) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(body: SizedBox(width: 300, child: TrendChart(series: _series()))),
      ),
    );

    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    expect(_paintedProgress(tester), 1.0, reason: '首次应已描完');

    await tester.pumpWidget(host(true)); // 开:直接给终态(别的用例已经单独断言过)。
    await tester.pump();
    expect(_paintedProgress(tester), 1.0);

    await tester.pumpWidget(host(false)); // 关:_played 应该挡住重新 forward()。
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse, reason: '不该重新排队动画帧');
    expect(_paintedProgress(tester), 1.0, reason: '已经描过一次,不重播');
  });

  testWidgets('compact 模式:24 高、78 宽也画得出来,不抛异常,animate:false 直接画完', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 78,
            height: 24,
            child: TrendChart(series: _series(), height: 24, compact: true, animate: false),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_paintedProgress(tester), 1.0);
  });

  testWidgets('compact 模式不画参考带', (tester) async {
    // 参考带用单独的 `canvas.drawRect` 调用画(见 `_TrendPainter.paint`)——选
    // `paints` matcher 直接断言画布调用本身,比只读 `painter.compact` 字段更
    // 能挡住「compact 传对了、但 paint() 里的分支写漏」这类回归。
    final chart = find.descendant(of: find.byType(TrendChart), matching: find.byType(CustomPaint)).first;

    // 先证明前提:这份数据配了参考区间,非 compact 时确实画带——不然下面
    // 「compact 跳过」的断言测不出东西(`_series()` 没配参考区间,那样不管
    // compact 与否本来就不画带)。
    await tester.pumpWidget(_host(TrendChart(series: _seriesWithBand(), animate: false)));
    await tester.pump();
    expect(chart, paints..rect());

    await tester.pumpWidget(
      _host(TrendChart(series: _seriesWithBand(), animate: false, compact: true)),
    );
    await tester.pump();
    expect(chart, isNot(paints..rect()));
  });
}
