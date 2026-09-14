import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/cloud_extract.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/vault_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条真实的 OCR 行框(数值随意,只要是正数矩形)。
const _line = OcrLineDto(text: '白细胞 5.6', left: 10, top: 20, right: 300, bottom: 60);

/// 图片导入没有"缺文本层的页"(那是 PDF 专属),`ImportOutcomeDto` 却要求给一个。
final _noPages = Int32List(0);

/// 一份已落库的图片文档。
ImportOutcomeDto _stored(int docId, {String? detectedName}) => ImportOutcomeDto(
  name: 'a$docId.jpg',
  sourceFileId: docId,
  status: 'stored',
  documentId: docId,
  detectedName: detectedName,
  pagesWithoutText: _noPages,
);

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
        // `/v1/extract` 直接回抽取结果对象本身 + 这次真正用的模型名
        // (services/api/extract.py 的 run())。
        req.response.write(jsonEncode({
          'labs': [
            {'name': '白细胞', 'value': '5.6'},
          ],
          'model': 'deepseek-vision-y',
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

    test('返回响应体原样,一个字段都不改写', () async {
      final out = await postExtract(api, mode: 'image', payload: 'AAAA');
      expect(out, {
        'labs': [
          {'name': '白细胞', 'value': '5.6'},
        ],
        'model': 'deepseek-vision-y',
      });
      expect((seen.single['body'] as Map)['mode'], 'image');
    });

    // 落盘的模型版本必须是**服务端说的那个**:模型名是环境变量,运维随时能换,
    // 客户端硬编码一个默认值就是在结果溯源上说谎。
    test('模型版本取服务端回的 model;没有这个字段才退兜底值', () async {
      final out = await postExtract(api, mode: 'text', payload: 'x');
      expect(out['model'], 'deepseek-vision-y');
      expect(out['model'], isNot(extractModelVersion), reason: '不是兜底值,是服务端说的那个');
      // 老版本服务端不回 model 时的表达式(与 runCloudExtraction 里那行同形)。
      const noModel = <String, dynamic>{'labs': []};
      expect((noModel['model'] as String?) ?? extractModelVersion, extractModelVersion);
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

  group('runCloudExtractions:整批在导入循环之外跑', () {
    // 未登录,所以每一份都在 `runCloudExtraction` 的第一道门就返回 null —— 这里要钉
    // 的不是抽取本身,而是**这个批量入口不抛、不 bump、跑完整批**。
    test('整批跑完不抛;一份都没成功就一次都不 bump', () async {
      final before = vaultRevision.value;
      await runCloudExtractions([
        (outcome: _stored(1), ocr: const OcrResult('a', 0.9)),
        (outcome: _stored(2), ocr: const OcrResult('b', 0.9)),
        (outcome: _stored(3), ocr: const OcrResult('c', 0.9)),
      ]);
      expect(vaultRevision.value, before, reason: '没有新结果就没有要刷新的东西');
    });

    test('空队列:什么都不做', () async {
      final before = vaultRevision.value;
      await runCloudExtractions([]);
      expect(vaultRevision.value, before);
    });
  });

  // 三态里剩下的两条(memory `test-all-three-states`)。真机上这两条分别是「闸拒发」
  // 和「云不可用」;host 上没有 Rust 库,`vault_cloud_*` 一律抛 —— 而**闸拒发走的就是
  // 同一条 catch**(`vault.rs` 的 `assert_clean` 失败是 `bail!`,到 Dart 是异常),
  // 所以这里钉住的是那条 catch 真的在、且在它之前一个字节都没发出去。
  group('三态:云不可用 / 闸拒发', () {
    late HttpServer server;
    late ApiClient api;
    late int hits;

    setUp(() async {
      hits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api = ApiClient(base: 'http://127.0.0.1:${server.port}', bearer: () async => 'tok');
      server.listen((req) async {
        hits++;
        req.response.statusCode = 500;
        req.response.write('{"detail":"boom"}');
        await req.response.close();
      });
      // ensureLoaded 要落盘 profiles.json;不 mock 的话会在 FRB 之前就炸,
      // 那样这条测试钉的就不是我们想钉的东西了。
      final support = await Directory.systemTemp.createTemp('medme-cloud-extract-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
    });
    tearDown(() => server.close(force: true));

    test('闸拒发 / FRB 不可用 → null,而且一个请求都没发出去', () async {
      final r = await runCloudExtraction(_stored(11, detectedName: '张建国'), const OcrResult('白细胞 5.6', 0.9), api: api);
      expect(r, isNull, reason: '不抛,只是没有云抽取结果');
      expect(hits, 0, reason: '拒发就是拒发:prepare 没过,代理那一步压根不该发生');
    });

    test('整批里有一份拒发,后面的照样跑完,也不 bump', () async {
      final before = vaultRevision.value;
      await runCloudExtractions([
        (outcome: _stored(12), ocr: const OcrResult('a', 0.9)),
        (outcome: _stored(13), ocr: const OcrResult('b', 0.9)),
      ]);
      expect(vaultRevision.value, before);
      expect(hits, 0);
    });

    test('本机先量体积:两条上限与服务端 app.py 的那两个数一致', () {
      // 量错了就是白跑一趟上行换一个 413(手机上那是用户的流量和等待时间)。
      expect(extractTextMaxBytes, 64 * 1024);
      expect(extractImageMaxBytes, 2 * 1024 * 1024);
    });

    test('云不可用(服务端 500)→ postExtract 抛 ApiFailed,由上面那条 catch 吞掉', () async {
      await expectLater(
        postExtract(api, mode: 'text', payload: 'x'),
        throwsA(isA<ApiFailed>()),
      );
      expect(hits, 1);
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

  group('「云端整理」开关(Task 17):runCloudExtractions 入口的门', () {
    // 拿 debugPrint 有没有响当"这一份到底进没进 `runCloudExtraction` 内部"的信号——
    // host 测试环境没有真实 FRB,不管开关开没开,最终都是 hits==0、`vaultRevision`
    // 不变(见上面「三态」组的注释),这两个数分不出"被新开关拦在
    // `runCloudExtractions` 入口"和"照旧走、只是在更里面的 FRB 那步失败"。而
    // `runCloudExtraction` 唯一的 catch 块**必打一行 debugPrint**(不管是 FRB 没
    // 初始化、还是别的什么异常)——只要这份文档被送进 `runCloudExtraction`,这行
    // 就一定响;没被送进去,这行就一定不响。
    final captured = <String?>[];
    late DebugPrintCallback originalDebugPrint;

    setUp(() {
      captured.clear();
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => captured.add(message);
      final support = Directory.systemTemp.path;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support,
      );
      // `runCloudExtractions` 不接受注入 `api`,要走到"没登录 = 没这个功能"那道门
      // 之后的代码,必须真的登录——否则不管新开关开没开,都会在那道更早的门前
      // 一样返回 null,测不出这道新开关到底起没起作用。
      AccountSession.instance.access = 'test-token';
      AccountSession.instance.accountId = 'acc-test';
    });
    tearDown(() {
      debugPrint = originalDebugPrint;
      AccountSession.instance.access = null;
      AccountSession.instance.accountId = null;
    });

    test('关掉(cloud_extract_enabled=false)→ 这份文档没被送进 runCloudExtraction,文档不受影响', () async {
      SharedPreferences.setMockInitialValues({'cloud_extract_enabled': false});
      final before = vaultRevision.value;
      await runCloudExtractions([
        (outcome: _stored(21, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9)),
      ]);
      expect(captured, isEmpty, reason: '开关关了在 runCloudExtractions 入口就该返回,压根没进到每一份的处理里');
      expect(vaultRevision.value, before, reason: '没跑就没有新结果,文档保持导入时落盘的样子');
    });

    test('开着(cloud_extract_enabled=true)→ 这份文档照旧被送进 runCloudExtraction(老行为不变)', () async {
      SharedPreferences.setMockInitialValues({'cloud_extract_enabled': true});
      await runCloudExtractions([
        (outcome: _stored(22, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9)),
      ]);
      expect(captured, isNotEmpty, reason: '开关开着,新加的这道门不该拦下原来就会跑的那条路');
      expect(captured.single, contains('文档 22 退回本地正则'));
    });

    test('没写过这个键(默认)→ 当作开着,跟老版本行为一致', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadCloudExtractEnabled(), isTrue);
      await runCloudExtractions([
        (outcome: _stored(23, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9)),
      ]);
      expect(captured, isNotEmpty);
    });

    test('存读一致:save(false) 之后 load 读到 false;save(true) 之后读到 true', () async {
      SharedPreferences.setMockInitialValues({});
      await saveCloudExtractEnabled(false);
      expect(await loadCloudExtractEnabled(), isFalse);
      await saveCloudExtractEnabled(true);
      expect(await loadCloudExtractEnabled(), isTrue);
    });
  });
}
