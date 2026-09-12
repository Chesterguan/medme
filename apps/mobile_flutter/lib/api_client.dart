import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/net.dart';

/// 服务端说这个请求没有有效的登录凭证。[ApiClient] 已经自动拿 refresh token 试过
/// 一次(见 [ApiClient._refreshTokens]),抛到这里说明连 refresh 都不管用了——
/// UI 唯一该做的事是让用户重新登录,所以 `toString` 直接就是给人看的那句话。
///
/// **[detail] 是服务端那句 `detail`**,因为 401 不全是"登录过期":
/// `POST /v1/auth/login` 的验证码打错/过期也是 401(`services/api/auth.py` 的
/// `PhoneOtpProvider.login` → `bad code`),而那条路上「登录状态已过期,请重新
/// 登录」是一句纯粹的错话——用户压根还没登录上,他要做的是重新发一次验证码。
/// 所以翻译放在这里一处,不让每个调用点各猜一遍。
class ApiUnauthorized implements Exception {
  const ApiUnauthorized([this.detail = '']);
  final String detail;
  @override
  String toString() => detail == 'bad code' ? '验证码不对或已过期,请重新发送' : '登录状态已过期,请重新登录';
}

class ApiFailed implements Exception {
  const ApiFailed(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => '服务器返回 $status:$message';
}

/// 网络层失败(连不上 / 连上了不吐数据 / TLS 握手不成)。
///
/// **翻译只在 [ApiClient] 这一处**(见 `ApiClient._net`):在这之前,这九处
/// 调用点(账号屏、兑换屏、同步……)直接把 `SocketException: Failed host lookup`
/// 这种英文异常摆给用户看。代拍那条线早就有两句中文(`claim_link.dart` 的
/// `_fetch`),这里是同两句——只把「没能取回病历」换成「没能连上服务器」,
/// 因为账号/同步这条路上还谈不到病历。
class ApiNetworkError implements Exception {
  const ApiNetworkError(this.message);
  final String message;

  /// 连上了,但对面不吐数据(进电梯、基站切换时的黑洞连接,见 `net.dart`)。
  static const slow = ApiNetworkError('网络太慢,没能连上服务器。换个网络再试一次。');

  /// 压根没连上(DNS 解析不了、拒绝连接、飞行模式),以及 TLS 握手失败。
  static const offline = ApiNetworkError('网络连不上,换个网络再试一次。');

  @override
  String toString() => message;
}

/// 一个失败 → 一句用户看得懂、能照着做的中文。**全 App 一份。**
///
/// 在这之前:`ApiFailed.toString()` 把状态码念给用户听(「服务器返回 410:
/// invite expired」),而每个在意某个码的调用点各写一个自己的 switch
/// (`_addFamily` 曾是唯一一个)。状态码的含义是服务端定的、全 App 一致的,
/// 所以这层翻译也该只有一份。
///
/// 调用点仍然可以在这之上加**自己这条路独有**的解释(比如「按手机号加家属」
/// 的 404 能说得比"没找到"具体得多,见 `account_screen.dart` 的
/// `_familyLookupError`)——那是端点语义,不是状态码语义。
String friendlyApiError(Object e) => switch (e) {
  // 这两个的 `toString()` 本来就是给人看的那句话。
  ApiNetworkError() || ApiUnauthorized() => '$e',
  // 真实的 [ApiClient] 把 401 抛成 [ApiUnauthorized],这两条是给别处构造的
  // `ApiFailed(401)` 兜底(测试里的假 API、将来某个自己拼状态码的调用点)——
  // 不兜的话它会落到最下面那条,把「服务器返回 401:bad code」摆给用户。
  ApiFailed(status: 401, message: 'bad code') => '验证码不对或已过期,请重新发送',
  ApiFailed(status: 401) => '登录状态已过期,请重新登录',
  ApiFailed(status: 429) => '操作太频繁,过一会儿再试',
  ApiFailed(status: 410) => '这个邀请码已经过期或被用过了,请对方重新生成一个',
  ApiFailed(status: 403) => '没有权限做这件事——这份档案可能不是你的,或者授权已经被收回',
  ApiFailed(status: 404) => '没有找到——可能已经被删除或撤销了',
  ApiFailed(status: 400) => '请求里有填错的地方,检查一下再试',
  ApiFailed(status: >= 500) => '服务器开小差了,稍后再试',
  // 其余(自定义异常 `UnlockFailed`/`ProfileLocked`/`StateError` 等)本来就是
  // 中文的,原样展示——**不吞**:吞掉就是把一个没预料到的失败说成"未知错误"。
  _ => '$e',
};

/// 账号 API 的唯一出口。所有请求走 [Net](有读超时);token 由 [bearer] 回调提供,
/// 于是测试里注入假服务器 + 假 token 即可,不碰 secure storage。
class ApiClient {
  ApiClient({String? base, this.bearer, this.session}) : base = base ?? defaultBase;

  /// **生产代码里的标准构造方式**:token 取自 [AccountSession],401 时自动刷新
  /// 一次再重试(见 [_refreshTokens])。以前每个调用点各写一遍
  /// `ApiClient(bearer: () async => AccountSession.instance.access)`,八处一模一样
  /// 的闭包,于是"刷新"这件事没有一个能统一加上去的地方。
  ApiClient.forSession(AccountSession session, {String? base})
      : this(base: base, bearer: () async => session.access, session: session);

  static const defaultBase = String.fromEnvironment('MEDME_API_BASE', defaultValue: 'https://api.medmenow.com');
  final String base;
  final Future<String?> Function()? bearer;

  /// 有它才有自动刷新:刷新要读 [AccountSession.refresh]、写回新 token、必要时
  /// 清掉整个账号态。没有(匿名 client / 测试里的假 client)时 401 原样抛出。
  final AccountSession? session;

  /// 同一个 client 上多个请求同时撞 401 时,合并成一次刷新。
  Future<bool>? _refreshInFlight;

  /// 与 [_json] 同一套请求逻辑,多返回一份响应头(小写 key,同名多值用逗号拼接)。
  /// [_json] 委托给它、丢掉头;[getJsonWithHeaders] 是唯一需要头的调用方——
  /// `SyncEngine` 拉事件要读 `X-Seq-Map`(见 `services/api/app.py` 的
  /// `events_pull`:该 profile 每个 device 当前的最大 seq,推送水位就是它,
  /// 不能从 `since` 反推)。
  Future<(dynamic, Map<String, String>)> _jsonWithHeaders(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    try {
      return await _send(method, path, body: body, query: query, headers: headers);
    } on ApiUnauthorized {
      // access token 只活 1 小时(`services/api/auth.py` 的 `ACCESS_TTL`)。
      // 刷新不成功就把原来那个 401 原样抛出去——**只重试一次**,不循环。
      if (path == _refreshPath || !await _refreshTokens()) rethrow;
      return await _send(method, path, body: body, query: query, headers: headers);
    }
  }

  static const _refreshPath = '/v1/auth/refresh';

  /// 用本机存着的 refresh token(30 天)换一对新 token,成功就写回 [session] 并
  /// 返回 true,调用方据此重试一次原请求。
  ///
  /// * 没有 session / 没有 refresh token / 没有 accountId → false(原样 401)。
  /// * **刷新自己也 401** → refresh 也过期或被吊销了,重试没有任何意义:清掉本机
  ///   账号态([AccountSession.clear],连档案密钥一起),让 UI 回到登录入口。
  /// * 网络错误等其它失败 → false,这次请求照原样失败,下次再试(不清账号态:
  ///   断网不等于被登出)。
  Future<bool> _refreshTokens() =>
      _refreshInFlight ??= _refreshOnce().whenComplete(() => _refreshInFlight = null);

  Future<bool> _refreshOnce() async {
    final s = session;
    final token = s?.refresh;
    final accountId = s?.accountId;
    if (s == null || token == null || accountId == null) return false;
    try {
      final (data, _) = await _send('POST', _refreshPath, body: {'refresh': token});
      final m = data as Map<String, dynamic>;
      await s.save(accountId: accountId, access: m['access'] as String, refresh: m['refresh'] as String);
      return true;
    } on ApiUnauthorized {
      await s.clear();
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<(dynamic, Map<String, String>)> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    return _net(() => Net.run((client) async {
      final req = await client.openUrl(method, uri);
      final tok = await bearer?.call();
      if (tok != null) req.headers.set('authorization', 'Bearer $tok');
      // 额外 header(如后端要求的 X-Device-Id)在 bearer 之后加,不影响 Authorization。
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        await Net.flush(req);
      }
      final res = await Net.send(req);
      final text = await Net.text(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = text;
        try { msg = (jsonDecode(text) as Map)['detail']?.toString() ?? text; } catch (_) {}
        // 401 带上 detail——「验证码打错」和「登录过期」都是 401,只有这个字段
        // 能把它们分开(见 [ApiUnauthorized])。
        if (res.statusCode == 401) throw ApiUnauthorized(msg);
        throw ApiFailed(res.statusCode, msg);
      }
      final respHeaders = <String, String>{};
      res.headers.forEach((name, values) => respHeaders[name.toLowerCase()] = values.join(','));
      return (text.isEmpty ? null : jsonDecode(text), respHeaders);
    }));
  }

  /// `dart:io` 的网络异常 → [ApiNetworkError]。**整个 [ApiClient] 只在这一处翻译**,
  /// 三个出口([_send]、[putBytes]、[getBytes])都包它。
  ///
  /// 为什么不下沉到 `Net.run` 里(那样连代拍线都免费拿到):`Net.retry` 的默认
  /// `retryIf` 认的就是 `e is SocketException`,而 `claim_link.dart` 也在重试**外面**
  /// 自己接这两种异常——在 `Net` 里翻译会同时拆掉那两处,换来的只是少写三个包装。
  static Future<T> _net<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on TimeoutException {
      throw ApiNetworkError.slow;
    } on HandshakeException {
      // `HandshakeException implements IOException`,**不是** `SocketException`
      // 的子类,所以必须单列一条,否则它会漏到最外面变成裸异常。证书/时间/
      // 中间人都可能,但用户能做的事和"连不上"一样:换个网络再试。
      throw ApiNetworkError.offline;
    } on SocketException {
      throw ApiNetworkError.offline;
    }
  }

  Future<dynamic> _json(String method, String path, {Object? body, Map<String, String>? query, Map<String, String>? headers}) async {
    final (data, _) = await _jsonWithHeaders(method, path, body: body, query: query, headers: headers);
    return data;
  }

  Future<Map<String, dynamic>> postJson(String path, Object body, {Map<String, String>? headers}) async =>
      (await _json('POST', path, body: body, headers: headers)) as Map<String, dynamic>;
  Future<dynamic> getJson(String path, {Map<String, String>? query, Map<String, String>? headers}) =>
      _json('GET', path, query: query, headers: headers);
  /// 同 [getJson],额外把响应头一并返回(小写 key)。
  Future<(dynamic, Map<String, String>)> getJsonWithHeaders(String path, {Map<String, String>? query, Map<String, String>? headers}) =>
      _jsonWithHeaders('GET', path, query: query, headers: headers);
  Future<Map<String, dynamic>> putJson(String path, Object body, {Map<String, String>? headers}) async =>
      (await _json('PUT', path, body: body, headers: headers)) as Map<String, dynamic>;
  Future<void> delete(String path, {Object? body, Map<String, String>? headers}) =>
      _json('DELETE', path, body: body, headers: headers);

  /// POST 一个不关心响应体的请求(服务端回 204)。[postJson] 会把空响应体强转成
  /// `Map` 而炸掉,所以注销账号那条走这个。
  ///
  /// 为什么注销用 POST 而不是带 body 的 DELETE(最终评审 I5):一些网关/代理会把
  /// DELETE 的请求体丢掉,那边重新鉴权的凭证就永远"缺失" → 401,用户看到的是
  /// 「注销失败」且毫无头绪。服务端两条路由同一个 handler
  /// (`services/api/app.py` 的 `account_delete`),DELETE 仍然能用。
  Future<void> postNoContent(String path, Object body, {Map<String, String>? headers}) =>
      _json('POST', path, body: body, headers: headers);

  /// 直传 OSS 预签名地址(不带 Bearer)。Content-Type 必须与签名一致。
  ///
  /// **这两个不走 401 自动刷新**:它们打的是 OSS 的预签名 URL,压根不带账号
  /// token——这里的 401/403 意味着"签名过期/不对",换一个 access token 没有任何
  /// 帮助,要重新去 `/v1/profiles/{pid}/objects/sign` 签一次。签名请求自己走
  /// [_jsonWithHeaders],该刷新的地方已经刷新了。
  Future<void> putBytes(String url, Uint8List bytes) => _net(() => Net.run((client) async {
        final req = await client.putUrl(Uri.parse(url));
        req.headers.set('content-type', 'application/octet-stream');
        req.contentLength = bytes.length;
        req.add(bytes);
        await Net.flush(req, timeout: const Duration(seconds: 90));
        final res = await Net.send(req, timeout: const Duration(seconds: 90));
        await Net.drain(res);
        if (res.statusCode != 200) throw ApiFailed(res.statusCode, 'upload');
      }));

  Future<Uint8List> getBytes(String url) => _net(() => Net.run((client) async {
        final res = await Net.send(await client.getUrl(Uri.parse(url)));
        if (res.statusCode != 200) { await Net.drain(res); throw ApiFailed(res.statusCode, 'download'); }
        return Net.bytes(res);
      }));
}
