// 「一份病历」(s8)+ 「还没核对」底栏(s7)的视觉验收(R22 fix round 1)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';
import 'package:mobile_flutter/widgets/report_content.dart';
import 'stage3_visual_helpers.dart';

DocumentDetailDto _detail({required String docType, required String ocrText}) =>
    DocumentDetailDto(
      document: DocumentSummaryDto(
        id: 1,
        docType: docType,
        pageCount: 1,
        provider: '协和医院',
        docDate: '2026-03-14',
      ),
      sourceFile: const SourceFileMetaDto(
        id: 1,
        originalName: '化验单.jpg',
        mimeType: 'image/jpeg',
        byteSize: 0,
        importedAt: '2026-03-14',
      ),
      ocrText: ocrText,
    );

void main() {
  testWidgets('抬头卡:一枚 MedIcon,MedCard 外壳,渐变预算 0', (
    tester,
  ) async {
    await pumpStage3(
      tester,
      Scaffold(body: DetailBody(detail: _detail(docType: 'lab_report', ocrText: '正文'))),
    );
    expect(find.byType(MedIcon), findsWidgets);
    // 抬头卡本身是 MedCard(1px line 细边、无阴影),这条自动满足,顺带钉一下。
    expect(find.byType(MedCard), findsWidgets);
    // 这一屏渐变预算是 0(brief 的每屏预算表:一份病历 s8 = 0/0/0)。
    expectSurfaceBudget();
  });

  testWidgets('抬头卡「查看原件」是 MedSecondaryButton,不是 OutlinedButton', (tester) async {
    await pumpStage3(
      tester,
      Scaffold(body: DetailBody(detail: _detail(docType: 'lab_report', ocrText: '正文'))),
    );
    expect(find.widgetWithText(MedSecondaryButton, '查看原件'), findsOneWidget);
  });

  testWidgets('「还没核对」底栏:看原件=MedSecondaryButton,没问题=MedPrimaryButton(预算=1)', (
    tester,
  ) async {
    var viewed = false, confirmed = false;
    await pumpStage3(
      tester,
      Scaffold(
        body: const SizedBox(),
        bottomNavigationBar: DocumentReviewActionBar(
          onViewOriginal: () => viewed = true,
          onConfirm: () => confirmed = true,
        ),
      ),
    );
    expect(find.widgetWithText(MedSecondaryButton, '看原件'), findsOneWidget);
    expect(find.widgetWithText(MedPrimaryButton, '没问题'), findsOneWidget);
    // 颜色面预算表:s7 = 1 颗 MedPrimaryButton,没有 HeroCard。
    expectSurfaceBudget(button: 1);

    await tester.tap(find.text('看原件'));
    expect(viewed, isTrue, reason: '「看原件」回调没接上');
    await tester.tap(find.text('没问题'));
    expect(confirmed, isTrue, reason: '「没问题」回调没接上');
  });

  testWidgets('化验表格行:无 4px 色条,偏高/偏低是上色的状态词,正常不上色不加字', (
    tester,
  ) async {
    const c = MedColors.light;
    // 与 report_content_test.dart 已验证过的形状一致(单空格、表头 + 连续
    // 数据行),只是名字换成好认的测试夹具,不是真的化验项目。
    const header = '项目缩写 项目名称 结果 单位 参考范围 提示';
    const rows = [
      'H1 高值项目 12.0 mg/L 1.0 - 5.0 ↑',
      'L1 低值项目 0.5 mg/L 1.0 - 5.0 ↓',
      'N1 正常项目 3.0 mg/L 1.0 - 5.0 正常',
    ];
    await pumpStage3(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: ReportContent(
            text: [header, ...rows].join('\n'),
            docType: 'lab_report',
          ),
        ),
      ),
    );
    expect(tester.widget<Text>(find.text('偏高')).style!.color, c.high);
    expect(tester.widget<Text>(find.text('偏低')).style!.color, c.low);
    expect(find.text('正常'), findsNothing);
    final hasLeftBar = tester
        .widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration)
        .whereType<BoxDecoration>()
        .any((d) => d.border is Border && (d.border! as Border).left.width == 4);
    expect(hasLeftBar, isFalse, reason: '减法稿:化验表格行不再画左侧色条');
  });

  testWidgets('抬头卡在两种尺寸×两档字号都不溢出(长机构名/长来源文件名/长正文)', (tester) async {
    final longDetail = DocumentDetailDto(
      document: DocumentSummaryDto(
        id: 1,
        docType: 'imaging_report',
        pageCount: 1,
        provider: '北京协和医院放射科·发热门诊联合会诊中心',
        docDate: '2026-03-14',
      ),
      sourceFile: const SourceFileMetaDto(
        id: 1,
        originalName: 'IMG_20260314_胸部CT平扫加增强扫描报告单最终版.jpg',
        mimeType: 'image/jpeg',
        byteSize: 0,
        importedAt: '2026-03-14',
      ),
      ocrText: '影像所见:双肺纹理增粗,建议随诊复查。\n影像诊断:双肺感染性病变可能,建议结合临床。',
    );
    await expectNoOverflowAtBothSizes(
      tester,
      Scaffold(body: DetailBody(detail: longDetail)),
    );
  });
}
