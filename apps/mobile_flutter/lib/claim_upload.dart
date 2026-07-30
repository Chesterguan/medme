import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mobile_flutter/claim_storage.dart';
import 'package:mobile_flutter/net.dart';

/// 可续传的分片上传。
///
/// **设计前提:断连不是「发生了再补」,是本来就不该让用户重来。** 所以密文被切成若干片
/// 分别上传,每片成功后记下它的 ETag;中途断网、超时、用户取消再重试,**已经成功的片
/// 不重传**。5 MB 的载荷切成 20 片,一次断网最多损失 266 KB,而不是整份。
///
/// 分片方案与参数由签名端点决定(见 `services/claim-signer/handler.py` 的
/// `part_size_for`):我们用分片不是因为文件大(阿里云建议 >100MB 才用分片),而是
/// 为了**断了能续**,顺带让进度条平滑。
///
/// 状态只活在内存里,不落盘 —— 一次「出示二维码」的生命周期内有效。跨 App 重启续传
/// 需要把 uploadId 与 ETag 持久化,那是更大的一步,现在不做(重来一次的成本可接受,
/// 而落盘意味着要管清理与过期)。
class ResumableUpload {
  ResumableUpload(this.bytes, {String? signerBase})
    // 去掉尾部的 `/sign` 得到端点根;测试注入假服务器就靠这个参数。
    : signerBase =
          signerBase ??
          ClaimStorage.signerUrl.replaceFirst(RegExp(r'/sign/?$'), '');

  final Uint8List bytes;

  /// 签名端点的根地址(不含 `/sign`)。分片走 `<root>/multipart`。
  final String signerBase;

  /// 已成功的分片:片号 → ETag。**这就是「续传」的全部依据。**
  final Map<int, String> _done = {};

  _Plan? _plan;
  bool _cancelled = false;

  /// 单片的超时。太短会在慢网络上误杀,太长则「卡住」和「在传」分不出来 ——
  /// 90 秒是让最大一片(5MB)在很差的网络上也能传完的量级。
  static const partTimeout = Duration(seconds: 90);

  /// 已成功的字节数(用于进度)。
  int get uploadedBytes {
    final p = _plan;
    if (p == null) return 0;
    return _done.keys.fold(0, (sum, n) => sum + p.sizeOfPart(n));
  }

  double get progress => bytes.isEmpty ? 1 : uploadedBytes / bytes.length;

  /// 用户主动取消。已传的片留在云上,由桶的生命周期规则回收 —— 我们不主动 abort,
  /// 因为那需要网络,而用户取消往往正是因为网络不行。
  void cancel() => _cancelled = true;

  /// 传完并合并,回对象 id。可重复调用:第二次只补没成功的片。
  Future<String> run({void Function(double)? onProgress}) async {
    _cancelled = false;
    final plan = _plan ??= await _initiate();
    onProgress?.call(progress);

    for (final part in plan.parts) {
      if (_cancelled) throw const ClaimUploadCancelled();
      if (_done.containsKey(part.number)) continue; // ← 续传:跳过已成功的
      final etag = await _putPart(plan, part);
      _done[part.number] = etag;
      onProgress?.call(progress);
    }

    if (_cancelled) throw const ClaimUploadCancelled();
    await _complete(plan);
    return plan.id;
  }

  Future<_Plan> _initiate() async {
    try {
      return await Net.retry(_initiateOnce); // GET,幂等
    } on TimeoutException {
      throw const ClaimUploadFailed('网络太慢,没能取到上传许可。请重试。');
    } on SocketException {
      throw const ClaimUploadFailed('网络连不上,请检查网络后重试。');
    }
  }

  Future<_Plan> _initiateOnce() => Net.run((client) async {
    final uri = Uri.parse('$signerBase/multipart?size=${bytes.length}');
    final res = await Net.send(await client.getUrl(uri));
    final body = await Net.text(res);
    if (res.statusCode != 200) {
      throw ClaimUploadFailed('取上传许可失败(${res.statusCode})');
    }
    return _Plan.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
      bytes.length,
    );
  });

  Future<String> _putPart(_Plan plan, _Part part) async {
    return Net.run((client) async {
      try {
        final start = (part.number - 1) * plan.partSize;
        final end = (start + plan.partSize).clamp(0, bytes.length);
        final chunk = Uint8List.sublistView(bytes, start, end);

        final req = await client.putUrl(part.url);
        // **必须与签名端点里的 CONTENT_TYPE 逐字一致** —— 它进签名串,对不上 OSS 拒收。
        req.headers.contentType = ContentType.binary;
        req.contentLength = chunk.length;
        req.add(chunk);
        await Net.flush(req, timeout: partTimeout);
        final res = await Net.send(req, timeout: partTimeout);
        await Net.drain(res);
        if (res.statusCode != 200) {
          throw ClaimUploadFailed('第 ${part.number} 片上传失败(${res.statusCode})');
        }
        final etag = res.headers.value('etag');
        if (etag == null) throw const ClaimUploadFailed('OSS 未返回分片校验值');
        return etag;
      } on TimeoutException {
        // 超时**不丢已成功的片** —— 调用方重试时会从这一片接着传。
        throw ClaimUploadFailed('第 ${part.number} 片超时,可以重试继续');
      } on SocketException {
        throw const ClaimUploadFailed('网络中断,可以重试继续');
      }
    });
  }

  Future<void> _complete(_Plan plan) async {
    final nums = _done.keys.toList()..sort();
    final xml = StringBuffer('<CompleteMultipartUpload>');
    for (final n in nums) {
      xml.write(
        '<Part><PartNumber>$n</PartNumber><ETag>${_done[n]}</ETag></Part>',
      );
    }
    xml.write('</CompleteMultipartUpload>');

    return Net.run((client) async {
      try {
        final req = await client.postUrl(plan.completeUrl);
        // 合并请求的 Content-Type 也进签名串,必须与端点签的那个一致(application/xml)。
        req.headers.contentType = ContentType('application', 'xml');
        final body = utf8.encode(xml.toString());
        req.contentLength = body.length;
        req.add(body);
        await Net.flush(req, timeout: partTimeout);
        final res = await Net.send(req, timeout: partTimeout);
        await Net.drain(res);
        if (res.statusCode != 200) {
          throw ClaimUploadFailed('合并分片失败(${res.statusCode})');
        }
      } on TimeoutException {
        throw const ClaimUploadFailed('合并超时,可以重试');
      } on SocketException {
        throw const ClaimUploadFailed('网络中断,可以重试');
      }
    });
  }
}

class _Part {
  const _Part(this.number, this.url);
  final int number;
  final Uri url;
}

class _Plan {
  _Plan({
    required this.id,
    required this.partSize,
    required this.parts,
    required this.completeUrl,
    required this.totalBytes,
  });

  final String id;
  final int partSize;
  final List<_Part> parts;
  final Uri completeUrl;
  final int totalBytes;

  /// 某一片的实际字节数(最后一片通常不满)。
  int sizeOfPart(int number) {
    final start = (number - 1) * partSize;
    return (start + partSize).clamp(0, totalBytes) - start;
  }

  factory _Plan.fromJson(Map<String, dynamic> j, int totalBytes) {
    final ps = j['partSize'] as int?;
    final id = j['id'] as String?;
    final complete = j['completeUrl'] as String?;
    final raw = j['parts'] as List?;
    if (ps == null || id == null || complete == null || raw == null) {
      throw const ClaimUploadFailed('上传许可格式不对');
    }
    return _Plan(
      id: id,
      partSize: ps,
      totalBytes: totalBytes,
      completeUrl: Uri.parse(complete),
      parts: [
        for (final p in raw)
          _Part((p as Map)['partNumber'] as int, Uri.parse(p['url'] as String)),
      ],
    );
  }
}

/// 用户主动取消。**不是错误** —— UI 不该把它当失败报,静默回到出码前的状态即可。
class ClaimUploadCancelled implements Exception {
  const ClaimUploadCancelled();
  @override
  String toString() => '已取消';
}
