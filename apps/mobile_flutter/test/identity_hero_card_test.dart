// 概览页 hero 身份卡的看门测试。这张卡是产品反馈里明说要「显眼」的那张,
// 同时挂着好几条硬规矩,拆开来对应到这里的每一组:
//
//  1. **数字必须是真的**:传 null 的字段一律显示「暂无」,不许留空、不许编
//     一个「0」出来;
//  2. **卡面文字颜色是确定性的**:非装饰性文字一律 `Colors.white`,压在
//     `MedBrand.gradientColors` 上(见预检裁定 R11)——不再对渐变端点实测
//     WCAG 对比度(那套 `IdentityHeroPalette` 已删,见 Stage 3 视觉令牌
//     brief Task 4);
//  3. **大字模式不许截断姓名**:系统字号放大后,姓名的 Text 不能带
//     `maxLines`/`ellipsis`,长名字要能整段读到;
//  4. **点击必须能触发切换成员**:hero 卡是概览/档案联动切换的入口之一。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  group('每一个数字都是真的,缺失说「暂无」不留空', () {
    testWidgets('性别/年龄/份数照实显示', (tester) async {
      await tester.pumpWidget(
        wrap(
          IdentityHeroCard(
            name: '张建国(示例)',
            gender: '男',
            age: '59岁',
            recordCount: 22,
            recentVisitDate: '2024-03-01',
            onSwitchMember: () {},
          ),
        ),
      );
      expect(find.text('张建国(示例)'), findsOneWidget);
      expect(find.textContaining('男'), findsOneWidget);
      expect(find.textContaining('59岁'), findsOneWidget);
      expect(find.textContaining('22 份记录'), findsOneWidget);
      expect(find.textContaining('2024-03-01'), findsOneWidget);
    });

    testWidgets('没有就诊记录时显示「暂无」,不是空白也不是「0」', (tester) async {
      await tester.pumpWidget(
        wrap(
          IdentityHeroCard(
            name: '我',
            gender: null,
            age: null,
            recordCount: 0,
            recentVisitDate: null,
            onSwitchMember: () {},
          ),
        ),
      );
      expect(find.textContaining('暂无'), findsOneWidget);
      expect(find.textContaining('0 份记录'), findsOneWidget, reason: '份数是 0 就照实显示 0,不是隐藏这一行');
    });

    testWidgets('日期字段解析不出来时也归为「暂无」,不显示脏数据', (tester) async {
      await tester.pumpWidget(
        wrap(
          IdentityHeroCard(
            name: '我',
            gender: '女',
            age: '30岁',
            recordCount: 1,
            recentVisitDate: '不是日期',
            onSwitchMember: () {},
          ),
        ),
      );
      expect(find.textContaining('暂无'), findsOneWidget);
    });
  });

  group('点击是切换成员的入口', () {
    testWidgets('整卡可点,触发 onSwitchMember', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          IdentityHeroCard(
            name: '我',
            gender: '男',
            age: '40岁',
            recordCount: 5,
            recentVisitDate: null,
            onSwitchMember: () => tapped = true,
          ),
        ),
      );
      await tester.tap(find.byType(IdentityHeroCard));
      expect(tapped, isTrue);
    });
  });

  group('大字模式不许截断姓名', () {
    testWidgets('姓名的 Text 不带 maxLines / ellipsis', (tester) async {
      const longName = '欧阳建国·爱新觉罗·示例长姓名测试用';
      await tester.pumpWidget(
        wrap(
          const IdentityHeroCard(
            name: longName,
            gender: '男',
            age: '80岁',
            recordCount: 3,
            recentVisitDate: null,
            onSwitchMember: _noop,
          ),
          textScale: 3.0,
        ),
      );
      expect(tester.takeException(), isNull, reason: '3× 字号也不许溢出/报错');
      final nameText = tester.widget<Text>(find.text(longName));
      expect(nameText.maxLines, isNull, reason: '不设行数上限,允许换行');
      expect(
        nameText.overflow,
        isNot(TextOverflow.ellipsis),
        reason: '姓名不许被省略号截断——这是这张卡专门被要求守住的一条',
      );
    });
  });

  group('hero 卡面的文字颜色规则(预检裁定 R11,取代旧的 WCAG 对比度实测)', () {
    // 旧版本这里直接导入 `IdentityHeroPalette` 算出来的深色渐变端点,拿
    // `Color.computeLuminance()` 对每种文字/图标颜色实测 WCAG 对比度。Stage 3
    // 视觉令牌 brief 把卡片换成了全 app 统一收口的品牌渐变(`HeroCard` →
    // `BrandGradientBox`,见 `widgets/brand_surfaces.dart`),那套渐变最亮的
    // 一段 #1FB0C6 上压白字只有 2.4:1,达不到 AA——`IdentityHeroPalette` 已经
    // 整个删掉,不再有渐变端点可测。
    //
    // 取而代之的是一条确定性规则(R11):**非装饰性文字一律 `Colors.white`,
    // 压在渐变里 `#1789C1` 及更深的一段上**,不做像素取色、不算对比度公式。
    // 几何前提(不在这里验证,只record 为什么这条规则站得住):渐变
    // 135°(`gradientBegin` = 左上)从最亮的 #1FB0C6 铺到最深的 #16508E;
    // 头像固定占住卡片左上角——正是渐变最亮的那个角——姓名与「最近就诊」
    // 这些非装饰性文字都排在头像右侧、渐变中点(#1789C1)之后的区域,所以
    // 白字实际压的是中段及更深的颜色,不是最亮那一角。
    testWidgets('卡面是实色 sealInk,没有渐变(减法稿 2026-09-22)', (tester) async {
      await tester.pumpWidget(wrap(IdentityHeroCard(
        name: '我',
        gender: '男',
        age: '40岁',
        recordCount: 5,
        recentVisitDate: null,
        onSwitchMember: () {},
      )));
      final m = tester.widget<Material>(find.descendant(
        of: find.byType(HeroCard), matching: find.byType(Material)).first);
      expect(m.color, MedColors.light.sealInk);
      expect(
        find.byWidgetPredicate((w) => w is Ink && (w.decoration as BoxDecoration?)?.gradient != null),
        findsNothing,
      );
    });

    testWidgets('非装饰性文字(姓名、最近就诊数值)一律 Colors.white', (tester) async {
      await tester.pumpWidget(wrap(IdentityHeroCard(
        name: '张建国(示例)',
        gender: '男',
        age: '59岁',
        recordCount: 22,
        recentVisitDate: '2024-03-01',
        onSwitchMember: () {},
      )));
      expect(tester.widget<Text>(find.text('张建国(示例)')).style!.color, Colors.white,
          reason: '姓名是这张卡最关键的信息,渐变中段之后必须是不透明白字');
      expect(tester.widget<Text>(find.text('2024-03-01')).style!.color, Colors.white,
          reason: '「最近就诊」的大数字同一档待遇');
    });

    testWidgets('次级文字/图标是白字降透明度,不是另配一个颜色', (tester) async {
      await tester.pumpWidget(wrap(IdentityHeroCard(
        name: '我',
        gender: '男',
        age: '40岁',
        recordCount: 5,
        recentVisitDate: null,
        onSwitchMember: () {},
      )));
      expect(tester.widget<Text>(find.textContaining('5 份记录')).style!.color,
          Colors.white.withValues(alpha: 0.88));
      // R18:这一行的标签改用了 MedColors.onDarkMeta = Color(0xE0FFFFFF) 令牌
      // (仍是白 88%,只是不再内联)。不能再拿 Colors.white.withValues(alpha:
      // 0.88) 比:新版 Color 是浮点内部表示,0xE0/255 = 0.878431… 和字面量
      // 0.88 在 == 下不是同一个浮点数,尽管两者量化到 8 位都是同一个字节
      // 0xE0,渲染出来是同一个颜色。
      expect(tester.widget<Text>(find.text('最近就诊 · ')).style!.color,
          MedColors.light.onDarkMeta);
      expect(tester.widget<Icon>(find.byIcon(Icons.unfold_more)).color,
          Colors.white.withValues(alpha: 0.9));
    });
  });

  group('review fix round 1(Minor):「最近就诊」标签与数值合并成一个读屏节点', () {
    // 标签(「最近就诊 · 」)与数值(日期/「暂无」)拆成两个 Text 之后,不加
    // MergeSemantics 会让读屏在这一行停两次。这条钉住 MergeSemantics 确实包住
    // 了这一整行——不是「有没有拆」的问题(拆分本身是 mockup 要的两档字号),
    // 是「拆了之后读屏体验有没有补回来」的问题。
    testWidgets('标签与数值同属一个 MergeSemantics', (tester) async {
      await tester.pumpWidget(wrap(IdentityHeroCard(
        name: '我',
        gender: '男',
        age: '40岁',
        recordCount: 5,
        recentVisitDate: '2024-03-01',
        onSwitchMember: () {},
      )));
      final merged = find.byType(MergeSemantics);
      expect(merged, findsOneWidget);
      expect(
        find.descendant(of: merged, matching: find.text('最近就诊 · ')),
        findsOneWidget,
        reason: '标签必须在 MergeSemantics 里面',
      );
      expect(
        find.descendant(of: merged, matching: find.text('2024-03-01')),
        findsOneWidget,
        reason: '数值也必须在同一个 MergeSemantics 里面,两者才合并成一个节点',
      );
    });
  });

  group('R18:头像块按 mockup 修白底 54/14/28,「最近就诊」值 22/600', () {
    testWidgets(
      '头像白底 54×54/圆角14/投影;首字母 28·600·seal;数值 22·600·白;标签 onDarkMeta',
      (tester) async {
        await tester.pumpWidget(wrap(IdentityHeroCard(
          name: '张建国(示例)',
          gender: '男',
          age: '59岁',
          recordCount: 22,
          recentVisitDate: '2024-03-01',
          onSwitchMember: () {},
        )));

        // 头像白底:旧版本是 Stack 里一个没有 child、没有显式宽高的
        // ColoredBox——非 Positioned 子项走 StackFit.loose,没有 child 可借
        // 尺寸,收缩成 0×0,品牌渐变直接透出来。这里钉住渲染尺寸(不止声明值),
        // 回归了会直接红。
        final tileFinder = find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).color == Colors.white);
        expect(
          tileFinder,
          findsOneWidget,
          reason: '白底 Container 只有头像这一个——渐变面的光晕用的是 gradient,不是纯色',
        );
        expect(
          tester.getSize(tileFinder),
          const Size(MedBrand.heroTileSize, MedBrand.heroTileSize),
        );
        final tileDeco = tester.widget<Container>(tileFinder).decoration! as BoxDecoration;
        expect(tileDeco.borderRadius, BorderRadius.circular(MedShape.radiusBlock));
        expect(tileDeco.boxShadow, MedBrand.heroTileShadow);

        final letterStyle = tester.widget<Text>(find.text('张')).style!;
        expect(letterStyle.fontSize, MedBrand.heroTileLetterSize);
        expect(letterStyle.fontWeight, FontWeight.w600);
        expect(letterStyle.fontVariations, MedType.w600);
        expect(letterStyle.color, MedColors.light.seal);

        final valueStyle = tester.widget<Text>(find.text('2024-03-01')).style!;
        expect(valueStyle.fontSize, 22);
        expect(valueStyle.fontWeight, FontWeight.w600);
        expect(valueStyle.fontVariations, MedType.w600);
        expect(valueStyle.color, Colors.white);

        final labelStyle = tester.widget<Text>(find.text('最近就诊 · ')).style!;
        expect(labelStyle.fontSize, 14);
        expect(labelStyle.color, MedColors.light.onDarkMeta);
      },
    );
  });
}

void _noop() {}
