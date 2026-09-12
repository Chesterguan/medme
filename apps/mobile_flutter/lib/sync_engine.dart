import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';

/// 对 `sync_*` FRB 调用的薄包装,纯粹是为了让 [SyncEngine] 在测试里可以注入假实现
/// (同 `AccountFlow`/`SyncCrypto` 的套路,`flutter test` 不加载 Rust 原生库)。
/// 方法与参数对应 FRB 侧签名;`PlatformInt64` 在本 app 只发的 iOS/安卓上就是
/// `int`(web 才是 BigInt,本项目不发 web——见 `import_flow.dart` 顶部同一条注释),
/// 所以这里直接用 `int`,不必再包一层转换。
abstract class RustSyncApi {
  Future<Uint8List> profileKeyNew();
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext);

  /// 本机每个 device 段当前可信的最大 seq——拉取水位。
  Future<List<(String, int)>> localSeqMap();

  /// 导出本机日志里 `seq > after[device_id]` 的条目,已加密。
  Future<List<SyncEventDto>> exportEvents(Uint8List profileKey, List<(String, int)> after);

  /// 解密 + 落盘拉回来的事件。
  Future<SyncImportOutcomeDto> importEvents(Uint8List profileKey, List<SyncEventDto> events);

  /// 事件引用了、本机还没有的对象:`(hash, objectId)`。
  Future<List<(String, String)>> missingObjects(Uint8List profileKey);

  /// 本机已落地、可以上传的对象全量清单:`(hash, objectId)`。
  Future<List<(String, String)>> allObjectIds(Uint8List profileKey);

  /// 读本地对象 + 加密,供上传。返回 `(objectId, ciphertext)`。
  Future<(String, Uint8List)> encryptObject(Uint8List profileKey, String hash);

  /// 解密拉回来的对象、存入本地 CAS(校验 + materialize 都在 Rust 侧完成)。
  Future<String> storeObject(Uint8List profileKey, String objectId, Uint8List ciphertext);
}

class RustSync implements RustSyncApi {
  const RustSync();

  @override
  Future<Uint8List> profileKeyNew() => rust.syncProfileKeyNew();

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) =>
      rust.syncSealTo(public: public, plaintext: plaintext);

  @override
  Future<List<(String, int)>> localSeqMap() => rust.syncLocalSeqMap();

  @override
  Future<List<SyncEventDto>> exportEvents(Uint8List profileKey, List<(String, int)> after) =>
      rust.syncExportEvents(profileKey: profileKey, after: after);

  @override
  Future<SyncImportOutcomeDto> importEvents(Uint8List profileKey, List<SyncEventDto> events) =>
      rust.syncImportEvents(profileKey: profileKey, events: events);

  @override
  Future<List<(String, String)>> missingObjects(Uint8List profileKey) =>
      rust.syncMissingObjects(profileKey: profileKey);

  @override
  Future<List<(String, String)>> allObjectIds(Uint8List profileKey) =>
      rust.syncAllObjectIds(profileKey: profileKey);

  @override
  Future<(String, Uint8List)> encryptObject(Uint8List profileKey, String hash) =>
      rust.syncEncryptObject(profileKey: profileKey, hash: hash);

  @override
  Future<String> storeObject(Uint8List profileKey, String objectId, Uint8List ciphertext) =>
      rust.syncStoreObject(profileKey: profileKey, objectId: objectId, ciphertext: ciphertext);
}

/// 一次 [SyncEngine.syncProfile] 的结果:推了几条事件、拉了几条(落盘成功的,
/// 即 [SyncImportOutcomeDto.applied])、上传/下载了几个对象。
class SyncReport {
  int pushed = 0;
  int pulled = 0;
  int objectsUp = 0;
  int objectsDown = 0;
}

/// 档案上云之后的推拉引擎:事件按水位增量推拉,对象按需上下行(服务端没有的才
/// 传、本机缺的才拉)。服务端全程只见密文——本文件里不得出现任何解密调用之外的
/// 明文病历字段。
class SyncEngine {
  SyncEngine(this.api, this.session, {this.rust = const RustSync()});

  final ApiClient api;
  final AccountSession session;
  final RustSyncApi rust;

  /// 单次推送最多多少条事件(`services/api/db.py` 的 `MAX_EVENTS_PER_PUSH`)。
  static const maxEventsPerPush = 500;

  /// 单条事件密文上限(`services/api/db.py` 的 `EVENT_MAX_BYTES`)。超过这个
  /// 数的单条事件服务端一定拒收(还会连累同一批里其它合法事件一起被 400),
  /// 所以推送前就把它们摘出去,不做无谓的一趟网络往返。
  // ponytail: 摘出去的事件目前直接跳过、不重试也不告警——真出现单条事件超 1MiB
  // (正常病历文本不会),这里需要一个专门的失败反馈通道,而不是默默不推。
  static const maxEventBytes = 1024 * 1024;

  /// 开通云同步:建一把新的档案密钥,用账号公钥封起来上传给自己(服务端只存
  /// 密文),登记为 owner,存进本机 secure storage,写回 [ProfileManager],
  /// 重开箱(走 keyed 路径)后立刻跑一次首同步。
  Future<String> enableCloud(Profile p) async {
    final cloudId = await registerCloudProfile(p);
    await openCurrentProfileVault(); // 走 vault_boot 的 FIFO 队列,重开成 keyed
    await syncProfile(Profile(id: p.id, name: p.name, cloudId: cloudId, role: 'owner'));
    return cloudId;
  }

  /// [enableCloud] 里不碰 FFI 开箱的那半截:建密钥、封给自己公钥、POST
  /// `/v1/profiles`、密钥存本机、[ProfileManager.markCloud]。拆出来单独可测——
  /// `flutter test` 不能跑到 `openCurrentProfileVault`(需要真实 Rust 原生库),
  /// 但这半截的逻辑用假 API/假 Rust 就能钉住。返回新的 `cloudId`。
  @visibleForTesting
  Future<String> registerCloudProfile(Profile p) async {
    final key = await rust.profileKeyNew();
    final pub = session.publicKey;
    if (pub == null) throw StateError('账号公钥未就绪,不能开通云同步');
    final wrapped = await rust.sealTo(pub, key);
    final r = await api.postJson('/v1/profiles', {'wrapped_profile_key': base64Encode(wrapped)});
    final cloudId = r['profile_id'] as String;
    await session.putProfileKey(cloudId, key);
    await ProfileManager.instance.markCloud(p.id, cloudId, 'owner', null);
    return cloudId;
  }

  Future<SyncReport> syncProfile(Profile p) async {
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final rep = SyncReport();
    final canWrite = p.role == 'owner' || p.role == 'editor';

    // 1. 拉:本机水位当 since,服务端只给比它新的;响应头 X-Seq-Map 顺带带回
    // 该 profile 每个 device 当前的最大 seq——第 2 步的推送水位就是它。
    final local = <String, int>{for (final e in await rust.localSeqMap()) e.$1: e.$2};
    final (body, headers) = await api.getJsonWithHeaders(
      '/v1/profiles/$cloudId/events',
      query: {'since': jsonEncode(local)},
    );
    final pulled = (body as List)
        .map(
          (e) => SyncEventDto(
            deviceId: e['device_id'] as String,
            seq: e['seq'] as int,
            eventId: e['event_id'] as String,
            ts: e['ts'] as String,
            ciphertext: base64Decode(e['ciphertext'] as String),
          ),
        )
        .toList();
    if (pulled.isNotEmpty) {
      rep.pulled = (await rust.importEvents(key, pulled)).applied;
    }

    if (canWrite) {
      // 2. 推:服务端水位来自 X-Seq-Map,不能从 since 反推(since 只是本机已有
      // 到哪,推不出"服务端已有到哪"——本机自己这台设备的段服务端可能还没有)。
      final serverWatermark = <String, int>{};
      final seqMapHeader = headers['x-seq-map'];
      if (seqMapHeader != null) {
        (jsonDecode(seqMapHeader) as Map).forEach((k, v) => serverWatermark[k as String] = v as int);
      }
      final toPush = (await rust.exportEvents(
        key,
        serverWatermark.entries.map((e) => (e.key, e.value)).toList(),
      )).where((e) => e.ciphertext.length <= maxEventBytes).toList();
      for (final chunk in _chunk(toPush, maxEventsPerPush)) {
        await api.postJson(
          '/v1/profiles/$cloudId/events',
          chunk
              .map(
                (e) => {
                  'device_id': e.deviceId,
                  'seq': e.seq,
                  'event_id': e.eventId,
                  'ts': e.ts,
                  'ciphertext': base64Encode(e.ciphertext),
                },
              )
              .toList(),
        );
        rep.pushed += chunk.length;
      }

      // 3. 对象上行:本机有、服务端还没有的。
      final serverObjs = ((await api.getJson('/v1/profiles/$cloudId/objects')) as List).cast<String>().toSet();
      for (final (hash, oid) in await rust.allObjectIds(key)) {
        if (serverObjs.contains(oid)) continue;
        final (_, ct) = await rust.encryptObject(key, hash);
        final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {
          'object_id': oid,
          'verb': 'PUT',
          'size': ct.length,
        });
        await api.putBytes(s['url'] as String, ct);
        rep.objectsUp++;
      }
    }

    // 4. 对象下行:事件引用了、本机还没有的。
    for (final (_, oid) in await rust.missingObjects(key)) {
      final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {'object_id': oid, 'verb': 'GET'});
      await rust.storeObject(key, oid, await api.getBytes(s['url'] as String));
      rep.objectsDown++;
    }

    bumpVaultRevision();
    return rep;
  }

  /// 按需拉单个对象(如查看器打开一份还没同步下来的文档时调)。找不到就是本机
  /// 已经有了,或者根本没有事件引用这个哈希——两种情况都什么也不做。
  Future<void> fetchObject(Profile p, String hash) async {
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final missing = await rust.missingObjects(key);
    final match = missing.where((e) => e.$1 == hash);
    if (match.isEmpty) return;
    final oid = match.first.$2;
    final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {'object_id': oid, 'verb': 'GET'});
    await rust.storeObject(key, oid, await api.getBytes(s['url'] as String));
    bumpVaultRevision();
  }

  Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }
}
