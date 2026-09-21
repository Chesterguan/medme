// C3 遗留:设置页那句「请先在设置里关闭 iCloud 同步」指向的开关被
// `_showIcloudSync = false` 藏起来了(settings_screen.dart ~37)——老用户此刻
// 正开着 iCloud 同步,却在设置里根本找不到关掉它的入口。
//
// 修复:`shouldShowIcloudSection` 除了 `_showIcloudSync` 这个总开关之外,还要在
// `icloudStatus().enabled == true` 时露出这一节,让这些老用户能自己关掉。新用户
// (没开过)不受影响,依旧收起。
//
// 只测这条纯函数,不 pump 整个 `SettingsScreen`——它 `initState` 里直接调
// `icloudStatus()`/`patientProfile()`(真实 Rust FFI),`flutter test` 没有原生库,
// 同仓库其它测试对 Rust 桥屏幕的一贯限制(见 `account_screen_test.dart` 顶部关于
// `enableCloud` 的说明)。`IcloudStatusDto` 本身只是个数据类,不需要 FFI 就能构造。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

void main() {
  test('iCloud 开着 → 露出这一节(哪怕总开关收着)', () {
    expect(shouldShowIcloudSection(const IcloudStatusDto(available: true, enabled: true)), isTrue);
  });

  test('iCloud 没开、状态还没查回来(null)→ 保持收起', () {
    expect(shouldShowIcloudSection(const IcloudStatusDto(available: true, enabled: false)), isFalse);
    expect(shouldShowIcloudSection(null), isFalse);
  });
}
