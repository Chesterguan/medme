import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 全 App 唯一的 HTTP 出口。存在的理由只有一个:**`dart:io` 的 `HttpClient` 没有读超时。**
///
/// 它只有 `connectionTimeout`(管 TCP 握手)和 `idleTimeout`(管连接池复用)。握手成功
/// 之后,等响应头、收响应体、写请求体这三处**全是无限等**。手机上这不是理论情况:
/// Wi-Fi 切 4G、进电梯地库、运营商中间设备静默丢包 —— 连接变成黑洞,不发 RST。
/// 传输层也指望不上:我们是接收方,没有待重传的包,TCP 没有东西可以超时;就算有,内核
/// 放弃前是 ~15 分钟,而 `SO_KEEPALIVE` 默认关、开了也是空闲 2 小时才探测。
///
/// 结果就是「永远转圈」:不报错、不超时、埋点里也看不见,用户只能杀掉重来。
///
/// 成熟栈都把读超时做成一等参数(OkHttp `readTimeout` 默认 10s、Go
/// `ResponseHeaderTimeout`、curl `--speed-time`)。这里补的就是同一件事。
///
/// **用的是空闲超时,不是总时长超时**:[bytes] 每收到一块就重新计时,只在**一整个
/// [idle] 内一个字节都没来**时才炸。总时长超时得先猜包多大,猜错就是慢网上的好人被
/// 误杀 —— 代拍的包可以有几 MB,而病人的网正是最差的那一档。
class Net {
  /// TCP 握手。
  static const connect = Duration(seconds: 20);

  /// 空闲超时(等响应头 / 两块数据之间 / 写不动)。OkHttp `readTimeout` 同义。
  static const idle = Duration(seconds: 30);

  /// 开一个客户端跑 [body],结束时**强制**关闭。
  ///
  /// `close()`(不带 force)会等连接空闲下来再关 —— 而挂死的连接永远不空闲,那样超时
  /// 了也白超时,socket 还攥在手里。所以这里一律 force。
  static Future<T> run<T>(Future<T> Function(HttpClient) body) async {
    final client = HttpClient()..connectionTimeout = connect;
    try {
      return await body(client);
    } finally {
      client.close(force: true);
    }
  }

  /// 发出请求并等响应头。超时抛 [TimeoutException],由调用方翻成人话。
  static Future<HttpClientResponse> send(
    HttpClientRequest req, {
    Duration timeout = idle,
  }) => req.close().timeout(timeout);

  /// 把请求体推出去。写也会卡住(对端不读 → TCP 窗口满 → `flush` 永远不返回)。
  static Future<void> flush(HttpClientRequest req, {Duration timeout = idle}) =>
      req.flush().timeout(timeout);

  /// 收完响应体。**每块数据重置计时**,见类文档。
  static Future<Uint8List> bytes(
    HttpClientResponse res, {
    Duration timeout = idle,
  }) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(timeout)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  static Future<String> text(
    HttpClientResponse res, {
    Duration timeout = idle,
  }) async => utf8.decode(await bytes(res, timeout: timeout));

  /// 读完丢掉(错误响应体、PUT 的空响应)—— 不读干净会让连接没法复用。
  static Future<void> drain(
    HttpClientResponse res, {
    Duration timeout = idle,
  }) async => bytes(res, timeout: timeout);

  /// 有限次退避重试。**只用于幂等请求**(GET / HEAD)—— 非幂等的重试可能造成重复副作用。
  ///
  /// **默认只重试连接层失败([SocketException]),不重试读超时。** 连接失败是立刻返回的
  /// (换基站、刚出电梯那一下),重试几乎不花时间、又真能救回来;而读超时意味着**已经
  /// 干等了 [idle] 秒**,再来两轮就是 90 多秒的转圈 —— 用户早走了,救不回任何人。
  /// OkHttp 的 `retryOnConnectionFailure` 也是这么划的线。
  static Future<T> retry<T>(
    Future<T> Function() body, {
    int attempts = 3,
    bool Function(Object)? retryIf,
  }) async {
    for (var i = 1; ; i++) {
      try {
        return await body();
      } catch (e) {
        final worth = retryIf?.call(e) ?? e is SocketException;
        if (i >= attempts || !worth) rethrow;
        await Future<void>.delayed(Duration(seconds: i));
      }
    }
  }
}
