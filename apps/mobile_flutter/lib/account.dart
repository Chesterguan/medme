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
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    accountId = p.getString('acct_id');
    access = p.getString('acct_access');
    refresh = p.getString('acct_refresh');
    final pk = await _secure.read(key: 'acct_priv');
    privateKey = pk == null ? null : base64Decode(pk);
    final pub = p.getString('acct_pub');
    publicKey = pub == null ? null : base64Decode(pub);
    _loaded = true;
    loggedIn.value = accountId != null && access != null;
  }

  Future<void> save({required String accountId, required String access, required String refresh, Uint8List? publicKey, Uint8List? privateKey}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('acct_id', accountId);
    await p.setString('acct_access', access);
    await p.setString('acct_refresh', refresh);
    if (publicKey != null) await p.setString('acct_pub', base64Encode(publicKey));
    if (privateKey != null) await _secure.write(key: 'acct_priv', value: base64Encode(privateKey));
    this.accountId = accountId; this.access = access; this.refresh = refresh;
    if (publicKey != null) this.publicKey = publicKey;
    if (privateKey != null) this.privateKey = privateKey;
    loggedIn.value = true;
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in ['acct_id', 'acct_access', 'acct_refresh', 'acct_pub']) { await p.remove(k); }
    await _secure.delete(key: 'acct_priv');
    accountId = access = refresh = null; publicKey = privateKey = null;
    loggedIn.value = false;
  }

  Future<Uint8List?> profileKey(String cloudId) async {
    final v = await _secure.read(key: 'pk_$cloudId');
    return v == null ? null : base64Decode(v);
  }

  Future<void> putProfileKey(String cloudId, Uint8List key) => _secure.write(key: 'pk_$cloudId', value: base64Encode(key));
}
