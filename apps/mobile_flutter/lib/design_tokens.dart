import 'package:flutter/material.dart';

/// MedMe 设计系统 v1 —— 颜色 / 字阶 / 形状 令牌。
///
/// 规范正本是 `DESIGN-SYSTEM-v1.html`(设计系统 v1 与信息架构)。本文件是它在
/// Flutter 侧的**唯一**落点:任何规范内的色值、字号、圆角、间距都只在这里出现
/// 一次,各屏通过 `MedColors.of(context)` / `MedType` / `MedShape` 取用,不再写
/// 裸的 `Color(0x…)`。`test/design_tokens_test.dart` 会逐一断言这些值,谁随手改
/// 一个色值,测试就红。
///
/// 与 `theme.dart` 里既有的 `MedMe` 常量的关系:`MedMe` 仍被各屏大量引用,本次
/// **不动它**(动了就是全 app 重新配色,视觉回归没法评审)。令牌层先建立、化验
/// 状态色先接过来,其余常量按屏逐步迁移。
@immutable
class MedColors extends ThemeExtension<MedColors> {
  const MedColors({
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.paper,
    required this.surface,
    required this.line,
    required this.line2,
    required this.seal,
    required this.sealInk,
    required this.sealWash,
    required this.low,
    required this.lowWash,
    required this.high,
    required this.highWash,
    required this.critical,
    required this.criticalWash,
    required this.shadowColor,
  });

  /// 主文字 / 深色卡。
  final Color ink;

  /// 次级文字(说明、辅助信息)。
  final Color ink2;

  /// 三级文字(参考区间、时间戳这类只在需要时才读的信息)。
  final Color ink3;

  /// 页面底色。
  final Color paper;

  /// 卡片、面板底色。
  final Color surface;

  /// 一级分隔线(卡片外框)。
  final Color line;

  /// 二级分隔线(卡内行间)。
  final Color line2;

  /// 主色「钤印」:链接、主按钮、焦点圈。沿用 hosted-viewer 现值 #1789C1 ——
  /// 比通用健康 app 的亮蓝更沉,像「档案」而不是「健身」。
  final Color seal;

  /// 主色的深调,用于浅底上的文字(对比度需要)。
  final Color sealInk;

  /// 主色的极浅底,用于次级按钮 / 选中态。
  final Color sealWash;

  /// 化验「偏低」前景色。
  final Color low;

  /// 化验「偏低」底色。
  final Color lowWash;

  /// 化验「偏高」前景色。
  final Color high;

  /// 化验「偏高」底色。
  final Color highWash;

  /// 化验「危急值」前景色。危急值报告是中国临床的真实制度,化验单上本来就有。
  final Color critical;

  /// 化验「危急值」底色。
  final Color criticalWash;

  /// 全 app 唯一一档阴影的颜色(含透明度)。层次靠**边框**不靠阴影。
  final Color shadowColor;

  /// 化验状态四级里的**正常**刻意没有令牌 —— 正常值不上色,继承正文。
  ///
  /// 一份血常规 22 项通常只有 1–2 项异常;若给正常配色,整屏都是彩的,真正需要
  /// 注意的那两项反而被淹没。要「正常」的颜色时用当前正文色,不要来这里找。
  static const String normalIsUncolored = '正常不上色:继承正文。见 DESIGN-SYSTEM-v1 §二。';

  /// 全 app 唯一一档阴影:`0 1px 2px rgba(…)`。
  List<BoxShadow> get shadow => [
    BoxShadow(color: shadowColor, offset: const Offset(0, 1), blurRadius: 2),
  ];

  /// 浅色一套。
  static const MedColors light = MedColors(
    ink: Color(0xFF101A23),
    ink2: Color(0xFF3A4A57),
    ink3: Color(0xFF6B7C89),
    paper: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    line: Color(0xFFE3E9EE),
    line2: Color(0xFFEEF2F5),
    seal: Color(0xFF1789C1),
    sealInk: Color(0xFF0E6285),
    sealWash: Color(0xFFEAF5FA),
    low: Color(0xFF1D4ED8),
    lowWash: Color(0xFFE8EEFC),
    high: Color(0xFFB45309),
    highWash: Color(0xFFFBF1E4),
    critical: Color(0xFFBE123C),
    criticalWash: Color(0xFFFCEAEF),
    shadowColor: Color.fromRGBO(16, 26, 35, 0.05),
  );

  /// 深色一套。目前 `MaterialApp` 只挂了浅色主题,这套先备好,不切换 —— 切换是
  /// 独立一件事,会改动每一屏的视觉。
  static const MedColors dark = MedColors(
    ink: Color(0xFFE8EEF3),
    ink2: Color(0xFFA6B6C2),
    ink3: Color(0xFF7C8D9A),
    paper: Color(0xFF0D141A),
    surface: Color(0xFF151F27),
    line: Color(0xFF25333D),
    line2: Color(0xFF1D2830),
    seal: Color(0xFF4FB3DF),
    sealInk: Color(0xFF8FD3F0),
    sealWash: Color(0xFF13303D),
    low: Color(0xFF7BA3F5),
    lowWash: Color(0xFF17233D),
    high: Color(0xFFE0A45C),
    highWash: Color(0xFF33260F),
    critical: Color(0xFFF2789A),
    criticalWash: Color(0xFF3A1521),
    shadowColor: Color.fromRGBO(0, 0, 0, 0.3),
  );

  /// 从当前主题取令牌。主题里没挂扩展时(裸 `MaterialApp`、部分 widget test)
  /// 退回浅色一套,而不是抛异常 —— 渲染永不因为缺个扩展就崩。
  static MedColors of(BuildContext context) =>
      Theme.of(context).extension<MedColors>() ?? light;

  @override
  MedColors copyWith({
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? paper,
    Color? surface,
    Color? line,
    Color? line2,
    Color? seal,
    Color? sealInk,
    Color? sealWash,
    Color? low,
    Color? lowWash,
    Color? high,
    Color? highWash,
    Color? critical,
    Color? criticalWash,
    Color? shadowColor,
  }) {
    return MedColors(
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      paper: paper ?? this.paper,
      surface: surface ?? this.surface,
      line: line ?? this.line,
      line2: line2 ?? this.line2,
      seal: seal ?? this.seal,
      sealInk: sealInk ?? this.sealInk,
      sealWash: sealWash ?? this.sealWash,
      low: low ?? this.low,
      lowWash: lowWash ?? this.lowWash,
      high: high ?? this.high,
      highWash: highWash ?? this.highWash,
      critical: critical ?? this.critical,
      criticalWash: criticalWash ?? this.criticalWash,
      shadowColor: shadowColor ?? this.shadowColor,
    );
  }

  @override
  MedColors lerp(covariant MedColors? other, double t) {
    if (other == null) return this;
    return MedColors(
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      line: Color.lerp(line, other.line, t)!,
      line2: Color.lerp(line2, other.line2, t)!,
      seal: Color.lerp(seal, other.seal, t)!,
      sealInk: Color.lerp(sealInk, other.sealInk, t)!,
      sealWash: Color.lerp(sealWash, other.sealWash, t)!,
      low: Color.lerp(low, other.low, t)!,
      lowWash: Color.lerp(lowWash, other.lowWash, t)!,
      high: Color.lerp(high, other.high, t)!,
      highWash: Color.lerp(highWash, other.highWash, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
      criticalWash: Color.lerp(criticalWash, other.criticalWash, t)!,
      shadowColor: Color.lerp(shadowColor, other.shadowColor, t)!,
    );
  }

  // 值相等:令牌是值类型,主题重建时同值的两个实例不该触发下游 rebuild。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MedColors &&
          ink == other.ink &&
          ink2 == other.ink2 &&
          ink3 == other.ink3 &&
          paper == other.paper &&
          surface == other.surface &&
          line == other.line &&
          line2 == other.line2 &&
          seal == other.seal &&
          sealInk == other.sealInk &&
          sealWash == other.sealWash &&
          low == other.low &&
          lowWash == other.lowWash &&
          high == other.high &&
          highWash == other.highWash &&
          critical == other.critical &&
          criticalWash == other.criticalWash &&
          shadowColor == other.shadowColor;

  @override
  int get hashCode => Object.hashAll([
    ink,
    ink2,
    ink3,
    paper,
    surface,
    line,
    line2,
    seal,
    sealInk,
    sealWash,
    low,
    lowWash,
    high,
    highWash,
    critical,
    criticalWash,
    shadowColor,
  ]);
}

/// 字阶。比参考 demo 整体上移一档 —— MedMe 的用户含老年人,`007 §2.5` 规定
/// 「字号可放大,不可砍」,所以下表最小 12px。
///
/// 这些是 **TextStyle 常量**,不是写死的像素:Flutter 默认让 `TextStyle.fontSize`
/// 走 `MediaQuery.textScaler`,系统字号放大会照常生效。**不要**在任何地方用
/// `MediaQuery.withNoTextScaling` 或给 `Text` 传死的 `textScaler` 去抵消它。
class MedType {
  MedType._();

  /// 28 · 700 —— 应急卡姓名血型、单指标大字。
  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
  );

  /// 22 · 600 · 等宽表格数字 —— 化验数值。
  static const TextStyle value = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    fontFeatures: tabular,
  );

  /// 20 · 700 —— 卡片 / 页面标题。
  static const TextStyle title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
  );

  /// 17 · 600 —— 副标题(医院名、科室)。
  static const TextStyle subtitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
  );

  /// 15 · 400 —— 正文。
  static const TextStyle body = TextStyle(fontSize: 15);

  /// 13 · 400 —— 次要信息(日期、科室)。
  static const TextStyle secondary = TextStyle(fontSize: 13);

  /// 12 · 600 · 字距 .05em —— 小标签(「参考区间」这类)。
  ///
  /// Flutter 的 `letterSpacing` 单位是逻辑像素不是 em:.05em × 12px = 0.6。
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
  );

  /// 字阶下限。低于这个值的字号一律不许出现。
  static const double minFontSize = 12;

  /// 等宽表格数字。**不是审美选择**:化验值的小数点必须对齐,否则一列数字读起来
  /// 要一个个对位。凡是渲染数值的地方都要带上。
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}

/// 形状与间距。
class MedShape {
  MedShape._();

  /// 20 —— 外层卡片。
  static const double radiusCard = 20;

  /// 14 —— 卡内分块。
  static const double radiusBlock = 14;

  /// 10 —— 按钮、输入框。
  static const double radiusControl = 10;

  /// 999 —— 状态 pill。
  static const double radiusPill = 999;

  /// 间距阶:8 / 12 / 16 / 20 / 24 / 32。
  /// 8·12 行内紧邻,16·20 卡内分区与内边距,24·32 区块之间。
  static const double s1 = 8;
  static const double s2 = 12;
  static const double s3 = 16;
  static const double s4 = 20;
  static const double s5 = 24;
  static const double s6 = 32;

  /// 圆角必须严格递减(卡片 > 分块 > 控件),嵌套时不能同级。
  static const List<double> radiiDescending = [
    radiusCard,
    radiusBlock,
    radiusControl,
  ];

  static const List<double> spacing = [s1, s2, s3, s4, s5, s6];
}
