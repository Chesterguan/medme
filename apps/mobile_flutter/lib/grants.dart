import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:mobile_flutter/sync_engine.dart' show SyncEngine, firstSyncAndName;
import 'package:mobile_flutter/vault_boot.dart' show removeProfileAndReopen, switchProfileAndReopen;

/// `token_hash` 用的哈希——与 Rust 侧 `sync::kek_from_token` 的 salt(`medme-invite-v1`)
/// 是两回事:这里只是让服务端能核对客户端出示的 token 对不对,不参与密钥推导。
String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// 对 `sync_*` FRB 调用的薄包装——同 `SyncCrypto`/`RustSyncApi` 的套路(见
/// `account_flow.dart`/`sync_engine.dart`),让 [Grants] 在 `flutter test` 里
/// 可以注入假实现,不碰真实 Rust 桥。
abstract class GrantsRust {
  /// `kek = HKDF(token)`(salt `medme-invite-v1`),用它包一份档案密钥,发邀请时用。
  Future<Uint8List> wrapWithToken(Uint8List plaintext, String token);

  /// 上面那个的逆——兑换邀请时,拿到手的密文只有出示 token 的人能拆开。
  Future<Uint8List> unwrapWithToken(Uint8List blob, String token);

  /// 用对方账号公钥封一份明文——只有对方自己的私钥能拆开(`sync_open_sealed`)。
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext);
}

class RustGrants implements GrantsRust {
  const RustGrants();

  @override
  Future<Uint8List> wrapWithToken(Uint8List plaintext, String token) =>
      rust.syncWrapWithToken(plaintext: plaintext, token: token);

  @override
  Future<Uint8List> unwrapWithToken(Uint8List blob, String token) =>
      rust.syncUnwrapWithToken(blob: blob, token: token);

  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) =>
      rust.syncSealTo(public: public, plaintext: plaintext);
}

/// 过期授权被清掉时说的那一句。**两个 purge 调用点共用**:医生模式主页那一节、
/// 以及个人/病人模式的成员切换器(`member_switcher.dart`)。
///
/// C11:过期档案原来是**静默消失**的 —— 昨天还能看的那份病历今天不见了、本机目录
/// 被删,屏上一个字都没有。第一轮只在医生模式说了这句话,个人模式(也就是原来那个
/// purge 点)照旧静默(评审 Important 4)。
String? expiredGrantNotice(List<Profile> removed) => switch (removed.length) {
  0 => null,
  1 => '${removed.single.name} 的授权已到期,已移出',
  _ => '${removed.map((p) => p.name).join('、')} 的授权已到期,已移出',
};

/// 授权落地:家属(手机号,永久 editor)、医生(15 天邀请二维码,viewer)、代拍转移
/// (owner,老 owner 服务端自动降 editor)、过期清理。
///
/// 服务端全程只见密文——本文件里除了 [GrantsRust] 的调用之外,不得出现任何解密
/// 调用之外的明文密钥字段(见 `services/api/app.py` 的 invites/grants 端点)。
class Grants {
  Grants(this.api, this.session, {this.rust = const RustGrants(), this.switchAndReopen = switchProfileAndReopen});

  final ApiClient api;
  final AccountSession session;
  final GrantsRust rust;

  /// 兑换收尾时"切到新档案 + 重开箱"走的函数。默认
  /// `vault_boot.switchProfileAndReopen`——**可回退**的那一条(开箱失败会把
  /// `currentId` 退回去再 rethrow,见最终评审 I2)。抽成字段只为测试能注入一个
  /// 假的:真实现里的开箱调 FRB,`flutter test` 跑不到。
  final Future<void> Function(String id, {String? revertTo}) switchAndReopen;

  /// 非永久授权(邀请/家属直发)的天数上限——与 `services/api/db.py` 的
  /// `GRANT_DOCTOR_DAYS` 一致,客户端这边只是不发一个注定被服务端砍掉的数字。
  static const grantDoctorDays = 15;

  Future<GrantLink> _invite(
    Profile p, {
    required String role,
    int? days,
    required int ttlS,
  }) async {
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云端备份');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final token = base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final wrapped = await rust.wrapWithToken(key, token);
    final r = await api.postJson('/v1/profiles/$cloudId/invites', {
      'role': role,
      'days': ?days,
      'token_hash': sha256Hex(token),
      'wrapped_key_by_token': base64Encode(wrapped),
      'invite_ttl_s': ttlS,
    });
    Analytics.track(AnalyticsEvent.grantCreated, {'role': role});
    return GrantLink(inviteId: r['invite_id'] as String, token: token);
  }

  /// 看诊码自己的有效期:10 分钟内必须被扫(与「兑换后能看多久」的 15 天是两个
  /// 概念)。
  static const doctorInviteTtlS = 600;

  /// C8:同一个档案、[doctorInviteTtlS] 之内,复用同一条看诊邀请。
  ///
  /// 原来**每进一次出码屏就在服务端多建一条 invite**。病人在诊室里退出去又进来很
  /// 常见(医生说"等下再给我看"、切去翻别的东西),而新建出来的那条码和上一条没有
  /// 任何区别 —— 白在服务端攒记录、白发一次请求、白让病人多等一次转圈。
  ///
  /// **只记在内存里**:`token` 是明文凭证(谁拿到它就能兑换这份只读授权),不落盘;
  /// App 重启后重新建一条,无害。30 秒安全边际 —— 不把一条马上就要过期的码递到
  /// 医生的相机前。
  static final _doctorInvites = <String, (GrantLink, DateTime)>{};

  /// 两个邀请缓存都清掉。
  ///
  /// **退出登录/注销账号时必须调**(`AccountFlow.logout`/`deleteAccount*`,
  /// 评审 Minor 10):它们是静态的,`AccountSession.clear()` 不碰它们 —— 不清的话,
  /// 一个只读看诊令牌在登出后仍在内存里活最多 10 分钟,而一个**所有权转移**令牌
  /// 能活 15 天。测试也用它(静态状态在用例之间会串)。
  static void clearInviteCache() {
    _doctorInvites.clear();
    _transferInvites.clear();
  }

  /// 医生的看诊码:viewer、15 天。见 [_doctorInvites] 说明的复用规则。
  Future<GrantLink> inviteDoctor(Profile p) =>
      _cachedInvite(p, _doctorInvites, role: 'viewer', days: grantDoctorDays, ttlS: doctorInviteTtlS);

  /// 转移邀请自己的有效期:15 天(对方不一定当场就有空点开)。
  static const transferInviteTtlS = 15 * 86400;

  /// 所有权转移邀请的复用缓存。**理由比看诊码那条强得多**(评审 Important 9):
  ///
  /// 服务端**没有列出、也没有撤销 invite 的端点**(`app.py` 只有
  /// `POST /v1/profiles/{pid}/invites` 和 `POST /v1/invites/redeem`)。于是三次手忙
  /// 脚乱的点击 = 三个各自都能把所有权交出去的、不可见、不可撤销的 bearer 令牌,
  /// 各活 15 天。这是系统里最高风险的授权 —— 它至少得和一个 10 分钟的只读看诊码
  /// 一样谨慎。
  ///
  /// 真正的修法是加一个 revoke 端点(另一个决定,不在这一轮)。
  static final _transferInvites = <String, (GrantLink, DateTime)>{};

  /// 代拍/家属转移:owner。一旦兑换即刻转移——不像医生邀请那样按天到期。
  /// 同一个档案在 [transferInviteTtlS] 之内复用同一条邀请,见 [_transferInvites]。
  Future<GrantLink> inviteTransfer(Profile p) =>
      _cachedInvite(p, _transferInvites, role: 'owner', days: null, ttlS: transferInviteTtlS);

  /// [inviteDoctor] / [inviteTransfer] 共用的"同一个档案在有效期内复用同一条邀请"。
  /// 30 秒安全边际:不把一条马上就要过期的码递到对方的相机前。
  Future<GrantLink> _cachedInvite(
    Profile p,
    Map<String, (GrantLink, DateTime)> cache, {
    required String role,
    required int? days,
    required int ttlS,
  }) async {
    final cloudId = p.cloudId;
    final cached = cloudId == null ? null : cache[cloudId];
    if (cached != null && cached.$2.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return cached.$1;
    }
    final link = await _invite(p, role: role, days: days, ttlS: ttlS);
    if (cloudId != null) cache[cloudId] = (link, DateTime.now().add(Duration(seconds: ttlS)));
    return link;
  }

  /// 兑换一条授权链接:服务端校验 token → 解出 token 包 → 用自己的账号公钥重新
  /// 封一份回填(服务端此后只留得住"封给我的"这一份,原来那份 token 包留着也无妨,
  /// 反正 token 只出示过一次)→ 建一个本机档案记下 cloudId/role/expiresAt →
  /// 开箱、首同步、按识别到的姓名命名。
  ///
  /// [afterStored] 是测试注入点:默认指向真实的开箱 + 同步 + 命名(都要碰真实
  /// Rust 原生库/`path_provider`,`flutter test` 没法伪造——同 `sync_engine_test.dart`
  /// 顶部对 `enableCloud` 的同一条限制)。测试传一个空实现,只钉住网络 + 密钥
  /// 回填 + 建档案这几步可测的逻辑。
  Future<Profile> redeem(GrantLink l, {Future<void> Function(Profile)? afterStored}) async {
    try {
      final r = await api.postJson('/v1/invites/redeem', {
        'invite_id': l.inviteId,
        'token': l.token,
      });
      final key = await rust.unwrapWithToken(base64Decode(r['wrapped_key_by_token'] as String), l.token);
      final pub = session.publicKey;
      if (pub == null) throw StateError('账号公钥未就绪,不能兑换授权');
      final mine = await rust.sealTo(pub, key);
      final profileId = r['profile_id'] as String;
      final grantId = r['grant_id'] as String;
      await api.putJson('/v1/profiles/$profileId/grants/$grantId/key', {
        'wrapped_profile_key': base64Encode(mine),
      });
      await session.putProfileKey(profileId, key);
      // 这次兑换是合法领回——即便这个 cloudId 之前在本机被删过(见
      // `account.dart`/`vault_boot.removeProfileAndReopenImpl`),这次重新拿到
      // 的授权也该生效,不能被 `AccountFlow.restoreProfileKeys` 当成历史删除跳过。
      await session.clearCloudProfileTombstone(profileId);

      // 这个云档案本机已经有一个入口——重新兑换同一条链接、或者角色/到期被服务端
      // 更新过(比如医生邀请续期)——复用它,别再建一个重复的空壳档案出来。
      await ProfileManager.instance.ensureLoaded();
      // **在 `create()` 之前**记下"原来停在哪个成员":`create()` 自己会把 current
      // 切到新建的那个(见 `ProfileManager.create`),开箱失败要退回的是这个,不是
      // 它。见 [_finishRedeem] 与最终评审 I2。
      final previousId = ProfileManager.instance.currentId.value;
      final existing = ProfileManager.instance.profiles.where((p) => p.cloudId == profileId).firstOrNull;
      final localId =
          existing?.id ?? await ProfileManager.instance.create(ProfileManager.redeemingPlaceholderName, userManaged: false);
      if (localId == null) throw StateError('无法创建本地档案');
      final role = r['role'] as String;
      final expiresAt = r['expires_at'] == null ? null : DateTime.parse(r['expires_at'] as String);
      await ProfileManager.instance.markCloud(localId, profileId, role, expiresAt);
      final stored = ProfileManager.instance.byId(localId)!;

      await (afterStored ?? (p) => _finishRedeem(p, revertTo: previousId))(stored);
      Analytics.track(AnalyticsEvent.grantRedeemed, {'role': role, 'ok': true});
      return ProfileManager.instance.byId(localId)!;
    } catch (_) {
      Analytics.track(AnalyticsEvent.grantRedeemed, {'ok': false});
      rethrow;
    }
  }

  /// 兑换收尾:切到这个档案 + 重开箱 → 首同步 → 按识别到的姓名命名。
  ///
  /// 切换走 [switchAndReopen](默认 `vault_boot.switchProfileAndReopen`)而不是
  /// 裸的 `ProfileManager.switchTo` + `openCurrentProfileVault`(最终评审 I2):
  /// 开箱失败时(最常见是 [ProfileLocked]——账号密钥这会儿读不出来)必须把
  /// `currentId` 退回兑换之前那个成员,否则就停在「current 指着新档案、进程里开着
  /// 的还是旧档案的箱子」这个状态上,接下来任何一次录入/导入都会把新档案的内容
  /// 写进旧档案的保险箱。[revertTo] 是兑换开始时那个成员,不能用
  /// `switchProfileAndReopen` 的默认值——`create()` 早就把 current 改掉了。
  /// 三步全在 `sync_engine.firstSyncAndName` 里——**换机领回自己的档案走的是同一个
  /// 函数**(A5:那条路原来一步都没做)。这里不传 `returnTo`:兑换完就该停在新档案
  /// 上,那正是用户刚点头要加入的东西。
  Future<void> _finishRedeem(Profile p, {required String revertTo}) => firstSyncAndName(
    p,
    revertTo: revertTo,
    sync: (x) => SyncEngine(api, session).syncProfile(x),
    switchAndReopen: switchAndReopen,
  );

  /// 家属按手机号加入:查到对方账号公钥 → 把档案密钥封给对方 → 永久 editor
  /// (家属不是「只读」,能一起录入)。找不到这个手机号(404)、限流(429)都
  /// 原样抛给调用方——服务端的 existence oracle 是接受并写进文档的行为,这里
  /// 不额外掩盖。
  Future<void> grantFamilyByPhone(Profile p, String phone) async {
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云端备份');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final looked = await api.postJson('/v1/accounts/lookup', {'phone': phone});
    final theirPub = base64Decode(looked['public_key'] as String);
    final wrapped = await rust.sealTo(theirPub, key);
    await api.postJson('/v1/profiles/$cloudId/grants', {
      'grantee_account_id': looked['account_id'],
      'role': 'editor',
      'wrapped_profile_key': base64Encode(wrapped),
    });
  }

  /// 撤销一份授权(删掉那条 grant)。
  Future<void> revoke(Profile p, String grantId) async {
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云端备份');
    await api.delete('/v1/profiles/$cloudId/grants/$grantId');
  }

  /// 清掉本机已过期的「被授权档案」(viewer/editor 授权到期,不是自己的 owner
  /// 档案——owner 的 `expiresAt` 恒为 null,天然不会被选中)。
  ///
  /// [removeProfile] 同 [afterStored] 的道理:默认指向真实的
  /// `vault_boot.removeProfileAndReopen`(删目录 + 重开箱,碰真实 Rust/IO),
  /// 测试传一个假实现只钉住"选中了哪些过期档案"这条逻辑。
  ///
  /// 返回**被清掉的那些成员**(不只是个数):调用方要能说出"谁的授权到期了"。
  /// C11:过期档案原来是**静默消失**的 —— 医生昨天还能看的那份病历今天不见了,
  /// 屏上一个字都没有。
  Future<List<Profile>> purgeExpired({Future<bool> Function(String id)? removeProfile}) async {
    final doRemove = removeProfile ?? removeProfileAndReopen;
    await ProfileManager.instance.ensureLoaded();
    final now = DateTime.now();
    final expired = ProfileManager.instance.profiles
        .where((p) => p.cloudId != null && p.role != 'owner' && p.expiresAt != null && p.expiresAt!.isBefore(now))
        .toList();
    final removed = <Profile>[];
    for (final p in expired) {
      if (await doRemove(p.id)) removed.add(p);
    }
    return removed;
  }
}
