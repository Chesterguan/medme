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
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';
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
  /// 签名会成功、但真正的 GET(下载)会失败的 object_id 集合——测 I1(一个对象
  /// 拉不回来不该作废整次同步)。
  final failGetBytesForObjectIds = <String>{};
  /// 不带 `X-Seq-Map` 响应头——测 I2(缺水位必须跳过推送,不能当空水位推全量)。
  bool dropSeqMapHeader = false;
  /// 带一个解不出来的 `X-Seq-Map`(不是 JSON 对象)——同上,测解析失败的分支。
  String? garbageSeqMapValue;
  /// `getJsonWithHeaders`(拉事件那一步)人为加的延迟——默认 0,测 I2(排队/
  /// 重叠触发)时才需要一个真实的时间窗口,让"并发的另一个操作"有机会真的
  /// 排到队列后面而不是纯凑巧地先后执行。
  Duration pullDelay = Duration.zero;

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
    if (pullDelay > Duration.zero) await Future<void>.delayed(pullDelay);
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
    final oid = _urlToObjectId[url];
    if (oid != null && failGetBytesForObjectIds.contains(oid)) {
      throw ApiFailed(500, 'download failed: $oid');
    }
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
    this.icloudOn = false,
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
  /// 这台设备开着 iCloud 同步——C3(`enableCloud` 必须拒绝)用。
  final bool icloudOn;
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
  Future<bool> icloudEnabled() async => icloudOn;

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
    // 见 Task 15 review I2 修复:`vault_boot._vaultQueue` 是模块级单例,不同
    // 用例共用,不清的话上一个用例排的收尾操作可能没走完,下一个用例的
    // `runSerialized` 调用会追加在一个不会再完成的 `Future` 后面。
    resetVaultQueueForTest();
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

  test('I4:推上去的事件不带真实时间戳,ts 一律是常量 "0"', () async {
    final api = RecordingApi(server: {'events': [], 'objects': []});
    // 假 Rust 故意回一个真实的 ISO 时间戳——这一层必须自己写死常量,不能"因为
    // Rust 那边已经填了常量"就原样转发(见 sync_engine.dart 里 wireTs 的注释)。
    final rust = FakeRust(
      localEvents: [
        SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: '2026-09-12T08:00:00Z', ciphertext: Uint8List(3)),
      ],
    );
    final engine = SyncEngine(api, AccountSession.instance, rust: rust);

    await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

    expect(api.pushedEvents.single['ts'], '0');
    expect(wireTs, '0');
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

  // ---- A5:`firstSyncAndName` —— 兑换授权与换机领回自己的档案共用的那三步 ----
  group('firstSyncAndName:切过去 → 同步 → 用病历里的姓名命名 →(可选)切回来', () {
    /// 建一个带占位名的云成员,返回它。
    Future<Profile> placeholder(String name) async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final id = await ProfileManager.instance.create(name, userManaged: false);
      await ProfileManager.instance.markCloud(id!, 'prf_new', 'owner', null);
      return ProfileManager.instance.byId(id)!;
    }

    test('兑换那条路(returnTo 为 null):做完停在新档案上,只切一次', () async {
      final p = await placeholder(ProfileManager.redeemingPlaceholderName);
      final switches = <(String, String?)>[];
      final synced = <String>[];

      await firstSyncAndName(
        p,
        revertTo: 'p-1',
        sync: (x) async => synced.add(x.id),
        switchAndReopen: (id, {String? revertTo}) async => switches.add((id, revertTo)),
        detectedName: () async => '张建国',
      );

      expect(switches, [(p.id, 'p-1')], reason: '只切过去,不切回来');
      expect(synced, [p.id]);
      expect(ProfileManager.instance.byId(p.id)!.name, '张建国');
    });

    test('换机那条路(带 returnTo):做完切回原成员', () async {
      final p = await placeholder(ProfileManager.restoringPlaceholderName);
      final switches = <String>[];

      await firstSyncAndName(
        p,
        revertTo: 'p-1',
        returnTo: 'p-1',
        sync: (x) async {},
        switchAndReopen: (id, {String? revertTo}) async => switches.add(id),
        detectedName: () async => '李秀兰',
      );

      expect(switches, [p.id, 'p-1'], reason: '"顺手补齐"不该改变用户此刻正在看谁');
      expect(ProfileManager.instance.byId(p.id)!.name, '李秀兰');
    });

    test('病历里识别不到姓名:名字留在占位串上,不改成空的', () async {
      final p = await placeholder(ProfileManager.restoringPlaceholderName);
      await firstSyncAndName(
        p,
        revertTo: 'p-1',
        sync: (x) async {},
        switchAndReopen: (id, {String? revertTo}) async {},
        detectedName: () async => '  ',
      );
      expect(ProfileManager.instance.byId(p.id)!.name, ProfileManager.restoringPlaceholderName);
    });

    test('同步失败:异常照原样抛出,名字不动(调用方决定怎么处理)', () async {
      final p = await placeholder(ProfileManager.restoringPlaceholderName);
      await expectLater(
        firstSyncAndName(
          p,
          revertTo: 'p-1',
          sync: (x) async => throw Exception('pull failed'),
          switchAndReopen: (id, {String? revertTo}) async {},
          detectedName: () async => '张建国',
        ),
        throwsA(isA<Exception>()),
      );
      expect(ProfileManager.instance.byId(p.id)!.name, ProfileManager.restoringPlaceholderName);
    });

    test('用户自己改过名字:首同步不覆盖它', () async {
      final p = await placeholder('爸爸');
      await firstSyncAndName(
        p,
        revertTo: 'p-1',
        sync: (x) async {},
        switchAndReopen: (id, {String? revertTo}) async {},
        detectedName: () async => '张建国',
      );
      expect(ProfileManager.instance.byId(p.id)!.name, '爸爸');
    });
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

  // 事件的拉/推失败仍然整次抛出(没拉到事件 = 这次同步根本没开始);对象上行
  // (I3)与对象下行(最终评审 I1)都已改成逐个 try/catch,见下一组。
  group('三态:事件拉/推失败时不吞异常', () {
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

    test('fetchObject(用户手点「查看原件」)下载失败:照样抛出,要让他看到', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failObjectDownload = true;
      final rust = FakeRust(missing: [('h2', 'o2')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      await expectLater(
        engine.fetchObject(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'), 'h2'),
        throwsA(isA<ApiFailed>()),
      );
    });
  });

  group('I1:对象下行也逐个 try/catch——一个对象拉不回来,不能作废整次同步', () {
    test('三个对象里一个下载失败:另两个照常落盘、objectsFailed==1、revision 照 bump', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failGetBytesForObjectIds.add('o2');
      final rust = FakeRust(missing: [('h1', 'o1'), ('h2', 'o2'), ('h3', 'o3')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      final before = vaultRevision.value;

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.objectsDown, 2);
      expect(rep.objectsFailed, 1);
      expect(rust.storedObjectIds, ['o1', 'o3'], reason: 'o2 失败不该拖累后面的 o3');
      expect(vaultRevision.value, before + 1, reason: '真的补到了两个对象,UI 该刷新');
    });

    test('签名请求失败(而不是下载本身失败):同样只算这一个对象失败', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []})..failObjectDownload = true;
      final rust = FakeRust(missing: [('h2', 'o2')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.objectsFailed, 1);
      expect(rep.objectsDown, 0);
    });

    test('下行途中箱子被换掉(VaultMismatch):立刻停手,不继续拉下一个', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final rust = _FlipKeyedBeforeStore(missing: [('h1', 'o1'), ('h2', 'o2')]);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<VaultMismatch>()),
      );
      expect(rust.storedObjectIds, isEmpty, reason: '核对没过 = 零写入');
    });
  });

  group('C3:开着 iCloud 同步时不许开通云同步(keyed 开箱会落在一个空的本机目录上)', () {
    test('enableCloud 拒绝,消息告诉用户去设置里关 iCloud,零 API 调用', () async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final p = ProfileManager.instance.current;
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final engine = SyncEngine(
        api,
        AccountSession.instance,
        rust: FakeRust(icloudOn: true),
        reopenVault: () async => fail('不该走到重开箱'),
      );

      await expectLater(
        engine.enableCloud(p),
        throwsA(isA<CloudEnableBlocked>().having((e) => '$e', 'toString', '请先在设置里关闭 iCloud 同步')),
      );
      expect(api.calls, isEmpty);
      expect(ProfileManager.instance.byId(p.id)!.cloudId, isNull, reason: '什么都没落盘');
    });
  });

  group('M4:enableCloud 可续做——注册成功、重开箱/首同步失败之后再点一次', () {
    test('第二次不再重复注册(服务端不会多出一个孤儿档案),直接重开箱 + 首同步', () async {
      await AccountSession.instance.save(
        accountId: 'acc',
        access: 'a',
        refresh: 'r',
        publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
      );
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      final p = ProfileManager.instance.current;
      final api = RecordingApi(server: {'events': [], 'objects': []});
      var reopenCalls = 0;
      var failReopen = true;
      final engine = SyncEngine(
        api,
        AccountSession.instance,
        rust: FakeRust(vaultRoot: '/x/profiles/${p.id}/vault'),
        reopenVault: () async {
          reopenCalls++;
          if (failReopen) throw StateError('重开箱失败(比如此刻磁盘满了)');
        },
      );

      await expectLater(engine.enableCloud(p), throwsA(isA<StateError>()));
      // 注册那一步的后果已经落盘了:服务端有档案、本机有密钥、markCloud 过。
      final half = ProfileManager.instance.byId(p.id)!;
      expect(half.cloudId, 'prf_new');
      expect(await AccountSession.instance.profileKey('prf_new'), isNotNull);
      expect(api.calls.where((c) => c == 'POST /v1/profiles').length, 1);

      // 再点一次:不重新注册,直接重开箱 + 首同步。
      failReopen = false;
      final cloudId = await engine.enableCloud(half);

      expect(cloudId, 'prf_new');
      expect(
        api.calls.where((c) => c == 'POST /v1/profiles').length,
        1,
        reason: '重复注册会在服务端建出第二个档案,第一个从此成了孤儿',
      );
      expect(reopenCalls, 2);
      expect(api.calls, contains('GET /v1/profiles/prf_new/events'), reason: '首同步真的跑了');
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

  group('Task 16 item 9:同步不该自己喂自己(vaultRevision 只在真拉到东西时才 bump)', () {
    test('推了本地事件、但拉/对象下行都是空的:不 bump vaultRevision,不会排下一轮触发器', () async {
      final api = RecordingApi(server: {'events': [], 'objects': []});
      final rust = FakeRust(
        localEvents: [
          SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3)),
        ],
      );
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);
      final before = vaultRevision.value;

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.pulled, 0);
      expect(rep.objectsDown, 0);
      expect(vaultRevision.value, before, reason: '什么都没拉到,不该 bump——否则 debounce 触发器会喂出一个永动同步循环');
    });

    test('拉到了新事件:照常 bump', () async {
      final api = RecordingApi(server: {
        'events': [
          {'device_id': 'd1', 'seq': 1, 'event_id': 'e1', 'ts': 't', 'ciphertext': base64Encode(Uint8List(2))},
        ],
        'objects': [],
      });
      final engine = SyncEngine(api, AccountSession.instance, rust: FakeRust());
      final before = vaultRevision.value;

      final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner'));

      expect(rep.pulled, 1);
      expect(vaultRevision.value, before + 1);
    });
  });

  group('Task 16 item 10:写之前的第二道核对(defense-in-depth,不依赖"排进了队列"这个假设本身永远成立)', () {
    test('拉取网络往返期间箱子被换掉(keyed 状态翻转):写之前的核对拦住,importEvents 零调用', () async {
      final api = RecordingApi(server: {
        'events': [
          {'device_id': 'd1', 'seq': 1, 'event_id': 'e1', 'ts': 't', 'ciphertext': base64Encode(Uint8List(2))},
        ],
      });
      final rust = _FlipKeyedAfterFirstCall();
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      await expectLater(
        engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'owner')),
        throwsA(isA<VaultMismatch>()),
      );
      expect(rust.importCalls, 0, reason: '写之前的核对没过,importEvents 一次都不该被调,零写入');
    });
  });

  group('I2 (fix round 1: Task 15 review) — 同步排进 vault_boot 的 FIFO 队列', () {
    test('"切成员"类动作必须等 syncProfile 的写操作(importEvents)完成才能执行', () async {
      final order = <String>[];
      final api = RecordingApi(server: {
        'events': [
          {'device_id': 'd1', 'seq': 1, 'event_id': 'e1', 'ts': 't', 'ciphertext': base64Encode(Uint8List(2))},
        ],
        'objects': [],
      })..pullDelay = const Duration(milliseconds: 20);
      final rust = _OrderRecordingRust(order);
      final engine = SyncEngine(api, AccountSession.instance, rust: rust);

      // 不 await——`syncProfile` 内部一调就已经把自己排进 `_vaultQueue`,接下来
      // 排的任何操作(哪怕是"切成员"这种跟同步毫不相干的动作)都必须等它。
      final syncFuture = engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: cloudId, role: 'viewer'));
      final switchFuture = runSerialized(() async => order.add('switch'));

      await Future.wait([syncFuture, switchFuture]);

      expect(order, ['write', 'switch'], reason: '切成员必须等同步的写操作完成才轮到,不能在同步进行中间插进来');
    });
  });
}

/// 假 `RustSyncApi`——只在 [FakeRust] 基础上给 `importEvents` 记一笔"写发生了"
/// (测 I2 的排队顺序),不追求覆盖度。
class _OrderRecordingRust extends FakeRust {
  _OrderRecordingRust(this.order);
  final List<String> order;

  @override
  Future<SyncImportOutcomeDto> importEvents(Uint8List profileKey, List<SyncEventDto> events) async {
    order.add('write');
    return super.importEvents(profileKey, events);
  }
}

/// 只用来测 Task 16 item 10(写之前的第二道核对):`currentVaultIsKeyed` 第一次
/// (`syncProfile` 开头的核对)答 true,从第二次起(拉完事件、写之前的核对)答
/// false——模拟"网络往返期间箱子被换掉"。`importEvents` 记一下有没有被调,
/// 断言"核对没过,压根不该走到写这一步"。
class _FlipKeyedAfterFirstCall extends FakeRust {
  int _keyedCalls = 0;
  int importCalls = 0;

  @override
  Future<bool> currentVaultIsKeyed() async {
    _keyedCalls++;
    return _keyedCalls == 1;
  }

  @override
  Future<SyncImportOutcomeDto> importEvents(Uint8List profileKey, List<SyncEventDto> events) async {
    importCalls++;
    return super.importEvents(profileKey, events);
  }
}

/// 只用来测 I1 的 `VaultMismatch` 分支:`currentVaultIsKeyed` 前两次(开头核对 +
/// 第一个对象落盘前的核对)之间翻脸——第一个对象下载完、写之前核对不过,整次
/// 同步必须立刻停,而不是"算这个对象失败、继续下一个"。
class _FlipKeyedBeforeStore extends FakeRust {
  _FlipKeyedBeforeStore({required super.missing});
  int _calls = 0;

  @override
  Future<bool> currentVaultIsKeyed() async {
    _calls++;
    return _calls == 1;
  }
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
