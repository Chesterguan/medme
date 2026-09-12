import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart' show patientProfile;
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' as rust;
import 'package:mobile_flutter/sync_engine.dart' show SyncEngine;
import 'package:mobile_flutter/vault_boot.dart'
    show autoNameCurrentProfileFrom, openCurrentProfileVault, removeProfileAndReopen;

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

/// 授权落地:家属(手机号,永久 editor)、医生(15 天邀请二维码,viewer)、代拍转移
/// (owner,老 owner 服务端自动降 editor)、过期清理。
///
/// 服务端全程只见密文——本文件里除了 [GrantsRust] 的调用之外,不得出现任何解密
/// 调用之外的明文密钥字段(见 `services/api/app.py` 的 invites/grants 端点)。
class Grants {
  Grants(this.api, this.session, {this.rust = const RustGrants()});

  final ApiClient api;
  final AccountSession session;
  final GrantsRust rust;

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
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
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
    return GrantLink(inviteId: r['invite_id'] as String, token: token);
  }

  /// 医生的看诊码:viewer、15 天、二维码本身 10 分钟内必须扫(`invite_ttl_s`——
  /// 邀请链接自己的有效期,与「兑换后能看多久」的 15 天是两个概念)。
  Future<GrantLink> inviteDoctor(Profile p) => _invite(p, role: 'viewer', days: grantDoctorDays, ttlS: 600);

  /// 代拍转移:owner。链接本身给足 15 天去扫(病人不一定当场就有空点开),
  /// 一旦兑换即刻转移——不像医生邀请那样按天到期。
  Future<GrantLink> inviteTransfer(Profile p) => _invite(p, role: 'owner', days: null, ttlS: 15 * 86400);

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

    // 这个云档案本机已经有一个入口——重新兑换同一条链接、或者角色/到期被服务端
    // 更新过(比如医生邀请续期)——复用它,别再建一个重复的空壳档案出来。
    await ProfileManager.instance.ensureLoaded();
    final existing = ProfileManager.instance.profiles.where((p) => p.cloudId == profileId).firstOrNull;
    final localId = existing?.id ?? await ProfileManager.instance.create('(同步中)', userManaged: false);
    if (localId == null) throw StateError('无法创建本地档案');
    final expiresAt = r['expires_at'] == null ? null : DateTime.parse(r['expires_at'] as String);
    await ProfileManager.instance.markCloud(localId, profileId, r['role'] as String, expiresAt);
    await ProfileManager.instance.switchTo(localId);
    final stored = ProfileManager.instance.current;

    await (afterStored ?? _finishRedeem)(stored);
    return ProfileManager.instance.current;
  }

  Future<void> _finishRedeem(Profile p) async {
    await openCurrentProfileVault();
    await SyncEngine(api, session).syncProfile(p);
    // 拉完事件后用识别到的姓名命名——占位名「(同步中)」只在首同步完成前露面。
    await autoNameCurrentProfileFrom((await patientProfile()).name);
  }

  /// 家属按手机号加入:查到对方账号公钥 → 把档案密钥封给对方 → 永久 editor
  /// (家属不是「只读」,能一起录入)。找不到这个手机号(404)、限流(429)都
  /// 原样抛给调用方——服务端的 existence oracle 是接受并写进文档的行为,这里
  /// 不额外掩盖。
  Future<void> grantFamilyByPhone(Profile p, String phone) async {
    final cloudId = p.cloudId;
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
    final key = await session.profileKey(cloudId);
    if (key == null) throw StateError('没有这个档案的密钥');
    final looked = await api.getJson('/v1/accounts/lookup', query: {'phone': phone}) as Map<String, dynamic>;
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
    if (cloudId == null) throw StateError('这个成员还没开通云同步');
    await api.delete('/v1/profiles/$cloudId/grants/$grantId');
  }

  /// 清掉本机已过期的「被授权档案」(viewer/editor 授权到期,不是自己的 owner
  /// 档案——owner 的 `expiresAt` 恒为 null,天然不会被选中)。
  ///
  /// [removeProfile] 同 [afterStored] 的道理:默认指向真实的
  /// `vault_boot.removeProfileAndReopen`(删目录 + 重开箱,碰真实 Rust/IO),
  /// 测试传一个假实现只钉住"选中了哪些过期档案"这条逻辑。
  Future<int> purgeExpired({Future<bool> Function(String id)? removeProfile}) async {
    final doRemove = removeProfile ?? removeProfileAndReopen;
    await ProfileManager.instance.ensureLoaded();
    final now = DateTime.now();
    final expired = ProfileManager.instance.profiles
        .where((p) => p.cloudId != null && p.role != 'owner' && p.expiresAt != null && p.expiresAt!.isBefore(now))
        .toList();
    for (final p in expired) {
      await doRemove(p.id);
    }
    return expired.length;
  }
}
