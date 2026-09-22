// 设计系统 v1 令牌的看门测试。
//
// 这个文件的作用不是「测逻辑」,是**钉住数值**:规范 (DESIGN-SYSTEM-v1.html) 里
// 的每个色值 / 字号 / 圆角 / 间距在这里逐一断言一遍,将来谁随手改一个色值,红的
// 是这里,而不是三个月后有人发现手机和查看器的「偏高」不是同一个橙。
//
// 倒数第二组是**迁移的回归护栏**:直接把化验表渲染出来,断言异常行的文字颜色确实
// 是令牌值 —— 也就是迁移前那两个硬编码的同一个值,视觉零变化。
//
// 最后一组守**医生模式主色**(`proxy`)。它是规范正本之外唯一的增补,所以不能像上面
// 那样「抄规范」来验;改为验它必须满足的那几条**约束**:不撞任何一档化验状态色、
// 不是绿、与个人模式主色一眼可辨、老年用户读得清。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/report_content.dart';

/// 正本 = `stage3-visual-tokens-brief.md`(mockup v24,2026-09-17 认可)。
/// **它 supersede 了 DESIGN-SYSTEM-v1.html 的色板** —— 底色、偏高/偏低/危急三档
/// 都换了值。改这张表 = 改设计,不是改代码。
const Map<String, int> specLight = {
  'ink': 0xFF101A23,
  'ink-2': 0xFF3A4A57,
  'ink-3': 0xFF657581,
  'paper': 0xFFF6F8FA,
  'surface': 0xFFFFFFFF,
  'line': 0xFFE9EEF2,
  'line-2': 0xFFEEF2F5,
  'seal': 0xFF1789C1,
  'seal-ink': 0xFF0E6285,
  'seal-wash': 0xFFEAF5FA,
  'low': 0xFF1F5FB8,
  'low-wash': 0xFFDCE8FB,
  'high': 0xFFC25E18,
  'high-wash': 0xFFFDE3CC,
  'critical': 0xFFBE123C,
  'critical-wash': 0xFFFBDDE4,
};

/// 规范里的深色一套(`prefers-color-scheme:dark` / `[data-theme="dark"]`)。
const Map<String, int> specDark = {
  'ink': 0xFFE8EEF3,
  'ink-2': 0xFFA6B6C2,
  'ink-3': 0xFF7C8D9A,
  'paper': 0xFF0D141A,
  'surface': 0xFF151F27,
  'line': 0xFF25333D,
  'line-2': 0xFF1D2830,
  'seal': 0xFF4FB3DF,
  'seal-ink': 0xFF8FD3F0,
  'seal-wash': 0xFF13303D,
  'low': 0xFF7BA3F5,
  'low-wash': 0xFF17233D,
  'high': 0xFFE0A45C,
  'high-wash': 0xFF33260F,
  'critical': 0xFFF2789A,
  'critical-wash': 0xFF3A1521,
};

Map<String, Color> asMap(MedColors c) => {
  'ink': c.ink,
  'ink-2': c.ink2,
  'ink-3': c.ink3,
  'paper': c.paper,
  'surface': c.surface,
  'line': c.line,
  'line-2': c.line2,
  'seal': c.seal,
  'seal-ink': c.sealInk,
  'seal-wash': c.sealWash,
  'low': c.low,
  'low-wash': c.lowWash,
  'high': c.high,
  'high-wash': c.highWash,
  'critical': c.critical,
  'critical-wash': c.criticalWash,
};

// 化验表样本:6.05 偏高(↑)、0.98 偏低(↓)、95 正常。取自 report_content_test.dart
// 的真实提取文本形态。
const labText = '''
项目缩写 项目名称 结果 单位 参考范围 提示
TC 总胆固醇 Cholesterol 6.05 mmol/L < 5.20 ↑
HDL-C 高密度脂蛋白胆固醇 0.98 mmol/L > 1.04 ↓
Cr 肌酐 Creatinine 95 umol/L 57 - 97 正常
''';

/// WCAG 对比度。两色亮度之比,`(亮+0.05)/(暗+0.05)`。
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 两个色相在色环上的最短夹角(度)。
double hueGap(Color a, Color b) {
  final d =
      (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  group('颜色令牌与规范逐一对齐', () {
    test('浅色一套', () {
      final actual = asMap(MedColors.light);
      for (final entry in specLight.entries) {
        expect(
          actual[entry.key]!.toARGB32(),
          entry.value,
          reason:
              '--${entry.key} 与 DESIGN-SYSTEM-v1 不符,应为 '
              '#${entry.value.toRadixString(16).substring(2).toUpperCase()}',
        );
      }
    });

    test('深色一套', () {
      final actual = asMap(MedColors.dark);
      for (final entry in specDark.entries) {
        expect(
          actual[entry.key]!.toARGB32(),
          entry.value,
          reason:
              '--${entry.key}(深色)与 DESIGN-SYSTEM-v1 不符,应为 '
              '#${entry.value.toRadixString(16).substring(2).toUpperCase()}',
        );
      }
    });

    test('阴影只有一档:0 1px 2px rgba(16,26,35,.05)', () {
      final light = MedColors.light;
      expect(light.shadowColor.toARGB32() & 0x00FFFFFF, 0x101A23);
      expect(light.shadowColor.a, closeTo(0.05, 0.005));
      expect(light.shadow, hasLength(1));
      expect(light.shadow.single.offset, const Offset(0, 1));
      expect(light.shadow.single.blurRadius, 2);

      final dark = MedColors.dark;
      expect(dark.shadowColor.toARGB32() & 0x00FFFFFF, 0x000000);
      expect(dark.shadowColor.a, closeTo(0.3, 0.005));
    });

    test('lerp / copyWith 不丢字段', () {
      expect(MedColors.light.lerp(MedColors.dark, 0), MedColors.light);
      expect(MedColors.light.lerp(MedColors.dark, 1), MedColors.dark);
      final tweaked = MedColors.light.copyWith(high: const Color(0xFF000000));
      expect(tweaked.high.toARGB32(), 0xFF000000);
      expect(tweaked.low, MedColors.light.low); // 其余字段原样带过
    });

    test('主题挂上了令牌扩展,MedColors.of 取得到', () {
      expect(MedMe.theme().extension<MedColors>(), MedColors.light);
    });
  });

  group('字阶', () {
    test('七档字号 / 字重与规范一致', () {
      const expected = <String, (double, FontWeight)>{
        'display': (30, FontWeight.w600),
        'value': (16, FontWeight.w500),
        'title': (26, FontWeight.w600),
        'subtitle': (19, FontWeight.w600),
        'body': (16, FontWeight.w400),
        'secondary': (13, FontWeight.w400),
        'caption': (12, FontWeight.w500),
      };
      const actual = <String, TextStyle>{
        'display': MedType.display,
        'value': MedType.value,
        'title': MedType.title,
        'subtitle': MedType.subtitle,
        'body': MedType.body,
        'secondary': MedType.secondary,
        'caption': MedType.caption,
      };
      for (final entry in expected.entries) {
        final style = actual[entry.key]!;
        expect(style.fontSize, entry.value.$1, reason: '${entry.key} 字号');
        // body/secondary 不显式写 w400 —— 那本来就是默认值。
        expect(
          style.fontWeight ?? FontWeight.w400,
          entry.value.$2,
          reason: '${entry.key} 字重',
        );
        expect(
          style.fontSize!,
          greaterThanOrEqualTo(MedType.minFontSize),
          reason: '${entry.key} 低于 12px 下限 —— 用户含老年人,字号可放大不可砍',
        );
      }
    });

    test('数值档必须是等宽表格数字', () {
      expect(
        MedType.value.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(MedType.tabular, contains(const FontFeature.tabularFigures()));
    });

    testWidgets('字号响应系统放大 —— 令牌里不许写死像素', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Text('白细胞计数', style: MedType.body),
            ),
          ),
        ),
      );
      final richText = tester.widget<RichText>(find.byType(RichText));
      // body = 16px,系统放大 2× 后实际排版应为 32px。
      expect(richText.textScaler.scale(16), 32);
    });
  });

  group('形状与间距', () {
    test('圆角严格递减', () {
      expect(MedShape.radiusCard, 16);
      expect(MedShape.radiusBlock, 14);
      expect(MedShape.radiusControl, 10);
      expect(MedShape.radiusPill, 999);
      for (var i = 1; i < MedShape.radiiDescending.length; i++) {
        expect(
          MedShape.radiiDescending[i],
          lessThan(MedShape.radiiDescending[i - 1]),
          reason: '圆角必须递减,嵌套时不能同级',
        );
      }
    });

    test('间距阶为 8/12/16/20/24/32', () {
      expect(MedShape.spacing, [8, 12, 16, 20, 24, 32]);
    });
  });

  group('化验状态在实渲染上的落地', () {
    /// 化验值现在和单位同处一个 `Text.rich`(「6.05 mmol/L」),所以按整行富文本
    /// 定位,再取出数值那一段的颜色。
    Color valueColor(WidgetTester tester, String whole, String value) {
      final rich = tester.widget<RichText>(
        find.text(whole, findRichText: true).first,
      );
      Color? found;
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == value) {
          found = span.style?.color;
          return false;
        }
        return true;
      });
      expect(found, isNotNull, reason: '在「$whole」里没找到数值段「$value」');
      return found!;
    }

    Future<void> pumpLab(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: MedMe.theme(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: ReportContent(text: labText, docType: 'lab_report'),
          ),
        ),
      ),
    );

    testWidgets('偏高 = --high #C25E18,偏低 = --low #1F5FB8,正常 = ink(减法稿:不上色)', (
      tester,
    ) async {
      await pumpLab(tester);

      expect(
        valueColor(tester, '6.05 mmol/L', '6.05').toARGB32(),
        MedColors.light.high.toARGB32(),
      );
      expect(valueColor(tester, '6.05 mmol/L', '6.05').toARGB32(), 0xFFC25E18);
      expect(
        valueColor(tester, '0.98 mmol/L', '0.98').toARGB32(),
        MedColors.light.low.toARGB32(),
      );
      expect(valueColor(tester, '0.98 mmol/L', '0.98').toARGB32(), 0xFF1F5FB8);
      // 减法稿 2026-09-22:「正常不上色」——`LabFlag.normal` 现在走 `c.ink`,
      // 与 `lab_status.dart` 的 `labStatusColor`(`status == null` 那一档)
      // 同一套规则,预检裁定 R2 的「正常档也上色」作废。
      expect(
        valueColor(tester, '95 umol/L', '95').toARGB32(),
        MedColors.light.ink.toARGB32(),
      );
      expect(find.text('正常'), findsNothing);
    });

    testWidgets('状态同时给文字状态词 —— 色盲用户靠它读语义,不能只靠颜色', (tester) async {
      await pumpLab(tester);
      // 样本三行:6.05 偏高、0.98 偏低、95 正常。
      expect(find.text('偏高'), findsOneWidget);
      expect(find.text('偏低'), findsOneWidget);
      // 正常行两样都不给——不上色也不加字。参考区间那格里的
      // 「57 - 97 正常」是原件抄下来的文本,不是状态词,精确匹配不会命中。
      expect(find.text('正常'), findsNothing);
    });

    testWidgets('化验表里不出现医生模式主色 —— 同一份化验值两个模式必须长一样', (tester) async {
      await pumpLab(tester);
      // `widgets/report_content.dart` 被两个模式共用。它一旦消费了 `proxy`,
      // 同一张化验单在医生模式下就会变个样子,「偏高」这类结论也就有了两副面孔。
      final banned = {
        MedColors.light.proxy.toARGB32(),
        MedColors.light.proxyInk.toARGB32(),
        MedColors.light.proxyWash.toARGB32(),
      };
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          final color = span.style?.color;
          if (color != null) {
            expect(
              banned.contains(color.toARGB32()),
              isFalse,
              reason:
                  '「${span.toPlainText()}」用了医生模式主色 —— 化验表是两个模式共用的,'
                  '不能带模式色',
            );
          }
          return true;
        });
      }
    });

    testWidgets('化验表里没有任何字号低于 12px —— 007 §2.5「字号可放大,不可砍」', (
      tester,
    ) async {
      await pumpLab(tester);
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          final size = span.style?.fontSize;
          if (size != null) {
            expect(
              size,
              greaterThanOrEqualTo(MedType.minFontSize),
              reason: '「${span.toPlainText()}」用了 ${size}px,低于 12px 下限',
            );
          }
          return true;
        });
      }
    });
  });

  group('医生模式主色 proxy', () {
    test('色值钉死', () {
      expect(MedColors.light.proxy.toARGB32(), 0xFF7C4096);
      expect(MedColors.light.proxyInk.toARGB32(), 0xFF57296B);
      expect(MedColors.light.proxyWash.toARGB32(), 0xFFF4ECF8);
      expect(MedColors.dark.proxy.toARGB32(), 0xFFC289DE);
      expect(MedColors.dark.proxyInk.toARGB32(), 0xFFDBAAF0);
      expect(MedColors.dark.proxyWash.toARGB32(), 0xFF2B1936);
    });

    // 借用化验状态色当 chrome = 稀释语义。`feat/mobile-visual` 正是因为这个删掉了
    // 整张文档类型配色表;旧的医生模式橙 #C2570C 与 `high` #AB4E08 相差 1° 色相,
    // 就是这条规矩的现行反例,它已被换掉。
    test('不撞任何一档化验状态色,也不撞个人模式主色', () {
      for (final c in [MedColors.light, MedColors.dark]) {
        for (final other in [c.low, c.high, c.critical, c.seal, c.sealInk]) {
          expect(
            c.proxy.toARGB32(),
            isNot(other.toARGB32()),
            reason: 'proxy 与另一个有语义的令牌撞了色值',
          );
        }
        // 只不相等还不够 —— 相差 1° 的两个橙也「不相等」。要色相上真的分得开。
        expect(
          hueGap(c.proxy, c.low),
          greaterThanOrEqualTo(45),
          reason: 'proxy 离「偏低」太近,小色块上会被读成化验状态',
        );
        expect(
          hueGap(c.proxy, c.high),
          greaterThanOrEqualTo(45),
          reason: 'proxy 离「偏高」太近 —— 旧的医生模式橙就是栽在这里',
        );
        expect(
          hueGap(c.proxy, c.critical),
          greaterThanOrEqualTo(45),
          reason: 'proxy 离「危急值」太近',
        );
      }
    });

    test('一眼可辨于个人模式主色,但不是换了个 app', () {
      for (final c in [MedColors.light, MedColors.dark]) {
        expect(
          hueGap(c.proxy, c.seal),
          greaterThanOrEqualTo(60),
          reason: '两个模式的主色要一眼分得开 —— 这是安全设计,不是装饰',
        );
        // 同属一个体系:饱和度不高于个人模式主色。医生模式该更冷静,不更花哨。
        expect(
          HSLColor.fromColor(c.proxy).saturation,
          lessThanOrEqualTo(HSLColor.fromColor(c.seal).saturation),
          reason: 'proxy 比 seal 还艳 —— 医生模式不该是更吵的那个',
        );
      }
    });

    test('不是绿 —— 色板刻意没有绿(「正常值不上色」)', () {
      for (final c in [MedColors.light, MedColors.dark]) {
        final hue = HSLColor.fromColor(c.proxy).hue;
        expect(
          hue > 70 && hue < 170,
          isFalse,
          reason: '色相 $hue 落在绿区。绿 = 安全,正是规范 §二 拒绝做的暗示',
        );
      }
    });

    test('对比度够老年用户 —— 主按钮文字、淡底块文字都 ≥ 4.5:1', () {
      // 浅色一套的主色是**深**紫,按钮文字压白;深色一套的主色是**浅**紫,按钮文字
      // 压深墨 —— 与 `seal` 在两套里的处理完全一致(深色的 seal #4FB3DF 上压白字
      // 只有 2.0:1,深色主题的按钮从来不是白字)。所以两套各按各的文字色验。
      const white = Color(0xFFFFFFFF);
      expect(
        contrast(white, MedColors.light.proxy),
        greaterThanOrEqualTo(4.5),
        reason: '浅色一套:主按钮上的白字读不清',
      );
      expect(
        contrast(MedColors.dark.paper, MedColors.dark.proxy),
        greaterThanOrEqualTo(4.5),
        reason: '深色一套:主按钮上的深色字读不清',
      );
      // 顺带钉住「医生模式的主按钮不比个人模式难读」—— 这是换色带来的实际收益,
      // 掉回去应该红。
      expect(
        contrast(white, MedColors.light.proxy),
        greaterThan(contrast(white, MedColors.light.seal)),
      );

      for (final c in [MedColors.light, MedColors.dark]) {
        // 「已确认」这类淡底块:proxyInk 压在 proxyWash 上。
        expect(
          contrast(c.proxyInk, c.proxyWash),
          greaterThanOrEqualTo(4.5),
          reason: '淡底块上的文字读不清',
        );
        // 浅底上的图标 / 边框:proxy 压在页面底色上(非文字,按 3:1 这一档)。
        expect(
          contrast(c.proxy, c.paper),
          greaterThanOrEqualTo(3.0),
          reason: '页面底色上的主色图标读不清',
        );
      }
    });

    test('lerp / copyWith 带上了三个新字段', () {
      final tweaked = MedColors.light.copyWith(
        proxy: const Color(0xFF000000),
      );
      expect(tweaked.proxy.toARGB32(), 0xFF000000);
      expect(tweaked.proxyInk, MedColors.light.proxyInk);
      expect(tweaked.seal, MedColors.light.seal);
      // lerp 全字段:两端相等已由上面「lerp 不丢字段」覆盖,这里只确认中点会动 ——
      // 漏掉的字段在中点会停在 `this` 的值上。
      final mid = MedColors.light.lerp(MedColors.dark, 0.5);
      expect(mid.proxy, isNot(MedColors.light.proxy));
      expect(mid.proxyWash, isNot(MedColors.light.proxyWash));
    });
  });

  group('MedBrand —— Stage 3 brief §色 / §形', () {
    test('品牌渐变 135°,三段,逐字', () {
      expect(MedBrand.gradientColors, [
        const Color(0xFF1FB0C6),
        const Color(0xFF1789C1),
        const Color(0xFF16508E),
      ]);
      expect(MedBrand.gradientStops, [0.0, 0.5, 1.0]);
      // 135° = 左上 → 右下。
      expect(MedBrand.gradientBegin, Alignment.topLeft);
      expect(MedBrand.gradientEnd, Alignment.bottomRight);
      expect(MedBrand.heroGlow, const Color(0x38FFFFFF)); // rgba(255,255,255,.22)
    });

    test('横幅、示例框、看一眼、时间轴', () {
      expect(MedBrand.bannerBlue, const Color(0xFFDDEDF8));
      expect(MedBrand.bannerBlueInk, const Color(0xFF0E6285));
      expect(MedBrand.bannerAmber, const Color(0xFFFBE7D2));
      expect(MedBrand.bannerAmberInk, const Color(0xFF9A4A12));
      expect(MedBrand.demoBorder, const Color(0xFFB7C2CC));
      expect(MedBrand.demoInk, const Color(0xFF657581));
      expect(MedBrand.checkWash, const Color(0xFFE6EBF0));
      expect(MedBrand.checkInk, const Color(0xFF3A4A57));
      expect(MedBrand.timelineLine, const Color(0xFFDCE3EA));
      expect(MedBrand.expandedChartBg, const Color(0xFFF7FAFC));
    });

    // Fix round 1(R19):趋势行右侧值簇的换行上限——Task 9 review 的溢出根因。
    test('趋势行右侧值簇的最大宽度', () {
      expect(MedBrand.trendValueMaxWidth, 150);
    });

    test('五档阴影,逐字', () {
      expect(MedBrand.cardShadow.single.blurRadius, 18);
      expect(MedBrand.cardShadow.single.offset, const Offset(0, 6));
      expect(MedBrand.cardShadow.single.color, const Color(0x14101A23)); // rgba(16,26,35,.08)
      expect(MedBrand.heroShadow.single.blurRadius, 30);
      expect(MedBrand.heroShadow.single.offset, const Offset(0, 14));
      expect(MedBrand.heroShadow.single.color, const Color(0x5216508E)); // rgba(22,80,142,.32)
      expect(MedBrand.entryShadow.single.blurRadius, 26);
      expect(MedBrand.entryShadow.single.offset, const Offset(0, 12));
      expect(MedBrand.buttonShadow.single.blurRadius, 24);
      expect(MedBrand.buttonShadow.single.offset, const Offset(0, 10));
      expect(MedBrand.buttonShadow.single.color, const Color(0x4D16508E)); // rgba(22,80,142,.3)
      expect(MedBrand.navShadow.single.offset, const Offset(0, -6));
    });

    test('头像块令牌(R18,mockup .hero .tile):尺寸/字号/inset/投影', () {
      expect(MedBrand.heroTileSize, 54);
      expect(MedBrand.heroTileLetterSize, 28);
      // 圆角数值上与 MedShape.radiusBlock(14,「卡内分块」那档,头像本来就在
      // 用它)重复,不另开一个 MedBrand.heroTileRadius。
      expect(MedShape.radiusBlock, 14);
      expect(MedBrand.heroTileInset, const Color(0x1F16508E)); // rgba(22,80,142,.12)
      expect(MedBrand.heroTileShadow.single.color, const Color(0x590E3C64)); // rgba(14,60,100,.35)
      expect(MedBrand.heroTileShadow.single.offset, const Offset(0, 8));
      expect(MedBrand.heroTileShadow.single.blurRadius, 18);
    });

    test('减法稿:图标槽、化验刻度条', () {
      expect(MedBrand.iconSlot, 44);
      expect(MedBrand.iconSize, 22);
      expect(MedBrand.rangeBarWidth, 74);
      expect(MedBrand.rangeBarHeight, 3);
      expect(MedBrand.rangeMarkerSize, 9);
      expect(MedBrand.rangeBandAlpha, 0.3);
    });
  });

  group('MedShape / MedType —— Stage 3 brief §形 §字', () {
    test('六档圆角', () {
      // R6:sheet(26)压过主卡 hero(22),现在是全 app 最大的一档。
      expect(MedShape.radiusSheet, 26);
      expect(MedShape.radiusHero, 22);
      expect(MedShape.radiusCard, 16);
      expect(MedShape.radiusEntry, 18);
      expect(MedShape.radiusBanner, 16);
      expect(MedShape.radiusPill, 999);
    });

    test('字号字重', () {
      expect(MedType.title.fontSize, 26);
      expect(MedType.title.fontWeight, FontWeight.w600);
      expect(MedType.body.fontSize, 16);
      // body 不显式写 fontWeight(null,渲染时默认 w400)—— 同文件里「七档字号」
      // 测试一样用 `?? FontWeight.w400`;brief 原文这行是裸 `expect(..., w400)`,
      // 对着实际是 `null` 的字段直接会红。
      expect(MedType.body.fontWeight ?? FontWeight.w400, FontWeight.w400);
      expect(MedType.secondary.fontSize, 13);
      expect(MedType.value.fontSize, 16);
      expect(MedType.value.fontWeight, FontWeight.w500);
      expect(MedType.value.fontFeatures, MedType.tabular);
      expect(MedType.display.fontSize, 30);
      expect(MedType.display.fontWeight, FontWeight.w600);
      // R18:hero 卡「最近就诊」的值(mockup `.hero .rule b`)。
      expect(MedType.heroValue.fontSize, 22);
      expect(MedType.heroValue.fontWeight, FontWeight.w600);
      expect(MedType.heroValue.fontFeatures, MedType.tabular);
      // 700 不许出现:mockup 里没有一处 Latin/数字用它(见计划「已知分歧 3」)。
      for (final s in [MedType.display, MedType.value, MedType.heroValue, MedType.title,
                       MedType.subtitle, MedType.body, MedType.secondary, MedType.caption]) {
        // body/secondary 不显式写 fontWeight(null = 默认 w400)—— 同上面
        // 「七档字号」测试一样用 `?? FontWeight.w400`,不能直接 `!`(会在这两个
        // 空值上抛 null-check 异常,brief 原文这行漏了这一步)。用 `.value`
        // 而不是 brief 原文的 `.index`:后者在当前 Flutter 版本已标记 deprecated。
        expect(
          (s.fontWeight ?? FontWeight.w400).value,
          lessThanOrEqualTo(FontWeight.w600.value),
        );
      }
    });

    test('底色是实心 #F6F8FA,主题拿的就是它', () {
      expect(MedMe.theme().scaffoldBackgroundColor, const Color(0xFFF6F8FA));
    });

    test('卡片无边框', () {
      final shape = MedMe.theme().cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.side, BorderSide.none);
    });
  });

  group('预检裁定 R5 —— 暗幕令牌取代 Colors.black54/black26/white70', () {
    test('scrim / scrimLight 是 ink 的透明度变体,不是纯黑', () {
      for (final c in [MedColors.light, MedColors.dark]) {
        expect(c.scrim.a, closeTo(0.54, 0.001));
        expect(c.scrim.toARGB32() & 0x00FFFFFF, c.ink.toARGB32() & 0x00FFFFFF);
        expect(c.scrimLight.a, closeTo(0.26, 0.001));
        expect(c.scrimLight.toARGB32() & 0x00FFFFFF, c.ink.toARGB32() & 0x00FFFFFF);
      }
    });

    test('onDarkFaint 恒定白 70%,不随 ink 变(深底本身已经是深的)', () {
      expect(MedColors.light.onDarkFaint, const Color(0xB3FFFFFF));
      expect(MedColors.dark.onDarkFaint, const Color(0xB3FFFFFF));
    });

    // 严格说这条是 R18 加的(hero 卡「最近就诊」标签),不是 R5——放在这里是因为
    // 它和 onDarkFaint 同一类「深底恒定白、不随 ink 变」的令牌。
    test('onDarkMeta 恒定白 88%,不随 ink 变(R18,hero 卡「最近就诊」标签)', () {
      expect(MedColors.light.onDarkMeta, const Color(0xE0FFFFFF));
      expect(MedColors.dark.onDarkMeta, const Color(0xE0FFFFFF));
    });
  });
}
