// 成员移除的单测。盯的是一条**会静默毁数据**的不变量:
//
// 有一个成员占着保险箱的原始位置 `<docs>/vault`(零迁移的历史包袱),其余在
// `<docs>/profiles/<名字>/`。这个身份由 `rootMember` 显式记名,**不能由「排第几」推断**
// —— 按位置推的话,删掉排第一的会让第二个递补并继承那个位置,而它的病历还躺在
// `profiles/<名字>/`,于是「删了别人,自己的没了」。
//
// 所以本测试的核心断言是:**删任何一个成员,幸存者的数据路径一个字都不许变。**
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';

const _docs = '/docs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('删任何成员都不改变幸存者的路径;删到只剩一个就不给删了', () async {
    final support = await Directory.systemTemp.createTemp('medme-profile-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
    // 老格式:**没有 rootMember 字段** —— 加载时应把首位补成 root(向后兼容)。
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

    // 向后兼容:老档案里排第一的那个继承 root 身份。
    expect(pm.localBaseOf(_docs, '张建国'), _docs);
    expect(pm.localBaseOf(_docs, '李秀英'), '$_docs/profiles/李秀英');
    expect(pm.localBaseOf(_docs, '王小明'), '$_docs/profiles/王小明');

    // 谁都能删,与排第几无关 —— 包括占着原始位置的那个。
    expect(pm.canRemove('张建国'), isTrue);
    expect(await pm.remove('张建国'), isTrue);
    expect(pm.members, ['李秀英', '王小明']);

    // **核心断言**:root 被删后,幸存者路径**没有漂移**(按位置推断的老实现会让
    // 李秀英在这里变成 `/docs`,病历当场找不到)。
    expect(pm.localBaseOf(_docs, '李秀英'), '$_docs/profiles/李秀英');
    expect(pm.localBaseOf(_docs, '王小明'), '$_docs/profiles/王小明');
    expect(
      pm.containerBaseOf('/icloud', '李秀英'),
      '/icloud/Documents/profiles/李秀英',
    );
    expect(pm.containerBaseOf(null, '李秀英'), isNull, reason: '容器不可用时不该拼出路径');

    // 删的不是当前成员,当前不变;份数缓存要清掉。
    expect(pm.current, '李秀英');
    expect(pm.countFor('张建国'), isNull);

    // 删掉当前成员时自动落到一个存在的成员上。
    expect(await pm.remove('李秀英'), isTrue);
    expect(pm.current, '王小明');
    expect(pm.localBaseOf(_docs, '王小明'), '$_docs/profiles/王小明',
        reason: '连删两个之后路径依然不漂');

    // 只剩一个:不给删(清空整个保险箱要走「清空所有数据」那条明确的路)。
    expect(pm.members, ['王小明']);
    expect(pm.canRemove('王小明'), isFalse);
    expect(await pm.remove('王小明'), isFalse);
    expect(pm.members, ['王小明'], reason: '被拒绝的删除不许改动成员表');

    await support.delete(recursive: true);
  });
}
