// 成员移除的单测。盯的是一条**会静默毁数据**的不变量:
//
// 第一个成员用的是保险箱的原始位置 `<docs>/vault`,其余在 `<docs>/profiles/<名字>/`。
// 一旦允许删第一个,第二个就会递补成「第一个」,它的数据路径随之从 `profiles/X`
// 漂到 `<docs>` —— 病历还在磁盘上,但应用再也找不到,表现为「删了别人,自己的没了」。
// 所以 `canRemove` 必须永远对第一个成员说不,这个测试就是守它的。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('第一个成员不可删;删其他成员不影响任何人的数据路径', () async {
    final support = await Directory.systemTemp.createTemp('medme-profile-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
    await File('${support.path}/profiles.json').writeAsString(
      jsonEncode({
        'members': ['张建国', '李秀英', '王小明'],
        'current': '李秀英',
        'rootAutoNamed': false,
        'vaultName': '我家',
        'counts': {'张建国': 22, '李秀英': 3, '王小明': 1},
      }),
    );

    final pm = ProfileManager.instance;
    await pm.ensureLoaded();

    // 核心不变量:第一个成员永远删不掉。
    expect(pm.canRemove('张建国'), isFalse, reason: '删第一个会让后面的数据路径漂移');
    expect(await pm.remove('张建国'), isFalse, reason: 'remove 也要挡住,不能只靠 UI 不显示按钮');
    expect(pm.members, ['张建国', '李秀英', '王小明'], reason: '被拒绝的删除不许改动成员表');

    // 非第一个成员可删。删的正好是当前成员 → 自动切回第一个。
    expect(pm.canRemove('李秀英'), isTrue);
    expect(await pm.remove('李秀英'), isTrue);
    expect(pm.members, ['张建国', '王小明']);
    expect(pm.current, '张建国', reason: '删掉当前成员后必须落到一个存在的成员上');
    expect(pm.countFor('李秀英'), isNull, reason: '份数缓存要一并清掉');

    // 幸存成员的数据路径**没有变** —— 这是「删别人不会弄丢自己」的实质保证。
    const docs = '/docs';
    expect(pm.localBaseOf(docs, '张建国'), docs);
    expect(pm.localBaseOf(docs, '王小明'), '$docs/profiles/王小明');
    expect(
      pm.containerBaseOf('/icloud', '王小明'),
      '/icloud/Documents/profiles/王小明',
    );
    expect(pm.containerBaseOf(null, '王小明'), isNull, reason: '容器不可用时不该拼出路径');

    // 只剩一个成员时又回到「不可删」。
    expect(await pm.remove('王小明'), isTrue);
    expect(pm.members, ['张建国']);
    expect(pm.canRemove('张建国'), isFalse);

    await support.delete(recursive: true);
  });
}
