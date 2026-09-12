import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:mobile_flutter/net.dart';

class ApiUnauthorized implements Exception {
  const ApiUnauthorized();
}

class ApiFailed implements Exception {
  const ApiFailed(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => '服务器返回 $status:$message';
}

/// 账号 API 的唯一出口。所有请求走 [Net](有读超时);token 由 [bearer] 回调提供,
/// 于是测试里注入假服务器 + 假 token 即可,不碰 secure storage。
class ApiClient {
  ApiClient({String? base, this.bearer}) : base = base ?? defaultBase;

  static const defaultBase = String.fromEnvironment('MEDME_API_BASE', defaultValue: 'https://api.medmenow.com');
  final String base;
  final Future<String?> Function()? bearer;

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
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    return Net.run((client) async {
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
      if (res.statusCode == 401) throw const ApiUnauthorized();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = text;
        try { msg = (jsonDecode(text) as Map)['detail']?.toString() ?? text; } catch (_) {}
        throw ApiFailed(res.statusCode, msg);
      }
      final respHeaders = <String, String>{};
      res.headers.forEach((name, values) => respHeaders[name.toLowerCase()] = values.join(','));
      return (text.isEmpty ? null : jsonDecode(text), respHeaders);
    });
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

  /// 直传 OSS 预签名地址(不带 Bearer)。Content-Type 必须与签名一致。
  Future<void> putBytes(String url, Uint8List bytes) => Net.run((client) async {
        final req = await client.putUrl(Uri.parse(url));
        req.headers.set('content-type', 'application/octet-stream');
        req.contentLength = bytes.length;
        req.add(bytes);
        await Net.flush(req, timeout: const Duration(seconds: 90));
        final res = await Net.send(req, timeout: const Duration(seconds: 90));
        await Net.drain(res);
        if (res.statusCode != 200) throw ApiFailed(res.statusCode, 'upload');
      });

  Future<Uint8List> getBytes(String url) => Net.run((client) async {
        final res = await Net.send(await client.getUrl(Uri.parse(url)));
        if (res.statusCode != 200) { await Net.drain(res); throw ApiFailed(res.statusCode, 'download'); }
        return Net.bytes(res);
      });
}
