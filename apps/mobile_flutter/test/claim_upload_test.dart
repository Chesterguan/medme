// 可续传上传的核心性质:**断了再试,已成功的分片不重传**。
//
// 这是「断连不该让用户重来」这条要求的全部依据 —— 如果续传时又把成功的片传一遍,
// 那和整份重来没区别。用一个会按剧本失败的假 OSS 来钉住它。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/claim_upload.dart';

/// 假的签名端点 + 假的 OSS。记录每片被 PUT 了几次。
class _FakeCloud {
  _FakeCloud({this.failOnPart});

  /// 第几片该失败(片号,1 起)。null = 从不失败。
  final int? failOnPart;
  int failTimes = 1;

  late HttpServer server;
  final Map<int, int> putCount = {}; // 片号 → 被 PUT 的次数
  int completeCount = 0;
  int initiateCount = 0;

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start({required int totalBytes, required int partSize}) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final nParts = (totalBytes + partSize - 1) ~/ partSize;
    server.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/multipart')) {
        initiateCount++;
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'id': 'testobject123456',
            'uploadId': 'UPLOAD1',
            'partSize': partSize,
            'contentType': 'application/octet-stream',
            'completeContentType': 'application/xml',
            'completeUrl': '$base/complete',
            'parts': [
              for (var i = 1; i <= nParts; i++)
                {'partNumber': i, 'url': '$base/part/$i'},
            ],
          }));
        await req.response.close();
        return;
      }
      if (path.startsWith('/part/')) {
        final n = int.parse(path.split('/').last);
        putCount[n] = (putCount[n] ?? 0) + 1;
        await req.drain<void>();
        if (n == failOnPart && failTimes > 0) {
          failTimes--;
          req.response.statusCode = 500;
        } else {
          req.response
            ..statusCode = 200
            ..headers.set('etag', '"etag-$n"');
        }
        await req.response.close();
        return;
      }
      if (path == '/complete') {
        completeCount++;
        await req.drain<void>();
        req.response.statusCode = 200;
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  test('中途失败后重试:已成功的分片不重传', () async {
    // 10 片,第 4 片第一次失败。
    const partSize = 1000;
    final bytes = Uint8List(10 * partSize);
    final cloud = _FakeCloud(failOnPart: 4);
    await cloud.start(totalBytes: bytes.length, partSize: partSize);
    addTearDown(cloud.stop);

    final up = ResumableUpload(bytes, signerBase: cloud.base);

    // 第一趟:传到第 4 片挂掉。
    await expectLater(up.run(), throwsA(isA<Exception>()));
    expect(cloud.putCount[1], 1);
    expect(cloud.putCount[3], 1);
    expect(cloud.putCount[4], 1, reason: '第 4 片试过一次');
    expect(cloud.putCount[5], isNull, reason: '失败后不该继续传后面的片');
    expect(cloud.completeCount, 0);

    // 第二趟:应当**跳过 1–3**,从第 4 片接着传。
    final id = await up.run();
    expect(id, 'testobject123456');
    expect(cloud.putCount[1], 1, reason: '第 1 片不该被重传');
    expect(cloud.putCount[2], 1, reason: '第 2 片不该被重传');
    expect(cloud.putCount[3], 1, reason: '第 3 片不该被重传');
    expect(cloud.putCount[4], 2, reason: '第 4 片重试了一次');
    expect(cloud.putCount[10], 1);
    expect(cloud.completeCount, 1);
    // 发起也只做一次 —— 续传复用同一个 uploadId,不重新协商。
    expect(cloud.initiateCount, 1);
  });

  test('取消会中止,且不算作失败', () async {
    const partSize = 1000;
    final bytes = Uint8List(10 * partSize);
    final cloud = _FakeCloud();
    await cloud.start(totalBytes: bytes.length, partSize: partSize);
    addTearDown(cloud.stop);

    final up = ResumableUpload(bytes, signerBase: cloud.base);
    // 传了两片就取消。
    late Future<String> fut;
    fut = up.run(onProgress: (_) {
      if (up.uploadedBytes >= 2 * partSize) up.cancel();
    });
    await expectLater(fut, throwsA(isA<ClaimUploadCancelled>()));
    expect(cloud.completeCount, 0, reason: '取消不该合并');
    expect(up.uploadedBytes, greaterThan(0), reason: '已传的片仍记着,可续传');
  });

  test('进度按已成功字节算,不是按片数', () async {
    const partSize = 1000;
    final bytes = Uint8List(2500); // 3 片:1000 / 1000 / 500
    final cloud = _FakeCloud();
    await cloud.start(totalBytes: bytes.length, partSize: partSize);
    addTearDown(cloud.stop);

    final up = ResumableUpload(bytes, signerBase: cloud.base);
    final seen = <double>[];
    await up.run(onProgress: seen.add);
    expect(seen.last, 1.0);
    // 最后一片只有 500 字节,若按片数算第 2 片会是 0.67,按字节是 0.8。
    expect(seen, contains(closeTo(0.8, 0.001)));
  });
}
