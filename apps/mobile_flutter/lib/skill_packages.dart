/// 病种包的拉取与安装:`GET /v1/skills/index.json` → **验签** → 按验过的
/// `id`/`version` 拉 `GET /v1/skills/{id}/{ver}.json` → 交给 Rust 装进缓存
/// (`vault_profile_install_package`,那边再验一次签 + 引擎版本闸 + 单调版本闸)。
///
/// **两个请求都不带任何账号头。** 这条路故意**不复用 [ApiClient]** —— 那个会自动挂
/// bearer(还有调用方给的 `X-Device-Id`)。包是公开的、无鉴权的静态文件
/// (spec §8;`services/api/app.py` 的两条路由也确实不鉴权),而请求里一旦出现账号
/// 凭证,服务端就能把「谁」和「开了哪个病」对上 —— 这正是这套设计要避免的事。
/// 请求里除了包 id/版本号,也不带任何别的东西。
///
/// **Dart 永远不自己解析未验签的清单。** 中间人改一行 `version` 就能把客户端引到
/// 任意路径,或者把新版本从清单里删掉把用户按在旧规则上。所以清单先过
/// `vaultProfileVerifyIndex`(Ed25519,公钥编在二进制里),**验过之后**才拿里面的
/// 字段去拼下一个请求的路径。
///
/// **失败一律静默**:没网、验签不过、被单调闸拒了降级,都退回缓存里已经装着的
/// 那一份(`profile::cache_load` 每次读都重新验签)。病程档案没有「必须联网」这
/// 回事,拉包失败不该让任何界面报错。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'package:mobile_flutter/api_client.dart' show ApiClient, ApiFailed;
import 'package:mobile_flutter/net.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;

/// 一次裸 GET:返回响应体文本。`headers` 是**这条路想带的头**(恒为空,见类文档)
/// —— 摆成参数是为了让"没带账号头"这件事有个能下断言的地方。
typedef SkillGet = Future<String> Function(String path, Map<String, String> headers);

const String skillsIndexPath = '/v1/skills/index.json';

class SkillPackages {
  SkillPackages({
    this.dir,
    this.httpGet,
    Future<String> Function(String envelopeJson)? verifyIndex,
    Future<String> Function(String dir, String envelopeJson)? install,
    String? base,
  }) : _verifyIndex = verifyIndex ??
           ((envelopeJson) => rust_profile.vaultProfileVerifyIndex(envelopeJson: envelopeJson)),
       _install = install ??
           ((dir, envelopeJson) => rust_profile.vaultProfileInstallPackage(
                 dir: dir,
                 envelopeJson: envelopeJson,
               )),
       base = base ?? ApiClient.defaultBase;

  /// 包缓存目录(Rust 在它下面建 `skills/`)。`null` = 用沙盒的 Application
  /// Support —— 包是公开的、签过名的、**全成员共用**的东西,不属于任何一个保险箱,
  /// 也不该跟着某个成员的档案走。
  final String? dir;

  /// `null` = 用下面那个裸客户端。摆成可注入的只为单测(FFI 与真网络都上不了 host)。
  final SkillGet? httpGet;
  final Future<String> Function(String envelopeJson) _verifyIndex;
  final Future<String> Function(String dir, String envelopeJson) _install;
  final String base;

  /// 拉一遍清单,把清单里列的包都装上,返回**真的装上了**的那几个 id。
  ///
  /// 任何一步失败都只是「这次没更新」:返回空列表 / 少几个 id,不抛。
  Future<List<String>> refreshIndex() async {
    final List<Map<String, dynamic>> skills;
    try {
      final envelope = await _get(skillsIndexPath);
      // 验过签的清单才有资格拼出下一个请求的路径。
      final verified = jsonDecode(await _verifyIndex(envelope)) as Map<String, dynamic>;
      skills = (verified['skills'] as List).cast<Map<String, dynamic>>();
    } catch (e) {
      // 包 id/版本号是公开信息,异常文本里不会有病历内容,可以进日志。
      debugPrint('[skills] 清单没取到或没验过,继续用缓存里那份:$e');
      return const [];
    }
    if (skills.isEmpty) return const [];

    final dir = await _resolveDir();
    final installed = <String>[];
    for (final s in skills) {
      final id = s['id'], version = s['version'];
      try {
        // 一个包装不上不影响别的:引擎太老、被单调闸拒了降级,都只是这一个病
        // 这次没更新。
        installed.add(await _install(dir, await _get('/v1/skills/$id/$version.json')));
      } catch (e) {
        debugPrint('[skills] $id $version 这次没装上:$e');
      }
    }
    return installed;
  }

  Future<String> _resolveDir() async =>
      dir ?? (await getApplicationSupportDirectory()).path;

  Future<String> _get(String path) => (httpGet ?? _bareGet)(path, const {});

  /// 生产的那个口子:**裸** `HttpClient`(只有 [Net] 的超时),一个头都不设。
  Future<String> _bareGet(String path, Map<String, String> headers) => Net.run((client) async {
    final req = await client.getUrl(Uri.parse('$base$path'));
    headers.forEach(req.headers.set);
    final res = await Net.send(req);
    if (res.statusCode != 200) {
      await Net.drain(res);
      throw ApiFailed(res.statusCode, 'skills');
    }
    return Net.text(res);
  });
}
