// Task 11 review round 1 · item 8:代拍交付对话框——登录且代拍档案已开通云同步
// 时改发转移链接,但**转移链接生成失败必须回退到调用方传来的原始链接**,不能
// 让医生对着一个没法用的码交差。
//
// 决定用哪条链接的逻辑抽成了纯异步函数 `resolveDoctorClaimUrl`(不碰
// BuildContext/Widget 树),直接测它——不需要真的 `pumpWidget` 这个对话框。
// (`AlertDialog` 内嵌的 `QrImageView` 用了 `LayoutBuilder`,在 `flutter test`
// 里 pump 会踩一个已知的 Flutter 渲染坑——"LayoutBuilder does not support
// returning intrinsic dimensions",与这里要测的逻辑无关,踩过一次才发现。)
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/doctor/doctor_claim_link_dialog.dart';

class _ThrowingApi extends ApiClient {
  _ThrowingApi() : super(base: 'http://x');
}

class _FakeGrants extends Grants {
  _FakeGrants({this.link, this.error}) : super(_ThrowingApi(), AccountSession.instance);
  final GrantLink? link;
  final Object? error;

  @override
  Future<GrantLink> inviteTransfer(Profile p) async {
    if (error != null) throw error!;
    return link!;
  }
}

const _originalUrl = 'https://medmenow.com/claim/#c1.original123456.thekeythekeythekey';
const _cloudProfile = Profile(id: 'p-1', name: '病人', cloudId: 'prf_1', role: 'owner');

void main() {
  test('未登录:原样用调用方传来的链接,不碰 Grants', () async {
    final grants = _FakeGrants(error: StateError('不该被调用'));
    final url = await resolveDoctorClaimUrl(
      fallbackUrl: _originalUrl,
      loggedIn: false,
      cloudProfile: _cloudProfile,
      grants: grants,
    );
    expect(url, _originalUrl);
  });

  test('登录但没传云档案:原样用原始链接', () async {
    final grants = _FakeGrants(error: StateError('不该被调用'));
    final url = await resolveDoctorClaimUrl(
      fallbackUrl: _originalUrl,
      loggedIn: true,
      cloudProfile: null,
      grants: grants,
    );
    expect(url, _originalUrl);
  });

  test('登录 + 已开通云同步 + 转移链接生成成功:用这条新链接', () async {
    final transferLink = GrantLink(inviteId: 'inv_t', token: 'thetransfertokenABCDEFGHIJ');
    final url = await resolveDoctorClaimUrl(
      fallbackUrl: _originalUrl,
      loggedIn: true,
      cloudProfile: _cloudProfile,
      grants: _FakeGrants(link: transferLink),
    );
    expect(url, transferLink.toUrl());
    expect(url, isNot(_originalUrl));
  });

  test('登录 + 已开通云同步 + 转移链接生成失败:回退到原始链接,不是死胡同', () async {
    final url = await resolveDoctorClaimUrl(
      fallbackUrl: _originalUrl,
      loggedIn: true,
      cloudProfile: _cloudProfile,
      grants: _FakeGrants(error: Exception('invite create failed')),
    );
    expect(url, _originalUrl);
  });
}
