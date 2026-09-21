// Task 15 fix round 1(review Important 1):删掉整个文件时把 `_pinCopiedMessage`
// 这条跟 `resolveDoctorClaimUrl` 无关的断言一起删掉了——评审 Minor 18 那次已经
// 丢过一次「代拍那条路的复制提示是「链接已复制,可以发给病人」,不是通用那句
// 「链接已复制」」,补回来,别再丢第二次。
//
// 只钉文案常量这件事本身——对话框的渲染由 `test/account_screen_test.dart` 的 B5
// 用例(同一个 `showLinkQrDialog`)覆盖,这里不重复。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('代拍交付:复制提示是「链接已复制,可以发给病人」,不是通用那句', () async {
    final src = await File(
      'lib/screens/doctor/doctor_claim_link_dialog.dart',
    ).readAsString();
    expect(src, contains("copiedMessage: '链接已复制,可以发给病人'"));
  });
}
