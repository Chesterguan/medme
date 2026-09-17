// 「你是?」删掉之后,没选过模式的人必须直接落在个人模式的三 tab 里,
// 而不是一个空屏或一个还问一次的选择页(ux-audit 屏02)。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';

void main() {
  test('没选过模式 → 直接进个人模式的壳,不再问一次', () {
    expect(modeRoot(null), isA<HomeShell>());
    expect(modeRoot(AppModeKind.personal), isA<HomeShell>());
    expect(modeRoot(AppModeKind.doctor), isA<DoctorHomeScreen>());
  });
}
