// 主页顶部「你是谁,现在看的是谁」那一行(`MemberHeader`)的看门测试。这一行取代了
// 原来的品牌渐变身份卡(`IdentityHeroCard`,减法稿 2026-09-22)——挂着的硬规矩不变,
// 只是从一整张卡收成一行文字 + 一对 `⌃⌄`:
//
//  1. **数字必须是真的**:传 null 的字段一律显示「暂无」,不许留空、不许编
//     一个「0」出来;
//  2. **大字模式不许截断姓名**:系统字号放大后,姓名的 Text 不能带
//     `maxLines`/`ellipsis`,长名字要能整段读到;
//  3. **点击必须能触发切换成员**:这一行是概览/档案联动切换成员的入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/member_header.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Future<void> pump(WidgetTester t, Widget child, {double textScale = 1.0}) =>
    t.pumpWidget(wrap(child, textScale: textScale));

void main() {
  group('每一个数字都是真的,缺失说「暂无」不留空', () {
    testWidgets('性别/年龄/份数照实显示', (tester) async {
      await pump(
        tester,
        MemberHeader(
          name: '张建国(示例)',
          gender: '男',
          age: '59岁',
          recordCount: 22,
          recentVisitDate: '2024-03-01',
          onSwitchMember: () {},
        ),
      );
      expect(find.text('张建国(示例)'), findsOneWidget);
      expect(find.textContaining('男'), findsOneWidget);
      expect(find.textContaining('59岁'), findsOneWidget);
      expect(find.textContaining('22 份记录'), findsOneWidget);
      expect(find.textContaining('2024-03-01'), findsOneWidget);
    });

    testWidgets('没有就诊记录时显示「暂无」,不是空白也不是「0」', (tester) async {
      await pump(
        tester,
        MemberHeader(
          name: '我',
          gender: null,
          age: null,
          recordCount: 0,
          recentVisitDate: null,
          onSwitchMember: () {},
        ),
      );
      expect(find.textContaining('暂无'), findsOneWidget);
      expect(find.textContaining('0 份记录'), findsOneWidget, reason: '份数是 0 就照实显示 0,不是隐藏这一行');
    });

    testWidgets('日期字段解析不出来时也归为「暂无」,不显示脏数据', (tester) async {
      await pump(
        tester,
        MemberHeader(
          name: '我',
          gender: '女',
          age: '30岁',
          recordCount: 1,
          recentVisitDate: '不是日期',
          onSwitchMember: () {},
        ),
      );
      expect(find.textContaining('暂无'), findsOneWidget);
    });
  });

  group('点整行 → onSwitchMember', () {
    testWidgets('整行可点,触发 onSwitchMember', (tester) async {
      var tapped = false;
      await pump(
        tester,
        MemberHeader(
          name: '我',
          gender: '男',
          age: '40岁',
          recordCount: 5,
          recentVisitDate: null,
          onSwitchMember: () => tapped = true,
        ),
      );
      await tester.tap(find.byType(MemberHeader));
      expect(tapped, isTrue);
    });
  });

  group('3× 字号姓名不截断', () {
    testWidgets('姓名的 Text 不带 maxLines / ellipsis', (tester) async {
      const longName = '欧阳建国·爱新觉罗·示例长姓名测试用';
      await pump(
        tester,
        const MemberHeader(
          name: longName,
          gender: '男',
          age: '80岁',
          recordCount: 3,
          recentVisitDate: null,
          onSwitchMember: _noop,
        ),
        textScale: 3.0,
      );
      expect(tester.takeException(), isNull, reason: '3× 字号也不许溢出/报错');
      final nameText = tester.widget<Text>(find.text(longName));
      expect(nameText.maxLines, isNull, reason: '不设行数上限,允许换行');
      expect(
        nameText.overflow,
        isNot(TextOverflow.ellipsis),
        reason: '姓名不许被省略号截断——这是这一行专门被要求守住的一条',
      );
    });
  });

  testWidgets('一行元数据:性别 · 年龄 · N 份记录 · 最近就诊 · 日期,ink3、tabular', (t) async {
    final handle = t.ensureSemantics();
    await pump(t, MemberHeader(name: '张建国', gender: '男', age: '59', recordCount: 52,
        recentVisitDate: '2026-09-18', onSwitchMember: () {}));
    final meta = t.widget<Text>(find.text('男 · 59 · 52 份记录 · 最近就诊 · 2026-09-18'));
    expect(meta.style!.color, MedColors.light.ink3);
    expect(meta.style!.fontFeatures, MedType.tabular);
    expect(find.byType(HeroCard), findsNothing);

    final nameStyle = t.widget<Text>(find.text('张建国')).style!;
    expect(nameStyle.fontSize, 16);
    expect(nameStyle.fontWeight, FontWeight.w600);
    expect(nameStyle.color, MedColors.light.ink);
    expect(find.byIcon(Icons.unfold_more), findsOneWidget);
    // Semantics 节点会把没有 excludeSemantics 的子节点(姓名/元数据两个 Text)
    // 合并进这一个节点,换行拼在显式 label 后面——精确匹配整串会跟着子文本
    // 一起碎;用正则找子串,只钉「这句 label 在」这一件事。
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape('当前查看:张建国。点击切换成员'))),
      findsOneWidget,
    );
    // 必须在 testWidgets body 内同步 dispose——`_endOfTestVerifications` 检查
    // SemanticsHandle 是否已释放,跑在 addTearDown 的回调之前,用 addTearDown
    // 会被判定为「测试结束时还有一个活着的 handle」而红。
    handle.dispose();
  });
}

void _noop() {}
