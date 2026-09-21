// 后台识别队列在档案屏上的那张卡。用户点完「导入」就回到档案了 —— 这张卡是他
// **唯一**能看见「东西确实在处理」的地方,所以三种状态各钉一条:排队中 / 正在识别 /
// 失败还带重试。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/import_flow.dart' show ImportChoice;
import 'package:mobile_flutter/import_queue.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/import_queue_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host() =>
    MaterialApp(theme: MedMe.theme(), home: const Scaffold(body: ImportQueueCard()));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetImportQueueForTest();
    // 什么都不做的替身:这组用例只看屏,不要它真去跑 OCR / FFI。等在这里不返回,
    // 行就稳稳停在「正在识别」上。
    importItemProcessor = (job, onStage) async {
      await Completer<void>().future;
      throw StateError('不可达');
    };
  });
  tearDown(resetImportQueueForTest);

  testWidgets('队列空着 → 这张卡完全不占位', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('正在后台识别'), findsNothing);
  });

  testWidgets('排着三份:说清还剩几份,而且不把 image_picker 临时名端出来', (tester) async {
    await tester.pumpWidget(_host());
    enqueueImport(
      items: [
        for (var i = 0; i < 3; i++)
          PendingImport(
            name: 'image_picker_$i.jpg',
            path: '/tmp/$i.jpg',
            isImage: true,
          ),
      ],
      profile: const Profile(id: 'p-1', name: '我'),
      vaultRoot: '/docs/p-1/vault',
      source: ImportChoice.gallery,
      mergePhotos: false,
    );
    await tester.pump();

    expect(find.textContaining('正在后台识别 3 份'), findsOneWidget);
    expect(find.text('照片'), findsNWidgets(3));
    expect(find.textContaining('image_picker'), findsNothing);
    expect(find.text('正在识别…'), findsOneWidget);
    expect(find.text('排队中'), findsNWidgets(2));
  });

  testWidgets('失败那一行留着,带「重试」;点了就重新排队', (tester) async {
    var attempts = 0;
    importItemProcessor = (job, onStage) async {
      attempts++;
      throw StateError('炸');
    };
    await tester.pumpWidget(_host());
    enqueueImport(
      items: [
        const PendingImport(name: 'a.jpg', path: '/tmp/a.jpg', isImage: true),
      ],
      profile: const Profile(id: 'p-1', name: '我'),
      vaultRoot: '/docs/p-1/vault',
      source: ImportChoice.camera,
      mergePhotos: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('没能处理这一份'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2, reason: '点重试就真的再跑一次');
  });
}
