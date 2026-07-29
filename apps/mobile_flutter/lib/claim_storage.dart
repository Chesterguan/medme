import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 瞬时云:把一份密文从这台设备搬到那台设备,然后消失。
///
/// **它是中转,不是存储。** 不备份、不同步、不是「我的病历在云上」。由此推出的性质:
/// 我们拿不到钥匙(密钥只在 URL 的 `#` 之后)、对象是短命的(桶上的生命周期规则到期
/// 即删)、没有账号(中转不需要知道你是谁)、失败的后果是「这次没传成」而不是「你的
/// 病历没了」。
///
/// **铁律:上云的东西,别处必然还有一份。** 出码传的原件在病人自己的保险箱里,代拍
/// 传的在医生手机的保留区加纸质原件。这条一破,云就变成存储 —— 那时丢了就是真丢了,
/// 我们得做持久化、备份、灾备,就成了一家替人保管病历的公司,监管重量差一个数量级。
///
/// 读是公开的(拿到的是没有密钥的密文,等同随机字节),**写必须签名** —— 手机里绝不
/// 能内嵌 AccessKey。眼下 [base] 指向本地模拟服务,换成真桶只改这一处 + 查看器里的
/// `CLAIM_BASE` + 其 CSP 的 connect-src。
class ClaimStorage {
  ClaimStorage({String? base}) : base = base ?? defaultBase;

  /// 桶地址。**换存储只改这一行**(查看器 `web/hosted-viewer/index.html` 里还有一处
  /// 同名的 `CLAIM_BASE`,以及它 CSP 的 connect-src,要一起改)。
  ///
  /// 可用 `--dart-define=MEDME_CLAIM_BASE=http://<内网IP>:8900/c/` 覆盖,指向本地
  /// 模拟桶 —— 真桶到位之前整条链路就靠这个跑通,不必为了测试改代码。
  static const defaultBase = String.fromEnvironment(
    'MEDME_CLAIM_BASE',
    defaultValue: 'https://medme-claim.oss-cn-hangzhou.aliyuncs.com/c/',
  );

  /// 上传许可证的签发地址(阿里云函数计算,见 services/claim-signer/)。
  ///
  /// **手机不持 AccessKey** —— 那东西进了 App 就能被反编译扒出来,而账号是实名主体的。
  /// 所以每次上传先问它要一个限时的预签名 PUT 地址。空串表示未配置:那时退回裸 PUT,
  /// 只有本地模拟桶会接受,真桶会 403 → 出码降级为简版码(见 qr_share_screen)。
  static const signerUrl = String.fromEnvironment(
    'MEDME_SIGNER_URL',
    defaultValue: 'https://claim-signer-rujxaehppb.cn-hangzhou.fcapp.run/sign',
  );

  final String base;

  /// 对象 id:96 位随机,不可枚举。安全性建立在两条上 —— 猜不到这个 id,以及密钥
  /// 从不上服务器。桶上不开放 ListObjects,所以也没法遍历。
  ///
  /// 走签名端点时 id 由**服务端**生成(客户端无权指定,否则能覆盖别人的对象);
  /// 这个本地实现只在没配签名端点的本地模拟桶场景下用。
  static String newId() {
    final r = Random.secure();
    final b = Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
    return base64Url.encode(b).replaceAll('=', '');
  }

  /// 向签名端点要一份上传许可证,回 `(对象id, 上传地址)`。
  Future<(String, Uri)> _requestPermit() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(signerUrl));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw ClaimUploadFailed('取上传许可失败(${res.statusCode})');
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      final id = j['id'] as String?;
      final url = j['uploadUrl'] as String?;
      if (id == null || url == null) throw const ClaimUploadFailed('上传许可格式不对');
      return (id, Uri.parse(url));
    } on SocketException {
      throw const ClaimUploadFailed('网络连不上,请检查网络后重试。');
    } finally {
      client.close();
    }
  }

  /// 上传一份密文,回对象 id。`onProgress` 给 0.0–1.0,用于进度条 —— 病人在诊室里
  /// 盯着屏幕等,不能只给一个转圈。
  ///
  /// 保留期由桶上的生命周期规则统一给(`c/` 前缀 15 天)—— 认领那条要留够
  /// 「病人回家才装 App」的时间,出码其实一天就够,但**不为这点收益让对象 id 里
  /// 出现斜杠**:那正是防目录穿越那道校验要挡的东西。真要分档,以后用不含斜杠的
  /// 类别前缀(如 `c/q…` / `c/k…`)再配两条规则。
  Future<String> upload(
    Uint8List bytes, {
    void Function(double)? onProgress,
  }) async {
    // 配了签名端点就走「先要许可证」;没配则裸 PUT(仅本地模拟桶可用)。
    final String id;
    final Uri target;
    if (signerUrl.isNotEmpty) {
      (id, target) = await _requestPermit();
    } else {
      id = newId();
      target = Uri.parse('$base$id');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.putUrl(target);
      // **必须与签名端点里的 CONTENT_TYPE 逐字一致** —— 它进签名串,对不上 OSS 拒收。
      req.headers.contentType = ContentType.binary;
      req.contentLength = bytes.length;

      // 分块写并汇报进度。块太小会拖慢吞吐,太大则进度条一跳一跳 —— 64KB 是个
      // 在几 MB 到几十 MB 之间都不难看的折中。
      const chunk = 64 * 1024;
      for (var off = 0; off < bytes.length; off += chunk) {
        final end = (off + chunk).clamp(0, bytes.length);
        req.add(bytes.sublist(off, end));
        await req.flush();
        onProgress?.call(end / bytes.length);
      }
      final res = await req.close();
      // OSS PUT 成功回 200。其余一律当失败 —— 出码流程会据此降级。
      if (res.statusCode != 200 && res.statusCode != 201 && res.statusCode != 204) {
        await res.drain<void>();
        throw ClaimUploadFailed('上传失败(${res.statusCode})');
      }
      await res.drain<void>();
      return id;
    } on SocketException {
      throw const ClaimUploadFailed('网络连不上,请检查网络后重试。');
    } finally {
      client.close();
    }
  }
}

class ClaimUploadFailed implements Exception {
  const ClaimUploadFailed(this.message);
  final String message;
  @override
  String toString() => message;
}
