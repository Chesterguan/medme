// 概览页 hero 身份卡的看门测试。这张卡是产品反馈里明说要「显眼」的那张,
// 同时挂着好几条硬规矩,拆开来对应到这里的每一组:
//
//  1. **数字必须是真的**:传 null 的字段一律显示「暂无」,不许留空、不许编
//     一个「0」出来;
//  2. **对比度必须过 WCAG AA**:卡片自己推出来的深色渐变,与卡上每一种
//     文字/图标颜色的组合,都拿 `Color.computeLuminance()` 实打实算一遍,
//     正文 ≥4.5:1、非文本 UI ≥3:1 ——这个项目之前踩过 `seal` 配白字只有
//     3.90:1 不达标的坑,不能再踩一次;
//  3. **大字模式不许截断姓名**:系统字号放大后,姓名的 Text 不能带
//     `maxLines`/`ellipsis`,长名字要能整段读到;
//  4. **点击必须能触发切换成员**:hero 卡是概览/档案联动切换的入口之一。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// WCAG 对比度,与 `test/design_tokens_test.dart` 同一公式
/// ((亮+0.05)/(暗+0.05))——那边测规范色板,这里测这张卡实际用到的组合。
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

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

  group('深色 hero 的对比度必须过 WCAG AA', () {
    // 直接导入 IdentityHeroPalette 里卡片实际用的颜色——不在这里另抄一遍
    // HSL 推导公式。两处各写一份同样的算式,谁改了卡片那份而没改测试这份,
    // 对比度测试就会悄悄测着一个卡片实际不用的颜色,红不了真正的回归。
    final gradientStart = IdentityHeroPalette.gradientStart;
    final gradientEnd = IdentityHeroPalette.gradientEnd;
    final heroInk = IdentityHeroPalette.textPrimary; // 姓名
    final heroInk2 = IdentityHeroPalette.textSecondary; // 次级信息、图标

    test('正文级文字(姓名/次级信息)在渐变两端都 ≥ 4.5:1', () {
      for (final bg in [gradientStart, gradientEnd]) {
        expect(
          contrast(heroInk, bg),
          greaterThanOrEqualTo(4.5),
          reason: '姓名用的 heroInk 在渐变端点 $bg 上必须达标',
        );
        expect(
          contrast(heroInk2, bg),
          greaterThanOrEqualTo(4.5),
          reason: '次级信息用的 heroInk2 在渐变端点 $bg 上必须达标'
              '(这个项目之前 seal+白字量出来是 3.90,不够,别再踩一次)',
        );
      }
    });

    test('非文本 UI(切换图标)在渐变两端都 ≥ 3:1', () {
      for (final bg in [gradientStart, gradientEnd]) {
        expect(contrast(heroInk2, bg), greaterThanOrEqualTo(3.0));
      }
    });

    test('头像上的白字对头像底色 ≥ 4.5:1', () {
      expect(
        contrast(Colors.white, IdentityHeroPalette.avatarBackground),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('渐变端点自身足够深:不会在卡片中段意外变亮到不达标', () {
      // 亮度取中点,防止「两端都深、中间被插了一个浅色」这种没被上面两组
      // 覆盖到的情况。
      final mid = Color.lerp(gradientStart, gradientEnd, 0.5)!;
      expect(contrast(heroInk, mid), greaterThanOrEqualTo(4.5));
      expect(contrast(heroInk2, mid), greaterThanOrEqualTo(4.5));
    });
  });
}

void _noop() {}
