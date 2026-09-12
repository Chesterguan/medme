// 最终评审 I6:安卓系统自动备份**必须是关的**。
//
// 这是一条没有任何运行时代码能体现、只存在于清单文件里的安全约束:沙盒里躺着的是
// 明文的病历保险箱(vault 真相目录 + 派生库)和账号 refresh token,而安卓的自动
// 备份默认开启,会把它们整包传进用户的 Google Drive —— 一份我们看不见也撤不回的
// 副本。出包前没有任何测试会提醒你这一点,所以这条就是那个提醒:直接读清单文件
// 和备份规则 xml 断言,删掉属性就红。
//
// ⚠️ 改这两个文件 = 改「数据会不会离开手机」,必须同步隐私政策
// (gh-pages 的 privacy.html)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // `flutter test` 的工作目录是包根(apps/mobile_flutter),所以相对路径就够。
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml');

  test('AndroidManifest:allowBackup=false + 指向 data_extraction_rules', () {
    expect(manifest.existsSync(), isTrue, reason: '清单文件路径变了?那这条测试也要跟着改');
    final xml = manifest.readAsStringSync();
    expect(xml, contains('android:allowBackup="false"'), reason: 'Android 11 及以下只认这一条');
    expect(
      xml,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      reason: 'Android 12+ 认这一条',
    );
  });

  test('data_extraction_rules:云备份与设备迁移都把每个 domain 排除干净', () {
    expect(rules.existsSync(), isTrue);
    final xml = rules.readAsStringSync();
    // 去掉注释再断言,免得"注释里提到过"被当成规则生效。
    final body = xml.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    for (final section in ['cloud-backup', 'device-transfer']) {
      final start = body.indexOf('<$section>');
      final end = body.indexOf('</$section>');
      expect(start >= 0 && end > start, isTrue, reason: '缺 <$section> 段');
      final inner = body.substring(start, end);
      for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
        expect(inner, contains('domain="$domain"'), reason: '$section 没排除 $domain');
      }
      expect(inner, isNot(contains('<include')), reason: '一条 include 就等于把某个目录放回备份里');
    }
  });
}
