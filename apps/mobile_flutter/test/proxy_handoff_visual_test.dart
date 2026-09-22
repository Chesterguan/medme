// R27:mockup s14「替病人代拍」——生成取件码后交给病人看的那张对话框
// (`showDoctorClaimLinkDialog` → `link_qr_dialog.dart` 的 `showLinkQrDialog`)。
// 这是「取件码 / QR 实际渲染的地方」——`proxy_intake_flow.dart` 本身只在
// `_PendingListStep` 按下「生成取件码,交给病人」后调用它,不自己画码。
//
// `showLinkQrDialog` 同时服务另一条路(账户页 B5「把这份病历交给别人」),
// 那条路没有 `hero: true`,样式必须像改动前一样——不在这个文件里重复断言,
// `test/account_screen_test.dart` 的 B5 用例已经覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/doctor/doctor_claim_link_dialog.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

import 'stage3_visual_helpers.dart';

/// 触发对话框的最小外壳。`showDoctorClaimLinkDialog` 本身是纯函数(只吃字符串
/// /回调,不碰 FFI/vault),不需要像 `ForDoctorActions`/`VisitSummaryBody` 那样
/// 把私有 body 提出来——它已经是可以直接从测试调用的公开顶层函数。
class _Harness extends StatelessWidget {
  const _Harness({required this.recordCount, required this.url});

  final int recordCount;
  final String url;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        key: const Key('open_handoff'),
        onPressed: () => showDoctorClaimLinkDialog(
          context,
          url,
          recordCount,
          shareOrigin: () => Rect.zero,
        ),
        child: const Text('open'),
      ),
    ),
  );
}

/// 「长文件数 + 4 位数」的写实数据:mockup 示例是「取件码 4829」,这里没有
/// 单独的取件码文字元素(见 task-13b-report.md),但 body 文案里的份数
/// (`共 $recordCount 份记录…`)与 URL 长度都按同一个数量级给够压力。
const _kRecordCount = 4829;
const _kUrl =
    'https://medme.example/c#c1.doctorHandoffFixtureId0123456789abcdef.'
    'aVeryLongResumableUploadKeyBase64Fixture1234567890ABCDEFGHIJKLMN==';

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open_handoff')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('代拍交付对话框:一张 HeroCard 包住 MedQrFrame,零主入口块/主按钮', (tester) async {
    await pumpStage3(
      tester,
      const _Harness(recordCount: _kRecordCount, url: _kUrl),
    );
    await _openDialog(tester);

    expectSurfaceBudget(hero: 1);
    expect(find.byType(MedQrFrame), findsOneWidget);
  });

  testWidgets('复制链接换成 MedSecondaryButton(mockup .btn.ghost)', (tester) async {
    await pumpStage3(
      tester,
      const _Harness(recordCount: _kRecordCount, url: _kUrl),
    );
    await _openDialog(tester);

    expect(find.byType(MedSecondaryButton), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
  });

  testWidgets('分享按钮原样是 FilledButton(不占主按钮预算),关闭原样是 TextButton', (tester) async {
    await pumpStage3(
      tester,
      const _Harness(recordCount: _kRecordCount, url: _kUrl),
    );
    await _openDialog(tester);

    expect(find.widgetWithText(FilledButton, '发给病人'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '关闭'), findsOneWidget);
  });

  testWidgets('两个尺寸 × 两档字号,开对话框都不溢出', (tester) async {
    for (final size in kStage3Sizes) {
      for (final scale in [1.0, 2.0]) {
        await pumpStage3(
          tester,
          const _Harness(recordCount: _kRecordCount, url: _kUrl),
          size: size,
          textScale: scale,
        );
        await _openDialog(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '$size @ ${scale}x 溢出了',
        );
        // `pumpStage3` 复用同一个 Navigator(`pumpWidget` 换的是同类型的
        // `MaterialApp`,元素树被复用),不关掉这次的对话框,下一轮的
        // 「open_handoff」就会被这一轮还开着的对话框挡住,点不到。
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      }
    }
  });
}
