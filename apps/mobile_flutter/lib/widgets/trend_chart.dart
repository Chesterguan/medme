import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';

/// 趋势折线图 —— `CustomPainter` 手写,**不引图表库**。
///
/// 视觉规格复用 hosted-viewer 的 `sparkSVG`(`web/hosted-viewer/index.html`,只读
/// 参考):参考带、点 r=2.2 / 末点 r=3.4 带白圈、**折线用直线段**。三端画出来的同
/// 一条序列必须是同一个形状(规范 §七)。
///
/// ## 三条不能破的规矩
///
/// **一、折线不平滑。** 贝塞尔/单调三次样条会在两次测量之间画出一条根本没测过的
/// 曲线 —— 那是在凭空造值。相邻两点之间到底发生了什么,我们不知道;直线段至少
/// 是「我只知道这两个端点」的诚实表达。临床上这不是审美偏好。
///
/// **二、[trendSeriesIsRenderable] 这一关 UI 自己再把一遍。** Rust 侧
/// (`parser::handoff::is_renderable`,handoff.rs:369)已经把「全部点都无日期」的
/// 序列挡在投影之外了,这里仍然独立判一次。查看器在同一处留了话:
/// *keeps the renderer honest on its own terms rather than trusting the payload.*
/// 画不出来的东西不该由数据源来保证画不出来 —— 渲染器得自己知道自己画不了什么。
///
/// **三、点的颜色只读 `flag`。** `TrendPointDto` 同时带着 `refLow`/`refHigh`,
/// 拿来重算异常唾手可得,查看器的 `sumFlag(value, refLow, refHigh)` 就是这么做的。
/// **不要抄。** 007 §2.5:所有「怎么算」在 Rust。见 `widgets/lab_status.dart`。
///
/// ## X 轴用真实时间,不是点的序号
///
/// 2016、2017、2024 三个点若按序号等距排布,图上会显示成匀速变化 —— 而真实情况是
/// 七年里前两年测了两次、之后七年没测。按天数定位才不撒谎,代价是密集期的点会挤在
/// 一起。那个挤是真的。

/// UI 侧的 `is_renderable`,与 `handoff.rs:369` 同一条判据:**至少有一个点带日期**。
///
/// 一条点全无日期的序列画出来是**一片空白**,而它上方还顶着一个项目名和一个可能的
/// 「偏高」—— 等于告诉用户「这里有条趋势」然后给他看空气。观测本身没有丢:它还在
/// 那份记录的原文里,从档案点得进去。丢掉的只是「这里有一条趋势」这个断言。
bool trendSeriesIsRenderable(TrendSeriesDto s) =>
    s.points.any((p) => p.date != null);

/// 序列里**画得出来**的点:带日期的,按日期升序。
///
/// 无日期的点(`date == null`)在这里被跳过 —— 它落不到时间轴上的任何位置。但它
/// 仍带 `documentId`,原件照样可达(007 §2.1「原件永远可达」),那条路在档案里。
///
/// DTO 承诺点已按时间升序(无日期的排最后),这里仍然自己排一次:排序是画线的
/// 前提,一个顺序错乱的输入会画出一条来回折返的假线,而那种错在图上很难看出来。
List<TrendPointDto> trendDatedPoints(TrendSeriesDto s) {
  final out = s.points.where((p) => p.date != null).toList()
    ..sort((a, b) => a.date!.compareTo(b.date!));
  return out;
}

/// 日期串 → 天数(用于 X 轴定位)。解析不出来的当作没有日期。
double? _dayOf(String? iso) {
  if (iso == null) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return null;
  return d.millisecondsSinceEpoch / Duration.millisecondsPerDay;
}

/// Y 轴值域:`(lo, hi)`,已含上下各 20% 余量。数据点**和**参考区间的两个界值都必须
/// 装得进去。
///
/// 每个界值都要**双向**撑开值域,不能只往一个方向撑。sparkSVG(`index.html:765`)写的是
/// `lo = min(...vs, refLow)` / `hi = max(...vs, refHigh)` —— 各自只往外推一侧。于是遇到
/// eGFR「参考 ≥ 90」而实测 63/71/78 时,90 落在 `hi` 之上、画布之外:参考带塌成零高度,
/// 那条虚线被画在**图的顶边**。用户看到「参考区间 ≥ 90」加一条虚线,只会认为虚线就是
/// 90、自己刚好差一点 —— 而真实情况是差得远。位置错了的基准线比没有基准线更糟,因为
/// 它看起来像个结论。查看器有同一处缺陷,已单独记录。
(double, double) trendYDomain(
  Iterable<double> values, {
  double? refLow,
  double? refHigh,
}) {
  var lo = values.reduce(math.min);
  var hi = values.reduce(math.max);
  for (final b in [refLow, refHigh]) {
    if (b == null) continue;
    lo = math.min(lo, b);
    hi = math.max(hi, b);
  }
  // 全部点等值且没有参考区间时跨度为 0 —— 退回 1,免得除零把点画到无穷远。
  final pad = (hi - lo) * 0.2 == 0 ? 1.0 : (hi - lo) * 0.2;
  return (lo - pad, hi + pad);
}

/// 一条序列的折线图。高度固定,宽度随卡片。
///
/// 高度不随 `textScaler` 变,是因为**画布里一个字都没有** —— 项目名、数值、参考
/// 区间、日期全部是图外的 Flutter `Text`,照常响应系统字号放大(007 §2.5)。
/// 这也是与 `sparkSVG` 唯一一处刻意的偏离:它把末点数值用 10px 画在画布里,而
/// 10px 低于字阶下限 12,并且画布里的字不会跟着系统字号放大。那个数值改由卡头
/// 的 22px 承担,比原来更大也更好读。
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.series, this.height = 96});

  final TrendSeriesDto series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final pts = trendDatedPoints(series);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TrendPainter(
          points: pts,
          selfMeasured: series.selfMeasured,
          refLow: series.refLow,
          refHigh: series.refHigh,
          band: c.sealWash,
          bandEdge: c.ink3,
          line: c.seal,
          dot: c.seal,
          dotHigh: c.high,
          dotLow: c.low,
          ring: c.surface,
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({
    required this.points,
    required this.selfMeasured,
    required this.refLow,
    required this.refHigh,
    required this.band,
    required this.bandEdge,
    required this.line,
    required this.dot,
    required this.dotHigh,
    required this.dotLow,
    required this.ring,
  });

  final List<TrendPointDto> points;
  /// 整条序列是不是自测值(`TrendSeriesDto.selfMeasured`,组内同质,见其文档)。
  /// 只改点的**形状**(实心/空心圈),颜色逻辑不变 —— 颜色永远只读 `flag`。
  final bool selfMeasured;
  final double? refLow;
  final double? refHigh;
  final Color band;
  final Color bandEdge;
  final Color line;
  final Color dot;
  final Color dotHigh;
  final Color dotLow;
  final Color ring;

  // 内边距沿用 sparkSVG 的取法,右侧收窄:它留 32 是给画在图内的末点数值文字,
  // 而那个数值这里搬到卡头去了,只需给 r=3.4 的末点 + 白圈留出余地。
  static const double _padL = 4;
  static const double _padR = 8;
  static const double _padT = 6;
  static const double _padB = 6;

  /// 点半径,逐字对齐 sparkSVG。末点更大 + 白圈 = 「这是最新的一次」。
  static const double _r = 2.2;
  static const double _rLast = 3.4;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final plotW = size.width - _padL - _padR;
    final plotH = size.height - _padT - _padB;
    if (plotW <= 0 || plotH <= 0) return;

    // ── Y 值域:数据与参考区间都要装得下,再上下各留 20% 余量(同 sparkSVG)──
    final (lo, hi) = trendYDomain(
      points.map((p) => p.value),
      refLow: refLow,
      refHigh: refHigh,
    );
    final yr = hi - lo;
    double y(double v) => _padT + plotH - (v - lo) / yr * plotH;

    // ── X 位置:按**真实天数**,不是点的序号 ──
    final days = points.map((p) => _dayOf(p.date)).whereType<double>().toList();
    // trendDatedPoints 已保证每个点都有 date;仍解析不出来的(格式怪)不画。
    if (days.length != points.length) return;
    final x0 = days.reduce(math.min);
    final xSpan = days.reduce(math.max) - x0;
    // 所有点同一天(或只有一个点)→ 没有横向跨度可言,居中排布,不假装有时间轴。
    double x(int i) => xSpan == 0
        ? _padL + plotW / 2
        : _padL + (days[i] - x0) / xSpan * plotW;

    // ── 参考带 ──
    // **不画网格线。** 查看器的 `sparkSVG`(index.html:760-781)一条也不画,规范 §七
    // 要求三端画出来的同一条序列是同一个形状。而且不带刻度值的横线不承诺任何数值,
    // 却长得像刻度 —— 装饰而已。图里唯一有数值语义的横向元素就是这条参考带。
    //
    // 区间颠倒(refLow > refHigh)时整个带不画。OCR 在偏斜的并排双表上会把相邻记录
    // 的区间错配过来,产出 refLow=50 / refHigh=10 这种无意义区间(见 openmed 的
    // A/B 实测)。画一条位置无意义的边,比什么都不画更容易被当成结论。
    final bandOk = refLow == null || refHigh == null || refLow! <= refHigh!;
    if ((refLow != null || refHigh != null) && bandOk) {
      final top = y(refHigh ?? hi);
      final bottom = y(refLow ?? lo);
      final rect = Rect.fromLTRB(
        _padL,
        top,
        size.width - _padR,
        math.max(top, bottom),
      );
      canvas.drawRect(rect, Paint()..color = band);
      // 上下缘各一条虚线。用 `ink3` 而不是 `line`:`line`(#E3E9EE)压在
      // `seal-wash`(#EAF5FA)上几乎看不见,画了等于没画。这条线是非文本 UI 元素
      // (3:1 门槛),`ink3` 既看得清又明显不是「数据色」,不会和折线抢读。
      final edge = Paint()
        ..color = bandEdge
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      _dashedLine(canvas, Offset(rect.left, rect.top), rect.right, edge);
      if (rect.bottom > rect.top) {
        _dashedLine(canvas, Offset(rect.left, rect.bottom), rect.right, edge);
      }
    }

    // ── 折线:**直线段,不平滑** ──
    if (points.length >= 2) {
      final path = Path()..moveTo(x(0), y(points[0].value));
      for (var i = 1; i < points.length; i++) {
        path.lineTo(x(i), y(points[i].value));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── 点 ──
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final last = i == points.length - 1;
      // 颜色只看 Rust 给的 flag。**不从 refLow/refHigh 反推**(见文件头第三条)。
      final color = switch (p.flag?.trim().toUpperCase()) {
        'H' || '↑' => dotHigh,
        'L' || '↓' => dotLow,
        // 认不出的标记不上色 —— 我们不知道它是高是低,涂个颜色就是替化验单下
        // 一个我们没读懂的结论(与 `lab_status.dart` 同一条口径)。
        _ => dot,
      };
      final at = Offset(x(i), y(p.value));
      final r = last ? _rLast : _r;
      if (last) {
        // 末点先铺一圈底色再画实心 —— 与 sparkSVG 的 `stroke="#fff"` 同效果,
        // 让它从折线和参考带上「浮」出来。
        canvas.drawCircle(at, _rLast + 1.5, Paint()..color = ring);
      }
      if (selfMeasured) {
        // 自测值:空心圈(底色先垫一层背景色,再描边)——与医院值的实心圈一眼
        // 可辨,同一条规矩不靠颜色讲(颜色永远只读 flag,见文件头第三条)。
        canvas.drawCircle(at, r, Paint()..color = ring);
        canvas.drawCircle(
          at,
          r,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      } else {
        canvas.drawCircle(at, r, Paint()..color = color);
      }
    }
  }

  /// 一条水平虚线(6 实 / 4 虚,与 `med_card.dart` 的空态虚线框同一节奏)。
  void _dashedLine(Canvas canvas, Offset from, double toX, Paint paint) {
    const dash = 6.0, gap = 4.0;
    var x = from.dx;
    while (x < toX) {
      final end = math.min(x + dash, toX);
      canvas.drawLine(Offset(x, from.dy), Offset(end, from.dy), paint);
      x = end + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.points != points ||
      old.selfMeasured != selfMeasured ||
      old.refLow != refLow ||
      old.refHigh != refHigh ||
      old.line != line;
}
