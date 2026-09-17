// 系统权限弹窗逐字给用户看,而它的文案在 Info.plist 里,没有任何 Dart 测试
// 能碰到它 —— 于是它成了全项目最容易过期的两句话(ux-audit §4 第 7、8 条)。
// 这个测试直接读那个文件。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('相机/相册用途说明不再承诺「不会上传」', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    for (final s in ['不会上传', '只存在本机', '只在本机处理']) {
      expect(plist.contains(s), isFalse, reason: 'Info.plist 里还有「$s」');
    }
    // 两条用途说明本身必须还在 —— 删掉会直接被 App Store 拒。
    expect(plist.contains('NSCameraUsageDescription'), isTrue);
    expect(plist.contains('NSPhotoLibraryUsageDescription'), isTrue);
  });

  // fix round 1(task-2-review.md W3):涂黑后的病历图会交给第三方模型服务商
  // (`services/api/extract.py` → DeepSeek),这是 PIPL 第二十三条的单独告知事项,
  // 之前两条用途说明都读作「送我们自己的云」。
  test('相机/相册用途说明点名第三方模型服务(PIPL 23 单独告知)', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist.contains('合作的模型服务'), isTrue);
  });
}
