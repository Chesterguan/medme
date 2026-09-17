import 'package:mobile_flutter/claim_link.dart' show ClaimLink;

/// 授权链接:家人/医生凭它去 `POST /v1/invites/redeem` 兑换某个云档案的访问权
/// (viewer 只读、owner 转移……角色由服务端邀请记录决定,链接本身不带角色)。
///
/// 形如 `<认领页>/#g1.<inviteId>.<token>` —— **与 [ClaimLink] 同一个 `pageUrl`、
/// 同一套 id 字符集规则**,只是前缀不同(`g1.` 而不是 `c1.`)。这是刻意的:
/// Universal Links 的路由规则按路径匹配、不看 `#` 后面的内容,`/claim/` 这一条路径
/// 已经注册给了「代拍认领」,让「授权邀请」复用同一条路径,不必再为它申请、审核
/// 第二个 Universal Links 关联文件。两种链接在 `main.dart._dispatch` 里各自
/// `tryParse`,谁认得算谁的。
class GrantLink {
  GrantLink({required this.inviteId, required this.token});

  final String inviteId;
  final String token;

  static const _prefix = 'g1.';

  /// id 与 token 都只允许不透明字符——同 [ClaimLink] 的那道闸:链接内容不能被
  /// 拿来当地址或者塞进意料之外的字符集,只能原样转发给服务端核对。
  static final _partRe = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

  /// 与 [ClaimLink] 同一张认领页——不需要单独的 Universal Links 关联路径。
  static const pageUrl = ClaimLink.pageUrl;

  static GrantLink? tryParse(Uri uri) {
    var frag = uri.fragment;
    // 少数环境把 fragment 吞掉、落在 path 上——同 `ClaimLink.tryParse` 的兜底。
    if (!frag.startsWith(_prefix)) {
      final tail = uri.path.split('/').where((s) => s.isNotEmpty).lastOrNull;
      if (tail != null && tail.startsWith(_prefix)) frag = tail;
    }
    if (!frag.startsWith(_prefix)) return null;

    final parts = frag.substring(_prefix.length).split('.');
    if (parts.length != 2) return null;
    final id = parts[0], token = parts[1];
    if (!_partRe.hasMatch(id) || !_partRe.hasMatch(token)) return null;
    return GrantLink(inviteId: id, token: token);
  }

  String toUrl() => '$pageUrl#$_prefix$inviteId.$token';
}
