// 设计系统 v1 令牌的看门测试。
//
// 这个文件的作用不是「测逻辑」,是**钉住数值**:规范 (DESIGN-SYSTEM-v1.html) 里
// 的每个色值 / 字号 / 圆角 / 间距在这里逐一断言一遍,将来谁随手改一个色值,红的
// 是这里,而不是三个月后有人发现手机和查看器的「偏高」不是同一个橙。
//
// 最后一组是**迁移的回归护栏**:直接把化验表渲染出来,断言异常行的文字颜色确实
// 是令牌值 —— 也就是迁移前那两个硬编码的同一个值,视觉零变化。
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

  group('化验状态配色迁移后的实渲染(视觉零变化护栏)', () {
    testWidgets('偏高 = --high #B45309,偏低 = --low #1D4ED8,正常不上色', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ReportContent(text: labText, docType: 'lab_report'),
            ),
          ),
        ),
      );

      Color colorOf(String value) =>
          tester.widget<Text>(find.text(value).first).style!.color!;

      expect(colorOf('6.05').toARGB32(), MedColors.light.high.toARGB32());
      expect(colorOf('6.05').toARGB32(), 0xFFB45309); // 迁移前的硬编码值
      expect(colorOf('0.98').toARGB32(), MedColors.light.low.toARGB32());
      expect(colorOf('0.98').toARGB32(), 0xFF1D4ED8); // 迁移前的硬编码值
      // 正常行继承正文墨色,不走状态色。
      expect(colorOf('95'), MedMe.ink);
    });
  });
}
