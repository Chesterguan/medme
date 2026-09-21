// 授权链接解析。与 claim_link_test.dart 同形:守的是同一条安全性质
// (id/token 只能是不透明字符,不能被拿来当地址),外加 `toUrl` 的回环。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/grant_link.dart';

void main() {
  test('认得 g1 前缀,toUrl 回环', () {
    const id = 'inv_JNpaUxZ3qiojrL3u';
    const token = 'oQEi4A-ksiW991nX8ZNkpDYfXdhbTkURCJhb';

    final a = GrantLink.tryParse(Uri.parse('${GrantLink.pageUrl}#g1.$id.$token'));
    expect(a, isNotNull);
    expect(a!.inviteId, id);
    expect(a.token, token);

    final url = a.toUrl();
    expect(url, '${GrantLink.pageUrl}#g1.$id.$token');
    final b = GrantLink.tryParse(Uri.parse(url));
    expect(b?.inviteId, id);
    expect(b?.token, token);

    // 少数环境把 fragment 落在 path 上的兜底,同 ClaimLink。
    final c = GrantLink.tryParse(Uri.parse('medme://claim/g1.$id.$token'));
    expect(c?.inviteId, id);
  });

  test('非授权链接一律返回 null,不误吞', () {
    const token = 'oQEi4A-ksiW991nX8ZNkpDYfXdhbTkURCJhb';
    for (final s in [
      'https://example.com/',
      '${GrantLink.pageUrl}#c1.inv_abcdefgh.$token', // 认领链接的前缀,不是授权
      '${GrantLink.pageUrl}#g1.onlyid', // 缺 token
      '${GrantLink.pageUrl}#g1..$token', // 缺 id
    ]) {
      expect(GrantLink.tryParse(Uri.parse(s)), isNull, reason: s);
    }
  });

  test('非法 token 字符返回 null', () {
    const id = 'inv_abcdefgh';
    for (final bad in [
      'short', // 太短
      'has space',
      'has/slash',
      'id?x=1',
      'id%2Fcd',
    ]) {
      expect(
        GrantLink.tryParse(Uri.parse('${GrantLink.pageUrl}#g1.$id.$bad')),
        isNull,
        reason: bad,
      );
    }
  });

  test('id 里出现路径字符时拒绝', () {
    const token = 'oQEi4A-ksiW991nX8ZNkpDYfXdhbTkURCJhb';
    for (final bad in ['../../evil', 'ab/cd', 'a', 'id?x=1']) {
      expect(
        GrantLink.tryParse(Uri.parse('${GrantLink.pageUrl}#g1.$bad.$token')),
        isNull,
        reason: bad,
      );
    }
  });
}
