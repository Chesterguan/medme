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

/// 规范里的浅色一套,逐字抄自 DESIGN-SYSTEM-v1.html 的 `:root`。
const Map<String, int> specLight = {
  'ink': 0xFF101A23,
  'ink-2': 0xFF3A4A57,
  'ink-3': 0xFF6B7C89,
  'paper': 0xFFF6F8FA,
  'surface': 0xFFFFFFFF,
  'line': 0xFFE3E9EE,
  'line-2': 0xFFEEF2F5,
  'seal': 0xFF1789C1,
  'seal-ink': 0xFF0E6285,
  'seal-wash': 0xFFEAF5FA,
  'low': 0xFF1D4ED8,
  'low-wash': 0xFFE8EEFC,
  'high': 0xFFB45309,
  'high-wash': 0xFFFBF1E4,
  'critical': 0xFFBE123C,
  'critical-wash': 0xFFFCEAEF,
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
        'display': (28, FontWeight.w700),
        'value': (22, FontWeight.w600),
        'title': (20, FontWeight.w700),
        'subtitle': (17, FontWeight.w600),
        'body': (15, FontWeight.w400),
        'secondary': (13, FontWeight.w400),
        'caption': (12, FontWeight.w600),
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

    test('caption 字距 .05em @12px = 0.6 逻辑像素', () {
      expect(MedType.caption.letterSpacing, 0.6);
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
      // body = 15px,系统放大 2× 后实际排版应为 30px。
      expect(richText.textScaler.scale(15), 30);
    });
  });

  group('形状与间距', () {
    test('圆角严格递减', () {
      expect(MedShape.radiusCard, 20);
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

    testWidgets('偏高 = --high #B45309,偏低 = --low #1D4ED8,正常不上色', (tester) async {
      await pumpLab(tester);

      expect(
        valueColor(tester, '6.05 mmol/L', '6.05').toARGB32(),
        MedColors.light.high.toARGB32(),
      );
      expect(valueColor(tester, '6.05 mmol/L', '6.05').toARGB32(), 0xFFB45309);
      expect(
        valueColor(tester, '0.98 mmol/L', '0.98').toARGB32(),
        MedColors.light.low.toARGB32(),
      );
      expect(valueColor(tester, '0.98 mmol/L', '0.98').toARGB32(), 0xFF1D4ED8);
      // 正常行继承正文墨色(令牌 `ink`),不走任何状态色 —— 规范 §二 的
      // 「正常不上色」:22 项里 1–2 项异常,给正常配色会把异常淹没。
      expect(
        valueColor(tester, '95 umol/L', '95').toARGB32(),
        MedColors.light.ink.toARGB32(),
      );
    });

    testWidgets('状态同时给文字 pill —— 色盲用户靠它读语义,不能只有色条', (tester) async {
      await pumpLab(tester);
      // 样本三行:6.05 偏高、0.98 偏低、95 正常。
      expect(find.text('偏高'), findsOneWidget);
      expect(find.text('偏低'), findsOneWidget);
      // 正常行不给 pill —— pill 本身也是一种上色。参考区间那格里的
      // 「57 - 97 正常」是原件抄下来的文本,不是 pill,精确匹配不会命中。
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
    // 整张文档类型配色表;旧的医生模式橙 #C2570C 与 `high` #B45309 相差 1° 色相,
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
}
