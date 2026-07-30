import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 钉住「关于」里显示的版本号,别让它再漂。
///
/// 已经漂过两次:`pubspec.yaml` 早升到 1.3.6+50,`settings_screen.dart` 里手写的
/// 展示常量还停在 1.2.0——团队靠「关于」页核「有没有装到最新版」,于是全员都会
/// 以为自己没装对。约束里明确不为读版本号新增 `package_info_plus` 依赖,所以展示
/// 值只能手工同步,而手工同步的东西没有测试钉着必然再漂。
///
/// 选择「正则扫源码文件」而不是把 `_appVersion` 改成公开常量再 import:这颗常量
/// 纯展示、不参与任何业务逻辑,没必要为了一个测试扩大它的可见性;而且不管常量
/// 公不公开,真正的风险点始终是「代码里的字面量」和「pubspec.yaml 的字面量」这
/// 两处文本有没有对上——直接对比这两处文本,比经一层 import 更贴近实际在防的东西。
///
/// 注意:`flutter test` 的工作目录是 package 根,所以 `pubspec.yaml` 和
/// `lib/screens/settings_screen.dart` 都可以用相对路径直接读。
void main() {
  test('settings_screen 里手写的版本号常量与 pubspec.yaml 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionMatch = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(
      versionMatch,
      isNotNull,
      reason: 'pubspec.yaml 里没找到 `version: x.y.z+build` 这一行,格式是不是变了?',
    );
    final pubspecVersion = versionMatch!.group(1)!;
    final pubspecBuild = versionMatch.group(2)!;

    final settingsSource = File(
      'lib/screens/settings_screen.dart',
    ).readAsStringSync();
    final nameMatch = RegExp(
      r"const _appVersionName = '([^']+)';",
    ).firstMatch(settingsSource);
    final buildMatch = RegExp(
      r"const _appBuildNumber = '([^']+)';",
    ).firstMatch(settingsSource);
    expect(
      nameMatch,
      isNotNull,
      reason: '没找到 `const _appVersionName = \'...\';`——常量是不是被改名了?'
          '同步改一下这个测试。',
    );
    expect(
      buildMatch,
      isNotNull,
      reason: '没找到 `const _appBuildNumber = \'...\';`——常量是不是被改名了?'
          '同步改一下这个测试。',
    );

    expect(
      nameMatch!.group(1),
      pubspecVersion,
      reason:
          '「关于」里显示的版本号(${nameMatch.group(1)})和 pubspec.yaml($pubspecVersion)'
          '对不上了。发新版本时两处都要改。',
    );
    expect(
      buildMatch!.group(1),
      pubspecBuild,
      reason:
          '「关于」里显示的 build 号(${buildMatch.group(1)})和 pubspec.yaml($pubspecBuild)'
          '对不上了。发新版本时两处都要改。',
    );
  });
}
