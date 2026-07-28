import 'dart:io';
import 'dart:typed_data';

import 'package:mobile_flutter/claim_storage.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart' as rust;

/// 认领链接:医生代拍 → 病人把病历存进自己的保险箱。
///
/// 链接形如 `<查看器>/#c1.<对象id>.<密钥>`。病人先在浏览器里看到病历(那一步不需要
/// 装 App),点「存进我的 MedMe」时,认领页用自定义 scheme 把同一个 fragment 交给
/// 本 App:`medme://claim#c1.<对象id>.<密钥>`。
///
/// 自定义 scheme 与 Universal Links / App Links **两条都收**:前者是兜底(不依赖任何
/// 域名所有权,任何环境下认领页那个按钮都能用),后者让病人在微信里点链接就能直接
/// 唤起 App —— 顺带绕开「微信内置浏览器可能拦自定义 scheme」这个我们没法验证的风险。
///
/// 两条路进来都收敛到 [tryParse],所以下面同时认这两种形状。
class ClaimLink {
  ClaimLink({required this.objectId, required this.keyB64});

  final String objectId;
  final String keyB64;

  /// 密文所在前缀 —— 与上传端同一处定义,免得两边漂移。
  static const base = ClaimStorage.defaultBase;

  static const _prefix = 'c1.';
  // 对象 id 只允许不透明字符:id 只能拼在固定前缀之后,绝不让链接决定去哪台主机取
  // 数据 —— 否则一条伪造链接就能把 App 指向攻击者的服务器。与查看器同一条规则。
  static final _idRe = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

  /// 认领页的网址。**必须与 `/viewer/` 分开**:Universal Links 按路径匹配、不看
  /// `#` 后面的内容,只有独立路径才能做到「病人点认领链接进 App、医生扫码进浏览器」。
  static const pageUrl = 'https://medmenow.com/claim/';

  /// 从任意进来的 URI 里解析认领信息;不是认领链接则返回 null。
  ///
  /// 同时接受两种形状,因为两条路都会走到这里:
  ///   `medme://claim#c1.<id>.<key>`(认领页点按钮,任何环境下的兜底)
  ///   `https://medmenow.com/claim/#c1.<id>.<key>`(Universal Links,微信里直接开 App)
  static ClaimLink? tryParse(Uri uri) {
    var frag = uri.fragment;
    // 少数环境会把 fragment 吞掉而留在 path 上(自定义 scheme 尤其不统一),兜一层。
    if (!frag.startsWith(_prefix)) {
      final tail = uri.path.split('/').where((s) => s.isNotEmpty).lastOrNull;
      if (tail != null && tail.startsWith(_prefix)) frag = tail;
    }
    if (!frag.startsWith(_prefix)) return null;

    final parts = frag.substring(_prefix.length).split('.');
    if (parts.length != 2) return null;
    final id = parts[0], key = parts[1];
    if (!_idRe.hasMatch(id) || key.isEmpty) return null;
    return ClaimLink(objectId: id, keyB64: key);
  }

  /// 取回密文 → 解密 → 写进**当前打开的**保险箱。
  ///
  /// 调用前必须已经切到病人要存进去的那个成员(写的是当前箱子)。
  /// 重复认领同一条链接是安全的:内容哈希会去重,结果里体现为 `deduped`。
  Future<ClaimResultDto> claim() async {
    final blob = await _fetch();
    final result = await rust.claimImport(blob: blob, keyB64: keyB64);
    // 认领成功即删 —— 但删除要凭证,而凭证在医生那台设备上。眼下靠桶上的 15 天
    // 生命周期规则兜底(到期自动删)。要做到「即删」,得让医生端在上传时一并签一个
    // 限时 DELETE 链接随包带过来;等云账号到位再接。
    return result;
  }

  /// 先看一眼:这包里有几份、是谁的 —— 不落盘。
  Future<(int, String)> preview() async {
    final blob = await _fetch();
    final (n, name) = await rust.claimPreview(blob: blob, keyB64: keyB64);
    return (n.toInt(), name);
  }

  Future<Uint8List> _fetch() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse('$base$objectId'));
      final res = await req.close();
      // 认领成功即删、到期即删 —— 取不到多半不是坏了,而是这两种正常情况。
      if (res.statusCode == 404 ||
          res.statusCode == 403 ||
          res.statusCode == 410) {
        throw const ClaimGone();
      }
      if (res.statusCode != 200) {
        throw ClaimFailed('取病历失败(${res.statusCode})');
      }
      final chunks = <int>[];
      await for (final c in res) {
        chunks.addAll(c);
      }
      return Uint8List.fromList(chunks);
    } on SocketException {
      throw const ClaimFailed('网络连不上,换个网络再试一次。');
    } finally {
      client.close();
    }
  }
}

/// 密文已经不在了:被领走过,或过了保留期。这是**正常结局**,不是故障。
///
/// 文案刻意不提「找医生重发」:一来链接未必来自医生,二来走到这里最可能的真相是
/// **他之前已经存过了**,东西就在本机档案里 —— 把人支去找别人是帮倒忙。
class ClaimGone implements Exception {
  const ClaimGone();
  @override
  String toString() => '这个链接已经用过了,或者过了保留期。如果之前存过,在你的档案里就能找到。';
}

class ClaimFailed implements Exception {
  const ClaimFailed(this.message);
  final String message;
  @override
  String toString() => message;
}
