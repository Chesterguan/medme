// 品牌资源闸。brief §品牌 规定 logo 出现在四处、圆角 22%。
//
// 「用到没用到」的断言在 test/stage3_screens_test.dart(Task 16)—— 那里屏都做完了。
// 这里只守资源本身:文件在、声明了、圆角对、四档尺寸是 brief 的数。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';

void main() {
  test('logo 文件在,且声明进了 pubspec', () {
    expect(File(BrandLogo.assetPath).existsSync(), isTrue);
    expect(File('pubspec.yaml').readAsStringSync(), contains(BrandLogo.assetPath));
  });

  test('两档尺寸就是 brief 的数', () {
    expect(BrandLogo.topBar, 30);
    expect(BrandLogo.splash, 104);
  });

  testWidgets('圆角 22%,不是圆形也不是直角', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: Center(child: BrandLogo(size: 100)))));
    final clip = tester.widget<ClipRRect>(find.descendant(
        of: find.byType(BrandLogo), matching: find.byType(ClipRRect)));
    expect(clip.borderRadius, BorderRadius.circular(22));   // 22% × 100
    expect(tester.getSize(find.byType(BrandLogo)), const Size(100, 100));
  });

  testWidgets('默认 30px(主页顶栏那一档)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: BrandLogo()))));
    expect(tester.getSize(find.byType(BrandLogo)), const Size(30, 30));
    // 第二个尺寸点:100 那档 22% 恰好等于 22,分不清「按尺寸算」和「写死 22」。
    final clip = tester.widget<ClipRRect>(find.descendant(
        of: find.byType(BrandLogo), matching: find.byType(ClipRRect)));
    expect(clip.borderRadius, BorderRadius.circular(30 * 0.22));   // 6.6
  });
}
