import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    accountId = p.getString('acct_id');
    access = p.getString('acct_access');
    refresh = p.getString('acct_refresh');
    loginMethod = p.getString('acct_method');
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
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('acct_id', accountId);
    await p.setString('acct_access', access);
    await p.setString('acct_refresh', refresh);
    if (publicKey != null) await p.setString('acct_pub', base64Encode(publicKey));
    if (privateKey != null) await _secure.write(key: 'acct_priv', value: base64Encode(privateKey));
    if (loginMethod != null) await p.setString('acct_method', loginMethod);
    this.accountId = accountId; this.access = access; this.refresh = refresh;
    if (publicKey != null) this.publicKey = publicKey;
    if (privateKey != null) this.privateKey = privateKey;
    if (loginMethod != null) this.loginMethod = loginMethod;
    loggedIn.value = true;
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in ['acct_id', 'acct_access', 'acct_refresh', 'acct_pub', 'acct_method']) { await p.remove(k); }
    // `deleteAll` 而不是逐个 delete:AccountSession 是这个 app 里唯一用 secure storage
    // 的地方,它的命名空间下只会有账号私钥(acct_priv)和各档案密钥(pk_<cloudId>)。
    // 换账号必须把上一个账号的档案密钥也清掉,不然共享设备上账号 B 能读到账号 A 的密钥。
    await _secure.deleteAll();
    accountId = access = refresh = loginMethod = null; publicKey = privateKey = null;
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

  /// 测试专用:把内存态重置成刚启动、还没 `ensureLoaded()` 的样子,不碰底层存储。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    accountId = access = refresh = loginMethod = null;
    publicKey = privateKey = null;
    loggedIn.value = false;
  }

  /// 测试专用:核实 iOS secure storage 选项确实开了 `synchronizable`。
  @visibleForTesting
  static Map<String, String> get iosOptionsForTest => _secure.iOptions.toMap();
}
