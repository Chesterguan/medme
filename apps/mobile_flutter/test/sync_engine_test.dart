// SyncEngine 的单测:事件推拉按水位、对象按需上下行。全部用假 API + 假 Rust
// 桥(`flutter test` 不加载原生库,真实 FRB 调用在这里会直接崩——同
// `account_screen_test.dart`/`wipe_all_data_test.dart` 顶部同一条限制)。
//
// `enableCloud()` 末尾会经 `vault_boot.openCurrentProfileVault()` 重开箱,那条
// 路径调的是真实 FRB(`syncOpenProfileVault`/`syncCurrentVaultIsKeyed`)+
// `path_provider`,在这里没法伪造,所以本文件不测 `enableCloud`——它建密钥/封装/
// 上传/存密钥/`markCloud` 这几步用的都是可注入的假实现,逻辑上和 `syncProfile`
// 一样可测,只是接不到「重开箱」那一步而已。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 API——每个方法都记进 [calls],推的事件记进 [pushedEvents]。[server] 描述
/// 服务端此刻的状态:`events`(GET .../events 应该返回的列表)、
/// `seqMap`(响应头 X-Seq-Map 应该带回的值,默认空)、`objects`(GET .../objects
/// 已注册的 object_id 列表)。
class RecordingApi extends ApiClient {
  RecordingApi({required this.server}) : super(base: 'http://x');

  final Map<String, dynamic> server;
  final calls = <String>[];
  final pushedEvents = <Map<String, dynamic>>[];
  final signedUrls = <String>[];
  bool failPullEvents = false;
  bool failPushEvents = false;
  bool failObjectUpload = false;
  bool failObjectDownload = false;

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    if (path.endsWith('/objects')) return (server['objects'] as List?) ?? const [];
    return const [];
  }

  @override
  Future<(dynamic, Map<String, String>)> getJsonWithHeaders(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    calls.add('GET $path');
    if (failPullEvents) throw const ApiFailed(500, 'pull failed');
    final seqMap = (server['seqMap'] as Map<String, int>?) ?? const <String, int>{};
    return ((server['events'] as List?) ?? const [], {'x-seq-map': jsonEncode(seqMap)});
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    if (path.endsWith('/events')) {
      if (failPushEvents) throw const ApiFailed(500, 'push failed');
      pushedEvents.addAll((body as List).cast<Map<String, dynamic>>());
      return {'ok': true};
    }
    if (path.endsWith('/objects/sign')) {
      final verb = (body as Map)['verb'];
      if (verb == 'PUT' && failObjectUpload) throw const ApiFailed(500, 'sign failed');
      if (verb == 'GET' && failObjectDownload) throw const ApiFailed(500, 'sign failed');
      final url = '<presigned:${signedUrls.length}>';
      signedUrls.add(url);
      return {'url': url};
    }
    if (path == '/v1/profiles') return {'profile_id': 'prf_new'};
    return {'ok': true};
  }

  @override
  Future<void> putBytes(String url, Uint8List bytes) async {
    calls.add('PUT $url');
    if (failObjectUpload) throw ApiFailed(500, 'upload failed');
  }

  @override
  Future<Uint8List> getBytes(String url) async {
    calls.add('GET-BYTES $url');
    if (failObjectDownload) throw ApiFailed(500, 'download failed');
    return Uint8List.fromList([9, 9, 9]);
  }
}

/// 假 Rust 桥。`exportEvents`/`allObjectIds`/`missingObjects` 返回固定清单——
/// 测的是 [SyncEngine] 怎么组织这些清单去调 API,不是 Rust 自己怎么算出清单。
class FakeRust implements RustSyncApi {
  FakeRust({
    this.localEvents = const [],
    this.localObjects = const [],
    this.missing = const [],
    this.importOutcome,
    this.failImport = false,
  });

  final List<SyncEventDto> localEvents;
  final List<(String, String)> localObjects;
  final List<(String, String)> missing;
  final SyncImportOutcomeDto? importOutcome;
  final bool failImport;

  final storedObjectIds = <String>[];
  final encryptedHashes = <String>[];
  List<(String, int)>? lastExportAfter;

  @override
  Future<Uint8List> profileKeyNew() async => Uint8List.fromList(List.generate(32, (i) => i));

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async =>
      Uint8List.fromList([...public, ...plaintext]);

  @override
  Future<List<(String, int)>> localSeqMap() async => const [];

  @override
  Future<List<SyncEventDto>> exportEvents(Uint8List profileKey, List<(String, int)> after) async {
    lastExportAfter = after;
    return localEvents;
  }

  @override
  Future<SyncImportOutcomeDto> importEvents(Uint8List profileKey, List<SyncEventDto> events) async {
    if (failImport) throw Exception('import boom');
    return importOutcome ??
        SyncImportOutcomeDto(
          applied: events.length,
          skippedExisting: 0,
          outOfOrder: 0,
          untrusted: 0,
          undecodable: 0,
        );
  }

  @override
  Future<List<(String, String)>> missingObjects(Uint8List profileKey) async => missing;

  @override
  Future<List<(String, String)>> allObjectIds(Uint8List profileKey) async => localObjects;

  @override
  Future<(String, Uint8List)> encryptObject(Uint8List profileKey, String hash) async {
    encryptedHashes.add(hash);
    return (hash, Uint8List.fromList([1, 2, 3]));
  }

  @override
  Future<String> storeObject(Uint8List profileKey, String objectId, Uint8List ciphertext) async {
    storedObjectIds.add(objectId);
    return objectId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cloudId = 'prf_1';
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  late Directory support;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
    await AccountSession.instance.putProfileKey(cloudId, key);

    // `registerCloudProfile` 测试要用真的 ProfileManager(`markCloud` 落盘)——
    // 给它一个真实临时目录当 `getApplicationSupportDirectory()`,同
    // `profile_manager_remove_test.dart` 的套路。
    support = await Directory.systemTemp.createTemp('medme-sync-engine-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() async => support.delete(recursive: true));

  test('首次同步:推本地事件与对象,拉回缺的', () async {
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final rust = FakeRust(
      localEvents: [
        SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3)),
      ],
      localObjects: [('h1', 'o1')],
      missing: const [],
    );
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

    expect(rep.pushed, 1);
    expect(rep.objectsUp, 1);
    expect(
      api.calls,
      containsAll([
        'GET /v1/profiles/prf_1/events',
        'POST /v1/profiles/prf_1/events',
        'POST /v1/profiles/prf_1/objects/sign',
        'PUT ${api.signedUrls.single}',
      ]),
    );
    expect(api.pushedEvents.single['event_id'], 'e1');
    expect(rust.encryptedHashes, ['h1']);
  });

  test('viewer 不推只拉:不调事件 POST、不调 objects/sign PUT', () async {
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final rust = FakeRust(
      localEvents: [
        SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3)),
      ],
      localObjects: [('h1', 'o1')],
    );
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'viewer'));

    expect(rep.pushed, 0);
    expect(rep.objectsUp, 0);
    expect(api.calls, isNot(contains('POST /v1/profiles/prf_1/events')));
    expect(api.pushedEvents, isEmpty);
    expect(rust.encryptedHashes, isEmpty);
    // exportEvents/allObjectIds 干脆不该被 canWrite=false 挡住之前调用——
    // lastExportAfter 保持 null 说明 exportEvents 从未被调。
    expect(rust.lastExportAfter, isNull);
  });

  test('服务端已有的对象不重传;缺的对象拉回并 store', () async {
    final api = RecordingApi(server: {'events': [], 'objects': ['o1']});
    final rust = FakeRust(
      localObjects: [('h1', 'o1')], // 服务端已有 o1 → 不该重传
      missing: [('h2', 'o2')], // 本机缺 o2 → 该拉
    );
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

    expect(rep.objectsUp, 0, reason: 'o1 服务端已有,不该重传');
    expect(rust.encryptedHashes, isEmpty);
    expect(rep.objectsDown, 1);
    expect(rust.storedObjectIds, ['o2']);
    expect(
      api.calls.where((c) => c == 'POST /v1/profiles/prf_1/objects/sign').length,
      1,
      reason: '只为 o2 签了一次(GET),o1 不该走 sign',
    );
  });

  test('推送水位来自 X-Seq-Map,不从本机 since 反推', () async {
    final api = RecordingApi(server: {
      'events': [],
      'seqMap': {'d1': 7, 'd2': 3},
    });
    final rust = FakeRust();
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

    expect(
      Map.fromEntries(rust.lastExportAfter!.map((e) => MapEntry(e.$1, e.$2))),
      {'d1': 7, 'd2': 3},
    );
  });

  test('推送分批:超过 500 条事件拆成多次 POST,每次最多 500 条', () async {
    final events = List.generate(
      620,
      (i) => SyncEventDto(deviceId: 'd1', seq: i + 1, eventId: 'e$i', ts: 't', ciphertext: Uint8List(1)),
    );
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final rust = FakeRust(localEvents: events);
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

    expect(rep.pushed, 620);
    expect(api.pushedEvents.length, 620);
    final postCount = api.calls.where((c) => c == 'POST /v1/profiles/prf_1/events').length;
    expect(postCount, 2, reason: '620 条应拆成 500 + 120 两次 POST');
  });

  test('单条事件密文超过 1 MiB 时不推送(服务端会整批拒收,client 侧先摘掉)', () async {
    final huge = SyncEventDto(
      deviceId: 'd1',
      seq: 1,
      eventId: 'huge',
      ts: 't',
      ciphertext: Uint8List(SyncEngine.maxEventBytes + 1),
    );
    final ok = SyncEventDto(deviceId: 'd1', seq: 2, eventId: 'ok', ts: 't', ciphertext: Uint8List(3));
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final rust = FakeRust(localEvents: [huge, ok]);
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

    expect(rep.pushed, 1);
    expect(api.pushedEvents.single['event_id'], 'ok');
  });

  group('三态:拉/推/对象上下行失败时不吞异常', () {
    test('拉取失败(服务端 500):syncProfile 抛出,不留部分结果', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failPullEvents = true;
      final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());
      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<ApiFailed>()),
      );
    });

    test('推送失败(服务端 500):抛出,不吞', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failPushEvents = true;
      final rust = FakeRust(
        localEvents: [SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3))],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<ApiFailed>()),
      );
    });

    test('对象上传失败(预签名失败):抛出,不吞', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failObjectUpload = true;
      final rust = FakeRust(localObjects: [('h1', 'o1')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<ApiFailed>()),
      );
    });

    test('对象下载失败:抛出,不吞', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failObjectDownload = true;
      final rust = FakeRust(missing: [('h2', 'o2')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<ApiFailed>()),
      );
    });
  });

  test('syncProfile:档案没有 cloudId 时报错,不瞎猜服务端地址', () async {
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());
    await expectLater(
      engine.syncProfile(const Profile(id: 'p-1', name: 'x')),
      throwsA(isA<StateError>()),
    );
  });

  test('registerCloudProfile:建密钥、POST /v1/profiles、存密钥、markCloud(不含重开箱)', () async {
    await AccountSession.instance.save(
      accountId: 'acc',
      access: 'a',
      refresh: 'r',
      publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
    );
    await ProfileManager.instance.create('测试成员');
    final p = ProfileManager.instance.current;
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());

    final cloudId = await engine.registerCloudProfile(p);

    expect(cloudId, 'prf_new');
    expect(api.calls, contains('POST /v1/profiles'));
    expect(await AccountSession.instance.profileKey(cloudId), isNotNull);
    final updated = ProfileManager.instance.byId(p.id)!;
    expect(updated.cloudId, cloudId);
    expect(updated.role, 'owner');
  });

  test('registerCloudProfile:账号公钥未就绪时报错,不裸调服务端', () async {
    final api = RecordingApi(server: {'events': [], 'objects': []});
    final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());
    await expectLater(
      engine.registerCloudProfile(const Profile(id: 'p-x', name: 'x')),
      throwsA(isA<StateError>()),
    );
    expect(api.calls, isEmpty);
  });
}
