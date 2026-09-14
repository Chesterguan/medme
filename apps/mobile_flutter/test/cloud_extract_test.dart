import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/cloud_extract.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';

/// 一条真实的 OCR 行框(数值随意,只要是正数矩形)。
const _line = OcrLineDto(text: '白细胞 5.6', left: 10, top: 20, right: 300, bottom: 60);

/// 图片导入没有"缺文本层的页"(那是 PDF 专属),`ImportOutcomeDto` 却要求给一个。
final _noPages = Int32List(0);

void main() {
  // 同 api_client_test.dart:测试 binding 会装一个假的 HttpOverrides,装上之后
  // 回环服务器收不到任何请求,所以初始化完立刻摘掉。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('postExtract', () {
    late HttpServer server;
    late ApiClient api;
    late List<Map<String, dynamic>> seen;

    setUp(() async {
      seen = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api = ApiClient(base: 'http://127.0.0.1:${server.port}', bearer: () async => 'tok');
      server.listen((req) async {
        seen.add({
          'method': req.method,
          'path': req.uri.path,
          'auth': req.headers.value('authorization'),
          'body': jsonDecode(await utf8.decodeStream(req)),
        });
        req.response.headers.contentType = ContentType.json;
        // `/v1/extract` 直接回抽取结果对象本身(services/api/extract.py 的 run())。
        req.response.write(jsonEncode({
          'labs': [
            {'name': '白细胞', 'value': '5.6'},
          ],
        }));
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('发到 /v1/extract、带账号 Bearer、body 是 {mode, schema:1, payload}', () async {
      await postExtract(api, mode: 'text', payload: '白细胞 5.6');
      expect(seen.single, {
        'method': 'POST',
        'path': '/v1/extract',
        'auth': 'Bearer tok', // 走的是账号会话,不是另一套 token
        'body': {'mode': 'text', 'schema': 1, 'payload': '白细胞 5.6'},
      });
    });

    test('返回的是抽取结果 JSON 字符串,原样不改写', () async {
      final out = await postExtract(api, mode: 'image', payload: 'AAAA');
      // commit 要的是字符串;Dart 不解读其中任何字段,只是编回去。
      expect(jsonDecode(out), {
        'labs': [
          {'name': '白细胞', 'value': '5.6'},
        ],
      });
      expect((seen.single['body'] as Map)['mode'], 'image');
    });
  });

  group('canRedactImage 是「能不能把图发出去」的闸', () {
    // 喂给识别引擎的那份字节(iOS 上是拉正后的),内容无所谓,非空即可。
    const bytes = [1, 2, 3];

    test('有框 + 有字节 + frame 尺寸为正 → 走图片档', () {
      expect(
        canRedactImage(const OcrResult('t', 0.9, lines: [_line], frameW: 800, frameH: 1200, bytes: bytes)),
        isTrue,
      );
    });

    test('没有检测框 → 不走图片档(没有框就没有涂黑依据,发出去等于把整页 PHI 送走)', () {
      expect(
        canRedactImage(const OcrResult('t', 0.9, frameW: 800, frameH: 1200, bytes: bytes)),
        isFalse,
      );
    });

    test('没有 OCR 当时那份字节 → 不走图片档', () {
      expect(
        canRedactImage(const OcrResult('t', 0.9, lines: [_line], frameW: 800, frameH: 1200)),
        isFalse,
      );
    });

    test('frame 尺寸不是正数 → 不走图片档(坐标系不对会静默漏涂)', () {
      expect(
        canRedactImage(const OcrResult('t', 0.9, lines: [_line], frameW: 0, frameH: 1200, bytes: bytes)),
        isFalse,
      );
      expect(
        canRedactImage(const OcrResult('t', 0.9, lines: [_line], frameW: 800, frameH: 0, bytes: bytes)),
        isFalse,
      );
    });
  });

  group('knownNameFor:闸要认的是纸上印的名字,不是成员标签', () {
    ImportOutcomeDto outcome(String? detected) => ImportOutcomeDto(
      name: 'a.jpg',
      sourceFileId: 1,
      status: 'stored',
      documentId: 7,
      detectedName: detected,
      pagesWithoutText: _noPages,
    );

    test('成员标签是默认的「我」、报告里认出张建国 → 用张建国', () {
      // 「我」只有一个字,`deid/gate.rs` 的 `chars().count() >= 2` 会整条跳过它 ——
      // 传成员标签等于姓名闸空转,这正是这个函数存在的理由。
      expect(knownNameFor(outcome('张建国'), const Profile(id: 'p-1', name: '我')), '张建国');
    });

    test('成员叫「爸爸」(够两个字、但不是纸上那个名字)→ 仍用报告里认出的', () {
      expect(knownNameFor(outcome('张建国'), const Profile(id: 'p-2', name: '爸爸')), '张建国');
    });

    test('报告里认不出姓名 → 退回成员标签(总比什么都不给强)', () {
      expect(knownNameFor(outcome(null), const Profile(id: 'p-2', name: '爸爸')), '爸爸');
      expect(knownNameFor(outcome('   '), const Profile(id: 'p-2', name: '爸爸')), '爸爸');
    });
  });

  group('runCloudExtraction 不阻断导入', () {
    const ocr = OcrResult('白细胞 5.6', 0.9);

    test('没建文档(去重/失败)→ null,一个字节都不发', () async {
      final r = await runCloudExtraction(
        ImportOutcomeDto(name: 'a.jpg', sourceFileId: 1, status: 'duplicate', pagesWithoutText: _noPages),
        ocr,
      );
      expect(r, isNull);
    });

    test('没登录 → null,不发、不报错', () async {
      // AccountSession.instance.access 未登录时为 null;不注入 api 就该在这一步
      // 直接返回,碰不到 FRB(测试环境里没有 Rust 库,碰到就会炸)。
      final r = await runCloudExtraction(
        ImportOutcomeDto(name: 'a.jpg', sourceFileId: 1, status: 'stored', documentId: 7, pagesWithoutText: _noPages),
        ocr,
      );
      expect(r, isNull);
    });
  });
}
