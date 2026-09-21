// 字体闸。brief §字:数字/字母 = Manrope(只 500、600),中文 = 系统苹方 /
// 系统默认,**不打包 Noto**。
//
// 为什么要测:打包一份中文字体是 20 MB 起步的事,而它会在某次「顺手修一下字重」
// 里悄悄进来。这个测试扫 pubspec,不扫渲染 —— 渲染看不出字体是打包的还是系统的。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  test('不打包任何中文字体', () {
    for (final banned in ['Noto', 'noto', 'SourceHan', 'PingFang.ttf', 'HarmonyOS']) {
      expect(pubspec.contains(banned), isFalse, reason: '$banned 不该进包');
    }
  });

  test('只打包 Manrope 一个字族', () {
    final families = RegExp(r'^\s*- family:\s*(\S+)', multiLine: true)
        .allMatches(pubspec).map((m) => m.group(1)).toList();
    expect(families, ['Manrope']);
  });

  test('字体文件真的在,且只有一个 ttf', () {
    final ttfs = Directory('assets/fonts').listSync()
        .where((f) => f.path.endsWith('.ttf')).map((f) => f.path).toList();
    expect(ttfs, ['assets/fonts/Manrope[wght].ttf']);
  });

  test('MedType 只用 500 / 600 两档轴值', () {
    const styles = <TextStyle>[
      MedType.display, MedType.title, MedType.subtitle,
      MedType.body, MedType.value, MedType.secondary, MedType.caption,
    ];
    for (final s in styles) {
      for (final v in s.fontVariations ?? const <FontVariation>[]) {
        expect(v.axis, 'wght');
        expect(v.value, anyOf(500.0, 600.0), reason: '只许 500 / 600');
      }
    }
  });

  test('数值样式一律带 tabular figures —— 小数点要对齐', () {
    expect(MedType.value.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(MedType.display.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('主题把 Manrope 挂上去,中文回落到系统', () {
    final t = MedMe.theme();
    expect(t.textTheme.bodyMedium!.fontFamily, 'Manrope');
    expect(t.textTheme.bodyMedium!.fontFamilyFallback, contains('PingFang SC'));
  });
}
