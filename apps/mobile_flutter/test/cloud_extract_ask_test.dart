// 「云端整理」第一次添加病历时问一次(ia-proposal §7 决定 5)。
//
// 这一屏是隐私政策、Info.plist、App Store 描述三处「照片会送云端」站得住的
// 唯一依据 —— 所以它被钉住的是:只问一次、不预设默认、两条路都记得住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';

void main() {
  group('问不问', () {
    test('没登录不问 —— 没有账号就没有云端,问了也没意义', () {
      expect(shouldAskCloudExtract(loggedIn: false, asked: false), isFalse);
    });
    test('登录了、没问过 → 问', () {
      expect(shouldAskCloudExtract(loggedIn: true, asked: false), isTrue);
    });
    test('问过就不再问 —— 一次性,不是每次导入都弹', () {
      expect(shouldAskCloudExtract(loggedIn: true, asked: true), isFalse);
    });
  });

  group('sheet 本体', () {
    testWidgets('两颗按钮点击行为不预设默认答案;说清楚送出去的是什么', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: MedMe.theme(), home: const Scaffold(body: CloudExtractAskBody())),
      );
      expect(find.text('开,帮我整理'), findsOneWidget);
      expect(find.text('不开'), findsOneWidget);
      // Stage 3(task-14):s17 渐变预算 = 1 颗主按钮,「开,帮我整理」视觉上比
      // 「不开」重一点(brief 明确点名的那颗)——但两颗仍是各自独立的按钮,
      // 谁都不是提前选好的默认值,点哪颗都是用户自己按的那一下才算数。
      expect(find.byType(MedPrimaryButton), findsOneWidget);
      expect(find.byType(MedSecondaryButton), findsOneWidget);
      // 必须说出:先在本机涂掉身份信息,再送出去。
      expect(find.textContaining('涂黑'), findsOneWidget);
      expect(find.textContaining('「我 → 云端」随时改'), findsOneWidget);
    });

    testWidgets('2× 字号不溢出', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(body: SingleChildScrollView(child: CloudExtractAskBody())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
