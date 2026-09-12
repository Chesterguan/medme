import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grants.dart' show Grants;
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:mobile_flutter/sync_engine.dart' show pendingCloudEnable, pendingFirstSync;
import 'package:mobile_flutter/vault_boot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// 本机在服务端的登记名——首次用时生成、存进 shared_preferences,后续复用。
/// 不落 secure storage:它不是密钥,只是设备批准/审计用的一个标识符,泄露无害。
Future<String> deviceId() async {
  final p = await SharedPreferences.getInstance();
  var id = p.getString('device_id');
  if (id == null) {
    final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
    id = base64UrlEncode(bytes).replaceAll('=', '');
    await p.setString('device_id', id);
  }
  return id;
}

/// 登录之后、密钥就绪之前,UI 该走哪条路。
enum LoginOutcome {
  /// 服务端还没有这个账号的密钥(`GET /v1/account/keys` 404)—— 首次注册,
  /// 需要设口令、生成密钥对。
  needsKeySetup,

  /// 服务端有密钥,但本机没有解出来的私钥(新设备/清过 App)—— 需要口令或
  /// 恢复码解锁。
  needsUnlock,

  /// 本机已经有私钥,可以直接用。
  ready,
}

/// 「把云端档案清单拉回来」最多等多久(`AccountFlow.restoreProfileKeys`)。
///
/// 比 `Net` 自己那两个超时(连接 20s + 空闲 30s)短得多是刻意的:这一步跑在启动
/// 序列里,拿不到清单只是"这次没补齐",下一次启动/登录还会再来;而让它最坏吊 50 秒
/// 会把后面整条链(解密、建成员、排首同步队列)一起堵住。
///
/// **不是 `const`**:测试要把它改小。这是一个真实的 `Timer`,在 `test()` 里等 10 秒
/// 就是等 10 秒真实时间 —— 为一条用例把整个套件拖慢一半不值得(同
/// `Analytics.debugSink` 的套路:一个模块级可替换的钩子)。
@visibleForTesting
Duration profilesFetchBudget = const Duration(seconds: 10);

/// 新设备出的那张「请用旧手机扫我」的码,前缀 + 版本。
///
/// 内容是 `mdv1.<device_id>.<临时公钥 b64url>` —— **一个秘密都不含**:device_id 只是
/// 一个设备标识符(泄露无害,见 [deviceId]),临时公钥是公钥。旁人拍到这张码能做的
/// 事只有"也给这台设备发一份批准",而发批准需要**旧设备上已解锁的账号私钥**,他没有。
const deviceApprovalPrefix = 'mdv1';

/// 解析上面那张码。认不出来返回 null —— 旧设备扫到别的二维码(地铁广告、微信付款码)
/// 是最常见的情形,那不是错误,只是"这不是我要的东西"。
///
/// 纯函数(不碰网络/FFI),所以"什么算一张合法的批准码"这条判断能单独钉住;
/// 生产调用方是 `account_screen.dart` 的 `_scanApproveDevice`。
({String deviceId, Uint8List ephPublic})? parseDeviceApprovalCode(String raw) {
  final parts = raw.trim().split('.');
  if (parts.length != 3 || parts[0] != deviceApprovalPrefix) return null;
  if (parts[1].isEmpty) return null;
  try {
    final pub = base64Url.decode(base64Url.normalize(parts[2]));
    // X25519 公钥恒为 32 字节。长度不对的一律当作"不是这种码",不拿它去调服务端。
    if (pub.length != 32) return null;
    return (deviceId: parts[1], ephPublic: Uint8List.fromList(pub));
  } catch (_) {
    return null;
  }
}

/// [AccountFlow.requestDeviceApproval] 的返回值:要显示成二维码的那串字 + **只在
/// 内存里**的临时私钥(用来拆开旧设备封回来的账号私钥)。
///
/// 临时私钥刻意不落盘:它的生命周期就是用户举着这张码的那两分钟,落盘只是多一处
/// 能解开账号私钥的材料躺在一台**还没被批准**的设备上。
typedef DeviceApprovalRequest = ({String code, Uint8List ephSecret});

/// 口令/恢复码解不开私钥。**绝不吞掉、绝不清 session**——调用方只应据此展示
/// 错误并允许重试,账号登录态本身不受影响。
class UnlockFailed implements Exception {
  const UnlockFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 对 `sync_*` FRB 调用的薄包装,纯粹是为了让 [AccountFlow] 在测试里可以注入假实现
/// (widget test 不应该碰真实 Rust bridge)。方法与参数一一对应 FRB 侧签名。
abstract class SyncCrypto {
  Future<(Uint8List, Uint8List)> accountKeysNew();
  Future<Uint8List> wrapPrivate(Uint8List secret, String password, Uint8List salt, int mKib, int t, int p);
  Future<Uint8List> unwrapPrivatePw(Uint8List blob, String password, Uint8List salt, int mKib, int t, int p);
  Future<String> recoveryCodeNew();
  Future<Uint8List> wrapPrivateRc(Uint8List secret, String code);
  Future<Uint8List> unwrapPrivateRc(Uint8List blob, String code);

  /// 设备批准:把 `plaintext`(本机账号私钥)用对方设备的临时公钥封起来,只有
  /// 那台设备自己的临时私钥能拆开(`sync_open_sealed`,在那台设备上跑,不在这里)。
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext);

  /// [sealTo] 的反向操作:用自己的私钥拆开别人用自己公钥封的密文。
  /// [AccountFlow.restoreProfileKeys] 拿它把 `wrapped_profile_key`(账号公钥封的
  /// 档案密钥)解出来——退出登录/换设备之后"重新登录自动恢复"的真正实现
  /// (Task 15 review C1:这条路径之前完全没有 Dart 调用点,是一句假文案)。
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob);
}

class RustCrypto implements SyncCrypto {
  const RustCrypto();

  @override
  Future<(Uint8List, Uint8List)> accountKeysNew() => rust.syncAccountKeysNew();

  @override
  Future<Uint8List> wrapPrivate(Uint8List secret, String password, Uint8List salt, int mKib, int t, int p) =>
      rust.syncWrapPrivate(secret: secret, password: password, salt: salt, mKib: mKib, t: t, p: p);

  @override
  Future<Uint8List> unwrapPrivatePw(Uint8List blob, String password, Uint8List salt, int mKib, int t, int p) =>
      rust.syncUnwrapPrivatePw(blob: blob, password: password, salt: salt, mKib: mKib, t: t, p: p);

  @override
  Future<String> recoveryCodeNew() => rust.syncRecoveryCodeNew();

  @override
  Future<Uint8List> wrapPrivateRc(Uint8List secret, String code) => rust.syncWrapPrivateRc(secret: secret, code: code);

  @override
  Future<Uint8List> unwrapPrivateRc(Uint8List blob, String code) => rust.syncUnwrapPrivateRc(blob: blob, code: code);

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) => rust.syncSealTo(public: public, plaintext: plaintext);

  @override
  Future<Uint8List> openSealed(Uint8List secret, Uint8List blob) => rust.syncOpenSealed(secret: secret, blob: blob);
}

/// [AccountFlow.prepareKeys] 的返回值——纯内存,不落任何盘。交给
/// [AccountFlow.commitKeys] 才会真正上传 + 存进本机 secure storage。
typedef PreparedKeys = ({
  Uint8List publicKey,
  Uint8List privateKey,
  Uint8List wrappedPw,
  Uint8List wrappedRc,
  Uint8List salt,
  String recoveryCode,
});

/// 注册 / 登录 / 解锁 / 设备批准的编排——不含任何 UI。[AccountScreen] 只负责
/// 按返回值/异常切状态、画界面。
class AccountFlow {
  AccountFlow(
    this.api,
    this.session, {
    this.crypto = const RustCrypto(),
    this.reopenCurrentProfileVault = openCurrentProfileVault,
    this.removeProfile = removeProfileAndReopen,
  });

  final ApiClient api;
  final AccountSession session;
  final SyncCrypto crypto;

  /// [restoreProfileKeys] 补完密钥后,如果补的正好是**当前打开的成员**、且它
  /// 补之前是锁着的,就用这个重开一次——测试注入点,默认真实的
  /// `vault_boot.openCurrentProfileVault`(`flutter test` 不能跑到它内部的
  /// FFI 开箱,测试传一个假的进来)。
  final Future<void> Function() reopenCurrentProfileVault;

  /// A5 最后一步:把那个从没被用过的空默认成员删掉。测试注入点,默认真实的
  /// `vault_boot.removeProfileAndReopen`(删目录 + 重开箱,碰真实 Rust/IO)。
  final Future<bool> Function(String id) removeProfile;


  /// Argon2id 参数。Task 14 会在真机上实测 `syncKdfBenchMs` 之后回来改这一处——
  /// 全部口令包/解包只从这一个常量取,改一次全生效。
  static const kdf = (mKib: 65536, t: 3, p: 1);

  Map<String, dynamic>? _serverKeys;

  /// [loginApple] 是 `Future<void>`(见接口),结果放这里给 UI 读。
  LoginOutcome? lastOutcome;

  Future<void> sendOtp(String phone) => api.postJson('/v1/auth/otp', {'phone': phone});

  /// `account_login` 只覆盖「认证 + session.save」这一小段——**`_afterLogin()`
  /// 必须留在这个 try 外面**。它调的 `GET /v1/account/keys` 只吞 404
  /// (见 `_afterLogin`),非 404 会 rethrow;如果把它包进同一个 try,登录本身
  /// 明明成功了,却会因为账号密钥服务 500 被这里的 catch 接住,再报一条
  /// `ok:false`——一次点击变成两条互相矛盾的 `account_login`。
  Future<LoginOutcome> loginOtp(String phone, String code) async {
    try {
      final r = await api.postJson('/v1/auth/login', {
        'phone': phone,
        'code': code,
        'device_id': await deviceId(),
        'device_name': Platform.operatingSystem,
      });
      await session.save(
        accountId: r['account_id'] as String,
        access: r['access'] as String,
        refresh: r['refresh'] as String,
        loginMethod: 'otp',
        // 只存脱敏串,明文一个字不留(见 `account.dart` 的 `maskPhone`)。
        phoneMasked: maskPhone(phone),
      );
    } catch (_) {
      Analytics.track(AnalyticsEvent.accountLogin, {'method': 'otp', 'ok': false});
      rethrow;
    }
    Analytics.track(AnalyticsEvent.accountLogin, {'method': 'otp', 'ok': true});
    return _afterLogin();
  }

  /// 同 [loginOtp] 的道理:`account_login` 只钉住 Apple 认证 + `session.save`,
  /// `_afterLogin()` 的失败留给调用方自己处理,不污染登录事件。
  Future<void> loginApple() async {
    try {
      final cred = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
      );
      final r = await api.postJson('/v1/auth/apple', {
        'identity_token': cred.identityToken,
        'device_id': await deviceId(),
        'device_name': Platform.operatingSystem,
      });
      await session.save(
        accountId: r['account_id'] as String,
        access: r['access'] as String,
        refresh: r['refresh'] as String,
        loginMethod: 'apple',
      );
    } catch (_) {
      Analytics.track(AnalyticsEvent.accountLogin, {'method': 'apple', 'ok': false});
      rethrow;
    }
    Analytics.track(AnalyticsEvent.accountLogin, {'method': 'apple', 'ok': true});
    await _afterLogin();
  }

  Future<LoginOutcome> _afterLogin() async {
    try {
      final k = await api.getJson('/v1/account/keys') as Map<String, dynamic>;
      _serverKeys = k;
      if (session.privateKey == null) {
        lastOutcome = LoginOutcome.needsUnlock;
      } else {
        // 本机已经有私钥(这台设备之前解锁过)——直接进「已就绪」之前,顺手把
        // 服务端记着、本机还没补上的档案密钥补一遍,见 [restoreProfileKeys]。
        await restoreProfileKeys();
        lastOutcome = LoginOutcome.ready;
      }
    } on ApiFailed catch (e) {
      if (e.status != 404) rethrow;
      lastOutcome = LoginOutcome.needsKeySetup;
    }
    return lastOutcome!;
  }

  /// 换设备/重新登录后,把服务端记着的、本机还没有的档案密钥补回来——
  /// 「退出登录/换设备之后重新登录会自动恢复」这句话的真正实现(Task 15
  /// review C1:之前 `syncOpenSealed` 压根没有 Dart 调用点,这句话是假的,
  /// `AccountSession.clear()` 清掉 `pk_<cloudId>` 之后没有任何路径能补回来,
  /// 云成员会永久锁死)。
  ///
  /// `GET /v1/profiles` 拿到这个账号能访问的全部云档案(含用账号公钥封的
  /// `wrapped_profile_key`),用账号私钥拆开:
  ///
  /// * cloudId 在本机的删除黑名单里(`AccountSession.deletedCloudProfileIds`)
  ///   → 整条跳过,密钥不补、成员不建——这个成员是被用户在本机主动删掉的,
  ///   owner 授权服务端删不掉,不跳过就是"删了又自动长回来"。
  /// * 本地**已经有**这个成员(有同一个 cloudId)、只是缺密钥 → 把密钥补回去;
  /// * 本地**没有**这个成员 → **新建一个**(最终评审 I3,spec 的「换机」那条路):
  ///   名字是占位的「云端档案 `<cloudId 前 6 位>`」,`markCloud` 记下
  ///   role/expiresAt,密钥存进 secure storage。换了台新手机、或者清了 App 数据
  ///   之后,用户重新登录 + 解锁就能看见自己的档案都在——在这之前这条路完全不
  ///   存在:服务端明明有这些档案、密钥也解得开,本机却因为「没有对应的本地
  ///   成员」全部跳过,于是新手机上一片空白,只有一条邀请链接能救(而 owner
  ///   根本给自己发不出邀请)。
  ///
  ///   **建完把它登记进 `sync_engine.pendingFirstSync`**(A5),首同步 + 回填姓名
  ///   交给后台同步触发器去跑。**不在这里直接同步**(评审 Important 3):首同步是
  ///   「拉一整个档案的事件 + 逐个下载附件」,而这个方法跑在启动序列里 —— N 个
  ///   档案串行跑完,启动画面会被按住几十秒。失败的留在集合里,下一次触发再试
  ///   (评审 Important 2:在这之前只试一次,一次网络抖动就把成员永久钉在
  ///   「正在恢复的档案」上)。
  ///
  ///   在这之前这里什么都不做,等"用户哪天自己切到这个成员"才会有第一次同步。
  ///   于是换了台新手机、解锁完账号,看到的是一个叫「云端档案 a1b2c3」、0 份病历
  ///   的成员 —— 看起来就是数据丢了,而其实一次同步就能全拉回来。
  ///
  ///   最后:如果本机那个默认成员「我」从没被用过(没改过名、没有病历),而这次
  ///   真的领回了云成员,就把它删掉 —— 否则用户新手机上永远多一个空成员杵着,
  ///   而他从没建过它。判据见 `ProfileManager.isUntouchedDefaultMember`。
  ///
  /// 单条数据解不开/格式不对只跳过那一条(见循环里的 try/catch),不让一条坏
  /// 数据拖累其它成员的恢复;整个 `/v1/profiles` 请求失败也不抛——这一步是
  /// "顺手补",不该挡住登录/解锁本身成功这件事。
  ///
  /// 如果**当前打开的成员**在补之前是锁着的(有 cloudId、没密钥),补上之后用
  /// [reopenCurrentProfileVault] 重开一次,免得用户还要再手动做一步才能看到
  /// 自己的档案。
  ///
  /// **不调 `ProfileManager.instance.ensureLoaded()`**——这里是唯一一次刻意
  /// 不调的地方,理由是真的会踩坑:它会去碰真实文件 I/O,而这类调用只有包在
  /// `tester.runAsync()` 里才能在 `flutter test` 的 widget 测试里跑完;这个方法
  /// 由一次按钮点击的调用链间接触发,一次平常的 `await tester.tap(...)` 会直接
  /// 卡死等不到它(踩过的坑,不是猜的——B6 时又踩了一次,20 个用例一起红)。
  ///
  /// **所以"加载过了没"是调用方的责任**:
  /// * 账号屏那条路(登录/解锁)走到这里时 `VaultBootstrap` 早就加载过了;
  /// * 启动序列那条路(B6)与开箱**并发**,谁先到不保证 —— 所以 `main.dart` 的
  ///   `_bootOpen` 在调它之前先自己 `ensureLoaded()` 了一次。不先问的话,这里会
  ///   读到那份还没从磁盘读回来的内存默认值(单成员 `p-1`),于是 `currentCloudId`
  ///   判错、已有的云成员被当成"本机没有"又建一遍。
  /// 正在跑的那一次。**静态**,不是实例字段:两个会并发的调用方各自 `new` 一个
  /// `AccountFlow`(`main.dart` 的启动序列一个、账号屏一个),实例级的守卫对真正
  /// 会撞上的那一对完全无效。
  static Future<void>? _restoreInFlight;

  /// 测试专用:上一个用例留下的 in-flight future 不该串到下一个。
  @visibleForTesting
  static void resetRestoreGuardForTest() => _restoreInFlight = null;

  /// 重入守卫(评审 Minor 13)。并发两次会把同一个 `cloudId` adopt 两遍:两边都
  /// 看到"本机没有这个成员" → 各 `create()` 一个 → 同一个云档案在本机成了两个成员,
  /// 而且两边各 `markCloud` 写一遍盘。启动那条路已经是 `unawaited` 的,所以"启动
  /// 补齐还在跑、用户已经点进账号屏登录"不是理论情形。
  ///
  /// 后来者**等前一次的 future**,不是直接返回:调用方的契约是"这句 await 回来
  /// 之后密钥就补齐了",提前返回会让它在密钥还没落地时就往下走。
  Future<void> restoreProfileKeys() =>
      _restoreInFlight ??= _restoreProfileKeys().whenComplete(() => _restoreInFlight = null);

  Future<void> _restoreProfileKeys() async {
    final priv = session.privateKey;
    if (priv == null) return;
    final currentCloudId = ProfileManager.instance.current.cloudId;
    final currentWasLocked = currentCloudId != null && await session.profileKey(currentCloudId) == null;

    List<dynamic> serverProfiles;
    try {
      // **超时要加在这儿**(复审新问题 4)。它原来套在调用方(`main.dart` 的启动
      // 序列)外面,而那个 Future 是 `unawaited` 的 —— 于是那个 `.timeout()` 纯属
      // 装饰:没人等它的结果,只留下一个没人取消的 pending Timer。
      //
      // 放在这一句上它是真的:`Net.connect` 20s + `Net.idle` 30s 意味着单单这一次
      // 请求最坏能吊 50 秒,而后面整条链(解密、建成员、排队)都堵在它后面。
      // `TimeoutException` 被下面同一个 `catch` 接住 —— 与"断网"同等对待:这一步
      // 是"顺手补",拿不到清单就下次再说。
      serverProfiles =
          await api.getJson('/v1/profiles').timeout(profilesFetchBudget) as List<dynamic>;
    } catch (_) {
      return;
    }
    // 本机主动删过的云成员——owner 授权服务端删不掉,`GET /v1/profiles` 还会照样
    // 报回来。不跳过的话,这里就是"删了又自动长回来"的元凶(见 `account.dart` /
    // `vault_boot.removeProfileAndReopenImpl` 的说明)。
    final tombstoned = await session.deletedCloudProfileIds();

    // `ProfileManager.create()` 会把 current 切到新建的那个成员——而这里只是
    // "顺手补齐",绝不该改变用户此刻正在看哪个成员。新建完统一切回来。
    final currentIdBefore = ProfileManager.instance.currentId.value;
    var restoredCurrent = false;
    /// 这一轮需要跑首同步 + 回填姓名的成员:新建出来的,加上**本机已有、但名字
    /// 还是占位串**(说明首同步从来没成功过)的那些。
    final adopted = <String>[];
    for (final raw in serverProfiles) {
      try {
        final entry = raw as Map<String, dynamic>;
        final cloudId = entry['profile_id'] as String;
        if (tombstoned.contains(cloudId)) continue;
        final wrapped = entry['wrapped_profile_key'] as String?;
        if (wrapped == null) continue;
        final role = entry['role'] as String? ?? 'viewer';
        final expiresAt = DateTime.tryParse(entry['expires_at'] as String? ?? '');
        final local = ProfileManager.instance.profiles.where((p) => p.cloudId == cloudId).firstOrNull;
        if (local != null && await session.profileKey(cloudId) != null) {
          // 密钥齐了 —— 但还有两件事要做,不能直接 `continue`:
          await _refreshLocalGrant(local, cloudId, role, expiresAt);
          // **首同步可能从来没成功过** —— 名字还是我们自己写上去的占位串就是证据
          // (首同步成功必然把它换掉,哪怕病历里抽不出姓名也会换成
          // `restoredFallbackName`,见 `nameCloudProfileOnFirstSync`)。重新排一次
          // (评审 Important 2:密钥是在同步之前就存下的,所以下一次启动这条
          // `continue` 会把它整条跳过,于是那唯一一次尝试里的一次网络抖动 =
          // 永久卡住)。
          if (ProfileManager.cloudPlaceholderNames.contains(local.name)) adopted.add(local.id);
          if (cloudId == currentCloudId) restoredCurrent = true;
          continue;
        }
        // **先解密再建成员**:解不开(这条数据坏了 / 不是用这把私钥封的)就整条
        // 跳过,不留下一个永远打不开的空壳成员。
        final key = await crypto.openSealed(priv, base64Decode(wrapped));
        await session.putProfileKey(cloudId, key);
        if (local == null) {
          final localId = await ProfileManager.instance.create(
            ProfileManager.restoringPlaceholderName,
            userManaged: false,
          );
          if (localId == null) continue;
          await ProfileManager.instance.markCloud(localId, cloudId, role, expiresAt);
          adopted.add(localId);
        } else {
          await _refreshLocalGrant(local, cloudId, role, expiresAt);
          if (ProfileManager.cloudPlaceholderNames.contains(local.name)) adopted.add(local.id);
        }
        if (cloudId == currentCloudId) restoredCurrent = true;
      } catch (_) {
        continue;
      }
    }
    if (ProfileManager.instance.currentId.value != currentIdBefore) {
      await ProfileManager.instance.switchTo(currentIdBefore);
    }

    if (currentWasLocked && restoredCurrent) {
      try {
        await reopenCurrentProfileVault();
      } catch (_) {
        // 重开失败不影响"密钥已经补上了"这件事本身——下次任何触发开箱的路径
        // (比如用户自己切一下成员、或 `VaultBootstrap` 的重试)都会用上它。
      }
    }

    // A5:把"还需要首同步"的成员登记给后台触发器。这里**不跑同步** —— 理由见上面
    // 文档与 `sync_engine.pendingFirstSync`。
    pendingFirstSync.addAll(adopted);

    // 最后:领回了云成员,而本机那个默认「我」从没被用过 —— 删掉它。
    // `canRemove` 挡住"删到一个不剩"(那时 adopted 的成员已经在表里,所以正常
    // 情况下这一条是成立的)。
    if (adopted.isNotEmpty &&
        ProfileManager.instance.isUntouchedDefaultMember(currentIdBefore) &&
        ProfileManager.instance.canRemove(currentIdBefore)) {
      try {
        await removeProfile(currentIdBefore);
      } catch (_) {
        // 删不掉就留着 —— 一个多余的空成员远好过一次失败的启动。
      }
    }

    // **有账号就默认开云**(UX 第二轮,创始人拍板)。这个方法是"本机账号密钥就绪"
    // 的唯一汇流处(`commitKeys` 注册完、口令/恢复码解锁完、每次启动补齐都经过
    // 它),所以登记这件事只挂这一处。
    //
    // 真正的开通交给后台触发器排空(见 `sync_engine.pendingCloudEnable`):开通 =
    // 注册云档案 + 重开箱 + 一整次首同步,N 个成员串行跑完会把启动画面按住几十秒。
    //
    // `cloudPaused` 的成员一律不碰 —— 用户手动关过的东西,不许下次启动又替他打开。
    // 代拍病人不在 `ProfileManager` 里(独立命名空间),这里天然碰不到。
    pendingCloudEnable.addAll(
      ProfileManager.instance.profiles.where((p) => p.cloudId == null && !p.cloudPaused).map((p) => p.id),
    );
  }


  /// 服务端那边的角色/到期变了就写回本机。
  ///
  /// 最典型的那一次变化是**所有权转移**:对方接受了我的转移链接,服务端在兑换时
  /// 把我从 owner 自动降成 editor(见 `services/api/db.py`)。本机不刷新的话会一直
  /// 以为自己还是 owner —— 账号屏那颗「把这份档案转给家人」还在,点一次撞一个 403
  /// (复审新问题 3)。被授权档案续期/缩期是同一件事的另一面。
  ///
  /// 没变就不写盘(`markCloud` 每次都会 `_save()`,而这个方法在每次启动的循环里)。
  Future<void> _refreshLocalGrant(Profile local, String cloudId, String role, DateTime? expiresAt) async {
    if (local.role == role && local.expiresAt == expiresAt) return;
    await ProfileManager.instance.markCloud(local.id, cloudId, role, expiresAt);
  }

  /// 本屏重建/冷启动时用:如果本机已经有登录 token(`loginOtp`/`loginApple`
  /// 早先存过),照 [_afterLogin] 同一套逻辑重新判一次该走哪个阶段——不重新发
  /// OTP、不重新走登录。从没登录过(或 `AccountSession.clear()` 过)时
  /// `session.accountId` 为 null,返回 null,UI 留在最初的登录入口。
  Future<LoginOutcome?> resumeIfLoggedIn() async {
    if (session.accountId == null || session.access == null) return null;
    return _afterLogin();
  }

  /// 首次注册,第一步:生成密钥对、口令包一份、恢复码包一份——**纯内存操作,
  /// 不上传、不写本机存储**。恢复码只在返回值里出现这一次。
  ///
  /// 与 [commitKeys] 分成两步,是因为中间要插一道「用户必须先抄下恢复码」的
  /// UI 关卡(见 `account_screen.dart` 的 showRecovery 阶段)——如果这一步就把
  /// 密钥传上服务器、存进本机,那道关卡就只是摆设:App 在恢复码画面被强杀,
  /// 账号已经是「有效可用」的了,但恢复码再也拿不出来第二次。拆成两步之后,
  /// 强杀导致的最坏情况只是「服务端和本机都还没有这个账号的密钥」——用户下次
  /// 打开重新走一遍注册即可(会生成一把全新的密钥对,这一把从未落过盘、从未
  /// 上传过,不构成任何残留状态,谈不上"丢失")。
  Future<PreparedKeys> prepareKeys(String password) async {
    final (pub, sec) = await crypto.accountKeysNew();
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final pw = await crypto.wrapPrivate(sec, password, salt, kdf.mKib, kdf.t, kdf.p);
    final code = await crypto.recoveryCodeNew();
    final rc = await crypto.wrapPrivateRc(sec, code);
    return (publicKey: pub, privateKey: sec, wrappedPw: pw, wrappedRc: rc, salt: salt, recoveryCode: code);
  }

  /// 第二步,只应该在用户点了「我已抄下恢复码」之后调用:把 [prepareKeys] 备好
  /// 的密文上传服务器、私钥存进本机 secure storage。这一步失败(比如服务器
  /// 500)不清 `keys`——UI 应该原样保留恢复码画面,允许用户直接重试这一步,
  /// 不必重新生成一把新密钥对。
  Future<void> commitKeys(PreparedKeys keys) async {
    await api.putJson('/v1/account/keys', {
      'public_key': base64Encode(keys.publicKey),
      'wrapped_priv_pw': base64Encode(keys.wrappedPw),
      'wrapped_priv_rc': base64Encode(keys.wrappedRc),
      'kdf_salt': base64Encode(keys.salt),
      'kdf_params': {'m_kib': kdf.mKib, 't': kdf.t, 'p': kdf.p},
    });
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: keys.publicKey,
      privateKey: keys.privateKey,
    );
    // 全新账号,服务端此刻不会有任何档案(自己刚生成密钥对),调用一次也
    // 无害(空列表,循环直接跳过)——统一走这条路径,不必单独判断"是不是新
    // 账号"。
    await restoreProfileKeys();
    lastOutcome = LoginOutcome.ready;
  }

  Future<void> unlockWithPassword(String password) async {
    final k = _serverKeys!;
    final p = k['kdf_params'] as Map;
    final Uint8List sec;
    try {
      sec = await crypto.unwrapPrivatePw(
        base64Decode(k['wrapped_priv_pw'] as String),
        password,
        base64Decode(k['kdf_salt'] as String),
        p['m_kib'] as int,
        p['t'] as int,
        p['p'] as int,
      );
    } catch (_) {
      throw const UnlockFailed('口令不对');
    }
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: base64Decode(k['public_key'] as String),
      privateKey: sec,
    );
    await restoreProfileKeys();
    lastOutcome = LoginOutcome.ready;
  }

  /// 退出登录:清掉本机全部账号态(token、私钥、各档案密钥)。**不是**注销账号——
  /// 服务端账号与云端数据原样保留;已开通云同步的成员在这台设备上会因为没有档案
  /// 密钥而变成 [ProfileLocked](`vault_boot.dart`),重新登录后自动恢复。调用方
  /// (`AccountScreen`)在确认弹窗里把这句话说清楚,不是这里的事。
  Future<void> logout() async {
    // 邀请缓存是静态的,`session.clear()` 不碰它们 —— 不清的话一个只读看诊令牌在
    // 登出后仍在内存里活最多 10 分钟,而一个**所有权转移**令牌能活 15 天
    // (评审 Minor 10 / Important 9)。
    Grants.clearInviteCache();
    await session.clear();
  }

  /// 注销账号走的服务端路径。**POST 而不是带 body 的 DELETE**(最终评审 I5):
  /// 一些网关/代理会把 DELETE 的请求体丢掉,那边重新鉴权的凭证就永远"缺失"
  /// → 401,用户看到的是「注销失败」且毫无头绪。服务端两条路由同一个 handler,
  /// 旧的 `DELETE /v1/account` 仍然在(老版本 App 不受影响)。
  static const deletePath = '/v1/account/delete';

  /// 自助注销(手机账号):`otp_code` 必须是**刚发的**验证码(见
  /// `services/api/app.py` 的 `account_delete`——重新证明是本人,偷来的
  /// access token 单独用不了这条路)。成功后服务端账号、其名下云档案、授权全部
  /// 已被删除,这里跟着清掉本机账号态(同 [logout])——不可逆,调用方必须已经
  /// 走过确认弹窗。
  Future<void> deleteAccountWithOtp(String phone, String otpCode) async {
    await api.postNoContent(deletePath, {'phone': phone, 'otp_code': otpCode});
    Grants.clearInviteCache();
    await session.clear();
  }

  /// 自助注销(Apple 账号):需要一个**刚拿到的** identity token,和 [loginApple]
  /// 同一条系统弹窗,不能复用登录时那一次(那次早就用过、可能已过期)。
  Future<void> deleteAccountWithApple() async {
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email],
    );
    await api.postNoContent(deletePath, {'identity_token': cred.identityToken});
    Grants.clearInviteCache();
    await session.clear();
  }

  // ---- 旧设备扫码批准新设备(spec A2 的「旧设备批准」这条路)----
  //
  // 在这之前 `POST /v1/devices/request` 与 `GET /v1/devices/approval` 两个端点
  // **零 Dart 调用方**:服务端、Rust 的封/拆、设备列表里那颗「批准」按钮全都在,
  // 而没有任何路径会把 `eph_public` 写上去 —— 于是那颗按钮是一段永不触发的 UI,
  // 而新设备上唯一的出路是口令或恢复码(正是最容易两样都想不起来的时刻)。

  /// 新设备这一侧第一步:生成一对**临时** X25519 密钥,把公钥登记到服务端,返回
  /// 要画成二维码的那串字和只在内存里的临时私钥。
  ///
  /// 复用 `sync_account_keys_new`(就是一对 X25519 密钥),不新加 FRB 函数。
  Future<DeviceApprovalRequest> requestDeviceApproval() async {
    final (pub, sec) = await crypto.accountKeysNew();
    final did = await deviceId();
    await api.postJson(
      '/v1/devices/request',
      {'device_id': did, 'eph_public': base64Encode(pub)},
      headers: {'X-Device-Id': did},
    );
    return (code: '$deviceApprovalPrefix.$did.${base64UrlEncode(pub).replaceAll('=', '')}', ephSecret: sec);
  }

  /// 新设备这一侧第二步:问一次"旧手机批准了吗"。没有就返回 null(轮询的调用方
  /// 据此继续等),有就是那份**用本机临时公钥封好的账号私钥**(服务端取走即删,
  /// 见 `db.device_take_approval`)。
  Future<String?> fetchDeviceApproval() async {
    final did = await deviceId();
    final r = await api.getJson(
      '/v1/devices/approval',
      query: {'device_id': did},
      headers: {'X-Device-Id': did},
    ) as Map<String, dynamic>;
    return r['approved_priv'] as String?;
  }

  /// 新设备这一侧第三步:用临时私钥拆开,走和口令解锁**完全相同**的后半截
  /// (存 session → 补齐档案密钥 → ready)。不需要口令。
  ///
  /// ## 为什么这里要核对"私钥和公钥是一对",以及它**挡不住**什么(复审 C1 / N2)
  ///
  /// 这条路上两样东西都来自服务端:那份批准密文、和 `GET /v1/account/keys` 里那把公钥。
  ///
  /// **探针挡住的那一种:只换公钥。** 服务端把旧设备封的那份真密文原样转交(于是本机
  /// 拿到的是**真**账号私钥),但在 `/v1/account/keys` 里把 `public_key` 换成自己那把。
  /// 那之后一切都照常工作 —— 已有的云档案照样解得开(它们是用真公钥封的,而本机有真
  /// 私钥)—— 而"有账号默认开云"每给一个成员生成档案密钥,都会用
  /// `session.publicKey`(= 攻击者那把)封起来上传。没有任何症状,而服务器从此读得到
  /// 这些新成员。这一种被挡住,因为真私钥与那把假公钥配不上。
  ///
  /// **探针挡不住的那一种:整对替换。** 服务端自造一对 `(pub_a, sec_a)`,把 `sec_a`
  /// 封给 `eph_public`(`eph_public` 是公开的,就在那张码里),同时发下 `pub_a`。
  /// 那**是**一对真密钥,探针照样通过 —— 这不是实现疏漏,是这条路形状上的缺口:
  /// 码是单向的(新手机 → 旧手机),新设备没有任何经过认证的渠道能知道"我账号真正的
  /// 公钥是哪一把"。
  ///
  /// 这一种的后果与症状:受害者**已有**的云档案一个都打不开(它们用真公钥封的,而本机
  /// 拿到的是 `sec_a`),`restoreProfileKeys` 的逐条 try/catch 会把它们全部跳过 ——
  /// 新手机上看起来是"档案没回来";而此后新建的档案密钥都封给 `pub_a`。所以它会留下
  /// 可见的异常,但**不是被密码学挡住的**。
  ///
  /// 真正的堵法是**双向确认**:两台手机各显示同一把账号公钥的指纹(短认证串),让用户
  /// 对一眼。没做,记在 `docs/superpowers/specs/2026-09-11-account-keys-sync-design.md`
  /// 的「已知缺口」里。口令/恢复码两条路不需要这道探针、也没有这个缺口:那两份密文
  /// 只有用户知道的秘密才解得开,服务器替换不了。
  ///
  /// 探针只用现有的两个 FRB 函数(不加新的):用服务端给的公钥封一个字节,再用刚
  /// 拆出来的私钥拆开 —— 拆得回原样才说明它们是一对。
  Future<void> unlockWithDeviceApproval(Uint8List ephSecret, String sealed) async {
    final k = _serverKeys!;
    final pub = base64Decode(k['public_key'] as String);
    final Uint8List sec;
    try {
      sec = await crypto.openSealed(ephSecret, base64Decode(sealed));
    } catch (_) {
      // 拆不开 = 这份批准不是封给这台设备此刻这把临时密钥的(比如用户中途重新
      // 生成过一张码)。让他重来一次,别把账号态搞脏。
      throw const UnlockFailed('这份批准打不开,请重新生成二维码再让旧手机扫一次');
    }
    if (!await _isKeyPair(pub, sec)) {
      throw const UnlockFailed('这份批准对不上你账号的密钥,请改用口令或恢复码');
    }
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: base64Decode(k['public_key'] as String),
      privateKey: sec,
    );
    await restoreProfileKeys();
    lastOutcome = LoginOutcome.ready;
  }

  /// [pub] 和 [sec] 是一对吗 —— 用公钥封一个字节,再用私钥拆开,拆得回原样就是。
  /// 任何异常都算"不是一对"(拆不开本身就是最常见的"不是一对")。
  Future<bool> _isKeyPair(Uint8List pub, Uint8List sec) async {
    try {
      final probe = Uint8List.fromList([0]);
      final opened = await crypto.openSealed(sec, await crypto.sealTo(pub, probe));
      return opened.length == 1 && opened[0] == 0;
    } catch (_) {
      return false;
    }
  }

  /// 旧设备这一侧:把本机**已解锁的账号私钥**用新设备的临时公钥封起来交给服务端
  /// (服务端只见密文,拆得开它的只有那台设备自己的临时私钥)。
  ///
  /// 设备列表里那颗「批准」按钮和「扫码批准新设备」走的是同一条 —— 同一件事不该
  /// 有两个实现。
  Future<void> approveDevice(String targetDeviceId, Uint8List ephPublic) async {
    final priv = session.privateKey;
    if (priv == null) throw StateError('本机账号还没解锁,不能批准别的设备');
    final sealed = await crypto.sealTo(ephPublic, priv);
    await api.postJson(
      '/v1/devices/approve',
      {'device_id': targetDeviceId, 'approved_priv': base64Encode(sealed)},
      headers: {'X-Device-Id': await deviceId()},
    );
  }

  Future<void> unlockWithRecovery(String code) async {
    final k = _serverKeys!;
    final Uint8List sec;
    try {
      sec = await crypto.unwrapPrivateRc(base64Decode(k['wrapped_priv_rc'] as String), code);
    } catch (_) {
      throw const UnlockFailed('恢复码不对');
    }
    await session.save(
      accountId: session.accountId!,
      access: session.access!,
      refresh: session.refresh!,
      publicKey: base64Decode(k['public_key'] as String),
      privateKey: sec,
    );
    await restoreProfileKeys();
    lastOutcome = LoginOutcome.ready;
  }
}
