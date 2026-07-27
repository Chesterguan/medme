// 成员管理的单测。核心是一条设计不变量:**目录认 id,名字只是标签**。
//
// 早先目录按名字拼(`profiles/<名字>/`),于是改名 = 搬数据。而自动命名恰恰发生在
// 首次导入**之后**(`import_flow.dart` 里 ingest 完才调),所以那个组合会让首次导入的
// 病历当场消失。改成 id 之后,改名只动标签、删除只影响自己,这些坑一次性没了。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';

const _docs = '/docs';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-profile-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
  });

  tearDown(() async => support.delete(recursive: true));

  test('改名不动数据;删任何成员都不影响别人的路径;删到只剩一个就不给删', () async {
    await File('${support.path}/profiles.json').writeAsString(
      jsonEncode({
        'version': 2,
        'profiles': [
          {'id': 'p-a', 'name': '张建国'},
          {'id': 'p-b', 'name': '李秀英'},
          {'id': 'p-c', 'name': '王小明'},
        ],
        'currentId': 'p-b',
        'autoNamePending': false,
        'vaultName': '我家',
        'counts': {'p-a': 22, 'p-b': 3, 'p-c': 1},
      }),
    );

    final pm = ProfileManager.instance;
    await pm.ensureLoaded();
    expect(pm.profiles.map((p) => p.name), ['张建国', '李秀英', '王小明']);
    expect(pm.current.name, '李秀英');

    // 路径只认 id,和名字、和排第几都无关。
    expect(pm.localBaseOf(_docs, 'p-a'), '$_docs/profiles/p-a');
    expect(pm.containerBaseOf('/icloud', 'p-c'), '/icloud/Documents/profiles/p-c');
    expect(pm.containerBaseOf(null, 'p-c'), isNull, reason: '容器不可用时不该拼出路径');

    // **改名不动数据**:换个标签,目录一个字不变。
    await pm.rename('p-a', '张建国(改)');
    expect(pm.byId('p-a')!.name, '张建国(改)');
    expect(pm.localBaseOf(_docs, 'p-a'), '$_docs/profiles/p-a',
        reason: '目录认 id,改名不许影响它');

    // 谁都能删,包括排第一的。
    expect(pm.canRemove('p-a'), isTrue);
    expect(await pm.remove('p-a'), isTrue);
    expect(pm.profiles.map((p) => p.id), ['p-b', 'p-c']);
    expect(pm.countFor('p-a'), isNull, reason: '份数缓存要一并清掉');

    // 幸存者路径不漂移。
    expect(pm.localBaseOf(_docs, 'p-b'), '$_docs/profiles/p-b');
    expect(pm.localBaseOf(_docs, 'p-c'), '$_docs/profiles/p-c');

    // 删掉当前成员时自动落到一个存在的成员上。
    expect(await pm.remove('p-b'), isTrue);
    expect(pm.currentId.value, 'p-c');

    // 只剩一个:不给删(清空整个保险箱要走「清空所有数据」)。
    expect(pm.canRemove('p-c'), isFalse);
    expect(await pm.remove('p-c'), isFalse);
    expect(pm.profiles.length, 1, reason: '被拒绝的删除不许改动成员表');
  });

  test('同名成员各自独立;载入示例不关掉自动命名', () async {
    final pm = ProfileManager.instance;
    await pm.ensureLoaded();
    await pm.factoryReset();

    // 名字只是标签 —— 家里两个「张伟」是两个人,各有各的 id 和目录。
    final a = await pm.create('张伟');
    final b = await pm.create('张伟');
    expect(a, isNot(b));
    expect(pm.localBaseOf(_docs, a!), isNot(pm.localBaseOf(_docs, b!)));

    // 用户自己建成员 → 关掉「首次导入自动命名」。
    expect(await pm.maybeAutoNameCurrent('王五'), isNull);

    // 载入示例建的成员不算用户在管理档案,不该关掉自动命名:否则「先看示例、
    // 再导入自己病历」的用户,档案会永远停在占位名。
    await pm.factoryReset();
    await pm.create('张建国(示例)', userManaged: false);
    await pm.remove(pm.currentId.value); // 看完移除示例,回到唯一的默认成员
    expect(await pm.maybeAutoNameCurrent('王五'), '王五');
    expect(pm.current.name, '王五');
  });
}
