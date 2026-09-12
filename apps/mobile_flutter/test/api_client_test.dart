import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/api_client.dart';

void main() {
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
}
