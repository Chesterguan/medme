// 设计系统 v1 共用外壳的看门测试:卡片形状(细边、圆角、无阴影)、pill、内置
// Material 层、MedBanner 配色、化验表状态词——钉数值,不测「画得好不好看」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/report_content.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: MedMe.theme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// 化验样本:6.05 偏高、0.98 偏低、95 正常。
const labText = '''
项目缩写 项目名称 结果 单位 参考范围 提示
TC 总胆固醇 Cholesterol 6.05 mmol/L < 5.20 ↑
HDL-C 高密度脂蛋白胆固醇 0.98 mmol/L > 1.04 ↓
Cr 肌酐 Creatinine 95 umol/L 57 - 97 正常
''';

/// 把当前树上所有 `BoxDecoration` 收集出来,用于断言边框/底色。
Iterable<BoxDecoration> decorations(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>();

void main() {
  group('卡片形状', () {
    testWidgets('卡 1px line 细边、圆角 16、无阴影', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MedCard(child: Text('x')))));
      final d = tester.widget<Container>(find.descendant(
        of: find.byType(MedCard), matching: find.byType(Container)).first)
        .decoration! as BoxDecoration;
      expect(d.border, Border.all(color: MedColors.light.line));
      expect(d.borderRadius, BorderRadius.circular(MedShape.radiusCard));
      expect(d.boxShadow, isNull);
      expect(d.color, Colors.white);
    });

    testWidgets('pill 圆角 999,字号不低于 12', (tester) async {
      await tester.pumpWidget(
        wrap(
          const MedPill(
            text: '偏低',
            foreground: Color(0xFF1D4ED8),
            background: Color(0xFFE8EEFC),
          ),
        ),
      );
      final box = tester
          .widget<Container>(find.byType(Container).first)
          .decoration as BoxDecoration;
      expect(box.borderRadius, BorderRadius.circular(MedShape.radiusPill));
      final style = tester.widget<Text>(find.text('偏低')).style!;
      expect(style.fontSize, greaterThanOrEqualTo(MedType.minFontSize));
      expect(style.color, const Color(0xFF1D4ED8));
    });
  });

  group('R24:child 槽位内置的透明 Material', () {
    testWidgets('恰好一层 type: transparency,ListTile 的墨水飞溅点得动、不报错', (tester) async {
      await tester.pumpWidget(
        wrap(MedCard(child: ListTile(title: const Text('x'), onTap: () {}))),
      );
      final transparencyMaterials = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(MedCard),
              matching: find.byType(Material),
            ),
          )
          .where((m) => m.type == MaterialType.transparency);
      expect(
        transparencyMaterials,
        hasLength(1),
        reason: 'MedCard 内置这一层,调用方不必再各自手抄',
      );
      await tester.tap(find.byType(ListTile));
      await tester.pump();
      // 没有这层 Material,ListTile 的 InkWell 会在 debug 下断言
      // 「No Material widget found」——这里钉住的正是这条不再发生。
      expect(tester.takeException(), isNull);
    });
  });

  group('MedBanner', () {
    testWidgets('MedBanner:蓝 #DDEDF8 / 文 #0E6285,琥珀 #FBE7D2 / 文 #9A4A12,圆角 16', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [
        MedBanner(icon: Icons.cloud_outlined,
                  title: '云端', subtitle: '已备份,刚刚'),
        MedBanner(icon: Icons.warning_amber_outlined,
                  title: '2 份还没核对', subtitle: '扫描件,识别出的字有几处不确定', amber: true),
      ]))));
      final decos = tester.widgetList<Container>(find.descendant(
        of: find.byType(MedBanner), matching: find.byType(Container)))
        .map((w) => w.decoration).whereType<BoxDecoration>()
        .where((d) => d.borderRadius == BorderRadius.circular(MedShape.radiusBanner)).toList();
      expect(decos.map((d) => d.color), [MedBrand.bannerBlue, MedBrand.bannerAmber]);
      expect(tester.widget<Text>(find.text('云端')).style!.color, MedBrand.bannerBlueInk);
      expect(tester.widget<Text>(find.text('2 份还没核对')).style!.color, MedBrand.bannerAmberInk);
      expect(tester.widget<Text>(find.text('已备份,刚刚')).style!.fontSize, 13);
      // 减法稿:图标是一枚纯 Icon,颜色与横幅文字色同一个 ink。
      expect(tester.widget<Icon>(find.byIcon(Icons.cloud_outlined)).color, MedBrand.bannerBlueInk);
      expect(tester.widget<Icon>(find.byIcon(Icons.warning_amber_outlined)).color, MedBrand.bannerAmberInk);
    });
  });

  group('化验表格行的状态词', () {
    testWidgets('三档 LabFlag:偏高/偏低是上色的词,正常不上色不加字', (tester) async {
      const c = MedColors.light;
      await tester.pumpWidget(
        wrap(const ReportContent(text: labText, docType: 'lab_report')),
      );
      expect(tester.widget<Text>(find.text('偏高')).style!.color, c.high);
      expect(tester.widget<Text>(find.text('偏低')).style!.color, c.low);
      expect(find.text('正常'), findsNothing);
      // 减法稿 2026-09-22:不再画左侧状态色条。
      final lefts = decorations(tester)
          .map((d) => d.border)
          .whereType<Border>()
          .where((b) => b.left.width == 4)
          .toList();
      expect(lefts, isEmpty);
    });
  });

  group('MedChip', () {
    testWidgets('count 为 null 时只显示 label,不带数字', (tester) async {
      await tester.pumpWidget(
        wrap(MedChip(label: '只看异常', selected: true, onTap: () {})),
      );
      expect(find.text('只看异常'), findsOneWidget);
    });
  });

  testWidgets('空态虚线框能画出来 —— 规范 §六「空态必须给出路」的容器', (tester) async {
    await tester.pumpWidget(
      wrap(const DottedBorderBox(child: Text('还没有病历'))),
    );
    expect(find.text('还没有病历'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统字号放大后化验表照常排版,不写死像素', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MedMe.theme(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ReportContent(text: labText, docType: 'lab_report'),
            ),
          ),
        ),
      ),
    );
    final rich = tester.widget<RichText>(
      find.text('6.05 mmol/L', findRichText: true).first,
    );
    // 化验值是 body(15),放大 2× 后实际排版 30。
    expect(rich.textScaler.scale(15), 30);
    expect(tester.takeException(), isNull, reason: '放大后不许溢出/报错');
  });

  // 内容渲染有四条互不相干的分支(化验表 / 通用多空格表 / 用药清单 / 分节段落),
  // 上面只覆盖了化验表。**放大到 2× 才是真正的考验** —— 老年用户会一直开着,
  // 而横向挤的表格和固定高度的块正是在那时溢出的。
  group('其余内容分支在 1× 与 2× 下都不溢出', () {
    const generic =
        '项目    结果    单位    参考范围\n'
        '血压    120/80  mmHg    90-140\n'
        '心率    72      次/分   60-100\n'
        '体温    36.5    ℃       36-37.2\n';
    const prescription =
        'Rp.\n1. 阿莫西林胶囊 0.5g\n每次2粒,每日3次,饭后服\n'
        '2. 布洛芬缓释胶囊 0.3g\n每次1粒,每日2次\n医师:张三\n';
    const prose = '【主诉】反复咳嗽三周。\n病理诊断:慢性支气管炎。\n患者一般情况良好。';

    for (final scale in [1.0, 2.0]) {
      for (final (label, text, type) in [
        ('通用表格', generic, 'other'),
        ('用药清单', prescription, 'prescription'),
        ('分节段落', prose, 'clinical_note'),
        ('空文本', '', 'lab_report'),
      ]) {
        testWidgets('$label @$scale×', (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: MedMe.theme(),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: ReportContent(text: text, docType: type),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
