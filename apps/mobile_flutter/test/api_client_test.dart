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
}
