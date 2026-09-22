import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';

Future<void> pump(WidgetTester t, Widget w, {double scale = 1.0}) => t.pumpWidget(MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: Scaffold(body: w))));

void main() {
  testWidgets('44 槽、22 图标、默认 ink2', (t) async {
    await pump(t, const MedIcon(Icons.science_outlined));
    final box = t.getSize(find.byType(MedIcon));
    expect(box, const Size(44, 44));
    final icon = t.widget<Icon>(find.byType(Icon));
    expect(icon.size, 22);
    expect(icon.color, MedColors.light.ink2);
  });

  testWidgets('只有这一行在报警时才传色', (t) async {
    await pump(t, MedIcon(Icons.delete_outline, color: MedColors.light.critical));
    expect(t.widget<Icon>(find.byType(Icon)).color, MedColors.light.critical);
  });

  testWidgets('MedAvatar:line2 圆底 + ink2 首字,3× 字号不放大不溢出', (t) async {
    await pump(t, const MedAvatar('李'), scale: 3.0);
    expect(t.getSize(find.byType(MedAvatar)), const Size(44, 44));
    final d = t.widget<DecoratedBox>(find.byType(DecoratedBox)).decoration as BoxDecoration;
    expect(d.color, MedColors.light.line2);
    expect(d.shape, BoxShape.circle);
    expect(t.widget<Text>(find.text('李')).style!.color, MedColors.light.ink2);
    expect(t.takeException(), isNull);
  });

  test('没有渐变、没有阴影可传', () {
    // 编译期就没有这些参数;这条只是把意图写进测试名。
    expect(const MedIcon(Icons.add).size, 22);
  });
}
