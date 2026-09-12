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
      } else if (req.uri.path == '/v1/nocontent') {
        req.response.statusCode = 204; // 注销账号那条路由就是 204 空体
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

  test('postNoContent():204 空响应体不炸(注销账号走这条,I5)', () async {
    await api.postNoContent('/v1/nocontent', {'phone': '13800000001', 'otp_code': '000000'});
    // 对照:postJson 会把空体强转成 Map 而炸掉——这就是为什么要有上面那个方法。
    await expectLater(api.postJson('/v1/nocontent', const {}), throwsA(isA<TypeError>()));
  });

  test('ApiUnauthorized 的文案是给人看的中文,不是类名', () {
    expect(const ApiUnauthorized().toString(), '登录状态已过期,请重新登录');
  });

  // ---- B1:网络层异常不许裸着给用户看 ----
  //
  // 在这之前,断网时账号屏/兑换屏/同步那九处 `'$e'` 显示的是
  // `SocketException: Connection refused (OS Error: ...), address = 127.0.0.1`。
  group('B1:网络失败翻成中文(ApiNetworkError),翻译只在 ApiClient 一处', () {
    test('连不上(服务器已关闭 = 断网):抛 ApiNetworkError,文案是中文', () async {
      // 真的断一次网:把回环服务器关掉,端口上就没人再 listen 了。
      final port = server.port;
      await server.close(force: true);
      final dead = ApiClient(base: 'http://127.0.0.1:$port');

      await expectLater(
        dead.getJson('/v1/echo'),
        throwsA(
          isA<ApiNetworkError>().having((e) => '$e', 'toString', '网络连不上,换个网络再试一次。'),
        ),
      );
      // 重开一个,让 tearDown 的 close 有东西可关。
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    });

    // 读超时那一支(`on TimeoutException → slow`)不真跑一遍:`Net.idle` 是写死的
    // 30 秒常量,注不进去,真等一次就是一个 30 秒的测试。上面那条已经证明 `_net`
    // 确实包住了请求,这里只钉住另一句文案本身。
    test('「网络太慢」那一句的文案', () {
      expect(ApiNetworkError.slow.toString(), '网络太慢,没能连上服务器。换个网络再试一次。');
    });

    test('HttpException(切网时"header 还没收完连接就断了")也翻成中文', () async {
      // 真的造一次:服务器收到请求直接把 socket 掐掉,不回任何响应头。
      final rude = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      rude.listen((req) => req.response.detachSocket().then((s) => s.destroy()));
      final client = ApiClient(base: 'http://127.0.0.1:${rude.port}');

      await expectLater(
        client.getJson('/v1/whatever'),
        throwsA(isA<ApiNetworkError>().having((e) => '$e', 'toString', '网络连不上,换个网络再试一次。')),
      );
      await rude.close(force: true);
    });
  });

  // ---- B2:状态码不许念给用户听 ----
  group('B2:friendlyApiError —— 一个失败一句中文', () {
    test('429 / 410 / 403 / 404 / 400 / 5xx 各有一句人话,不出现状态码数字', () {
      expect(friendlyApiError(const ApiFailed(429, 'rate_limited')), '操作太频繁,过一会儿再试');
      expect(friendlyApiError(const ApiFailed(410, 'invite expired')), contains('邀请码已经过期或被用过'));
      expect(friendlyApiError(const ApiFailed(403, 'forbidden')), contains('没有权限'));
      expect(friendlyApiError(const ApiFailed(404, 'not found')), contains('没有找到'));
      expect(friendlyApiError(const ApiFailed(400, 'bad request')), contains('填错'));
      expect(friendlyApiError(const ApiFailed(500, 'boom')), '服务器开小差了,稍后再试');
      expect(friendlyApiError(const ApiFailed(503, 'unavailable')), '服务器开小差了,稍后再试');
      for (final s in [429, 410, 403, 404, 400, 500, 503]) {
        expect(friendlyApiError(ApiFailed(s, 'x')), isNot(contains('$s')));
      }
    });

    test('验证码打错/过期(登录那条路上的 401):说「重新发送」,不说「重新登录」', () {
      expect(friendlyApiError(const ApiUnauthorized('bad code')), '验证码不对或已过期,请重新发送');
      expect(friendlyApiError(const ApiUnauthorized('expired')), '登录状态已过期,请重新登录');
    });

    test('网络失败原样透传它自己那句中文', () {
      expect(friendlyApiError(ApiNetworkError.offline), '网络连不上,换个网络再试一次。');
    });

    test('StateError:只给 message,不带 `Bad state:` 前缀(精确匹配,别让前缀溜过去)', () {
      // 全仓 12 处 `throw StateError('中文…')` 都会走到这些错误展示位。
      expect(friendlyApiError(StateError('这个成员还没开通云同步')), '这个成员还没开通云同步');
      expect(friendlyApiError(StateError('x')), isNot(contains('Bad state')));
    });

    test('不认识的异常不吞:原样展示,不变成「未知错误」', () {
      expect(friendlyApiError(const FormatException('坏数据')), contains('坏数据'));
    });

    test('自己转给自己:说真话,不说「请求里有填错的地方」', () {
      expect(
        friendlyApiError(const ApiFailed(400, 'cannot redeem own invite')),
        '这条链接是你自己生成的,不能自己接受',
      );
    });
  });

  test('B1:401 带上服务端 detail(验证码错 vs 登录过期要分开)', () async {
    await expectLater(
      api.getJson('/v1/nope'),
      throwsA(isA<ApiUnauthorized>().having((e) => e.detail, 'detail', 'expired')),
    );
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
