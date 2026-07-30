import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/net.dart';

/// 这些测试针对的是**黑洞连接**:握手成功了,但对面此后一个字节都不发。
///
/// 手机上这不是理论情况(Wi-Fi 切 4G、进地库、中间设备静默丢包),而 `dart:io` 的
/// `HttpClient` 对此毫无防御 —— 它只有握手超时。修之前的表现是「永远转圈」:不报错、
/// 不超时、埋点里也看不见。所以下面每一条都用**真的假死服务器**验,不用 mock。
void main() {
  const short = Duration(milliseconds: 300);

  /// 起一个本地服务器,每个请求交给 [handle] 处理。
  Future<(HttpServer, Uri)> serve(
    void Function(HttpRequest) handle,
  ) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(handle);
    return (s, Uri.parse('http://127.0.0.1:${s.port}/'));
  }

  test('对面收下请求却不给响应 → 超时,不是永远等', () async {
    // 拿住请求什么都不做 —— 修之前这里会一直挂着。
    final (s, uri) = await serve((_) {});
    addTearDown(() => s.close(force: true));

    await expectLater(
      Net.run((c) async => Net.send(await c.getUrl(uri), timeout: short)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('响应头发了、body 发一半就不动了 → 超时', () async {
    final (s, uri) = await serve((req) {
      req.response.add([1, 2, 3]);
      req.response.flush(); // 之后既不写也不关
    });
    addTearDown(() => s.close(force: true));

    await expectLater(
      Net.run((c) async {
        final res = await Net.send(await c.getUrl(uri), timeout: short);
        return Net.bytes(res, timeout: short);
      }),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('慢但一直在吐数据 → 不该被杀(这就是空闲超时与总时长超时的区别)', () async {
    // 每 100ms 吐一块,总共 1 秒 —— 远超 300ms 的阈值,但从没**空闲**够 300ms。
    // 若图省事用「总时长 300ms」,这条就会误杀;而代拍的包有好几 MB,病人的网又是
    // 最差的那一档,误杀等于功能不可用。
    //
    // ⚠️ 块必须够大(64KB > MSS)。写一字节一块的话 Nagle 会把它们攒到最后一起发,
    // 客户端在 close 之前一个事件都收不到 —— 那时测的是 Nagle,不是我们的超时。
    const chunk = 64 * 1024;
    final (s, uri) = await serve((req) async {
      for (var i = 0; i < 10; i++) {
        req.response.add(Uint8List(chunk));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await req.response.close();
    });
    addTearDown(() => s.close(force: true));

    final got = await Net.run((c) async {
      final res = await Net.send(await c.getUrl(uri), timeout: short);
      return Net.bytes(res, timeout: short);
    });
    expect(got.length, chunk * 10);
  });

  test('retry:连接层抖动 → 重试,第二次成功', () async {
    var calls = 0;
    final got = await Net.retry(() async {
      if (++calls == 1) throw const SocketException('换基站了');
      return 'ok';
    });
    expect(got, 'ok');
    expect(calls, 2);
  });

  test('retry:读超时**不**重试 —— 已经干等过一轮,再等两轮就是 90 秒转圈', () async {
    var calls = 0;
    await expectLater(
      Net.retry(() async {
        calls++;
        throw TimeoutException('黑洞');
      }),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 1);
  });

  test('retry:不该重试的错误立刻抛(「已经没了」不是抖动)', () async {
    var calls = 0;
    await expectLater(
      Net.retry(() async {
        calls++;
        throw const FormatException('坏了');
      }),
      throwsA(isA<FormatException>()),
    );
    expect(calls, 1);
  });
}
