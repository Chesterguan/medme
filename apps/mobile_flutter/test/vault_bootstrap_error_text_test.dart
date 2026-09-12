// review round 2:`main.dart` 的 `VaultBootstrap` 开箱失败画面曾经无条件加一句
// 「请重启 App 再试」——对 `ProfileLocked`(账号没解锁,不是箱子坏了)这条建议是
// 错的,重启解决不了。钉住 `vaultBootstrapErrorText` 这条纯函数:`ProfileLocked`
// 走标题「需要解锁账号」+ 不带重启建议的正文,其它错误维持原文案不变。
//
// `VaultBootstrap` 本身的 `_open` 是一次调真实 FFI 的 IIFE,`flutter test` 没法
// 驱动整个 widget;这条判断因此被抽成纯函数单独测,同 `vault_boot.dart` 里
// `planVaultOpen`/`shouldOpenKeyed` 一路的做法。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/vault_boot.dart';

void main() {
  test('ProfileLocked:标题是「需要解锁账号」,正文不带「请重启 App 再试」', () {
    final text = vaultBootstrapErrorText(const ProfileLocked('prf_1'));
    expect(text.title, '需要解锁账号');
    expect(text.body, contains('解锁账号'));
    expect(text.body, isNot(contains('请重启 App 再试')));
  });

  test('其它错误:维持原文案(标题「无法打开你的健康档案」,正文带重启建议)', () {
    final text = vaultBootstrapErrorText(StateError('boom'));
    expect(text.title, '无法打开你的健康档案');
    expect(text.body, contains('boom'));
    expect(text.body, contains('请重启 App 再试。'));
  });
}
