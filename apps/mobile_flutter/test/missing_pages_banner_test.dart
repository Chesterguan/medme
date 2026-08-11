import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/screens/document_detail.dart';

/// 缺页横幅:漏页此前**只在导入那一刻的结果框里说过一次**,框一关就永远消失
/// —— 用户过一周回来看到的是一份「看起来正常」的病历,里面却有几页是空的。
/// 这组测试钉的就是「详情页必须一直把这件事摆在明处」。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: MedMe.theme(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('有缺页时:说出页数、列出页码、给出能点的按钮', (tester) async {
    await tester.pumpWidget(
      wrap(
        MissingPagesBanner(
          pages: const [2, 5, 7],
          reindexing: false,
          onReindex: () {},
        ),
      ),
    );
    // 页数要说,页码也要列 —— 只说「3 页」用户没法拿着原件对上是哪几页,
    // 也就判断不了丢的是化验结果那页还是封面。
    expect(find.textContaining('3 页'), findsOneWidget);
    expect(find.textContaining('2、5、7'), findsOneWidget);
    // 必须点得动:这条按钮的存在本身就是本次修复的全部意义。
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('必须说清后果 —— 医生看到的摘要也缺这几页', (tester) async {
    await tester.pumpWidget(
      wrap(
        MissingPagesBanner(
          pages: const [3],
          reindexing: false,
          onReindex: () {},
        ),
      ),
    );
    // 「文档内容少了」用户自己能看出来;「给医生看的摘要也少了」看不出来,
    // 而后者才是真正会影响就诊的那一半。这句话不许被优化掉。
    expect(find.textContaining('医生'), findsOneWidget);
  });

  testWidgets('正在识别时按钮禁掉,不让连点叠着跑', (tester) async {
    await tester.pumpWidget(
      wrap(
        MissingPagesBanner(
          pages: const [2],
          reindexing: true,
          onReindex: () {},
        ),
      ),
    );
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull, reason: '端上渲染+OCR 一页要几秒,连点会叠着跑');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('页码很多时省略,不把横幅撑成一屏', (tester) async {
    await tester.pumpWidget(
      wrap(
        MissingPagesBanner(
          pages: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
          reindexing: false,
          onReindex: () {},
        ),
      ),
    );
    expect(find.textContaining('11 页'), findsOneWidget);
    expect(find.textContaining('等'), findsOneWidget);
  });

  testWidgets('正在识别时要说到第几页 —— 不能只给一个不动的转圈', (tester) async {
    // 实测:一份 25 页扫描件在模拟器上跑了十几分钟,而界面全程只显示
    // 「正在导入 1/1」(那个 1/1 数的是文件数)。用户面对十分钟不动的转圈,
    // 只能认为 app 死了。这条钉住「按页报」这件事本身。
    await tester.pumpWidget(
      wrap(
        MissingPagesBanner(
          pages: const [3, 4, 5],
          reindexing: true,
          reindexPage: (2, 3),
          onReindex: () {},
        ),
      ),
    );
    expect(find.textContaining('2/3'), findsOneWidget);
  });

  testWidgets('刚点下、还没开始报页时,退化成一句不确定进度的话', (tester) async {
    await tester.pumpWidget(
      wrap(
        MissingPagesBanner(
          pages: const [3],
          reindexing: true,
          onReindex: () {},
        ),
      ),
    );
    expect(find.textContaining('正在重新识别'), findsOneWidget);
  });
}
