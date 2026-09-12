import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart' as vault_api;
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 推上去的事件信封里 `ts` 字段的**唯一**取值(最终评审 I4)。
///
/// 事件的真实时间戳只在密文里(随 `LogEntry` 一起加密,见 Rust
/// `sync_export_events`)。明文带着它没有任何功能价值——服务端排序/去重只看
/// `(device_id, seq)`——但会在服务端攒出一条「这个账号什么时候、多久一次产生
/// 病历事件」的时间线。服务端的 schema 仍要求这个字段非空(老客户端发过真
/// 时间戳),所以发一个占位常量而不是省掉它。
const wireTs = '0';

/// 当前打开的保险箱和要同步的档案对不上——切换了成员却没重开箱,或者代拍病人的
/// 箱子(unkeyed)还开着。宁可整次同步失败,也不能把不相关的箱子内容推上/拉进
/// 这个云档案(见 C1 review:`SyncEngine` 拿到的 `Profile` 只是个参数,真正写盘
/// 读盘的是进程级单例 vault,两者必须显式核对,不能靠调用顺序自证)。
class VaultMismatch implements Exception {
  const VaultMismatch(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 对 `sync_*` FRB 调用的薄包装,纯粹是为了让 [SyncEngine] 在测试里可以注入假实现
/// (同 `AccountFlow`/`SyncCrypto` 的套路,`flutter test` 不加载 Rust 原生库)。
/// 方法与参数对应 FRB 侧签名;`PlatformInt64` 在本 app 只发的 iOS/安卓上就是
/// `int`(web 才是 BigInt,本项目不发 web——见 `import_flow.dart` 顶部同一条注释),
/// 所以这里直接用 `int`,不必再包一层转换。
abstract class RustSyncApi {
  Future<Uint8List> profileKeyNew();
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext);

  /// 这台设备有没有开 iCloud 同步(持久标记 `<data_dir>/icloud_enabled`)。
  /// [SyncEngine.enableCloud] 拿它挡住「两套同步一起开」——见
  /// [CloudEnableBlocked]。
  Future<bool> icloudEnabled();

  /// 当前打开的保险箱是不是 keyed(云档案)打开的——`SyncEngine` 每次touch vault
  /// 前拿它核对身份(见 [VaultMismatch])。
  Future<bool> currentVaultIsKeyed();

  /// 当前打开的保险箱的真相根目录——同上,核对"这真的是要同步的那个档案"。
  Future<String> currentVaultRoot();

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
  Future<bool> icloudEnabled() async => (await vault_api.icloudStatus()).enabled;

  @override
  Future<bool> currentVaultIsKeyed() => rust.syncCurrentVaultIsKeyed();

  @override
  Future<String> currentVaultRoot() => vault_api.currentVaultRoot();

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

/// 这台设备开着 iCloud 同步,不能给成员开通账号云同步(最终评审 C3)。
///
/// 两套同步搬的是**同一个保险箱的家**:iCloud 开着时,vault 的真相目录在
/// iCloud 容器里(`<container>/Documents/profiles/<id>/vault`);而 keyed 开箱
/// (`vault_boot.openCurrentProfileVault` 的 keyed 分支)只认本机沙盒那条路径,
/// 压根不接容器根。于是「开通云同步」会在一个**空的本机目录**上开出一个空箱子,
/// 用户眼里就是"我的病历凭空消失了"(真相其实还在容器里,但 App 再也不看那边)。
///
/// 宁可不给开,也不能演这一出。`toString` 就是给用户看的那句话。
class CloudEnableBlocked implements Exception {
  const CloudEnableBlocked();
  @override
  String toString() => '请先在设置里关闭 iCloud 同步';
}

/// 一次 [SyncEngine.syncProfile] 的结果。
class SyncReport {
  int pushed = 0;
  int pulled = 0;
  int objectsUp = 0;
  int objectsDown = 0;

  /// 对象上传失败的个数(签名失败、加密失败、PUT 失败、体积超限都算)——不再让
  /// 一个对象的失败拖累整次同步,详见 [SyncEngine.syncProfile] 第 3 步。
  int objectsFailed = 0;

  /// 拉回来的事件里,MAC/链校验没通过、被隔离的条目数——非零说明有台设备的
  /// 密钥不对或被篡改,不代表这次同步本身失败,但值得留意。
  int untrusted = 0;

  /// 撞到需要重排/暂时接不上的乱序条目数。`syncProfile` 内部已经自动重拉过一次
  /// (见该方法文档),这里的值是重拉之后仍然剩下的——非零说明这台设备的空洞还在。
  int outOfOrder = 0;

  /// 解不开/反序列化失败的条目数(每个设备最多算一条)。
  int undecodable = 0;

  /// 拉取事件时响应头里没有可信的 `X-Seq-Map`(缺失或解析失败)——本轮跳过了
  /// 事件推送:宁可这次不推,也不能把"本机 since"错当推送水位,那等于把整条本机
  /// 日志当成服务端从没见过、重推一遍。
  bool pushSkippedNoWatermark = false;
}

/// 档案上云之后的推拉引擎:事件按水位增量推拉,对象按需上下行(服务端没有的才
/// 传、本机缺的才拉)。服务端全程只见密文——本文件里不得出现任何解密调用之外的
/// 明文病历字段。
///
/// **每个会碰进程级 vault 的方法开头都核对身份**(见 [VaultMismatch])——vault 是
/// 进程级单例,`Profile p` 只是个参数,两者不天然一致:切换成员没重开箱、或者
/// 医生模式的代拍病人箱子还开着,都会让"传进来的 p"和"实际写盘读盘的箱子"对不上。
class SyncEngine {
  SyncEngine(this.api, this.session, {this.rust = const RustSync(), this.reopenVault = openCurrentProfileVault});

  final ApiClient api;
  final AccountSession session;
  final RustSyncApi rust;

  /// 开通云同步之后重开箱(走 keyed 路径)。测试注入点,默认真实的
  /// `vault_boot.openCurrentProfileVault`——它内部调 FRB,`flutter test` 跑不到,
  /// 于是 [enableCloud] 的"注册成功之后"那半截一直没法测(M4 的续开通逻辑正好
  /// 全在那半截)。同 `AccountFlow.reopenCurrentProfileVault` 的套路。
  final Future<void> Function() reopenVault;

  /// 单次推送最多多少条事件(`services/api/db.py` 的 `MAX_EVENTS_PER_PUSH`)。
  static const maxEventsPerPush = 500;

  /// 单条事件密文上限(`services/api/db.py` 的 `EVENT_MAX_BYTES`)。超过这个
  /// 数的单条事件服务端一定拒收(还会连累同一批里其它合法事件一起被 400),
  /// 所以推送前就把它们摘出去,不做无谓的一趟网络往返。
  // ponytail: 摘出去的事件目前直接跳过、不重试也不告警——真出现单条事件超 1MiB
  // (正常病历文本不会),这里需要一个专门的失败反馈通道,而不是默默不推。
  static const maxEventBytes = 1024 * 1024;

  /// 单个对象体积上限(`services/api/app.py` 的 `OBJECT_MAX_BYTES`)——签名前先
  /// 挡一道,别为一个注定被服务端拒收的 PUT 走一趟签名请求。
  static const objectMaxBytes = 64 * 1024 * 1024;

  /// 开通云同步:建一把新的档案密钥,用账号公钥封起来上传给自己(服务端只存
  /// 密文),登记为 owner,存进本机 secure storage,写回 [ProfileManager],
  /// 重开箱(走 keyed 路径)后立刻跑一次首同步。
  ///
  /// 只能给**当前打开的那个成员**开通——`p` 只是调用方传来的一个值对象,真正在
  /// 磁盘上被读写的是 [ProfileManager.currentId] 指向的那个成员;两者不一致时
  /// (比如切换成员的 UI 状态和实际 `currentId` 没同步)拒绝执行,不猜。
  ///
  /// **开着 iCloud 同步时拒绝**(最终评审 C3,见 [CloudEnableBlocked])。
  ///
  /// **可续做**(最终评审 M4):这件事有三步(注册 → 重开箱 → 首同步),后两步
  /// 任何一步失败,前面那步的后果都已经落盘了——服务端有了这个档案、本机有了
  /// 密钥、`profiles.json` 里已经 `markCloud` 过。再点一次不能重新走注册:那会
  /// 在服务端建出第二个档案、本机第二把密钥,第一个档案从此成了没人认领的孤儿。
  /// 所以已经有 [Profile.cloudId] 时直接从"重开箱 + 首同步"这一步继续。
  Future<String> enableCloud(Profile p) async {
    if (p.id != ProfileManager.instance.currentId.value) {
      throw VaultMismatch(
        '只能给当前打开的成员开通云同步(当前=${ProfileManager.instance.currentId.value},传入=${p.id})',
      );
    }
    if (await rust.icloudEnabled()) throw const CloudEnableBlocked();
    final cloudId = p.cloudId ?? await registerCloudProfile(p);
    await reopenVault(); // 走 vault_boot 的 FIFO 队列,重开成 keyed
    await syncProfile(Profile(id: p.id, name: p.name, cloudId: cloudId, role: p.role ?? 'owner'));
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
    // 同 `Grants.redeem` 的道理:这个 cloudId 万一命中过之前本机删过的黑名单,
    // 这次重新开通是合法的,得清掉,不然下次 `restoreProfileKeys` 会把它当历史
    // 删除跳过。
    await session.clearCloudProfileTombstone(cloudId);
    await ProfileManager.instance.markCloud(p.id, cloudId, 'owner', null);
    return cloudId;
  }

  /// 核对"此刻进程里开着的箱子"确实是 [p](keyed 打开、且根目录对应 `p.id`)。
  /// 不通过就抛 [VaultMismatch],什么都不做——不发一次网络请求,不碰任何本地
  /// 状态。keyed 和原路径开的是同一套目录规则,唯一能分辨"这箱子到底是谁的"
  /// 只能问 Rust 自己(同 `vault_boot.ensureProxyVaultOpen` 的思路)。
  Future<void> _assertVaultMatches(Profile p) async {
    if (!await rust.currentVaultIsKeyed()) {
      throw VaultMismatch('当前打开的保险箱不是这个云档案(keyed)——可能是本地档案或代拍病人的箱子还开着,拒绝同步');
    }
    final actual = await rust.currentVaultRoot();
    if (!actual.endsWith('/profiles/${p.id}/vault')) {
      throw VaultMismatch('当前打开的保险箱($actual)与要同步的档案(id=${p.id})不一致,拒绝同步');
    }
  }

  /// 同 [vault_boot.runSerialized] 的队列——同步的整段推拉(含网络往返)排进去,
  /// 不能只有"开箱"排队(见 Task 15 review I2):同步进行到一半、另一路把箱子
  /// 切换掉,写入就会落进错的档案。`fetchObject` 也走同一条队列。
  Future<SyncReport> syncProfile(Profile p) => runSerialized(() => _syncProfileLocked(p));

  Future<SyncReport> _syncProfileLocked(Profile p) async {
    await _assertVaultMatches(p);
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final rep = SyncReport();
    final canWrite = p.role == 'owner' || p.role == 'editor';

    try {
      await _doSyncProfile(p, cloudId, key, rep, canWrite);
      Analytics.track(AnalyticsEvent.syncRun, {
        'ok': true,
        'pushed_bucket': Bucket.count(rep.pushed),
        'pulled_bucket': Bucket.count(rep.pulled),
      });
      return rep;
    } catch (_) {
      Analytics.track(AnalyticsEvent.syncRun, {
        'ok': false,
        'pushed_bucket': Bucket.count(rep.pushed),
        'pulled_bucket': Bucket.count(rep.pulled),
      });
      rethrow;
    }
  }

  /// [syncProfile] 的实际推拉逻辑,拆出来只是为了让 try/catch 包住的范围
  /// 一眼看清——本身不是独立可调用的公共步骤。
  ///
  /// 虽然整段已经排进 [runSerialized] 队列(见 [syncProfile]),队列挡住的是
  /// "同一时刻有两段代码在动 vault";每一次真正落笔写入(`importEvents`/
  /// `storeObject`)之前仍然**再核一遍身份**(见 Task 15 review I2)——这是
  /// 防御性的第二道闸,不依赖"这段代码此刻确实排在队列里"这个假设本身永远成立。
  Future<void> _doSyncProfile(Profile p, String cloudId, Uint8List key, SyncReport rep, bool canWrite) async {
    // 1. 拉:本机水位当 since,服务端只给比它新的;响应头 X-Seq-Map 顺带带回
    // 该 profile 每个 device 当前的最大 seq——第 2 步的推送水位就是它。
    final local = <String, int>{for (final e in await rust.localSeqMap()) e.$1: e.$2};
    final (body, headers) = await api.getJsonWithHeaders(
      '/v1/profiles/$cloudId/events',
      query: {'since': jsonEncode(local)},
    );
    final pulled = _decodeEvents(body);
    if (pulled.isNotEmpty) {
      await _assertVaultMatches(p); // 网络往返期间箱子可能已经变了,写之前再核一次
      final outcome = await rust.importEvents(key, pulled);
      rep.pulled = outcome.applied;
      rep.untrusted = outcome.untrusted;
      rep.undecodable = outcome.undecodable;
      rep.outOfOrder = outcome.outOfOrder;
      if (outcome.outOfOrder > 0 || outcome.untrusted > 0 || outcome.undecodable > 0) {
        debugPrint(
          'SyncEngine.syncProfile($cloudId): import 异常 applied=${outcome.applied} '
          'outOfOrder=${outcome.outOfOrder} untrusted=${outcome.untrusted} undecodable=${outcome.undecodable}',
        );
      }
      if (outcome.outOfOrder > 0) {
        // 重拉一次:把这批事件涉及的设备从 since 里摘掉,逼服务端把这些设备的
        // 历史整段重发,弥合乱序造成的缺口。只重试这一次——再不行就如实报出去
        // (`rep.outOfOrder` 留着重拉后的值),不无限重试卡住整次同步。
        final retrySince = Map<String, int>.from(local);
        for (final e in pulled) {
          retrySince.remove(e.deviceId);
        }
        final (body2, _) = await api.getJsonWithHeaders(
          '/v1/profiles/$cloudId/events',
          query: {'since': jsonEncode(retrySince)},
        );
        final pulled2 = _decodeEvents(body2);
        if (pulled2.isNotEmpty) {
          await _assertVaultMatches(p);
          final outcome2 = await rust.importEvents(key, pulled2);
          rep.pulled += outcome2.applied;
          rep.untrusted += outcome2.untrusted;
          rep.undecodable += outcome2.undecodable;
          rep.outOfOrder = outcome2.outOfOrder;
          if (outcome2.outOfOrder > 0) {
            debugPrint('SyncEngine.syncProfile($cloudId): 重拉后 outOfOrder 仍为 ${outcome2.outOfOrder},持续存在');
          }
        }
      }
    }

    if (canWrite) {
      // 2. 推:服务端水位来自 X-Seq-Map,不能从 since 反推(since 只是本机已有
      // 到哪,推不出"服务端已有到哪"——本机自己这台设备的段服务端可能还没有)。
      // 头缺失/解不出来一律当错误处理,不能悄悄退化成"当空水位推",那等于把
      // 整条本机日志当成服务端从没见过、重推一遍。
      final serverWatermark = _parseSeqMap(headers['x-seq-map']);
      if (serverWatermark == null) {
        rep.pushSkippedNoWatermark = true;
      } else {
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
                    // 不发 `e.ts`,发常量 [wireTs]——见它的文档(最终评审 I4)。
                    // Rust 侧导出时已经填的就是这个常量,这里**再写死一次**不是
                    // 重复:这一层是真正拼请求体的地方,哪天 Rust 那边改回去,
                    // 明文时间戳也出不了这道门。
                    'ts': wireTs,
                    'ciphertext': base64Encode(e.ciphertext),
                  },
                )
                .toList(),
          );
          rep.pushed += chunk.length;
        }
      }

      // 3. 对象上行:本机有、服务端还没有的才传;逐个 try/catch,一个对象的
      // 失败不拖累其它对象、也不拖累后面的对象下行。服务端在**签名时**就登记了
      // object_id(见 `db.object_register`)——这只代表"打算传",不代表"真的传
      // 成功了"。PUT 真失败时把这个 object_id 记进本地"待重传"清单(按 cloudId
      // 分开存在 SharedPreferences 里),下次同步哪怕服务端清单里已经有它,也照
      // 样重传,直到真的传成功才从清单里摘掉。
      final retry = await _loadObjectRetrySet(cloudId);
      var retryChanged = false;
      final serverObjs = ((await api.getJson('/v1/profiles/$cloudId/objects')) as List).cast<String>().toSet();
      for (final (hash, oid) in await rust.allObjectIds(key)) {
        final needsUpload = !serverObjs.contains(oid) || retry.contains(oid);
        if (!needsUpload) continue;
        try {
          final (_, ct) = await rust.encryptObject(key, hash);
          if (ct.length > objectMaxBytes) {
            rep.objectsFailed++;
            continue;
          }
          final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {
            'object_id': oid,
            'verb': 'PUT',
            'size': ct.length,
          });
          await api.putBytes(s['url'] as String, ct);
          rep.objectsUp++;
          if (retry.remove(oid)) retryChanged = true;
        } catch (_) {
          rep.objectsFailed++;
          if (retry.add(oid)) retryChanged = true;
        }
      }
      if (retryChanged) await _saveObjectRetrySet(cloudId, retry);
    }

    // 4. 对象下行:事件引用了、本机还没有的。即使第 3 步有对象上传失败,这里
    // 照常跑——上传失败已经被 try/catch 挡住,不会传播到这里。
    //
    // **逐个 try/catch,同第 3 步**(最终评审 I1):原来一个对象下载失败(服务端
    // 还没收到那个对象、签名 403、网络断在中间)会让整次同步抛出去,于是**这一轮
    // 已经拉回来的事件和前面几个对象都不算数**——`bumpVaultRevision()` 在函数
    // 末尾,抛出去就跑不到,UI 看到的是"同步失败",而磁盘上其实已经多了东西。
    // 一份附件缺了就是缺了(下次同步、或者查看器里 `fetchObject` 按需补),不该
    // 拖累别的附件,更不该让整次同步的成果作废。
    for (final (_, oid) in await rust.missingObjects(key)) {
      try {
        final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {'object_id': oid, 'verb': 'GET'});
        final bytes = await api.getBytes(s['url'] as String);
        await _assertVaultMatches(p); // 每个对象下载完、真正落盘之前都再核一次
        await rust.storeObject(key, oid, bytes);
        rep.objectsDown++;
      } on VaultMismatch {
        // 箱子被换掉不是"这一个对象的问题"——继续下一个只会拿错箱子重试,整次
        // 同步必须立刻停手(同第 1 步写之前那道核对的处理)。
        rethrow;
      } catch (_) {
        rep.objectsFailed++;
      }
    }

    // 只在真的写了东西(拉到新事件/补齐了对象)才通知——`vaultRevision` 挂着
    // debounced push 触发器(见文件末尾 `triggerBackgroundSync`),无条件 bump
    // 会让"什么都没同步到"的一次同步 3 秒后又触发下一次同步,自己喂自己,
    // 前台一直转下去(见 Task 16 item 9)。
    if (rep.pulled > 0 || rep.objectsDown > 0) bumpVaultRevision();
  }

  /// 按需拉单个对象(如查看器打开一份还没同步下来的文档时调)。找不到就是本机
  /// 已经有了,或者根本没有事件引用这个哈希——两种情况都什么也不做。同 [syncProfile],
  /// 走同一条 [runSerialized] 队列。
  Future<void> fetchObject(Profile p, String hash) => runSerialized(() => _fetchObjectLocked(p, hash));

  Future<void> _fetchObjectLocked(Profile p, String hash) async {
    await _assertVaultMatches(p);
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final missing = await rust.missingObjects(key);
    final match = missing.where((e) => e.$1 == hash);
    if (match.isEmpty) return;
    final oid = match.first.$2;
    final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {'object_id': oid, 'verb': 'GET'});
    final bytes = await api.getBytes(s['url'] as String);
    await _assertVaultMatches(p); // 写之前再核一次
    await rust.storeObject(key, oid, bytes);
    bumpVaultRevision();
  }

  List<SyncEventDto> _decodeEvents(dynamic body) => (body as List)
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

  /// 把 `X-Seq-Map` 响应头解成 `{device_id: seq}`。缺失、不是 JSON 对象、或者
  /// 有任何一条不是 `字符串 -> 整数` 都视为"没有可信水位",返回 null——调用方据
  /// 此跳过推送,而不是悄悄退化成空 map(那等于把整条本机日志当全新的推一遍)。
  Map<String, int>? _parseSeqMap(String? header) {
    if (header == null) return null;
    try {
      final decoded = jsonDecode(header);
      if (decoded is! Map) return null;
      final out = <String, int>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! int) return null;
        out[entry.key as String] = entry.value as int;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  String _retryPrefsKey(String cloudId) => 'sync_retry_objects_$cloudId';

  Future<Set<String>> _loadObjectRetrySet(String cloudId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_retryPrefsKey(cloudId)) ?? const <String>[]).toSet();
  }

  Future<void> _saveObjectRetrySet(String cloudId, Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_retryPrefsKey(cloudId), ids.toList());
  }

  Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }
}

/// debounced push(`vaultRevision` 变化 3 秒后)和 app-resume pull 共用的一段
/// no-op 判断 + 静默失败:没登录、或当前成员没开通云同步(没有 [Profile.cloudId])
/// 时什么都不做,不发任何请求;真的跑了的话失败也不抛——后台触发器不该弹错误
/// 打断用户,想看这次到底成没成,去账号屏点「立即同步」(那边会显式展示
/// [SyncReport]/异常)。
///
/// 抽成顶层函数(而不是塞进 `main.dart` 的 `State` 里)是为了让"没登录/没
/// cloudId 时 no-op"这条契约能在不启动真实 Rust/Flutter 绑定的 `flutter test`
/// 里被单测钉住;`main.dart` 只负责接线(debounce 计时器 + 生命周期回调),不重复
/// 这段判断逻辑——所以这是一个正常的公开函数,不是仅供测试用的入口。
///
/// **重叠触发合并成"一次在跑 + 最多一次补跑"**(见 Task 15 review I2):
/// debounced push 和 app-resume pull 可能在极短时间内先后触发。`syncProfile`
/// 本身已经排进 `vault_boot` 的 FIFO 队列,重叠调用不会真的同时写 vault,但那
/// 只保证"不乱",不保证"不浪费"——两次触发会各自完整跑一遍推拉,两倍网络往返。
/// 用一个模块级的"正在跑"标记 + "有没有人等着再来一轮"标记合并:后来者在
/// 前一轮跑完之前不再单独起一轮,只是把"再补一轮"这件事记下来,前一轮跑完后
/// 立刻替它跑那一轮——不是无限攒(标记是布尔不是计数),也不是丢弃。
bool _backgroundSyncRunning = false;
bool _backgroundSyncRerunRequested = false;

Future<void> triggerBackgroundSync({
  required AccountSession session,
  required Profile? Function() currentProfile,
  required Future<SyncReport> Function(Profile) sync,
}) async {
  if (_backgroundSyncRunning) {
    _backgroundSyncRerunRequested = true;
    return;
  }
  _backgroundSyncRunning = true;
  try {
    do {
      _backgroundSyncRerunRequested = false;
      await _runBackgroundSyncOnce(session: session, currentProfile: currentProfile, sync: sync);
    } while (_backgroundSyncRerunRequested);
  } finally {
    _backgroundSyncRunning = false;
  }
}

Future<void> _runBackgroundSyncOnce({
  required AccountSession session,
  required Profile? Function() currentProfile,
  required Future<SyncReport> Function(Profile) sync,
}) async {
  if (!session.loggedIn.value) return;
  final profile = currentProfile();
  if (profile == null || profile.cloudId == null) return;
  try {
    await sync(profile);
  } catch (_) {
    // 静默——见上面的文档。
  }
}

/// 「切到这个云档案的箱子 → 首同步 → 用拉下来的病历里识别到的姓名给它命名」。
///
/// **两条路共用**,而在这之前只有第一条真的做了这件事:
///
///  * `Grants.redeem`(医生/家属扫码兑换):做完停在新档案上 —— 那正是用户刚
///    点头要加入的东西。[returnTo] 传 null。
///  * `AccountFlow.restoreProfileKeys`(换机/清过数据之后领回自己的档案,A5):
///    做完必须切回用户原来在看的那个成员 —— 这一步是"顺手补齐",不该改变用户
///    此刻正在看谁。[returnTo] 传原成员。
///
/// A5 之前那条路只建一个名叫「云端档案 a1b2c3」的空壳成员就收手:既不同步也不
/// 改名。用户换了台新手机、解锁完账号,看到的是一串内部 id 和 0 份病历 ——
/// 看起来就是数据丢了,而其实一次同步就能全拉回来。
///
/// [revertTo] 是**开箱失败时** `currentId` 要退回哪个成员。不能用
/// `switchProfileAndReopen` 的默认值:两条路都是 `ProfileManager.create()` 先把
/// current 改成新建那个之后才走到这里(见 `vault_boot.switchProfileAndReopenImpl`
/// 对 `revertTo` 的说明)。
///
/// 三个副作用做成参数,理由同 `vault_boot.runWipeSequence`:真实现要碰 Rust 原生
/// 库(开箱、读病历里的姓名)和网络,`flutter test` 跑不到;而"顺序对不对、
/// 回退/切回的目标对不对"跟它们成不成功无关,必须能单独钉住。
Future<void> firstSyncAndName(
  Profile p, {
  required String revertTo,
  required Future<void> Function(Profile) sync,
  String? returnTo,
  Future<void> Function(String id, {String? revertTo}) switchAndReopen = switchProfileAndReopen,
  Future<String?> Function() detectedName = patientNameFromVault,
}) async {
  await switchAndReopen(p.id, revertTo: revertTo);
  await sync(p);
  // 占位名只在首同步完成前露面。按 **id** 命名,不是"给当前成员命名" —— 这里
  // 当前成员恰好就是它,但写成 id 之后这件事不再依赖上一行的副作用。
  await ProfileManager.instance.nameCloudProfileOnFirstSync(p.id, await detectedName());
  if (returnTo != null && returnTo != p.id) await switchAndReopen(returnTo);
}

/// [firstSyncAndName] 的默认"真名从哪来":已经拉下来的病历里识别到的患者姓名。
Future<String?> patientNameFromVault() async => (await vault_api.patientProfile()).name;
