// 医生代拍「12 小时本机保留」的单测。盯两件最容易悄悄坏掉的事:
//  1. **TTL 真的会删**——超 12 小时的病人连目录一起没,没超的原样留着。承诺写在拍前
//     同意书里(「最多存 12 小时,到时间自动删掉」),坏了就是对病人失信。
//  2. **落盘状态真的读得回来**——拍前同意(签名)与逐份「已确认」要跨 app 重启存活,
//     不然 12 小时后回来交付时同意记录会丢,加密包里就没有签名了。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ensureLoaded 执行 12 小时 TTL,并读回同意 / 已确认状态', () async {
    final support = await Directory.systemTemp.createTemp('medme-proxy-test');
    // `getApplicationSupportDirectory()` 在单测里没有插件实现,直接答一个临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );

    final now = DateTime.now().millisecondsSinceEpoch;
    const h = 3600 * 1000;
    // 一个 2 小时前建的(该留),一个 13 小时前建的(该删)。
    await File('${support.path}/proxy_patients.json').writeAsString(
      jsonEncode({
        'patients': [
          {
            'id': 'fresh',
            'createdMs': now - 2 * h,
            'name': '张建国',
            'docCount': 2,
            'confirmedIds': [7, 9],
            'mismatch': {'9': '李小花'},
            'consent': {
              'utcTs': '2026-07-25T01:00:00Z',
              'consentTextVersion': 'v1',
              'signaturePngBase64': 'AAAA',
              'method': 'signature',
              'sessionId': 'sess-1',
            },
          },
          {'id': 'stale', 'createdMs': now - 13 * h, 'name': '李四'},
        ],
      }),
    );
    // 两个病人的数据目录都先摆上,验证过期的那个目录也被删掉(不只是列表里消失)。
    for (final id in ['fresh', 'stale']) {
      await Directory('${support.path}/proxy-patients/$id/vault').create(
        recursive: true,
      );
    }

    await ProxyPatientManager.instance.ensureLoaded();

    final patients = ProxyPatientManager.instance.patients;
    expect(patients.map((p) => p.id), ['fresh'], reason: '超 12 小时的必须消失');
    expect(
      Directory('${support.path}/proxy-patients/stale').existsSync(),
      isFalse,
      reason: '过期病人的目录要连数据一起删,不能只从列表摘掉',
    );
    expect(
      Directory('${support.path}/proxy-patients/fresh').existsSync(),
      isTrue,
      reason: '没到点的病人不许动',
    );

    final fresh = patients.single;
    expect(fresh.displayName, '张建国');
    expect(fresh.confirmedIds, {7, 9});
    // 姓名不匹配提醒必须跨重启活着——诊室里混进隔壁病人的单子要一直提示到处理掉。
    expect(fresh.mismatch, {9: '李小花'});
    expect(fresh.consent?.method, 'signature');
    expect(fresh.consent?.signaturePngBase64, 'AAAA');
    // 2 小时前建的,还剩约 10 小时(留 1 小时余量避免卡边界)。
    expect(fresh.remaining.inHours, greaterThanOrEqualTo(9));
    expect(fresh.remaining.inHours, lessThan(11));

    await support.delete(recursive: true);
  });
}
