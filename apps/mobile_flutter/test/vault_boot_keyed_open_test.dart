// 钉住「不登录 = 现状」这条不变量:没有 cloudId 的档案必须走原路径,一字不改。
//
// `openCurrentProfileVault` 本身调真实 FRB(`syncOpenProfileVault`/`openVault`)+
// `path_provider`,`flutter test` 不加载原生库,调用会直接崩(同
// `wipe_all_data_test.dart`/`account_screen_test.dart` 顶部同一条限制)。所以
// 它「走 keyed 还是走原路径」这个判断被抽成纯函数 `shouldOpenKeyed`——不碰
// IO/FFI,可以在这里直接钉住。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

void main() {
  test('没有 cloudId:不管有没有传密钥,一律走原路径(旧代码路径)', () {
    const p = Profile(id: 'p-1', name: '我');
    expect(shouldOpenKeyed(p, null), isFalse);
    expect(shouldOpenKeyed(p, Uint8List(32)), isFalse, reason: '没有 cloudId 的档案压根不该有密钥可传,但即使传了也不该走 keyed');
  });

  test('有 cloudId 但拿不到档案密钥(比如密钥还没落盘/被清过):走原路径', () {
    const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    expect(shouldOpenKeyed(p, null), isFalse);
  });

  test('有 cloudId 且有密钥:走 keyed 开箱', () {
    const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    expect(shouldOpenKeyed(p, Uint8List(32)), isTrue);
  });
}
