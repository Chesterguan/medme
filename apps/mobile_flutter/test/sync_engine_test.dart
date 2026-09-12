// SyncEngine 的单测:事件推拉按水位、对象按需上下行、vault 身份核对。全部用假
// API + 假 Rust 桥(`flutter test` 不加载原生库,真实 FRB 调用在这里会直接崩——同
// `account_screen_test.dart`/`wipe_all_data_test.dart` 顶部同一条限制)。
//
// `enableCloud()` 末尾会经 `vault_boot.openCurrentProfileVault()` 重开箱,那条
// 路径调的是真实 FRB(`syncOpenProfileVault`/`syncCurrentVaultIsKeyed`)+
// `path_provider`,在这里没法伪造,所以本文件不测 `enableCloud` 走到重开箱之后的
// 部分——它建密钥/封装/上传/存密钥/`markCloud`/身份核对这几步用的都是可注入的假
// 实现,逻辑上和 `syncProfile` 一样可测。
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
/// 已注册的 object_id 列表——**PUT 签名时会往这个列表里加**,模拟后端
/// `object_register` 在签名时就登记、不代表真的传成功那件事,见 I3)。
class RecordingApi extends ApiClient {
  RecordingApi({required this.server}) : super(base: 'http://x');

  final Map<String, dynamic> server;
  final calls = <String>[];
  final pushedEvents = <Map<String, dynamic>>[];
  final signedUrls = <String>[];
  final sinceQueries = <String>[];
  bool failPullEvents = false;
  bool failPushEvents = false;
  bool failObjectUpload = false; // 签名阶段就失败(PUT verb)
  bool failObjectDownload = false; // 签名阶段就失败(GET verb)
  /// 签名会成功、但真正的 PUT 会失败的 object_id 集合——测"登记 ≠ 传成功"。
  final failPutForObjectIds = <String>{};
  /// 不带 `X-Seq-Map` 响应头——测 I2(缺水位必须跳过推送,不能当空水位推全量)。
  bool dropSeqMapHeader = false;
  /// 带一个解不出来的 `X-Seq-Map`(不是 JSON 对象)——同上,测解析失败的分支。
  String? garbageSeqMapValue;

  final _urlToObjectId = <String, String>{};

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
    sinceQueries.add(query?['since'] ?? '');
    final respHeaders = <String, String>{};
    if (!dropSeqMapHeader) {
      respHeaders['x-seq-map'] = garbageSeqMapValue ?? jsonEncode((server['seqMap'] as Map<String, int>?) ?? const <String, int>{});
    }
    return ((server['events'] as List?) ?? const [], respHeaders);
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
      final map = body as Map;
      final verb = map['verb'];
      final oid = map['object_id'] as String;
      if (verb == 'PUT' && failObjectUpload) throw const ApiFailed(500, 'sign failed');
      if (verb == 'GET' && failObjectDownload) throw const ApiFailed(500, 'sign failed');
      final url = '<presigned:${signedUrls.length}>';
      signedUrls.add(url);
      _urlToObjectId[url] = oid;
      if (verb == 'PUT') {
        // 后端在签名时就 `object_register`——登记了不代表 PUT 真的会成功,见 I3。
        final objs = server['objects'] as List;
        if (!objs.contains(oid)) objs.add(oid);
      }
      return {'url': url};
    }
    if (path == '/v1/profiles') return {'profile_id': 'prf_new'};
    return {'ok': true};
  }

  @override
  Future<void> putBytes(String url, Uint8List bytes) async {
    calls.add('PUT $url');
    final oid = _urlToObjectId[url];
    if (oid != null && failPutForObjectIds.contains(oid)) {
      throw ApiFailed(500, 'upload failed: $oid');
    }
  }

  @override
  Future<Uint8List> getBytes(String url) async {
    calls.add('GET-BYTES $url');
    if (failObjectDownload) throw ApiFailed(500, 'download failed');
    return Uint8List.fromList([9, 9, 9]);
  }
}

/// POST /v1/profiles 报 500——单独用一个极简假 API,只覆盖 [SyncEngine.registerCloudProfile]
/// 的失败路径测试(不需要 [RecordingApi] 那一整套事件/对象相关的假逻辑)。
class Post500Api extends ApiClient {
  Post500Api() : super(base: 'http://x');
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    throw const ApiFailed(500, 'boom');
  }
}

/// 假 Rust 桥。`exportEvents`/`allObjectIds`/`missingObjects` 返回固定清单——
/// 测的是 [SyncEngine] 怎么组织这些清单去调 API,不是 Rust 自己怎么算出清单。
///
/// [keyed]/[vaultRoot] 是 C1(vault 身份核对)的开关:默认值(`true` /
/// `/x/profiles/p-1/vault`)让"档案 id 为 p-1"的既有测试不用改就能通过身份核对;
/// 需要测不匹配的用例显式传别的值。
class FakeRust implements RustSyncApi {
  FakeRust({
    this.localEvents = const [],
    this.localObjects = const [],
    this.missing = const [],
    this.importOutcome,
    this.importOutcomes,
    this.failImport = false,
    this.keyed = true,
    String? vaultRoot,
  }) : vaultRoot = vaultRoot ?? '/x/profiles/p-1/vault';

  final List<SyncEventDto> localEvents;
  final List<(String, String)> localObjects;
  final List<(String, String)> missing;
  final SyncImportOutcomeDto? importOutcome;
  /// 按调用次序依次返回的 import 结果(测「outOfOrder 触发自动重拉」用:第一次
  /// 返回 outOfOrder>0,第二次返回 0)。用完了退回 [importOutcome]/默认值。
  final List<SyncImportOutcomeDto>? importOutcomes;
  final bool failImport;
  final bool keyed;
  final String vaultRoot;

  final storedObjectIds = <String>[];
  final encryptedHashes = <String>[];
  List<(String, int)>? lastExportAfter;
  var _importCallIndex = 0;

  @override
  Future<Uint8List> profileKeyNew() async => Uint8List.fromList(List.generate(32, (i) => i));

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async =>
      Uint8List.fromList([...public, ...plaintext]);

  @override
  Future<bool> currentVaultIsKeyed() async => keyed;

  @override
  Future<String> currentVaultRoot() async => vaultRoot;

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
    if (importOutcomes != null && _importCallIndex < importOutcomes!.length) {
      return importOutcomes![_importCallIndex++];
    }
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

  group('C1: vault 身份核对——vault 是进程级单例,Profile 只是个参数,两者必须核对', () {
    test('当前打开的箱子 root 对不上这个档案:syncProfile 拒绝,零 API 调用', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final rust = FakeRust(vaultRoot: '/x/profiles/OTHER-PROFILE/vault');
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<VaultMismatch>()),
      );
      expect(api.calls, isEmpty);
    });

    test('当前打开的是代拍病人的箱子(unkeyed):syncProfile 拒绝,零 API 调用', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final rust = FakeRust(keyed: false);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<VaultMismatch>()),
      );
      expect(api.calls, isEmpty);
    });

    test('fetchObject 同样核对身份:不匹配就拒绝,不发请求', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final rust = FakeRust(keyed: false);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.fetchObject(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'), 'h1'),
        throwsA(isA<VaultMismatch>()),
      );
      expect(api.calls, isEmpty);
    });

    test('enableCloud:传入的档案不是当前打开的成员时拒绝,不建密钥不调用服务端', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());
      // 不依赖 ProfileManager 此刻具体是什么值(其它测试可能已经改过 currentId)——
      // 只要传的 id 和"当前"不一样就该被拒绝。
      final mismatchedId = '${ProfileManager.instance.currentId.value}-not-current';
      await expectLater(
        engine.enableCloud(Profile(id: mismatchedId, name: 'x')),
        throwsA(isA<VaultMismatch>()),
      );
      expect(api.calls, isEmpty);
    });
  });

  group('I1: outOfOrder 触发一次自动重拉', () {
    test('第一次 import 报 outOfOrder>0:自动重拉一次,重拉的 since 摘掉了本批涉及的设备', () async {
      final api = RecordingApi(server: {
        'events': [
          {'device_id': 'd1', 'seq': 5, 'event_id': 'e5', 'ts': 't', 'ciphertext': base64Encode(Uint8List(2))},
        ],
      });
      final rust = FakeRust(
        importOutcomes: [
          const SyncImportOutcomeDto(applied: 0, skippedExisting: 0, outOfOrder: 1, untrusted: 0, undecodable: 0),
          const SyncImportOutcomeDto(applied: 1, skippedExisting: 0, outOfOrder: 0, untrusted: 0, undecodable: 0),
        ],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(
        api.calls.where((c) => c == 'GET /v1/profiles/prf_1/events').length,
        2,
        reason: '触发了一次自动重拉',
      );
      expect(api.sinceQueries.length, 2);
      final retrySince = jsonDecode(api.sinceQueries[1]) as Map;
      expect(retrySince.containsKey('d1'), isFalse, reason: '重拉时把 d1 从 since 里摘掉,逼服务端重发它的历史');
      expect(rep.outOfOrder, 0, reason: '重拉后不再乱序,report 上不该留着第一次的旧值');
      expect(rep.pulled, 1, reason: '两次 import 的 applied 累加');
    });

    test('重拉后仍然 outOfOrder>0:如实报出去,不无限重试', () async {
      final api = RecordingApi(server: {
        'events': [
          {'device_id': 'd1', 'seq': 5, 'event_id': 'e5', 'ts': 't', 'ciphertext': base64Encode(Uint8List(2))},
        ],
      });
      final rust = FakeRust(
        importOutcomes: [
          const SyncImportOutcomeDto(applied: 0, skippedExisting: 0, outOfOrder: 1, untrusted: 0, undecodable: 0),
          const SyncImportOutcomeDto(applied: 0, skippedExisting: 0, outOfOrder: 1, untrusted: 0, undecodable: 0),
        ],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(api.calls.where((c) => c == 'GET /v1/profiles/prf_1/events').length, 2, reason: '只重试一次,不是无限循环');
      expect(rep.outOfOrder, 1);
    });

    test('untrusted/undecodable 也如实反映在 report 上', () async {
      final api = RecordingApi(server: {
        'events': [
          {'device_id': 'd1', 'seq': 5, 'event_id': 'e5', 'ts': 't', 'ciphertext': base64Encode(Uint8List(2))},
        ],
      });
      final rust = FakeRust(
        importOutcome: const SyncImportOutcomeDto(applied: 2, skippedExisting: 0, outOfOrder: 0, untrusted: 3, undecodable: 1),
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.untrusted, 3);
      expect(rep.undecodable, 1);
      expect(rep.pulled, 2);
    });
  });

  group('I2: X-Seq-Map 缺失/解析失败——不能悄悄退化成推全量', () {
    test('响应头没有 X-Seq-Map:跳过推送,报 pushSkippedNoWatermark', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..dropSeqMapHeader = true;
      final rust = FakeRust(
        localEvents: [SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3))],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.pushSkippedNoWatermark, isTrue);
      expect(rep.pushed, 0);
      expect(api.calls, isNot(contains('POST /v1/profiles/prf_1/events')));
      expect(rust.lastExportAfter, isNull, reason: '既然要跳过推送,压根不该调 exportEvents');
    });

    test('X-Seq-Map 解析不出来(不是 JSON 对象):同样跳过推送', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..garbageSeqMapValue = 'not json';
      final rust = FakeRust(
        localEvents: [SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3))],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.pushSkippedNoWatermark, isTrue);
      expect(rep.pushed, 0);
    });

    test('X-Seq-Map 里有非法条目(值不是整数):同样跳过推送', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..garbageSeqMapValue = '{"d1":"not-a-number"}';
      final rust = FakeRust();
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.pushSkippedNoWatermark, isTrue);
    });
  });

  group('I3: 对象上传逐个失败、体积上限、签名登记≠传成功的重传', () {
    test('三个对象里一个 PUT 失败:另两个照常上传、objectsFailed==1、下载照常跑', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failPutForObjectIds.add('o2');
      final rust = FakeRust(
        localObjects: [('h1', 'o1'), ('h2', 'o2'), ('h3', 'o3')],
        missing: [('h4', 'o4')],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.objectsUp, 2);
      expect(rep.objectsFailed, 1);
      expect(rep.objectsDown, 1, reason: '上传失败不该拖累下载');
      expect(rust.storedObjectIds, ['o4']);
    });

    test('上次 PUT 失败的对象,即使服务端签名清单里已经有它,下次同步也会重传;成功后不再重传', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failPutForObjectIds.add('o2');
      final rust = FakeRust(localObjects: [('h1', 'o1'), ('h2', 'o2')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep1 = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));
      expect(rep1.objectsUp, 1);
      expect(rep1.objectsFailed, 1);
      expect(api.server['objects'], contains('o2'), reason: '后端签名时就登记了,不代表传成功');

      // 第二次同步:PUT 不再失败,o2 虽然在服务端清单里,仍应因为本地"待重传"
      // 记录而被重传。
      api.failPutForObjectIds.clear();
      api.calls.clear();
      final rep2 = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));
      expect(rep2.objectsUp, 1, reason: '只有 o2 需要重传,o1 已经成功过、不在重试清单里');
      expect(rep2.objectsFailed, 0);

      // 第三次同步:o2 已经成功,不该再重传。
      api.calls.clear();
      final rep3 = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));
      expect(rep3.objectsUp, 0);
    });

    test('对象体积超过 64 MiB:跳过、计入 objectsFailed,不发签名请求', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final rust = _HugeObjectRust(localObjects: [('h1', 'o1')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.objectsFailed, 1);
      expect(rep.objectsUp, 0);
      expect(api.calls, isNot(contains('POST /v1/profiles/prf_1/objects/sign')));
    });

    test('对象签名失败:不再让整次同步抛出,计入 objectsFailed', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failObjectUpload = true;
      final rust = FakeRust(localObjects: [('h1', 'o1')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.objectsFailed, 1);
      expect(rep.objectsUp, 0);
    });
  });

  group('三态:拉/推/对象下行失败时不吞异常(对象上行已改为逐个 try/catch,见 I3)', () {
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

  test('registerCloudProfile:POST /v1/profiles 报 500 时,密钥不落盘、markCloud 不调用', () async {
    await AccountSession.instance.save(
      accountId: 'acc',
      access: 'a',
      refresh: 'r',
      publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
    );
    await ProfileManager.instance.create('测试成员2');
    final p = ProfileManager.instance.current;
    final api = Post500Api();
    final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());

    await expectLater(engine.registerCloudProfile(p), throwsA(isA<ApiFailed>()));

    expect(api.calls, ['POST /v1/profiles']);
    final unchanged = ProfileManager.instance.byId(p.id)!;
    expect(unchanged.cloudId, isNull, reason: 'markCloud 不该被调用');
    // 没有 cloudId 就没法拼 secure storage 的 key,这里只需确认 profile 状态没变。
  });
}

/// 只用来测「对象体积超过上限」——`encryptObject` 返回一个超过 64 MiB 的
/// ciphertext。单独一个类而不是往 [FakeRust] 加参数,是因为只有这一个测试用得到,
/// 不值得把体积搞成一个到处都要传的构造参数。
class _HugeObjectRust extends FakeRust {
  _HugeObjectRust({required super.localObjects});

  @override
  Future<(String, Uint8List)> encryptObject(Uint8List profileKey, String hash) async {
    encryptedHashes.add(hash);
    return (hash, Uint8List(SyncEngine.objectMaxBytes + 1));
  }
}
