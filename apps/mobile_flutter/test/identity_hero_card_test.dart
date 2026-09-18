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
import 'package:mobile_flutter/widgets/brand_gradient.dart';
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
    // `BrandGradientBox`,见 `widgets/brand_gradient.dart`),那套渐变最亮的
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
    testWidgets('渐变是 MedBrand.gradientColors,135°(begin=左上,头像占住这个角)', (tester) async {
      await tester.pumpWidget(wrap(IdentityHeroCard(
        name: '我',
        gender: '男',
        age: '40岁',
        recordCount: 5,
        recentVisitDate: null,
        onSwitchMember: () {},
      )));
      final box = tester.widget<Container>(find.descendant(
        of: find.byType(BrandGradientBox), matching: find.byType(Container)).first);
      final g = (box.decoration! as BoxDecoration).gradient! as LinearGradient;
      expect(g.colors, MedBrand.gradientColors);
      expect(g.begin, MedBrand.gradientBegin);
      expect(g.begin, Alignment.topLeft);
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
      expect(tester.widget<Text>(find.text('最近就诊 · ')).style!.color,
          Colors.white.withValues(alpha: 0.88));
      expect(tester.widget<Icon>(find.byIcon(Icons.unfold_more)).color,
          Colors.white.withValues(alpha: 0.9));
    });
  });
}

void _noop() {}
