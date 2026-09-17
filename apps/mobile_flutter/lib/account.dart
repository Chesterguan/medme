import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 手机号脱敏:`13800138000` → `138****8000`。
///
/// **只存这一串,不存明文**(见 [AccountSession.phoneMasked])。界面需要的只是
/// "让用户认出这是哪个号",而明文手机号是可辨识个人信息 —— 多存一份就是多一处
/// 可能泄露的地方。位数不够(不像手机号)一律给 `****`,不露出任何片段。
String maskPhone(String phone) {
  final d = phone.replaceAll(RegExp(r'\D'), '');
  if (d.length < 7) return '****';
  return '${d.substring(0, 3)}****${d.substring(d.length - 4)}';
}

/// 「有账号默认开云」那句一次性告知看过了没(`sync_engine` 读写它)。
///
/// 键名定在这里、而不是在用它的那一侧:它要被**两处**认识 —— `sync_engine` 读写,
/// 以及 [AccountSession.clear] 退出登录时清掉(复审 M16:它跟着账号走,不跟着设备走,
/// 否则同一台手机上换个账号登录的人从没被告知过"你的病历会自动上云")。
/// 反过来让本文件 import `sync_engine` 会成环(那边 import 这边)。
const cloudDefaultNoticeSeenKey = 'cloud_default_notice_seen';

/// 「云端整理」开关(`cloud_extract.dart` 读,账号屏的开关行写)——**跟设备走,
/// 不跟账号走**:默认 true,`AccountSession.clear()` 不清它(不像
/// [cloudDefaultNoticeSeenKey])。换个账号登录,这台设备"要不要把涂黑的单据图
/// 交给云端模型整理"的选择不该因为换了个人登录就重置回默认。
const cloudExtractEnabledKey = 'cloud_extract_enabled';

/// 第一次出码前那条告知,这台设备上说过没有(一次性)。**跟设备走,不按成员、
/// 也不按登录状态** —— 说的是「东西去哪了」,那件事和你是谁无关。
const qrNoticeSeenKey = 'qr_notice_seen';

/// 账号会话 + 密钥的本机存储。**私钥与档案密钥只进 secure storage**(iOS Keychain
/// 开 synchronizable = 同一 Apple ID 新机自动拿回,这就是「系统钥匙串」那条换机路;
/// 安卓用 EncryptedSharedPreferences,不跨机)。token 与 id 在 shared_preferences。
class AccountSession {
  AccountSession._();
  static final AccountSession instance = AccountSession._();

  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(synchronizable: true, accessibility: KeychainAccessibility.first_unlock),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final ValueNotifier<bool> loggedIn = ValueNotifier<bool>(false);
  String? accountId;
  String? access;
  String? refresh;
  Uint8List? publicKey;
  Uint8List? privateKey;

  /// 上一次登录走的是哪条认证方式(`'otp'`/`'apple'`)——**只是为了让「注销账号」
  /// 那一步知道该要求哪种重新鉴权凭证**(手机账号要新验证码,Apple 账号要新
  /// identity token,见 `services/api/app.py` 的 `DELETE /v1/account`),不是
  /// 别的用途。泄露无害(不是密钥),存 shared_preferences 即可。
  String? loginMethod;

  /// 登录时用的手机号,**脱敏之后**的样子(`138****8000`)。账号屏拿它告诉用户
  /// "你现在登的是哪个号" —— 在这之前那一行显示的是服务端的 `account_id`
  /// (`acc_7f3a…`),对用户毫无意义,而且那是一个只该出现在 debug 日志里的东西。
  /// 明文手机号**一个字都不存**,见 [maskPhone]。Apple 登录时为 null。
  String? phoneMasked;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    accountId = p.getString('acct_id');
    access = p.getString('acct_access');
    refresh = p.getString('acct_refresh');
    loginMethod = p.getString('acct_method');
    phoneMasked = p.getString('acct_phone_masked');
    final pk = await _secure.read(key: 'acct_priv');
    privateKey = pk == null ? null : base64Decode(pk);
    final pub = p.getString('acct_pub');
    publicKey = pub == null ? null : base64Decode(pub);
    _loaded = true;
    loggedIn.value = accountId != null && access != null;
  }

  Future<void> save({
    required String accountId,
    required String access,
    required String refresh,
    Uint8List? publicKey,
    Uint8List? privateKey,
    String? loginMethod,
    String? phoneMasked,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('acct_id', accountId);
    await p.setString('acct_access', access);
    await p.setString('acct_refresh', refresh);
    if (publicKey != null) await p.setString('acct_pub', base64Encode(publicKey));
    if (privateKey != null) await _secure.write(key: 'acct_priv', value: base64Encode(privateKey));
    if (loginMethod != null) await p.setString('acct_method', loginMethod);
    if (phoneMasked != null) await p.setString('acct_phone_masked', phoneMasked);
    this.accountId = accountId; this.access = access; this.refresh = refresh;
    if (publicKey != null) this.publicKey = publicKey;
    if (privateKey != null) this.privateKey = privateKey;
    if (loginMethod != null) this.loginMethod = loginMethod;
    if (phoneMasked != null) this.phoneMasked = phoneMasked;
    loggedIn.value = true;
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [
      'acct_id',
      'acct_access',
      'acct_refresh',
      'acct_pub',
      'acct_method',
      'acct_phone_masked',
      // 见 [cloudDefaultNoticeSeenKey]:那句告知跟着账号走,不跟着设备走(M16)。
      cloudDefaultNoticeSeenKey,
    ]) {
      await p.remove(k);
    }
    // `deleteAll` 而不是逐个 delete:AccountSession 是这个 app 里唯一用 secure storage
    // 的地方,它的命名空间下只会有账号私钥(acct_priv)和各档案密钥(pk_<cloudId>)。
    // 换账号必须把上一个账号的档案密钥也清掉,不然共享设备上账号 B 能读到账号 A 的密钥。
    await _secure.deleteAll();
    accountId = access = refresh = loginMethod = phoneMasked = null; publicKey = privateKey = null;
    loggedIn.value = false;
  }

  Future<Uint8List?> profileKey(String cloudId) async {
    final v = await _secure.read(key: 'pk_$cloudId');
    return v == null ? null : base64Decode(v);
  }

  Future<void> putProfileKey(String cloudId, Uint8List key) => _secure.write(key: 'pk_$cloudId', value: base64Encode(key));

  /// 这个云档案的授权/成员被移除时,连同它的密钥一起清掉——密钥留着没有任何
  /// 用处(服务端那份 grant 已经没了,拿着本机这份密钥解不出任何新内容),
  /// 留着只是白占 Keychain 位置、多一份"看起来还有效"的敏感材料。
  Future<void> removeProfileKey(String cloudId) => _secure.delete(key: 'pk_$cloudId');

  static const _tombstoneKey = 'deleted_cloud_profiles';

  /// 本机主动删过的云成员(cloudId 集合)——owner 授权服务端删不掉(见
  /// `vault_boot.removeProfileAndReopenImpl` 的说明),`AccountFlow.restoreProfileKeys`
  /// 换机/重新登录时拿 `GET /v1/profiles` 一样会看到这些还挂着的档案,不认这份
  /// 名单就会把用户刚删掉的成员原样建回来。存 shared_preferences——不是密钥,
  /// 泄露无害。
  Future<Set<String>> deletedCloudProfileIds() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_tombstoneKey) ?? const <String>[]).toSet();
  }

  /// 删成员时记一笔(只在被删的是云成员、即有 `cloudId` 时调用)。
  Future<void> tombstoneCloudProfile(String cloudId) async {
    final p = await SharedPreferences.getInstance();
    final ids = (p.getStringList(_tombstoneKey) ?? const <String>[]).toSet()..add(cloudId);
    await p.setStringList(_tombstoneKey, ids.toList());
  }

  /// 这个 cloudId 又被合法地领回来了(`Grants.redeem` 兑换到同一个档案 /
  /// `SyncEngine.enableCloud` 注册到同一个档案)——之前的"本机主动删过"不再成立,
  /// 清掉,免得下次 `restoreProfileKeys` 把这次合法领回的档案也当成历史删除跳过。
  Future<void> clearCloudProfileTombstone(String cloudId) async {
    final p = await SharedPreferences.getInstance();
    final ids = (p.getStringList(_tombstoneKey) ?? const <String>[]).toSet()..remove(cloudId);
    await p.setStringList(_tombstoneKey, ids.toList());
  }

  /// 测试专用:把内存态重置成刚启动、还没 `ensureLoaded()` 的样子,不碰底层存储。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    accountId = access = refresh = loginMethod = phoneMasked = null;
    publicKey = privateKey = null;
    loggedIn.value = false;
  }

  /// 测试专用:核实 iOS secure storage 选项确实开了 `synchronizable`。
  @visibleForTesting
  static Map<String, String> get iosOptionsForTest => _secure.iOptions.toMap();
}
