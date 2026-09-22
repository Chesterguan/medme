import 'package:flutter/material.dart';

/// MedMe 设计系统 v1 —— 颜色 / 字阶 / 形状 令牌。
///
/// 规范正本是 `DESIGN-SYSTEM-v1.html`(设计系统 v1 与信息架构)。本文件是它在
/// Flutter 侧的**唯一**落点:任何规范内的色值、字号、圆角、间距都只在这里出现
/// 一次,各屏通过 `MedColors.of(context)` / `MedType` / `MedShape` 取用,不再写
/// 裸的 `Color(0x…)`。`test/design_tokens_test.dart` 会逐一断言这些值,谁随手改
/// 一个色值,测试就红。
///
/// **Stage 3 视觉令牌 brief 取代了 `MedColors.light` 的六个字段**:`paper`、
/// `high`、`highWash`、`low`、`lowWash`、`criticalWash`(mockup v24,见
/// `.superpowers/sdd/2026-09-18-ux-stage3-visual-tokens/task-1-brief.md`)。
/// 其余字段与 `MedColors.dark` 全套仍以 `DESIGN-SYSTEM-v1.html` 为正本。
///
/// 与 `theme.dart` 里既有的 `MedMe` 常量的关系:`MedMe` 仍被各屏大量引用,本次
/// **不动它**(动了就是全 app 重新配色,视觉回归没法评审)。令牌层先建立、化验
/// 状态色先接过来,其余常量按屏逐步迁移。
///
/// **规范之外唯一的增补是 `proxy` / `proxyInk` / `proxyWash`** —— 医生代拍模式的
/// 主色。规范正本只有个人模式那一套(`seal`),而代拍是「当面替别人拍」,两个模式
/// 必须一眼可辨。除主色外,代拍模式与个人模式共用**同一套**中性色、字阶、圆角、
/// 阴影,尤其共用**同一套化验状态色**:同一份化验值在哪个模式下都长一样。
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
    required this.proxy,
    required this.proxyInk,
    required this.proxyWash,
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

  /// **医生代拍模式**的主色「经手」。与 [seal] 同一层用途(主按钮、图标底、顶部
  /// 横幅),但换一个色相 —— 代拍是「当面替别人拍」,最危险的失误是拍到别人的单子、
  /// 或者在错的模式下动手。两个模式一眼可辨是**安全设计**,不是装饰。
  ///
  /// 色相选在 282°:色板里 [low](224°)与 [critical](345°)之间那段**唯一没被
  /// 语义占用**的空档,离两边各约 60°,不会被读成任何一档化验状态;离 [seal]
  /// (200°)80°,一眼是另一个颜色。饱和度刻意压到 40(seal 是 79)——代拍
  /// 该更冷静,不是更花哨。
  ///
  /// 不能用 [low] / [high] / [critical]:它们是化验状态专用,借来当 chrome 就会
  /// 稀释语义。也不能用绿:绿是「正常」化验状态专用色(`normalInk`/`barNormal`),同样犯不得。
  final Color proxy;

  /// 代拍主色的深调,用于浅底上的文字(对比度需要)。
  final Color proxyInk;

  /// 代拍主色的极浅底,用于图标底块 / 次级强调。
  final Color proxyWash;

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

  /// 全 app 唯一一档阴影:`0 1px 2px rgba(…)`。
  List<BoxShadow> get shadow => [
    BoxShadow(color: shadowColor, offset: const Offset(0, 1), blurRadius: 2),
  ];

  /// 预检裁定 R5 的两档暗幕 —— 取代散落各屏的 `Colors.black54` / `Colors.black26`:
  /// 同样的不透明度,但底色用 [ink](暖黑 #101A23)而不是纯黑,与全 app 墨色系一致。
  /// 遮罩层、弹层背后的暗幕都走这两个,不再各写各的裸色值。
  Color get scrim => ink.withValues(alpha: 0.54);
  Color get scrimLight => ink.withValues(alpha: 0.26);

  /// 深底(照片查看器、DICOM 黑底)上的次级文字/图标 —— 取代 `Colors.white70`。
  /// 恒定白,不跟 [ink] 变:深底本身已经是深的,不需要再跟主题切换。
  Color get onDarkFaint => const Color(0xB3FFFFFF);

  /// 深底上比 [onDarkFaint] 更亮一档的说明文字 —— hero 卡「最近就诊」的标签
  /// (R18,mockup `.hero .rule` 的 label,rgba(255,255,255,.88))。同样恒定白,
  /// 不跟 [ink] 变。
  Color get onDarkMeta => const Color(0xE0FFFFFF);

  /// 浅色一套。
  static const MedColors light = MedColors(
    ink: Color(0xFF101A23),
    ink2: Color(0xFF3A4A57),
    ink3: Color(0xFF657581),
    paper: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    line: Color(0xFFE9EEF2),
    line2: Color(0xFFEEF2F5),
    seal: Color(0xFF1789C1),
    sealInk: Color(0xFF0E6285),
    sealWash: Color(0xFFEAF5FA),
    proxy: Color(0xFF7C4096),
    proxyInk: Color(0xFF57296B),
    proxyWash: Color(0xFFF4ECF8),
    low: Color(0xFF1F5FB8),
    lowWash: Color(0xFFDCE8FB),
    high: Color(0xFFC25E18),
    highWash: Color(0xFFFDE3CC),
    critical: Color(0xFFBE123C),
    criticalWash: Color(0xFFFBDDE4),
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
    proxy: Color(0xFFC289DE),
    proxyInk: Color(0xFFDBAAF0),
    proxyWash: Color(0xFF2B1936),
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
    Color? proxy,
    Color? proxyInk,
    Color? proxyWash,
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
      proxy: proxy ?? this.proxy,
      proxyInk: proxyInk ?? this.proxyInk,
      proxyWash: proxyWash ?? this.proxyWash,
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
      proxy: Color.lerp(proxy, other.proxy, t)!,
      proxyInk: Color.lerp(proxyInk, other.proxyInk, t)!,
      proxyWash: Color.lerp(proxyWash, other.proxyWash, t)!,
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
          proxy == other.proxy &&
          proxyInk == other.proxyInk &&
          proxyWash == other.proxyWash &&
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
    proxy,
    proxyInk,
    proxyWash,
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
///
/// 唯一例外:`MedAvatar` 里的头像首字母 —— 固定尺寸的装饰字形,不
/// 承载信息(姓名在旁边、照常放大)。
class MedType {
  MedType._();

  /// 数字与字母的字体。中文不走它 —— Manrope 没有汉字,Flutter 会自动回落到
  /// `fontFamilyFallback` 里的系统苹方 / 系统默认。**不打包 Noto**(brief §字)。
  static const String family = 'Manrope';
  static const List<String> fallback = ['PingFang SC', 'Heiti SC', 'sans-serif'];

  /// 可变字体的轴值。Google Fonts 已不再提供 Manrope 静态字重,只有一个
  /// `Manrope[wght].ttf`;钉轴值比指望平台自动映射 `fontWeight` 更稳。
  static const List<FontVariation> w500 = [FontVariation('wght', 500)];
  static const List<FontVariation> w600 = [FontVariation('wght', 600)];

  /// 30 · 600 · tabular —— 单指标大数(趋势主卡、急救卡)。
  static const TextStyle display = TextStyle(
    fontSize: 30, fontWeight: FontWeight.w600,
    fontVariations: w600, fontFeatures: tabular,
  );

  /// 26 · 600 —— 页面标题(brief §字:标题 26)。
  static const TextStyle title = TextStyle(
    fontSize: 26, fontWeight: FontWeight.w600, fontVariations: w600,
  );

  /// 19 · 600 —— 底部 sheet 的标题、卡片标题(mockup `.sheet h4`)。
  static const TextStyle subtitle = TextStyle(
    fontSize: 19, fontWeight: FontWeight.w600, fontVariations: w600,
  );

  /// 16 · 400 —— 正文(brief §字:正文 16)。
  static const TextStyle body = TextStyle(fontSize: 16);

  /// 16 · 500 · tabular —— 化验/趋势的数值(mockup `.lr .v` / `.tr .v`)。
  static const TextStyle value = TextStyle(
    fontSize: 16, fontWeight: FontWeight.w500,
    fontVariations: w500, fontFeatures: tabular,
  );

  /// 22 · 600 · tabular —— hero 卡「最近就诊」的值(R18,mockup `.hero .rule b`)。
  /// 颜色不在这里定:这张卡的白字规则是全卡统一的确定性规则(R11,见
  /// `identity_hero_card.dart` 类文档),用处按 `.copyWith(color: Colors.white)`。
  static const TextStyle heroValue = TextStyle(
    fontSize: 22, fontWeight: FontWeight.w600,
    fontVariations: w600, fontFeatures: tabular,
  );

  /// 13 · 400 —— 行元数据、横幅小字(brief §字:两处都是 13)。
  static const TextStyle secondary = TextStyle(fontSize: 13);

  /// 12 · 500 —— 状态 pill、底栏标签。
  static const TextStyle caption = TextStyle(
    fontSize: 12, fontWeight: FontWeight.w500, fontVariations: w500,
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

  /// 26 —— 底部 sheet(出处 mockup CSS;预检裁定 R6)。全 app 最大的一档。
  static const double radiusSheet = 26;

  /// 22 —— 主卡(品牌渐变那张)。
  static const double radiusHero = 22;
  /// 18 —— 入口块(主页两个方块、病历本条)。
  static const double radiusEntry = 18;
  /// 16 —— 横幅、输入框面板、二维码框。
  static const double radiusBanner = 16;

  /// 16 —— 外层卡片(减法稿 `.card{border-radius:16px}`)。
  static const double radiusCard = 16;

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

/// Stage 3 视觉层:渐变、阴影、状态条、横幅。
///
/// **不做成 `ThemeExtension`**:这些值不随明暗主题变(app 只挂了浅色),而
/// `ThemeExtension` 每加一个字段要在 copyWith / lerp / == / hashCode 四处各补一行。
/// 三十多个字段 = 一百多行纯样板,换不来任何东西。
///
/// 正本 `stage3-visual-tokens-brief.md`;每个值在 `test/design_tokens_test.dart`
/// 里逐一断言。
class MedBrand {
  MedBrand._();

  // ── 品牌渐变 ────────────────────────────────────────────
  /// 135°,三段。**减法稿(Task 2)删了唯一的消费者 `BrandGradientBox`**——这四个
  /// 常量目前没有任何 widget 在读,只是 `test/design_tokens_test.dart` 还钉着
  /// 它们的值,留给 Token 清扫(Task 8)一并删,这里不单独先删。
  static const List<Color> gradientColors = [
    Color(0xFF1FB0C6), Color(0xFF1789C1), Color(0xFF16508E),
  ];
  static const List<double> gradientStops = [0.0, 0.5, 1.0];
  static const Alignment gradientBegin = Alignment.topLeft;
  static const Alignment gradientEnd = Alignment.bottomRight;

  /// 主卡右上那团弱光晕。
  static const Color heroGlow = Color(0x38FFFFFF);          // rgba(255,255,255,.22)

  /// 主卡头像块(R18,mockup `.hero .tile`):白底 54×54 圆角 14。圆角复用
  /// [MedShape.radiusBlock](同为 14,「卡内分块」那档,旧版本头像本就在用它)
  /// ——不再另开一个数值重复的 `heroTileRadius`。inset 底边与投影都是从 mockup
  /// 逐字抄来的,取代旧版本借用的占位色 `glossBottom`(那是另一块光泽图标块的
  /// 底部高光,rgba 对不上)。
  static const double heroTileSize = 54;
  static const double heroTileLetterSize = 28;
  /// `inset 0 -2px 0 rgba(22,80,142,.12)`,贴一道 2px 实色边代替(CSS 的 inset
  /// box-shadow,Flutter 没有)。
  static const Color heroTileInset = Color(0x1F16508E);
  /// `0 8px 18px rgba(14,60,100,.35)`。
  static const List<BoxShadow> heroTileShadow = [
    BoxShadow(color: Color(0x590E3C64), offset: Offset(0, 8), blurRadius: 18),
  ];

  /// 病历本书脊:180°(上 → 下),两段。
  static const List<Color> spineColors = [Color(0xFF1FB0C6), Color(0xFF16508E)];
  /// 书脊上的细横纹:2px 实、9px 周期。
  static const Color spineStripe = Color(0x24FFFFFF);       // rgba(255,255,255,.14)
  static const double spineStripeOn = 2;
  static const double spineStripePeriod = 9;
  static const double spineWidth = 34;

  /// 行首图标槽 44、图标 22(减法稿:单色线性图标,没有底块)。
  static const double iconSlot = 44;
  static const double iconSize = 22;

  // ── 化验行的细刻度条(减法稿 `.bar`)────────────────────────
  /// 74×3 的浅条,参考区间那一段用 `ink3` 压 30% 不透明度,一枚 9px 圆点标出这次的值。
  static const double rangeBarWidth = 74;
  static const double rangeBarHeight = 3;
  static const double rangeMarkerSize = 9;
  static const double rangeBandAlpha = 0.3;

  // ── 状态 ────────────────────────────────────────────────
  static const Color barHigh = Color(0xFFE07A25);
  static const Color barLow = Color(0xFF1F6FD2);
  static const Color barNormal = Color(0xFF2F8F5B);
  static const Color barCritical = Color(0xFFCF3A5A);
  /// 「正常」的文字色。**底是透明的** —— brief 只给了文和条,没给底(见计划「已知分歧 5」)。
  static const Color normalInk = Color(0xFF227A4C);
  /// 「偏高」pill 压在 `highWash` 上的那档更深的琥珀(与琥珀横幅同色)。
  static const Color pillHighInk = Color(0xFF9A4A12);

  static const Color bannerBlue = Color(0xFFDDEDF8);
  static const Color bannerBlueInk = Color(0xFF0E6285);
  static const Color bannerAmber = Color(0xFFFBE7D2);
  static const Color bannerAmberInk = Color(0xFF9A4A12);

  static const Color demoBorder = Color(0xFFB7C2CC);
  static const Color demoInk = Color(0xFF657581);
  static const Color checkWash = Color(0xFFE6EBF0);
  static const Color checkInk = Color(0xFF3A4A57);

  static const Color timelineLine = Color(0xFFDCE3EA);
  static const Color expandedChartBg = Color(0xFFF7FAFC);

  /// 趋势行右侧值簇的最大宽度(≈ 375pt 行宽的 40%);超过就把单位折到数值下
  /// 一行(brief §形 化验行)。Fix round 1(控制者裁定 R19):2× 字号下长名称 +
  /// 长单位(「抗核抗体谱定量(ANA)」+「mmol/L」)会把这一簇顶出卡外,给它一个
  /// 硬上限、允许换行,而不是让它继续用 `Row(mainAxisSize: min)` 硬挤一行。
  static const double trendValueMaxWidth = 150;

  // ── 阴影(五档,逐字抄 mockup)────────────────────────────
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x14101A23), offset: Offset(0, 6), blurRadius: 18),
  ];
  static const List<BoxShadow> heroShadow = [
    BoxShadow(color: Color(0x5216508E), offset: Offset(0, 14), blurRadius: 30),
  ];
  static const List<BoxShadow> entryShadow = [
    BoxShadow(color: Color(0x5216508E), offset: Offset(0, 12), blurRadius: 26),
  ];
  static const List<BoxShadow> buttonShadow = [
    BoxShadow(color: Color(0x4D16508E), offset: Offset(0, 10), blurRadius: 24),
  ];
  static const List<BoxShadow> navShadow = [
    BoxShadow(color: Color(0x0F101A23), offset: Offset(0, -6), blurRadius: 18),
  ];
  static const List<BoxShadow> chipShadow = [
    BoxShadow(color: Color(0x0F101A23), offset: Offset(0, 3), blurRadius: 10),
  ];
  static const List<BoxShadow> qrShadow = [
    BoxShadow(color: Color(0x1A101A23), offset: Offset(0, 6), blurRadius: 18),
  ];
}
