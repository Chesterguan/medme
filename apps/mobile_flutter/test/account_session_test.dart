// AccountSession 是共享设备上唯一一份账号态:token、账号私钥、各档案密钥。
// 盯的是换账号时**不能残留上一个账号的密钥**——clear() 必须把这个类名下的
// secure storage 整个清空,不能只删它当时想起来的那几个 key。
import 'dart:typed_data';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> secureData;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureData = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(secureData);
    AccountSession.instance.resetForTest();
  });

  test('clear() 清掉整个 secure storage 命名空间:profile key、私钥都不残留', () async {
    await AccountSession.instance.save(
      accountId: 'acct-A',
      access: 'tokA',
      refresh: 'refA',
      privateKey: Uint8List.fromList([1, 2, 3]),
    );
    await AccountSession.instance.putProfileKey('cloud-1', Uint8List.fromList([9, 9, 9]));
    expect(await AccountSession.instance.profileKey('cloud-1'), isNotNull);

    await AccountSession.instance.clear();

    expect(await AccountSession.instance.profileKey('cloud-1'), isNull);
    expect(secureData, isEmpty, reason: '账号 A 的私钥/档案密钥不该留在钥匙串里等账号 B 读到');
    expect(AccountSession.instance.accountId, isNull);
    expect(AccountSession.instance.access, isNull);
    expect(AccountSession.instance.refresh, isNull);
    expect(AccountSession.instance.privateKey, isNull);
    expect(AccountSession.instance.loggedIn.value, isFalse);

    final p = await SharedPreferences.getInstance();
    expect(p.getString('acct_id'), isNull);
    expect(p.getString('acct_access'), isNull);
    expect(p.getString('acct_refresh'), isNull);
  });

  test('save → ensureLoaded 往返:account id / token / 公钥都能读回', () async {
    await AccountSession.instance.save(
      accountId: 'acct-B',
      access: 'tokB',
      refresh: 'refB',
      publicKey: Uint8List.fromList([4, 5, 6]),
      privateKey: Uint8List.fromList([7, 8, 9]),
    );

    // 模拟下次冷启动:内存态清空,只留底层存储,再走一次 ensureLoaded。
    AccountSession.instance.resetForTest();
    await AccountSession.instance.ensureLoaded();

    expect(AccountSession.instance.accountId, 'acct-B');
    expect(AccountSession.instance.access, 'tokB');
    expect(AccountSession.instance.refresh, 'refB');
    expect(AccountSession.instance.publicKey, Uint8List.fromList([4, 5, 6]));
    expect(AccountSession.instance.privateKey, Uint8List.fromList([7, 8, 9]));
    expect(AccountSession.instance.loggedIn.value, isTrue);
  });

  test('putProfileKey / profileKey 往返', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    await AccountSession.instance.putProfileKey('cloud-2', key);
    expect(await AccountSession.instance.profileKey('cloud-2'), key);
  });

  // ---- Task 16 item 3:成员/授权被移除时,连同它的档案密钥一起清掉 ----

  test('removeProfileKey:只删这一个档案的密钥,不碰别的', () async {
    final keyA = Uint8List.fromList(List.generate(32, (i) => i));
    final keyB = Uint8List.fromList(List.generate(32, (i) => 100 + i));
    await AccountSession.instance.putProfileKey('cloud-a', keyA);
    await AccountSession.instance.putProfileKey('cloud-b', keyB);

    await AccountSession.instance.removeProfileKey('cloud-a');

    expect(await AccountSession.instance.profileKey('cloud-a'), isNull);
    expect(await AccountSession.instance.profileKey('cloud-b'), keyB, reason: '不该被连坐删掉');
  });

  test('removeProfileKey:这个 cloudId 本来就没存过密钥时,不报错', () async {
    await AccountSession.instance.removeProfileKey('never-existed');
    expect(await AccountSession.instance.profileKey('never-existed'), isNull);
  });

  test('iOS secure storage 选项开了 synchronizable(iCloud 钥匙串同步)', () {
    expect(AccountSession.iosOptionsForTest['synchronizable'], 'true');
  });

  // ---- Task 15:loginMethod——注销账号那一步靠它决定要哪种重新鉴权 ----

  test('save(loginMethod: ...) 落盘 + 往返,clear() 清掉', () async {
    await AccountSession.instance.save(accountId: 'acct-C', access: 'tokC', refresh: 'refC', loginMethod: 'otp');
    expect(AccountSession.instance.loginMethod, 'otp');

    AccountSession.instance.resetForTest();
    await AccountSession.instance.ensureLoaded();
    expect(AccountSession.instance.loginMethod, 'otp', reason: '冷启动后应该能读回上次登录方式');

    await AccountSession.instance.clear();
    expect(AccountSession.instance.loginMethod, isNull);
    AccountSession.instance.resetForTest();
    await AccountSession.instance.ensureLoaded();
    expect(AccountSession.instance.loginMethod, isNull, reason: 'clear() 也要清掉落盘的那一份,不能读回来');
  });

  test('save() 不传 loginMethod 时保留原值(同 publicKey/privateKey 的"只在提供时写"约定)', () async {
    await AccountSession.instance.save(accountId: 'acct-D', access: 'tokD', refresh: 'refD', loginMethod: 'apple');
    await AccountSession.instance.save(accountId: 'acct-D', access: 'tokD2', refresh: 'refD2');
    expect(AccountSession.instance.loginMethod, 'apple');
  });
}
