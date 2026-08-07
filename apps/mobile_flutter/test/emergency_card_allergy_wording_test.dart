// 过敏史语义统一(产品拍板)的钉子测试:app 永远不能宣称「没有过敏」,只能说
// 「未识别」。
//
// 覆盖普通模式(`_AllergySection`,通过 `EmergencyCardScreen`)与大字模式
// (`_bigAllergyBox`,通过 `EmergencyBigCardScreen`)各自的空态文案 —— 这是
// 四个文案出口里,除了托管查看器(`packages/share/src/share.rs` 里
// `hosted_viewer_never_hides_the_allergy_row_when_empty` 验)之外,唯二能不
// 碰 FFI 直接钉的两个。「复制给医生」纯文本走 Rust
// (`vault_projections.rs::render_plain_text`),不在这份文件的能力范围内。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';

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
    // 紧急联系人 / 器官捐献意愿存的 SharedPreferences,与保险箱/过敏史无关,
    // 但 `EmergencyCardScreen.initState` 会读它(见 `emergency_card_refresh_test.dart`
    // 同一段设置)。
    SharedPreferences.setMockInitialValues({});
  });

  group('普通模式 _AllergySection', () {
    testWidgets('过敏史为空 —— 标题标「未识别」,正文说明为什么,不断言无过敏', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: EmergencyCardScreen(load: () async => (emptyCard(), _profile)),
        ),
      );
      await tester.pumpAndSettle();

      // 状态名落在小节标题上,单条条目不必再背这个包袱(产品设计要点)。
      expect(find.text('过敏史(未识别)'), findsOneWidget);
      // 光秃秃的「过敏史」标题不该同时存在 —— 空态只应该有带后缀的那一个。
      expect(find.text('过敏史'), findsNothing);
      // 保留「这不等于没有过敏」的既有解释(它本来就是对的),并且要点出为什么
      // 是「未识别」:很少有人做过完整的过敏原检测。
      expect(find.textContaining('不等于没有过敏'), findsOneWidget);
      expect(find.textContaining('完整的过敏原检测'), findsOneWidget);
    });

    testWidgets('过敏史有条目 —— 标题不带「未识别」后缀', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: EmergencyCardScreen(
            load: () async => (cardWithAllergy(), _profile),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('过敏史'), findsOneWidget);
      expect(find.text('过敏史(未识别)'), findsNothing);
      expect(find.text('青霉素'), findsOneWidget);
    });
  });

  group('大字模式 EmergencyBigCardScreen._bigAllergyBox', () {
    testWidgets('过敏史为空 —— 标题标「未识别」,正文比普通模式短很多', (
      tester,
    ) async {
      // 先量普通模式的空态说明有多长 —— 大字模式要比它短很多,这个基准量
      // 出来比写死一个魔数更贴合"不能照搬普通模式那一整段"这条要求本身。
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: EmergencyCardScreen(load: () async => (emptyCard(), _profile)),
        ),
      );
      await tester.pumpAndSettle();
      final normalModeBody = tester
          .widgetList<Text>(find.textContaining('不等于没有过敏'))
          .single;
      final normalModeLen = normalModeBody.data!.length;

      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: EmergencyBigCardScreen(card: emptyCard(), profile: _profile),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('过敏史(未识别)'), findsOneWidget);
      expect(find.text('过敏史'), findsNothing);
      // 大字模式是给急救人员三秒内读的,不能照搬普通模式那一整段;仍要落住
      // 「未识别 ≠ 没有」这条核心结论,措辞不必逐字一样。
      expect(find.textContaining('未识别'), findsWidgets);
      final bigModeBody = tester
          .widgetList<Text>(find.textContaining('请立刻向本人/家属确认'))
          .single;
      expect(
        bigModeBody.data!.length,
        lessThan(normalModeLen),
        reason: '大字模式文案要比普通模式短,不能照搬普通模式那一大段解释'
            '(普通模式 $normalModeLen 字,大字模式 ${bigModeBody.data!.length} 字)',
      );
    });

    testWidgets('过敏史有条目 —— 标题不带「未识别」后缀,内容照常显示', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: EmergencyBigCardScreen(
            card: cardWithAllergy(),
            profile: _profile,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('过敏史'), findsOneWidget);
      expect(find.text('过敏史(未识别)'), findsNothing);
      expect(find.text('青霉素'), findsOneWidget);
    });
  });
}
