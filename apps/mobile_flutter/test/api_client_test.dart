import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 这个文件既要**真的**发 HTTP(回环服务器),又要用 SharedPreferences/
  // secure storage 的 mock(`AccountSession`)。后者需要测试 binding,而
  // `TestWidgetsFlutterBinding` 会顺手装一个 `HttpOverrides.global`(给 Image
  // 用的假 HttpClient,对任何请求都回 400 空体)——装上之后回环服务器再也收不到
  // 请求。所以初始化完立刻把它摘掉。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late HttpServer server;
  late ApiClient api;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = ApiClient(base: 'http://127.0.0.1:${server.port}', bearer: () async => 'tok');
    server.listen((req) async {
      final auth = req.headers.value('authorization');
      if (req.uri.path == '/v1/echo') {
        final body = await utf8.decodeStream(req);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'auth': auth,
          'got': jsonDecode(body),
          'deviceId': req.headers.value('x-device-id'),
        }));
      } else if (req.uri.path == '/v1/events') {
        // 模拟 `GET /v1/profiles/{pid}/events`:响应头带 X-Seq-Map(SyncEngine
        // 拿它当推送水位,见 sync_engine.dart)。
        req.response.headers.set('X-Seq-Map', jsonEncode({'d1': 3}));
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode([
          {'device_id': 'd1', 'seq': 1},
        ]));
      } else if (req.uri.path == '/v1/nope') {
        req.response.statusCode = 401;
        req.response.write('{"detail":"expired"}');
      } else {
        req.response.statusCode = 500;
        req.response.write('{"detail":"boom"}');
      }
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('带 Bearer、发 JSON、解 JSON', () async {
    final r = await api.postJson('/v1/echo', {'a': 1});
    expect(r['auth'], 'Bearer tok');
    expect(r['got'], {'a': 1});
  });

  test('401 抛 ApiUnauthorized,其它抛 ApiFailed 带 detail', () async {
    expect(() => api.getJson('/v1/nope'), throwsA(isA<ApiUnauthorized>()));
    expect(() => api.getJson('/v1/other'), throwsA(predicate((e) => e is ApiFailed && e.status == 500 && e.message == 'boom')));
  });

  test('传入的 headers(如 X-Device-Id)会带到请求里', () async {
    final r = await api.postJson('/v1/echo', {'a': 1}, headers: {'X-Device-Id': 'd1'});
    expect(r['deviceId'], 'd1');
    // bearer 仍然在,headers 是加的不是替换的。
    expect(r['auth'], 'Bearer tok');
  });

  test('delete():带 body 的 DELETE(注销账号 DELETE /v1/account 用得到)', () async {
    // `/v1/echo` 不挑方法,只回显收到的 body——够验证 `delete()` 真的把 body
    // 编码进请求体发出去了(Task 15 之前 `delete()` 不带 body 参数)。
    await api.delete('/v1/echo', body: {'phone': '13800000001', 'otp_code': '000000'});
  });

  test('getJsonWithHeaders:同时拿到解出来的 body 和响应头(小写 key)', () async {
    final (body, headers) = await api.getJsonWithHeaders('/v1/events');
    expect(body, [
      {'device_id': 'd1', 'seq': 1},
    ]);
    expect(headers['x-seq-map'], jsonEncode({'d1': 3}), reason: '响应头 key 统一转小写,大小写不敏感');
  });

  test('ApiUnauthorized 的文案是给人看的中文,不是类名', () {
    expect(const ApiUnauthorized().toString(), '登录状态已过期,请重新登录');
  });

  // ---- C2:access token 只活 1 小时,401 要自动刷新一次再重试 ----
  //
  // 之前 `/v1/auth/refresh` 在客户端**没有任何调用方**:App 在前台连续用满一小时
  // (或者放一晚上回来),每一次同步/每一个账号接口都开始 401,用户看到的是"同步
  // 一直失败",而手里的 refresh token 还好好地躺在本机、30 天才过期。
  group('C2: 401 → 刷新一次 → 重试', () {
    late HttpServer authServer;
    late ApiClient client;
    final guardedHits = <String?>[];
    final refreshBodies = <String>[];
    var always401Hits = 0;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
      AccountSession.instance.resetForTest();
      guardedHits.clear();
      refreshBodies.clear();
      always401Hits = 0;

      authServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      authServer.listen((req) async {
        final auth = req.headers.value('authorization');
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == '/v1/guarded') {
          guardedHits.add(auth);
          // 只认刷新之后的那个 access token——拿旧的来一律 401。
          if (auth != 'Bearer new-access') {
            req.response.statusCode = 401;
            req.response.write('{"detail":"expired"}');
          } else {
            req.response.write('{"ok":true}');
          }
        } else if (req.uri.path == '/v1/always401') {
          always401Hits++;
          req.response.statusCode = 401;
          req.response.write('{"detail":"revoked"}');
        } else if (req.uri.path == '/v1/auth/refresh') {
          final raw = await utf8.decodeStream(req);
          refreshBodies.add(raw);
          final given = (jsonDecode(raw) as Map)['refresh'];
          if (given == 'good-refresh') {
            req.response.write('{"access":"new-access","refresh":"rotated-refresh"}');
          } else {
            req.response.statusCode = 401;
            req.response.write('{"detail":"refresh expired"}');
          }
        } else {
          req.response.statusCode = 404;
          req.response.write('{"detail":"nope"}');
        }
        await req.response.close();
      });
      client = ApiClient.forSession(AccountSession.instance, base: 'http://127.0.0.1:${authServer.port}');
    });

    tearDown(() => authServer.close(force: true));

    test('401 → 用 refresh token 换新 token、持久化、原请求重试成功', () async {
      await AccountSession.instance.save(accountId: 'acc_1', access: 'stale-access', refresh: 'good-refresh');

      final r = await client.getJson('/v1/guarded');

      expect(r, {'ok': true});
      expect(guardedHits, ['Bearer stale-access', 'Bearer new-access'], reason: '只重试一次,且带的是新 token');
      expect(refreshBodies.length, 1);
      expect(jsonDecode(refreshBodies.single), {'refresh': 'good-refresh'});
      // 新 token 必须落盘,否则下一个请求又要 401 一次。
      expect(AccountSession.instance.access, 'new-access');
      expect(AccountSession.instance.refresh, 'rotated-refresh');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('acct_access'), 'new-access');
      expect(AccountSession.instance.loggedIn.value, isTrue);
    });

    test('刷新本身 401(refresh 也过期了):清掉账号态并抛 ApiUnauthorized', () async {
      await AccountSession.instance.save(accountId: 'acc_1', access: 'stale-access', refresh: 'dead-refresh');

      await expectLater(client.getJson('/v1/guarded'), throwsA(isA<ApiUnauthorized>()));

      expect(AccountSession.instance.accountId, isNull);
      expect(AccountSession.instance.access, isNull);
      expect(AccountSession.instance.loggedIn.value, isFalse, reason: 'UI 据此回到登录入口');
      expect(guardedHits.length, 1, reason: '刷新都失败了,不该再重试原请求');
    });

    test('没有 session(未登录的 ApiClient):401 原样抛出,不发刷新请求', () async {
      final anon = ApiClient(base: 'http://127.0.0.1:${authServer.port}', bearer: () async => 'whatever');
      await expectLater(anon.getJson('/v1/guarded'), throwsA(isA<ApiUnauthorized>()));
      expect(refreshBodies, isEmpty);
    });

    test('刷新成功、但重试又 401:只重试一次就放手,不无限循环', () async {
      // `/v1/always401` 不管带什么 token 都 401(真实世界里对应"这个账号在服务端
      // 被吊销了")。刷新本身是成功的,所以不能清账号态,但也绝不能一直重试。
      await AccountSession.instance.save(accountId: 'acc_1', access: 'stale-access', refresh: 'good-refresh');

      await expectLater(client.getJson('/v1/always401'), throwsA(isA<ApiUnauthorized>()));

      expect(refreshBodies.length, 1, reason: '刷新只做一次');
      expect(always401Hits, 2, reason: '原请求 + 刷新后的一次重试,就这两次');
      expect(AccountSession.instance.loggedIn.value, isTrue, reason: '刷新没失败,不该把用户踢下线');
    });
  });
}
