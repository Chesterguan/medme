// 用户视角六:**笔记用户**。
//
// **硬不变量**:笔记绝不进「复制全文给医生」那份纯文本,也不进二维码分享
// (见 `vault_projections.rs` 的 `VisitNoteDto` 文档与 Rust 单测
// `notes_never_enter_the_doctor_facing_plain_text_but_do_enter_recent_notes`)。
// 这里在**真机 + 真实保险箱**上再钉一道:Rust 单测钉的是投影函数,这一条钉的是
// 「从 UI 存进去的笔记,到 UI 复制出来的那段字」这条完整链路。
//
// 输入覆盖:空笔记、超长(3000+ 字)、纯 emoji、含换行、`<script>` 注入串。
//
//     flutter test integration_test/journey_notes_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/vault_events.dart';

import 'harness.dart';

const kInjection = '<script>alert("xss")</script>&<b>粗体</b>';
const kEmoji = '😀😀😀🩺💊🏥';
final kLong = '复诊要问的问题:${'这个药还要吃多久?' * 300}';
const kMultiline = '第一行:昨天开始头晕\n第二行:早上量血压 160/95\n第三行:要不要换药?';

Future<void> openNoteEntry(WidgetTester tester) async {
  await gotoTab(tester, HomeTab.overview);
  await waitFor(tester, find.text('记录'));
  await tester.tap(find.text('记录').first);
  await settle(tester);
  await waitFor(tester, find.text('保存'));
  await tester.tap(find.text('笔记').first);
  await settle(tester);
}

Future<void> openVisitSheet(WidgetTester tester) async {
  await gotoTab(tester, HomeTab.overview);
  await waitFor(tester, find.text('看病带这个'));
  await tester.tap(find.text('看病带这个').first);
  await settle(tester, total: const Duration(seconds: 3));
  await waitFor(tester, find.text('复制全文给医生'));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空笔记存不进去', (tester) async {
    await bootApp(tester);
    await openNoteEntry(tester);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settle(tester);
    expect(find.text('请输入笔记内容'), findsOneWidget);
    expect((await patientProfile()).recordCount, 0);

    // 纯空格也算空。
    await tester.enterText(find.byType(TextField).first, '     ');
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settle(tester);
    expect(find.text('请输入笔记内容'), findsOneWidget, reason: '纯空格笔记被存进去了');
    expect((await patientProfile()).recordCount, 0);
  });

  testWidgets('超长 / emoji / 换行 / 注入串 —— 存得进、显示得出、且绝不进纯文本', (
    tester,
  ) async {
    final watch = OverflowWatch('笔记用户')..start();
    addTearDown(watch.stop);

    await resetEverything();

    // 四条都走 `addNote`(录入弹层 `_save()` 走的同一个入口)。
    for (final t in [kInjection, kEmoji, kMultiline, kLong]) {
      await addNote(text: t, measuredAt: DateTime.now().toUtc().toIso8601String());
    }
    bumpVaultRevision();

    // ── 硬不变量:纯文本里一个字都不能有 ──
    final s = await viewVisitSummary();
    debugPrint('[笔记用户] recentNotes=${s.recentNotes.length} '
        'plainText 长度=${s.plainText.length}');
    expect(s.recentNotes, isNotEmpty, reason: '笔记没进「我想问医生的」');

    for (final probe in [
      '<script>',
      'alert("xss")',
      '😀',
      '昨天开始头晕',
      '这个药还要吃多久?',
      '复诊要问的问题',
    ]) {
      expect(
        s.plainText.contains(probe),
        isFalse,
        reason: '**硬不变量破了**:笔记内容「$probe」漏进了「复制全文给医生」的纯文本。\n'
            'plainText = ${s.plainText}',
      );
    }

    // 二维码分享的载荷是**加密**的,所以「URL 里搜不到 <script>」不构成证据
    // (base64 密文里搜什么都搜不到)。这里只当冒烟用:带 emoji/换行/超长笔记
    // 的库不能把出码这条路搞崩。真正钉「笔记不进二维码」的是 Rust 侧组装
    // 载荷时压根不读 notes,见 `vault_projections.rs` 的单测。
    final qr = await buildQrShareUrl(baseUrl: 'https://example.invalid');
    expect(qr.url, isNotEmpty);

    // ── UI:浮层里要显示得出来 ──
    await bootApp(tester, reset: false);
    await openVisitSheet(tester);

    expect(find.textContaining('<script>'), findsWidgets,
        reason: '注入串没有原样显示 —— 笔记是「逐字来自你写的东西」');
    expect(find.textContaining('😀'), findsWidgets);
    expect(find.textContaining('昨天开始头晕'), findsWidgets);

    watch.assertClean();
  });

  // ⚠️ 这条**刻意不点保存**。
  //
  // 从这里保存会踩到 BUG-4(`visit_summary_sheet.dart:98` 的
  // `setState(() => _future = viewVisitSummary())`):异常逃成未捕获的 zone
  // 错误,`flutter_test` 收到就把用例当场终止 —— 后面的断言一行都执行不到,
  // 而且会把同文件后面的用例一起带塌。那个缺陷由
  // `test/known_defect_setstate_future_test.dart` 从源码层钉住。
  //
  // 这里能验、也值得验的是**前半段**:「加一条」有没有真的跳过六选一、直接落在
  // 笔记类型上(这是这颗按钮存在的全部理由)。
  testWidgets('从「看病带这个」里点「加一条」直接落到笔记类型(不保存 —— 见 BUG-4)', (
    tester,
  ) async {
    await bootApp(tester);
    await openVisitSheet(tester);

    await tester.tap(find.text('加一条'));
    await settle(tester, total: const Duration(seconds: 2));

    // 预选中笔记 → 只有一个多行文本框,而不是血压那两个数字框;
    // 而且六选一那排 chip 整个不出现(编辑/预选态跳过它)。
    await waitFor(tester, find.text('保存'));
    expect(find.byType(TextField), findsOneWidget,
        reason: '「加一条」没有预选中笔记(出现了不止一个输入框)');
    expect(find.text('想问医生的问题、吃药后的感觉……随手记一句就行'), findsOneWidget,
        reason: '「加一条」打开的不是笔记输入框');

    // 收掉,不保存。
    await tester.tapAt(const Offset(10, 10));
    await settle(tester, total: const Duration(seconds: 2));
    expect((await viewVisitSummary()).recentNotes, isEmpty,
        reason: '没点保存却存进去了');
  });
}
