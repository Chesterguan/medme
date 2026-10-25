// 化验折线(修订 2 返工):带 y 轴刻度、x 轴时间刻度、参考范围灰带;点多时按周取中位数降采样、
// 只画线不画点,最后一次结果用一个点标出(异常橙 / 偏低蓝 / 正常品牌色)。`compact` = 列表里的
// 迷你版(无轴、无文字)。父会话 2026-10-25 在真实数据上的反馈:225 个点里两根尖峰把两年压成
// 一条平线、迷你图是一团点云。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart' show trendDatedPoints;

/// 超过这么多点就降采样 + 只画线。
const int kChartMaxRawPoints = 60;

/// 单位里来自原件的占位(`(CALC)`、`(CALC`、`Detected)`)不显示。
String? cleanUnit(String? unit) {
  if (unit == null) return null;
  final u = unit.trim();
  if (u.isEmpty || u == '1') return null;
  final upper = u.toUpperCase();
  if (upper.contains('CALC')) return null;
  if (u.startsWith('(') && !u.contains(')')) return null;
  if (u.startsWith('(') && u.endsWith(')')) return null;
  if (u.endsWith(')') && !u.contains('(')) return null;
  return u;
}

/// 时间范围:3 个月 / 半年 / 1 年 / 全部。化验 tab 顶部一组 chip 定全局的,折线页自己也能切。
enum ChartRange { threeMonths, halfYear, oneYear, all }

const Map<ChartRange, String> kChartRangeLabel = {
  ChartRange.threeMonths: '3 个月',
  ChartRange.halfYear: '半年',
  ChartRange.oneYear: '1 年',
  ChartRange.all: '全部',
};

/// 范围的天数;「全部」为 null。
int? chartRangeDays(ChartRange r) => switch (r) {
  ChartRange.threeMonths => 91,
  ChartRange.halfYear => 182,
  ChartRange.oneYear => 365,
  ChartRange.all => null,
};

/// 范围的起点:`anchor`(列表页传「今天」)或最近一个点(折线页)往前数。
List<TrendPointDto> pointsInRange(List<TrendPointDto> dated, ChartRange range, {DateTime? anchor}) {
  if (dated.isEmpty || range == ChartRange.all) return dated;
  final end = anchor ?? DateTime.tryParse(dated.last.date!);
  if (end == null) return dated;
  final cutoff = switch (range) {
    ChartRange.threeMonths => DateTime(end.year, end.month - 3, end.day),
    ChartRange.halfYear => DateTime(end.year, end.month - 6, end.day),
    ChartRange.oneYear => DateTime(end.year - 1, end.month, end.day),
    ChartRange.all => DateTime(1900),
  };
  return [for (final p in dated) if (!DateTime.parse(p.date!).isBefore(cutoff)) p];
}

/// 按周取中位数:同一周(ISO 周一起算)的点合成一个点,日期取该周中间那天;flag 取该周里
/// 出现过的最严重的(H/L 优先于正常),好让最后一次仍能标异常。
List<TrendPointDto> downsampleWeeklyMedian(List<TrendPointDto> dated) {
  if (dated.length <= kChartMaxRawPoints) return dated;
  final buckets = <int, List<TrendPointDto>>{};
  for (final p in dated) {
    final d = DateTime.parse(p.date!);
    final monday = d.subtract(Duration(days: d.weekday - 1));
    final key = DateTime(monday.year, monday.month, monday.day).millisecondsSinceEpoch;
    buckets.putIfAbsent(key, () => []).add(p);
  }
  final keys = buckets.keys.toList()..sort();
  return [
    for (final k in keys)
      () {
        final b = buckets[k]!;
        final vals = b.map((p) => p.value).toList()..sort();
        final median = vals.length.isOdd
            ? vals[vals.length ~/ 2]
            : (vals[vals.length ~/ 2 - 1] + vals[vals.length ~/ 2]) / 2;
        final flag = b.any((p) => p.flag == 'H' || p.flag == 'HH')
            ? 'H'
            : b.any((p) => p.flag == 'L' || p.flag == 'LL')
                ? 'L'
                : null;
        final mid = DateTime.fromMillisecondsSinceEpoch(k).add(const Duration(days: 3));
        return TrendPointDto(
          date: '${mid.year.toString().padLeft(4, '0')}-${mid.month.toString().padLeft(2, '0')}-${mid.day.toString().padLeft(2, '0')}',
          value: median,
          unit: b.last.unit,
          flag: flag,
          documentId: b.last.documentId,
          unverified: b.any((p) => p.unverified),
        );
      }(),
  ];
}

/// 「好看的」刻度步长:1 / 2 / 5 × 10^k。
double niceStep(double span, int targetTicks) {
  if (span <= 0) return 1;
  final raw = span / targetTicks;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final r = raw / mag;
  final nice = r < 1.5 ? 1 : r < 3.5 ? 2 : r < 7.5 ? 5 : 10;
  return nice * mag;
}

String fmtTick(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e6) return v.toInt().toString();
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

class LabLineChart extends StatelessWidget {
  const LabLineChart({
    super.key,
    required this.series,
    this.points,
    this.height = 180,
    this.compact = false,
  });

  final TrendSeriesDto series;

  /// 已经选好范围的点(有日期);null → 全部有日期的点。调用方自己决定是否降采样之前的范围。
  final List<TrendPointDto>? points;
  final double height;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final raw = points ?? trendDatedPoints(series);
    final drawn = downsampleWeeklyMedian(raw);
    final lastRaw = raw.isEmpty ? null : raw.last;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _LabLinePainter(
          points: drawn,
          last: lastRaw,
          drawDots: raw.length <= kChartMaxRawPoints && !compact,
          refLow: series.refLow,
          refHigh: series.refHigh,
          compact: compact,
          band: c.line2,
          axis: c.line,
          label: c.ink3,
          line: c.seal,
          dot: c.seal,
          dotHigh: c.high,
          dotLow: c.low,
          labelStyle: MedType.caption.copyWith(color: c.ink3, fontSize: 10),
        ),
      ),
    );
  }
}

class _LabLinePainter extends CustomPainter {
  const _LabLinePainter({
    required this.points,
    required this.last,
    required this.drawDots,
    required this.refLow,
    required this.refHigh,
    required this.compact,
    required this.band,
    required this.axis,
    required this.label,
    required this.line,
    required this.dot,
    required this.dotHigh,
    required this.dotLow,
    required this.labelStyle,
  });

  final List<TrendPointDto> points;
  final TrendPointDto? last;
  final bool drawDots;
  final double? refLow;
  final double? refHigh;
  final bool compact;
  final Color band;
  final Color axis;
  final Color label;
  final Color line;
  final Color dot;
  final Color dotHigh;
  final Color dotLow;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final padL = compact ? 2.0 : 34.0;
    final padR = compact ? 4.0 : 8.0;
    final padT = compact ? 3.0 : 8.0;
    final padB = compact ? 3.0 : 18.0;
    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 0 || plotH <= 0) return;

    var lo = points.map((p) => p.value).reduce(math.min);
    var hi = points.map((p) => p.value).reduce(math.max);
    if (last != null) {
      lo = math.min(lo, last!.value);
      hi = math.max(hi, last!.value);
    }
    if (refLow != null) lo = math.min(lo, refLow!);
    if (refHigh != null) hi = math.max(hi, refHigh!);
    if (hi == lo) {
      hi = lo + (lo == 0 ? 1 : lo.abs() * 0.1);
      lo = lo - (lo == 0 ? 1 : lo.abs() * 0.1);
    }
    final step = niceStep(hi - lo, compact ? 2 : 4);
    final yLo = (lo / step).floor() * step;
    final yHi = (hi / step).ceil() * step;
    double y(double v) => padT + plotH - (v - yLo) / (yHi - yLo) * plotH;

    final days = points.map((p) => DateTime.parse(p.date!).millisecondsSinceEpoch / 86400000.0).toList();
    final x0 = days.first;
    var xSpan = days.last - x0;
    if (last != null) {
      final lastDay = DateTime.parse(last!.date!).millisecondsSinceEpoch / 86400000.0;
      xSpan = math.max(xSpan, lastDay - x0);
    }
    double x(double day) => xSpan == 0 ? padL + plotW / 2 : padL + (day - x0) / xSpan * plotW;

    // 参考范围灰带(只有一端时画到图边)。
    if (refLow != null || refHigh != null) {
      final top = y(refHigh ?? yHi);
      final bottom = y(refLow ?? yLo);
      canvas.drawRect(Rect.fromLTRB(padL, top, padL + plotW, bottom), Paint()..color = band);
    }

    if (!compact) {
      // y 轴刻度 + 横向网格线。
      final axisPaint = Paint()
        ..color = axis
        ..strokeWidth = 1;
      for (var v = yLo; v <= yHi + step / 2; v += step) {
        final yy = y(v);
        canvas.drawLine(Offset(padL, yy), Offset(padL + plotW, yy), axisPaint);
        final tp = TextPainter(
          text: TextSpan(text: fmtTick(v), style: labelStyle),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.right,
        )..layout(maxWidth: padL - 4);
        tp.paint(canvas, Offset(padL - 4 - tp.width, yy - tp.height / 2));
      }
      // x 轴时间刻度:按跨度选步长,最多 6 个标签。
      final first = DateTime.parse(points.first.date!);
      final spanDays = xSpan;
      final (stepDays, fmt) = _xStep(spanDays);
      var t = DateTime(first.year, first.month, first.day);
      var n = 0;
      while (n < 8) {
        final day = t.millisecondsSinceEpoch / 86400000.0;
        if (day - x0 > xSpan + 0.5) break;
        if (day >= x0) {
          final xx = x(day);
          canvas.drawLine(Offset(xx, padT + plotH), Offset(xx, padT + plotH + 3), axisPaint);
          final tp = TextPainter(text: TextSpan(text: fmt(t), style: labelStyle), textDirection: TextDirection.ltr)
            ..layout();
          final left = (xx - tp.width / 2).clamp(padL, size.width - tp.width);
          tp.paint(canvas, Offset(left, padT + plotH + 4));
          n++;
        }
        t = _advance(t, stepDays);
      }
    }

    // 折线。
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(days[i]), y(points[i].value));
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    if (points.length == 1) {
      canvas.drawCircle(Offset(x(days[0]), y(points[0].value)), compact ? 2 : 3, Paint()..color = dot);
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = compact ? 1.2 : 1.6
          ..strokeJoin = StrokeJoin.round,
      );
    }
    if (drawDots) {
      for (var i = 0; i < points.length; i++) {
        canvas.drawCircle(Offset(x(days[i]), y(points[i].value)), 2.2, Paint()..color = _dotColor(points[i].flag));
      }
    } else if (compact) {
      // 迷你图不画所有点,但异常点要看得见(橙 / 蓝)。
      for (var i = 0; i < points.length; i++) {
        if (labStatusOf(points[i].flag) == null) continue;
        canvas.drawCircle(Offset(x(days[i]), y(points[i].value)), 1.8, Paint()..color = _dotColor(points[i].flag));
      }
    }
    // 最后一次结果:一个点,颜色说状态。
    if (last != null) {
      final lastDay = DateTime.parse(last!.date!).millisecondsSinceEpoch / 86400000.0;
      canvas.drawCircle(Offset(x(lastDay), y(last!.value)), compact ? 2.6 : 4, Paint()..color = _dotColor(last!.flag));
    }
  }

  Color _dotColor(String? flag) => switch (labStatusOf(flag)) {
    LabStatus.high => dotHigh,
    LabStatus.low => dotLow,
    _ => dot,
  };

  (int, String Function(DateTime)) _xStep(double spanDays) {
    if (spanDays <= 45) return (7, (d) => '${d.month}/${d.day}');
    if (spanDays <= 120) return (14, (d) => '${d.month}/${d.day}');
    if (spanDays <= 400) return (61, (d) => '${d.year % 100}/${d.month.toString().padLeft(2, '0')}');
    if (spanDays <= 800) return (122, (d) => '${d.year % 100}/${d.month.toString().padLeft(2, '0')}');
    return (365, (d) => '${d.year}');
  }

  DateTime _advance(DateTime t, int stepDays) => switch (stepDays) {
    61 => DateTime(t.year, t.month + 2, 1),
    122 => DateTime(t.year, t.month + 4, 1),
    365 => DateTime(t.year + 1, 1, 1),
    _ => t.add(Duration(days: stepDays)),
  };

  @override
  bool shouldRepaint(covariant _LabLinePainter old) =>
      old.points != points || old.last != last || old.refLow != refLow || old.refHigh != refHigh || old.compact != compact;
}
