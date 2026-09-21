// 钉住三条开箱不变量(`VaultOpenPlan`):
// 1. 没有 cloudId 的档案必须走原路径,一字不改(不登录 = 现状)。
// 2. 有 cloudId 但拿不到档案密钥——这是「锁住」状态,`openCurrentProfileVault`
//    必须显式拒绝(`ProfileLocked`),不许悄悄退化成不加密的本地打开:那样写进去
//    的事件没有账号密钥的 MAC,下次真正 keyed 打开时会被永久隔离。
// 3. 有 cloudId 且有密钥:走 keyed 开箱。
//
// `openCurrentProfileVault` 本身调真实 FRB(`syncOpenProfileVault`/`openVault`)+
// `path_provider`,`flutter test` 不加载原生库,调用会直接崩(同
// `wipe_all_data_test.dart`/`account_screen_test.dart` 顶部同一条限制)。所以
// 它「走哪条路」这个判断被抽成纯函数 `planVaultOpen`——不碰 IO/FFI,可以在这里
// 直接钉住。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

void main() {
  test('没有 cloudId:不管有没有传密钥,一律走原路径(旧代码路径)', () {
    const p = Profile(id: 'p-1', name: '我');
    expect(planVaultOpen(p, null), VaultOpenPlan.unkeyed);
    expect(
      planVaultOpen(p, Uint8List(32)),
      VaultOpenPlan.unkeyed,
      reason: '没有 cloudId 的档案压根不该有密钥可传,但即使传了也不该走 keyed',
    );
  });

  test('有 cloudId 但拿不到档案密钥(账号没解锁/密钥被清过):锁住,不许静默退回本地打开', () {
    const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    expect(planVaultOpen(p, null), VaultOpenPlan.locked);
  });

  test('有 cloudId 且有密钥:走 keyed 开箱', () {
    const p = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    expect(planVaultOpen(p, Uint8List(32)), VaultOpenPlan.keyed);
  });

  test('C4:ProfileLocked 的提示说人话 —— 为什么打不开 + 要他做什么,不露 cloudId', () {
    // `main.dart` 的 `VaultBootstrap` 直接把 `snap.error` 的原文摆在屏上(那是
    // 启动时最显眼的一段字),所以文案得靠异常自己说清楚。
    const e = ProfileLocked('prf_1');
    expect(e.toString(), '你的病历是加密的,需要你的口令才能打开。');
    expect(e.toString(), isNot(contains('prf_1')), reason: 'cloudId 是服务端内部 id,只进 debug 日志');
    // 字段仍然留着(排查用、也是这个异常的身份)。
    expect(e.cloudId, 'prf_1');
  });
}
