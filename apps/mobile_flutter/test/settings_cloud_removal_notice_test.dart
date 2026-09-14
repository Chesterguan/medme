// 设置页删除成员的确认弹窗,原文案对所有成员统一写"彻底删除、无法恢复"——但云
// 成员的 `removeProfileAndReopen` 做的其实是"从这台手机摘掉"(owner 授权服务端
// 删不掉,只是本机记一笔黑名单不再自动拉回,见 `vault_boot.dart`),不是真的
// 彻底删除。`cloudRemovalNotice` 只为云成员(`cloudId != null`)多说这一句实话。
//
// 只测这条纯函数——`_confirmRemove` 所在的 `_VaultCard`/`SettingsScreen` 需要真实
// Rust FFI(`initState` 直接调 `icloudStatus()`/`patientProfile()`),`flutter test`
// 没有原生库,同仓库其它涉及 Rust 桥屏幕测试的一贯限制。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';

void main() {
  test('云成员:多说一句"本机删除、云端不受影响、不会再自动拉回"', () {
    const p = Profile(id: 'p-1', name: '张三', cloudId: 'prf_1', role: 'owner');
    final notice = cloudRemovalNotice(p);
    expect(notice, isNotNull);
    expect(notice, contains('云端副本和其他设备不受影响'));
    expect(notice, contains('本机不会再自动拉回'));
    // C10:末尾那半句「要彻底删除请注销账号或撤销授权」是错的指路 —— 注销账号删的是
    // 整个账号(连同其它成员、所有授权),不是"彻底删掉这一个成员";把它摆在删除
    // 单个成员的弹窗里,等于建议一个破坏性大得多的操作。
    expect(notice, isNot(contains('注销账号')));
  });

  test('纯本地成员:不多说这句(原文案已经如实描述"彻底删除")', () {
    const p = Profile(id: 'p-1', name: '张三');
    expect(cloudRemovalNotice(p), isNull);
  });
}
