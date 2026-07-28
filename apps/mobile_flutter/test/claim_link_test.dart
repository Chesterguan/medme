// 认领链接解析。这里守的是一条安全性质:**对象 id 只能拼在固定前缀之后**,
// 链接永远不能决定去哪台主机取数据 —— 否则一条伪造链接就能把 App 指向攻击者的
// 服务器,而病人根本看不出区别。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/claim_link.dart';

void main() {
  test('认得自定义 scheme 与 https 两种形状', () {
    const id = 'JNpaUxZ3qiojrL3u';
    const key = 'oQEi4A-ksiW991nX8ZNkpDYfXdhbTkURCJhb6vIQy7E';

    // 认领页点按钮走的这条。
    final a = ClaimLink.tryParse(Uri.parse('medme://claim#c1.$id.$key'));
    expect(a, isNotNull);
    expect(a!.objectId, id);
    expect(a.keyB64, key);

    // 将来配了 Universal Links 走的这条,同一个 fragment。
    final b = ClaimLink.tryParse(
      Uri.parse('${ClaimLink.pageUrl}#c1.$id.$key'),
    );
    expect(b?.objectId, id);

    // 少数环境把 fragment 落在 path 上的兜底。
    final c = ClaimLink.tryParse(Uri.parse('medme://claim/c1.$id.$key'));
    expect(c?.objectId, id);
  });

  test('非认领链接一律返回 null,不误吞', () {
    for (final s in [
      'medme://something-else',
      'https://example.com/',
      'medme://claim#q1.abc.def', // 二维码分享的前缀,不是认领
      'medme://claim#c1.onlyid', // 缺密钥
      'medme://claim#c1..key', // 缺 id
    ]) {
      expect(ClaimLink.tryParse(Uri.parse(s)), isNull, reason: s);
    }
  });

  test('id 里出现路径字符时拒绝 —— 这是防止链接改写取数地址的那道闸', () {
    final key = 'k' * 43;
    for (final bad in [
      '../../evil', // 目录穿越
      'ab/cd', // 斜杠
      'a', // 太短,不像不透明 id
      'id?x=1', // 查询串
      'id%2Fcd', // 编码过的斜杠
    ]) {
      expect(
        ClaimLink.tryParse(Uri.parse('medme://claim#c1.$bad.$key')),
        isNull,
        reason: bad,
      );
    }
  });
}
