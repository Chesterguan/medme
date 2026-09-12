// Task 10 review I5:钉住 `Profile.cloudId/role/expiresAt` 的序列化往返,以及
// `ProfileManager.rename` 不会把它们弄丢——这个字段是本次才加的,`rename` 早先
// 用 `Profile(id: p.id, name: trimmed)` 重建对象,会把这三个字段静默清空
// (改名 = 意外退出云同步),已在实现里修掉,这里钉住不许回归。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Profile.toJson/fromJson 往返', () {
    test('cloudId/role/expiresAt 都有值时,原样往返', () {
      final p = Profile(
        id: 'p-1',
        name: '我',
        cloudId: 'prf_1',
        role: 'editor',
        expiresAt: DateTime.utc(2026, 12, 31, 23, 59),
      );
      final restored = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(restored.id, p.id);
      expect(restored.name, p.name);
      expect(restored.cloudId, p.cloudId);
      expect(restored.role, p.role);
      expect(restored.expiresAt, p.expiresAt);
    });

    test('三者都没有值(本地档案)时,往返仍是 null——不写出多余的 key', () {
      const p = Profile(id: 'p-1', name: '我');
      final json = p.toJson();
      expect(json.containsKey('cloudId'), isFalse);
      expect(json.containsKey('role'), isFalse);
      expect(json.containsKey('expiresAt'), isFalse);
      final restored = Profile.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(restored.cloudId, isNull);
      expect(restored.role, isNull);
      expect(restored.expiresAt, isNull);
    });

    test('cloudPaused 往返;默认(没关过)不写出这个 key', () {
      const on = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
      expect(on.toJson().containsKey('cloudPaused'), isFalse);
      expect(Profile.fromJson(jsonDecode(jsonEncode(on.toJson())) as Map<String, dynamic>).cloudPaused, isFalse);

      const off = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner', cloudPaused: true);
      final restored = Profile.fromJson(jsonDecode(jsonEncode(off.toJson())) as Map<String, dynamic>);
      expect(restored.cloudPaused, isTrue);
      expect(restored.cloudId, 'prf_1');
    });

    test('expiresAt 为 null(owner 永不过期)但 cloudId/role 有值:分别往返', () {
      const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
      final restored = Profile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(restored.cloudId, 'prf_1');
      expect(restored.role, 'owner');
      expect(restored.expiresAt, isNull);
    });
  });

  group('ProfileManager.rename 保留云同步字段', () {
    late Directory support;

    // `ProfileManager.instance` 是真单例,`_loaded` 一旦为 true 就不会再重读
    // profiles.json——所以这里不手写 fixture 文件再 `ensureLoaded()`(第二个
    // test 会读到第一个 test 留下的内存态,而不是自己刚写的文件),改用
    // `factoryReset()` + `create()` 这两个公开 API 保证每个 test 都是独立的一个
    // 全新成员,不依赖"这是不是第一次 ensureLoaded"。`factoryReset`/`create`
    // 仍然会调 `_save()` 落盘,所以 path_provider 的 mock 还是需要的。
    setUp(() async {
      support = await Directory.systemTemp.createTemp('medme-profile-cloud-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      final pm = ProfileManager.instance;
      await pm.ensureLoaded();
      await pm.factoryReset();
    });

    tearDown(() async => support.delete(recursive: true));

    test('改名不清空 cloudId/role/expiresAt', () async {
      final pm = ProfileManager.instance;
      final id = (await pm.create('张建国'))!;
      await pm.markCloud(id, 'prf_9', 'owner', null);
      expect(pm.byId(id)!.cloudId, 'prf_9');

      await pm.rename(id, '张建国(改)');

      final renamed = pm.byId(id)!;
      expect(renamed.name, '张建国(改)');
      expect(renamed.cloudId, 'prf_9', reason: '改名不该把云同步字段弄丢');
      expect(renamed.role, 'owner');
    });

    // UX 第二轮:`cloudPaused`(用户手动关掉了这个成员的云同步)。改名/markCloud
    // 都曾经是"重建一个 Profile"的地方 —— 每加一个字段就多一处能被静默清空的可能,
    // 所以这几条和上面那条是同一件事的延续。
    test('关掉云同步:落盘,而且改名/markCloud 都不把它弄丢', () async {
      final pm = ProfileManager.instance;
      final id = (await pm.create('爸爸'))!;
      await pm.setCloudPaused(id, true);
      expect(pm.byId(id)!.cloudPaused, isTrue);

      await pm.rename(id, '爸爸(改)');
      expect(pm.byId(id)!.cloudPaused, isTrue, reason: '改名不该把"我关过它"这件事弄丢');

      await pm.markCloud(id, 'prf_8', 'owner', null);
      expect(pm.byId(id)!.cloudPaused, isTrue, reason: 'markCloud 也不许替用户打开');

      await pm.setCloudPaused(id, false);
      expect(pm.byId(id)!.cloudPaused, isFalse);
    });

    test('markCloud 写入 cloudId/role/expiresAt,不影响 name', () async {
      final pm = ProfileManager.instance;
      final id = (await pm.create('张建国'))!;

      await pm.markCloud(id, 'prf_7', 'owner', null);

      final updated = pm.byId(id)!;
      expect(updated.name, '张建国');
      expect(updated.cloudId, 'prf_7');
      expect(updated.role, 'owner');
      expect(updated.expiresAt, isNull);
    });
  });
}
