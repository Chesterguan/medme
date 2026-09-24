// Task 11 review round 1 · item 1 (CRITICAL):出码是不是走授权链接这条路,
// 必须先判 `role == 'owner'`(发邀请是服务端 owner-only 操作,editor/viewer
// 一律 403),而且**即使是 owner**,邀请创建失败时也不能停在死胡同——必须回退
// 到原来的加密上传路径,不能是个死胡同。
//
// 原路径的密文生成(`qrShareBlob`)是真实 FRB 调用——`flutter test` 没有原生库
// 时它不是抛异常,是真的把整个测试进程卡住退不出去(这里踩过一次,120s 超时都
// 救不回来)。所以 [QrShareScreen] 加了一个 `qrShareBlobFn` 注入点,测试传一个
// 立即失败的假实现,只验证"确实回退过去尝试了原路径",不必也不能真的跑通它。
//
// ⚠️ 真实文件 IO(`Directory.systemTemp.createTemp` 给 path_provider 当假根目录)
// 必须放在 `setUp()`/`tearDown()` 里,不能直接写在 `testWidgets` 回调体内——
// 那个回调体跑在一个"假时钟" zone 里,真实 `dart:io` 的完成回调进不来,会直接
// 卡死且 `--timeout` 都救不回来(同 `member_switcher_locked_test.dart` 顶部那条
// 教训;第一版这里踩过一次)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grant_link.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/disease_profile_screen.dart';
import 'package:mobile_flutter/screens/qr_notice_sheet.dart';
import 'package:mobile_flutter/screens/qr_share_screen.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stage3_visual_helpers.dart';

class _ThrowingApi extends ApiClient {
  _ThrowingApi() : super(base: 'http://x');
}

class _FailingGrants extends Grants {
  _FailingGrants() : super(_ThrowingApi(), AccountSession.instance);

  @override
  Future<GrantLink> inviteDoctor(Profile p) async {
    throw const ApiFailed(500, 'invite create failed');
  }
}

class _SucceedingGrants extends Grants {
  _SucceedingGrants() : super(_ThrowingApi(), AccountSession.instance);

  @override
  Future<GrantLink> inviteDoctor(Profile p) async =>
      GrantLink(inviteId: 'inv_ok', token: 'tokenABCDEFGHIJKLMNOPQRSTUV');
}

/// editor/viewer 档案根本不该调到这里——调用即测试失败,不是返回错误让代码
/// 自己去 catch(那样测不出"压根没试过"和"试了但失败了"的区别)。
class _NeverInvitedGrants extends Grants {
  _NeverInvitedGrants() : super(_ThrowingApi(), AccountSession.instance);

  @override
  Future<GrantLink> inviteDoctor(Profile p) async {
    fail('不是 owner 的档案不该尝试发邀请——服务端本来就会 403');
  }
}

/// 原路径的假密文生成:立即失败,验证的是"确实退回来尝试了",不是"原路径真的
/// 能跑通"(那需要真实 Rust 库)。
Future<(Uint8List, String, int)> _fakeQrShareBlobFails({
  required int expiresDays,
  String? profileJson,
}) async {
  throw Exception('fake: 原路径被调用到了(不含原生库,这里只验证调用发生)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    // 出码屏现在要读「上次选了哪条路」(UX 第二轮),默认旧路径。
    // `qr_notice_seen: true` = 第一次出码那条告知已经说过了(Task 11),不然
    // 每条用例都会先被那张 sheet 挡住,一个码都出不来。
    SharedPreferences.setMockInitialValues({'qr_notice_seen': true});
    support = await Directory.systemTemp.createTemp('medme-qr-share-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    AccountSession.instance.resetForTest();
  });

  tearDown(() async => support.delete(recursive: true));

  group('shouldTryGrantLink(纯函数)', () {
    const owner = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner');
    const editor = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'editor');
    const viewer = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'viewer');
    const noCloud = Profile(id: 'p-1', name: '我');

    test('登录 + owner + 已开通云同步 → true', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: owner), isTrue);
    });

    test('editor → false(发邀请是 owner-only,不该摸黑试)', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: editor), isFalse);
    });

    test('viewer → false', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: viewer), isFalse);
    });

    test('未登录 → false,即使是 owner', () {
      expect(shouldTryGrantLink(loggedIn: false, profile: owner), isFalse);
    });

    test('没有 cloudId(未开通云同步) → false', () {
      expect(shouldTryGrantLink(loggedIn: true, profile: noCloud), isFalse);
    });

    test('F2:把云备份关掉了的 owner → false(「已开通云备份」的定义含 !cloudPaused)', () {
      const paused = Profile(id: 'p-1', name: '我', cloudId: 'prf_1', role: 'owner', cloudPaused: true);
      expect(shouldTryGrantLink(loggedIn: true, profile: paused), isFalse);
      expect(shouldTryGrantLink(loggedIn: true, profile: owner), isTrue, reason: '没关的还得是 true');
    });
  });

  /// owner 档案就绪(登录 + 有公钥 + 当前成员 cloudId/role 已设),role 由调用方
  /// 再覆盖。真实文件 IO(`markCloud` 落盘)包进 `runAsync`。
  Future<void> setUpOwnerProfile(WidgetTester t, {String role = 'owner'}) async {
    AccountSession.instance.publicKey = Uint8List(32);
    AccountSession.instance.accountId = 'acc_1';
    AccountSession.instance.access = 'tok';
    AccountSession.instance.loggedIn.value = true;
    await t.runAsync(() async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
      await ProfileManager.instance.markCloud(ProfileManager.instance.current.id, 'prf_1', role, null);
    });
  }

  testWidgets('editor 档案:直接走原路径,压根不尝试发邀请', (t) async {
    await setUpOwnerProfile(t, role: 'editor');

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _NeverInvitedGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    // 走到了原路径(假实现抛出的通用错误态),而不是 `_NeverInvitedGrants` 里的
    // `fail()`(那会让整个测试直接红,断言写在假实现内部)。
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('owner + 邀请创建失败:不留在授权链接的报错态里,转去尝试原路径', (t) async {
    SharedPreferences.setMockInitialValues({'qr_share_grant_mode': true, 'qr_notice_seen': true});
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _FailingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump(); // 触发 initState 里的 _generate
    await t.pump(const Duration(milliseconds: 50));

    // 断言的是"没有卡在授权链接特有的报错态里"——原路径的假实现接下来会在 catch
    // 里落地成"生成失败"这个**通用**错误态,这正是回退发生了的证据:如果没有
    // 回退,失败会停在 `_grantMode == true` 的状态上,不会走到这里。
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('owner + 邀请创建成功:出码,不触碰原路径', (t) async {
    SharedPreferences.setMockInitialValues({'qr_share_grant_mode': true, 'qr_notice_seen': true});
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _SucceedingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    // 出码成功(这一步顺带跑过 `Analytics.track(shareQrShown, {})`——空 props
    // 不在目录允许集合之外,断言不炸就是它没违反目录契约)。
    // 码出来了的证据换成码下面那一行(`s13`):屏名「出码」现在在顶栏,正文里
    // 不再重写一遍(Task 11)。这一行只在 `_url != null` 时才画。
    expect(find.text('15 天内有效;只有扫这个码的人能看'), findsOneWidget);
    expect(find.text('生成失败'), findsNothing);
  });

  // Task 16:s13 真身是这一屏(`qr_share_screen.dart:591` 的 `MedCard` 包
  // `MedQrFrame`),不是 account_visual_test.dart 里个人模式「交给别人」弹窗
  // 复用的同一颗 `MedQrFrame`(那条路没有 `MedCard`,详见那份测试文件头部
  // 说明)。颜色面预算表:s13 = 0/0/0(唯一一颗主按钮在「第一次出码」那张
  // sheet 上,`account_visual_test.dart` 已经测过)。复用上面「出码成功」
  // 那条用例的 fixture(`_SucceedingGrants` 给一个短的假 token,不碰真实
  // FFI 密文生成)。
  group('Task 16:s13 颜色面预算 + 溢出矩阵', () {
    Future<void> pumpQr(WidgetTester t, {Size size = const Size(400, 800), double scale = 1.0}) async {
      await pumpStage3(
        t,
        QrShareScreen(grants: _SucceedingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
        size: size,
        textScale: scale,
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
    }

    testWidgets('零颜色面;MedCard 包 MedQrFrame', (t) async {
      SharedPreferences.setMockInitialValues({'qr_share_grant_mode': true, 'qr_notice_seen': true});
      await setUpOwnerProfile(t);
      await pumpQr(t);

      // 先确认真的出码了(同「出码成功」那条用例的证据行),预算才有意义。
      expect(find.text('15 天内有效;只有扫这个码的人能看'), findsOneWidget);
      expectSurfaceBudget();
      expectNoGradientAnywhere();
      expect(
        find.descendant(of: find.byType(MedCard), matching: find.byType(MedQrFrame)),
        findsOneWidget,
      );
    });

    testWidgets('两个尺寸 × 两档字号不溢出', (t) async {
      SharedPreferences.setMockInitialValues({'qr_share_grant_mode': true, 'qr_notice_seen': true});
      await setUpOwnerProfile(t);

      for (final size in kStage3Sizes) {
        for (final scale in [1.0, 2.0]) {
          await pumpQr(t, size: size, scale: scale);
          expect(t.takeException(), isNull, reason: '$size @ ${scale}x 溢出了');
        }
      }
    });
  });

  // ---- UX 第二轮:出码屏二选一,默认旧路径 ----
  //
  // 在这之前 `shouldTryGrantLink` 一为真就**自动**切成授权链接,于是"开通云同步"
  // 顺带改掉了诊室里那条最关键的路:医生拿自己手机扫一下当场看 → 医生必须先装
  // MedMe 并登录。

  testWidgets('owner 默认走旧路径:压根不发邀请(选择权交回用户)', (t) async {
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _NeverInvitedGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    // `_NeverInvitedGrants.inviteDoctor` 里是 `fail()` —— 走到那儿整条用例就红了。
    expect(find.text('生成失败'), findsOneWidget);
  });

  testWidgets('owner:顶部两个选项都在,默认选中「当场看」,说明文案说的是浏览器那条', (t) async {
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _SucceedingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(find.text('医生当场看(任何手机)'), findsOneWidget);
    expect(find.text('医生要长期看(15 天)'), findsOneWidget);
    expect(
      find.textContaining('他不用装 App'),
      findsOneWidget,
      reason: '默认那条的说明必须说准:医生不需要装任何东西',
    );
  });

  testWidgets('未登录:连选项都不给(只有旧路径)', (t) async {
    await t.runAsync(() async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
    });

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _NeverInvitedGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(find.text('医生要长期看(15 天)'), findsNothing);
  });

  testWidgets('拨到「医生要长期看」:出授权链接,并把选择记进 prefs', (t) async {
    await setUpOwnerProfile(t);

    await t.pumpWidget(MaterialApp(
      home: QrShareScreen(grants: _SucceedingGrants(), qrShareBlobFn: _fakeQrShareBlobFails),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('生成失败'), findsOneWidget); // 默认那条的假实现失败态

    await t.tap(find.text('医生要长期看(15 天)'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    // 码出来了的证据换成码下面那一行(`s13`):屏名「出码」现在在顶栏,正文里
    // 不再重写一遍(Task 11)。这一行只在 `_url != null` 时才画。
    expect(find.text('15 天内有效;只有扫这个码的人能看'), findsOneWidget);
    expect(find.textContaining('他需要已经装了 MedMe 并登录'), findsOneWidget);
    final prefs = await t.runAsync(() => SharedPreferences.getInstance());
    expect(prefs!.getBool('qr_share_grant_mode'), isTrue, reason: '下次打开该记得这个选择');
  });

  // ---- Task 11:第一次出码先告知一次 ----
  //
  // sheet 本体逐字钉在 `qr_notice_test.dart`;这里只钉**接线**:没说过就先说,
  // 「先不出」= 这一屏退掉、一个字节都没传。要推一层进去才测得到那个 pop。
  testWidgets('这台设备第一次出码:先弹告知,「先不出」就退回上一屏,不出码', (t) async {
    SharedPreferences.setMockInitialValues({}); // 没有 qr_notice_seen = 没说过
    await t.runAsync(() async {
      await ProfileManager.instance.ensureLoaded();
      await ProfileManager.instance.factoryReset();
    });

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (_) => QrShareScreen(
                grants: _NeverInvitedGrants(),
                qrShareBlobFn: _fakeQrShareBlobFails,
              ),
            )),
            child: const Text('去出码'),
          ),
        ),
      ),
    ));
    // 不能 `pumpAndSettle` —— 出码屏等码的时候画的是个转不完的圈,它永远 settle
    // 不了(这里踩过一次)。按帧推,推到够 sheet 的进场动画跑完为止。
    await t.tap(find.text('去出码'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500)); // sheet 插进来
    await t.pump(const Duration(milliseconds: 500)); // 进场动画跑完,按钮才点得到

    expect(find.text(kQrNoticeText), findsOneWidget);

    await t.tap(find.text('先不出'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    expect(find.text('去出码'), findsOneWidget, reason: '「先不出」= 退回上一屏');
    expect(find.text('生成失败'), findsNothing, reason: '压根没走到出码那一步');
  });

  // ── 病程档案随出码进加密包(Task 23)────────────────────────────────────
  //
  // 「开着才带」这条闸落在 Dart 这一侧:Rust 那边只负责「给了就原样挂上去」
  // (`build_share_blob_inner` 还会再挡一次空档案)。这两条用例钉的就是这道闸 ——
  // 带错了,医生那边会多出一份病人**没打算给**的东西。
  group('出码带不带病程档案', () {
    test('开着 → 原串逐字带上,不重新序列化', () async {
      var viewCalls = 0;
      final source = DiseaseProfileSource(
        installed: () async => ['sle'],
        view: (id) async {
          viewCalls++;
          return _enabledViewJson;
        },
        record: (k, p, at) async {},
        refresh: () async {},
      );
      expect(await profileJsonForShare(source), _enabledViewJson);
      // 一次分享只算一遍:`viewJson` 每调一次,Rust 那边就把整箱病历重投影一次。
      expect(viewCalls, 1, reason: '一次出码只该算一遍档案');
    });

    test('没开启 / 一个包都没装 / 读不出来 → 一律不带', () async {
      Future<String?> probe(DiseaseProfileSource s) => profileJsonForShare(s);
      final disabled = DiseaseProfileSource(
        installed: () async => ['sle'],
        view: (id) async => '{"package_id":"sle","enabled":false,"sections":[],"sources":[]}',
        record: (k, p, at) async {},
        refresh: () async {},
      );
      expect(await probe(disabled), isNull, reason: '没开启不许带');

      final none = DiseaseProfileSource(
        installed: () async => <String>[],
        view: (id) => fail('一个包都没装就不该去算视图'),
        record: (k, p, at) async {},
        refresh: () async {},
      );
      expect(await probe(none), isNull);

      // 算不出来只是「这次不带档案」—— 出码本身绝不能因此失败。
      final broken = DiseaseProfileSource(
        installed: () async => ['sle'],
        view: (id) async => throw Exception('fake: 投影失败'),
        record: (k, p, at) async {},
        refresh: () async {},
      );
      expect(await probe(broken), isNull);
    });

    testWidgets('整屏出码:开着的档案确实交到了密文生成那一步', (t) async {
      String? seen;
      var called = false;
      await t.pumpWidget(MaterialApp(
        home: QrShareScreen(
          grants: _NeverInvitedGrants(),
          profileSource: DiseaseProfileSource(
            installed: () async => ['sle'],
            view: (id) async => _enabledViewJson,
            record: (k, p, at) async {},
            refresh: () async {},
          ),
          qrShareBlobFn: ({required int expiresDays, String? profileJson}) async {
            called = true;
            seen = profileJson;
            throw Exception('fake: 到这一步就够了,不含原生库');
          },
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(called, isTrue, reason: '得真的走到密文生成那一步');
      expect(seen, _enabledViewJson, reason: '开着的档案要原样交下去');
    });
  });
}

/// 一份**开着**的 `ProfileView`(形状取自 `packages/profile/src/view.rs`)。
const _enabledViewJson =
    '{"package_id":"sle","package_version":"2026.09.1","display_name":"系统性红斑狼疮",'
    '"enabled":true,"disclaimer":"仅整理你的病历,不做诊断",'
    '"sections":[{"kind":"reminders","id":null,"title":"待补 / 逾期","empty_hint":null,'
    '"body":{"items":[]}}],"sources":[]}';
