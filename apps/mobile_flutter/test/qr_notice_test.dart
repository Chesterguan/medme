// 第一次出码时告知一次(创始人拍板,取代「未登录不给出码」)。
//
// 钉三件事:①「第一次」的判断只看 seen,不看登录;② 那句话逐字出现;
// ③ 两颗按钮各自返回什么。文案是对外承诺(与隐私政策第三节第 3 项同一件事),
// 改了就得回去改政策 —— 所以这里按逐字钉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/qr_notice_sheet.dart';
import 'package:mobile_flutter/theme.dart';

void main() {
  group('问不问', () {
    test('这台设备没见过 → 问', () {
      expect(shouldShowQrNotice(seen: false), isTrue);
    });
    test('见过就不再问 —— 一次性,不是每次出码都弹', () {
      expect(shouldShowQrNotice(seen: true), isFalse);
    });
  });

  group('sheet 本体', () {
    testWidgets('那句话逐字出现,两颗按钮都在', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const Scaffold(body: QrNoticeBody()),
        ),
      );
      expect(
        find.text('会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看;我们打不开。'),
        findsOneWidget,
      );
      expect(find.text('好,出码'), findsOneWidget);
      expect(find.text('先不出'), findsOneWidget);
      // 旧方案的痕迹一处都不许留:不拦登录、不报状态码。
      expect(find.textContaining('先登录'), findsNothing);
      expect(find.textContaining('403'), findsNothing);
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
            child: Scaffold(body: SingleChildScrollView(child: QrNoticeBody())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
