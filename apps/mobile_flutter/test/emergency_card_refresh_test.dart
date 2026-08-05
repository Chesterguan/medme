// 应急卡随保险箱变更刷新的回归测试(BUG-1)。
//
// ## 钉的是什么
//
// `EmergencyCardScreen` 监听 `vaultRevision`,任何一次写(手动录入、导入、载入示例、
// 清空)最后都会 `bumpVaultRevision()`。这一屏收到通知之后必须**真的重建**。
//
// 它曾经写的是 `setState(() => _future = _load())` —— **箭头体**。`State.setState`
// 先执行回调(赋值已经发生),再在断言里发现回调返回了一个 `Future` 并抛出,而那一抛
// 发生在 `markNeedsBuild()` **之前**:`_future` 换成了新的,却没有任何一次重建被调度。
// 五个 tab 全在 `IndexedStack` 里、`tabScreens` 又是 `const` 列表,切 tab 也不重建
// (`identical(newWidget, oldWidget)` 直接跳过),于是应急卡停在冷启动那一刻,直到
// App 重启 —— 而这恰恰是「别人拿着你的手机」那一屏。
//
// release 构建里断言被剥掉,`markNeedsBuild()` 照常执行,所以**只有 debug/profile
// 会现**;团队自己装的正是带 `.dev` 后缀的 debug 包。`flutter test` 跑在断言开着的
// 环境里,与 debug 同侧,所以这条测试正好站在能看见它的那一边。
//
// ## 为什么能不碰 FFI
//
// 触发端(`vaultRevision`)本来就是纯 Dart 的 `ValueNotifier`;数据端经
// `EmergencyCardScreen.load` 注入一个假的即可 —— `flutter test` 不加载 Rust 原生库。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';

const _profile = PatientProfileDto(gender: '男', age: '68岁', recordCount: 0);

EmergencyCardDto emptyCard() =>
    const EmergencyCardDto(allergies: [], activeMeds: [], conditions: []);

EmergencyCardDto cardWithAllergy() => EmergencyCardDto(
  allergies: [
    AllergyItemDto(
      substance: '青霉素',
      reaction: '全身皮疹',
      documentIds: Int64List(0),
    ),
  ],
  activeMeds: [],
  conditions: [],
);

void main() {
  setUp(() {
    // 紧急联系人 / 器官捐献意愿存在 SharedPreferences 里,与保险箱无关。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('保险箱一变,应急卡就重新拉一次数据并把新内容显示出来', (tester) async {
    // 「数据层」的替身:测试改它,就等于导入 / 录入 / 载入示例改了保险箱。
    var data = emptyCard();
    var loads = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: MedMe.theme(),
        home: EmergencyCardScreen(
          load: () async {
            loads++;
            return (data, _profile);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 冷启动:空态,而且空态得自己说话(留白会被读成「无过敏史」)。
    expect(loads, 1);
    expect(find.textContaining('不等于没有过敏'), findsOneWidget);
    expect(find.text('青霉素'), findsNothing);

    // 用户在别的 tab 上导了一份带过敏史的病历 —— 数据层变了,信号发出来。
    data = cardWithAllergy();
    bumpVaultRevision();
    await tester.pumpAndSettle();

    expect(loads, 2, reason: '收到保险箱变更后必须重新拉一次');
    expect(
      find.text('青霉素'),
      findsOneWidget,
      reason: 'BUG-1:重建没被调度,应急卡会一直停在冷启动那一刻的内容,直到 App 重启',
    );
  });

  testWidgets('刷新走的是 setState 的语句块 —— 不许把 Future 交给 setState', (tester) async {
    // 上面那条已经能抓住「没重建」,这条额外把**根因本身**钉住:箭头体会让
    // `State.setState` 在 `markNeedsBuild()` 之前抛断言。抛出的异常被
    // `ChangeNotifier.notifyListeners` 的 try/catch 接住 → 只走 `FlutterError.onError`,
    // `tester.takeException()` 接不到,所以这里自己挂一个 handler 收。
    final errors = <FlutterErrorDetails>[];
    final original = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = original);

    await tester.pumpWidget(
      MaterialApp(
        theme: MedMe.theme(),
        home: EmergencyCardScreen(load: () async => (emptyCard(), _profile)),
      ),
    );
    await tester.pumpAndSettle();

    bumpVaultRevision();
    await tester.pumpAndSettle();

    FlutterError.onError = original; // 必须在 expect 之前恢复
    expect(
      errors.map((e) => e.exceptionAsString()),
      isEmpty,
      reason: '刷新路径上不该有任何被吞掉的框架异常',
    );
  });
}
