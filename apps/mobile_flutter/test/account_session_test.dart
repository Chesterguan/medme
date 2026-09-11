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

  test('iOS secure storage 选项开了 synchronizable(iCloud 钥匙串同步)', () {
    expect(AccountSession.iosOptionsForTest['synchronizable'], 'true');
  });
}
