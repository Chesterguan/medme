// 「我」tab 点开一个成员之后的页面(`s10`,Task 13 fix round 1)。
//
// 覆盖:「谁能看」一行一个 grant(`能改` / `只能看 · 剩 N 天` / `撤销`,owner 那行
// 过滤掉不画)、没有删除图标(那颗撤掉了,「删除这个成员」是唯一入口)、从没开通
// 云端备份时用既有的那句解释顶替「加一个人」、不是 owner 时连「谁能看」「加一个人」
// 都不显示(服务端 `GET .../grants` 是 owner-only,问了也是 403)、撤销/改名/删除
// 各自的效果。「按手机号加成员」原来在 `account_screen.dart` 的覆盖(404/409/429/400
// 错误映射)一并搬过来——那条路已经不在那一屏了。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/member_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 API——只认这一页会打的几条路:`GET .../grants`(谁能看)、
/// `POST /v1/accounts/lookup` + `POST .../grants`(按手机号加)、
/// `POST .../invites`(扫码邀请医生)、`DELETE .../grants/{id}`(撤销)。
class _FakeApi extends ApiClient {
  _FakeApi({
    this.grantsResponse = const [],
    this.lookupResult,
    this.lookupError,
  }) : super(base: 'http://x');

  final List<Map<String, dynamic>> grantsResponse;
  final Map<String, dynamic>? lookupResult;
  final Object? lookupError;
  final calls = <String>[];

  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) async {
    calls.add('GET $path');
    if (path.endsWith('/grants')) return grantsResponse;
    return const [];
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async {
    calls.add('POST $path');
    if (path == '/v1/accounts/lookup') {
      if (lookupError != null) throw lookupError!;
      return lookupResult ?? {'account_id': 'acc_x', 'public_key': 'QQ=='};
    }
    if (path.endsWith('/invites')) return {'invite_id': 'inv_1'};
    return {};
  }

  @override
  Future<void> delete(String path, {Object? body, Map<String, String>? headers}) async {
    calls.add('DELETE $path');
  }
}

class _FakeGrantsRust implements GrantsRust {
  @override
  Future<Uint8List> wrapWithToken(Uint8List plaintext, String token) async => plaintext;
  @override
  Future<Uint8List> unwrapWithToken(Uint8List blob, String token) async => blob;
  @override
  Future<Uint8List> sealTo(Uint8List public, Uint8List plaintext) async => plaintext;
}

Grants _grants(_FakeApi api) => Grants(api, AccountSession.instance, rust: _FakeGrantsRust());

const _owner = Profile(id: 'p-1', name: '张建国', cloudId: 'prf_1', role: 'owner');

/// 没上云的成员——`_canManageGrants` 为 false,`initState` 不发任何请求、不画
/// 「谁能看」那颗常驻转圈的 `CircularProgressIndicator`。改名字/删除这两组用
/// 它:那颗转圈只要还没 resolve 就是"还在动画",`pumpAndSettle` 永远等不到
/// 结束(真机上等的是真实网络请求,这里等的是真实 `ApiClient` 打向一个测试环境
/// 里根本没有的服务器,同样会卡住)——不是这两组测试要钉的东西,用不着这份负担。
const _local = Profile(id: 'p-1', name: '张建国');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('medme-member-detail-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    // `AccountSession.putProfileKey`/`profileKey` 落的是真实 secure storage 插件
    // 的 MethodChannel——没有这个假 platform 就没人接那次调用,`await` 挂着不返回
    // (同 `account_screen_test.dart` 文件级 `setUp` 那一条,当时就是为这件事加的)。
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    AccountSession.instance.resetForTest();
    await ProfileManager.instance.ensureLoaded();
    await ProfileManager.instance.factoryReset();
  });

  tearDown(() async => support.delete(recursive: true));

  group('daysLeftLabel(纯函数):剩 N 天,按日期算不看时分', () {
    test('还有 9 天', () {
      expect(daysLeftLabel('2026-09-29T23:00:00', now: DateTime(2026, 9, 20, 8)), '剩 9 天');
    });
    test('就是今天:剩 0 天', () {
      expect(daysLeftLabel('2026-09-20T23:00:00', now: DateTime(2026, 9, 20, 8)), '剩 0 天');
    });
    test('已经过期:不给负数,钉在 0', () {
      expect(daysLeftLabel('2026-09-10T00:00:00', now: DateTime(2026, 9, 20)), '剩 0 天');
    });
    test('没有到期日:null', () {
      expect(daysLeftLabel(null), isNull);
    });
    test('解析不了:null,不编一个日期', () {
      expect(daysLeftLabel('不是日期'), isNull);
    });
  });

  group('谁能看这份病历', () {
    testWidgets('editor 说「能改」、viewer 说「只能看 · 剩 N 天」,各带一颗撤销;没有删除图标', (t) async {
      final api = _FakeApi(
        grantsResponse: [
          {'grant_id': 'g-owner', 'role': 'owner'},
          {'grant_id': 'g-editor', 'role': 'editor'},
          {
            'grant_id': 'g-viewer',
            'role': 'viewer',
            'expires_at': DateTime.now().add(const Duration(days: 9)).toIso8601String(),
          },
        ],
      );
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: _owner, grants: _grants(api))));
      await t.pumpAndSettle();

      expect(find.text('谁能看张建国的病历'), findsOneWidget);
      expect(find.text('能改'), findsOneWidget);
      expect(find.textContaining('只能看 · 剩'), findsOneWidget);
      expect(find.text('撤销'), findsNWidgets(2));
      // owner 那一行(服务端会原样带回来)不画——那就是这台设备的主人自己。
      expect(find.textContaining('主人'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('还没有人被邀请:空态文案,不是一片空白', (t) async {
      final api = _FakeApi(grantsResponse: [{'grant_id': 'g-owner', 'role': 'owner'}]);
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: _owner, grants: _grants(api))));
      await t.pumpAndSettle();

      expect(find.text('还没有人被邀请'), findsOneWidget);
    });

    testWidgets('点撤销:先问一句(说清楚对方会立刻看不到),确认后才调 DELETE、重新拉一次列表', (t) async {
      final api = _FakeApi(
        grantsResponse: [
          {'grant_id': 'g-owner', 'role': 'owner'},
          {'grant_id': 'g-editor', 'role': 'editor'},
        ],
      );
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: _owner, grants: _grants(api))));
      await t.pumpAndSettle();

      await t.tap(find.text('撤销'));
      await t.pumpAndSettle();

      // 弹窗挡在前面,还没真的撤销——此刻只有 `initState` 那一次 GET。
      expect(find.text('撤销这份授权?'), findsOneWidget);
      expect(find.textContaining('对方立刻看不到「张建国」的病历'), findsOneWidget);
      expect(api.calls, ['GET /v1/profiles/prf_1/grants']);

      await t.tap(find.text('撤销').last);
      await t.pumpAndSettle();

      expect(api.calls, contains('DELETE /v1/profiles/prf_1/grants/g-editor'));
      expect(api.calls.where((c) => c.startsWith('GET')).length, 2, reason: '初次加载一次,撤销后重新拉一次');
    });

    testWidgets('撤销弹窗点取消:不调 DELETE,列表也不重新拉', (t) async {
      final api = _FakeApi(
        grantsResponse: [
          {'grant_id': 'g-owner', 'role': 'owner'},
          {'grant_id': 'g-editor', 'role': 'editor'},
        ],
      );
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: _owner, grants: _grants(api))));
      await t.pumpAndSettle();

      await t.tap(find.text('撤销'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(api.calls, ['GET /v1/profiles/prf_1/grants'], reason: '取消不调 DELETE、不重新拉');
    });

    testWidgets('这个成员从没开通云端备份:不查、也不画这一节', (t) async {
      const local = Profile(id: 'p-2', name: '王淑芬');
      final api = _FakeApi();
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: local, grants: _grants(api))));
      await t.pumpAndSettle();

      expect(find.textContaining('谁能看'), findsNothing);
      expect(api.calls, isEmpty, reason: '没有 cloudId,压根不该发请求');
    });

    testWidgets('这台设备不是 owner(editor/viewer):不查、也不画这一节——问了也是 403', (t) async {
      const shared = Profile(id: 'p-3', name: '老爸', cloudId: 'prf_3', role: 'editor');
      final api = _FakeApi();
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: shared, grants: _grants(api))));
      await t.pumpAndSettle();

      expect(find.textContaining('谁能看'), findsNothing);
      expect(api.calls, isEmpty);
    });
  });

  group('加一个人', () {
    testWidgets('从没开通云端备份:顶替成既有的那句解释,不是一颗会 403 的按钮', (t) async {
      const local = Profile(id: 'p-2', name: '王淑芬');
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: local, grants: _grants(_FakeApi()))));
      await t.pumpAndSettle();

      expect(find.text('这个成员还没开通云端备份,暂时加不了人'), findsOneWidget);
      expect(find.text('加一个人'), findsNothing);
    });

    testWidgets('不是 owner:整行不画(同「谁能看」的理由,没有资格邀请别人)', (t) async {
      const shared = Profile(id: 'p-3', name: '老爸', cloudId: 'prf_3', role: 'editor');
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: shared, grants: _grants(_FakeApi()))));
      await t.pumpAndSettle();

      expect(find.text('加一个人'), findsNothing);
      expect(find.textContaining('暂时加不了人'), findsNothing);
    });

    testWidgets('按手机号加:选「按手机号加」→ 查到账号 → 成功、弹一句「已加上」', (t) async {
      final api = _FakeApi(lookupResult: {'account_id': 'acc_x', 'public_key': 'QQ=='});
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: _owner, grants: _grants(api))));
      await t.pumpAndSettle();

      await t.tap(find.text('加一个人'));
      await t.pumpAndSettle();
      await t.tap(find.text('按手机号加'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('add_by_phone')), '138 0000 1111');
      await t.tap(find.text('加'));
      await t.pumpAndSettle();

      expect(api.calls, contains('POST /v1/accounts/lookup'));
      expect(api.calls, contains('POST /v1/profiles/prf_1/grants'));
      expect(find.text('已加上'), findsOneWidget);
    });

    testWidgets('按手机号加:对方还没设账号口令(409 no_keys)——说清楚该他做什么', (t) async {
      final api = _FakeApi(lookupError: const ApiFailed(409, 'no_keys'));
      await AccountSession.instance.putProfileKey('prf_1', Uint8List(32));
      await t.pumpWidget(MaterialApp(home: MemberDetailScreen(member: _owner, grants: _grants(api))));
      await t.pumpAndSettle();

      await t.tap(find.text('加一个人'));
      await t.pumpAndSettle();
      await t.tap(find.text('按手机号加'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('add_by_phone')), '13800001111');
      await t.tap(find.text('加'));
      await t.pumpAndSettle();

      expect(
        find.text('对方已注册,但还没设置好账号口令 —— 请他在 MedMe 里打开 我 → 口令与恢复码,完成最后两步'),
        findsOneWidget,
      );
    });
  });

  group('改名字 / 删除这个成员', () {
    // 不用真实的 `ProfileManager.rename`——那条真实文件 IO 有自己的测试
    // (`test/profile_manager_remove_test.dart` 也顺带测了 `rename`)。这里只钉
    // `MemberDetailScreen` 自己的编排:调 `renameProfile`(带对的 id/新名字)、
    // 标题跟着换、通知调用方。注入纯内存假实现,零真实 IO。
    testWidgets('改名字:调 renameProfile(带对的 id/新名字),标题跟着换,通知调用方刷新', (t) async {
      var changed = 0;
      final renameCalls = <(String, String)>[];
      await t.pumpWidget(MaterialApp(
        home: MemberDetailScreen(
          member: _local,
          onChanged: () => changed++,
          renameProfile: (id, name) async {
            renameCalls.add((id, name));
          },
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('改名字'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '张建国(改)');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();

      expect(renameCalls, [('p-1', '张建国(改)')]);
      expect(find.text('张建国(改)'), findsOneWidget, reason: 'AppBar 标题跟着换');
      expect(changed, 1);
    });

    testWidgets('改名字:取消不调 renameProfile,标题不变', (t) async {
      final renameCalls = <(String, String)>[];
      await t.pumpWidget(MaterialApp(
        home: MemberDetailScreen(
          member: _local,
          renameProfile: (id, name) async => renameCalls.add((id, name)),
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('改名字'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '不算数');
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();

      expect(renameCalls, isEmpty);
      expect(find.text('张建国'), findsOneWidget);
    });

    // 不用真实的 `ProfileManager.remove`——那条真实文件 IO 已经有自己的测试
    // (`test/profile_manager_remove_test.dart`)。这里只钉 `MemberDetailScreen`/
    // `confirmRemoveMember` 自己的编排:取消不动手、确认才调 `removeProfile`(带
    // 对的 id)、成功才通知 + 退回上一页、失败就留在原地说清楚。注入一个纯内存的
    // 假实现,零真实 IO,不依赖任何时序。
    testWidgets('删除这个成员:取消不删;确认后调 removeProfile(带对的 id)、通知、退回上一页', (t) async {
      var changed = 0;
      final removeCalls = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(
            builder: (_) => MemberDetailScreen(
              member: _local,
              onChanged: () => changed++,
              removeProfile: (id) async {
                removeCalls.add(id);
                return true;
              },
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('删除这个成员'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(find.byType(MemberDetailScreen), findsOneWidget, reason: '取消:还在这一页');
      expect(removeCalls, isEmpty);
      expect(changed, 0);

      await t.tap(find.text('删除这个成员'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认删除'));
      await t.pumpAndSettle();

      expect(removeCalls, ['p-1']);
      expect(changed, 1);
      expect(find.byType(MemberDetailScreen), findsNothing, reason: '删完退回上一页');
    });

    // 上一条用的是只有一层的裸 `Navigator`——删完弹层退到底就没有下一层可落地,
    // 顾不上验证 SnackBar(那种情况下 `ScaffoldMessenger` 找不到还活着的
    // `Scaffold` 可以挂,消息直接丢了,不是这句话没发,而是这个裸壳测试环境本身
    // 撑不住这个场景)。真实 App 里 `MemberDetailScreen` 永远是 `push` 到「我」tab
    // 之上的,退回去落在的是那一屏的 `Scaffold`——这里补一层「落地页」照实还原:
    // 退回上一页要能看到「已移除」这句话。
    testWidgets('删除这个成员成功:退回的上一页上能看到「已移除「名字」」', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MemberDetailScreen(
                        member: _local,
                        removeProfile: (id) async => true,
                      ),
                    ),
                  ),
                  child: const Text('打开成员详情'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('打开成员详情'));
      await t.pumpAndSettle();

      await t.tap(find.text('删除这个成员'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认删除'));
      await t.pumpAndSettle();

      expect(find.byType(MemberDetailScreen), findsNothing, reason: '删完退回上一页');
      expect(find.text('已移除「张建国」'), findsOneWidget);
    });

    testWidgets('删除失败(removeProfile 返回 false):留在这一页,说清楚', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(
            builder: (_) => MemberDetailScreen(
              member: _local,
              removeProfile: (id) async => false,
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('删除这个成员'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认删除'));
      await t.pumpAndSettle();

      expect(find.text('无法移除该成员'), findsOneWidget);
      expect(find.byType(MemberDetailScreen), findsOneWidget, reason: '失败不退出');
    });
  });
}
