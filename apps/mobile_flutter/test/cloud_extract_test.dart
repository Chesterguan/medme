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
import 'package:mobile_flutter/vault_boot.dart' show resetVaultQueueForTest;
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

/// 「落库那一刻的成员」——真实路径上由 `import_flow` 从 [ProfileManager] 捕获,
/// 所以测试也得拿**当前**那个,否则每一份都会被新加的身份核对跳掉。
Future<Profile> _currentProfile() async {
  await ProfileManager.instance.ensureLoaded();
  return ProfileManager.instance.current;
}

/// 「落库那一刻的箱子」。默认 `readCurrentVaultRoot` 仍是 FRB 那个(host 上必抛),
/// 所以这个值只在**显式注入** reader 的那几条用例里才真的被比较。
const _root = '/docs/profiles/p-1/vault';

void main() {
  // 同 api_client_test.dart:测试 binding 会装一个假的 HttpOverrides,装上之后
  // 回环服务器收不到任何请求,所以初始化完立刻摘掉。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  // 云抽取现在把 prepare/commit 排进 `vault_boot` 的 FIFO 队列(评审 C2),而那条
  // 队列是模块级单例——上一个用例挂在它尾巴上的收尾 `.then()` 可能永远不在这个
  // 用例的 zone 里推进,下一个用例就会干等到超时(见 `resetVaultQueueForTest`)。
  setUp(resetVaultQueueForTest);
  tearDown(resetVaultQueueForTest);

  // 「箱子还是不是导入时那个」这道核对要问 Rust(host 上必抛),只有注入才钉得住。
  // 谁注入谁负责还回去,别漏给下一个用例。
  final realRootReader = readCurrentVaultRoot;
  tearDown(() => readCurrentVaultRoot = realRootReader);

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
      final me = await _currentProfile();
      await runCloudExtractions([
        (outcome: _stored(1), ocr: const OcrResult('a', 0.9), profile: me, vaultRoot: _root),
        (outcome: _stored(2), ocr: const OcrResult('b', 0.9), profile: me, vaultRoot: _root),
        (outcome: _stored(3), ocr: const OcrResult('c', 0.9), profile: me, vaultRoot: _root),
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
      final r = await runCloudExtraction(
        _stored(11, detectedName: '张建国'),
        const OcrResult('白细胞 5.6', 0.9),
        profile: await _currentProfile(),
        vaultRoot: _root,
        api: api,
      );
      expect(r, isNull, reason: '不抛,只是没有云抽取结果');
      expect(hits, 0, reason: '拒发就是拒发:prepare 没过,代理那一步压根不该发生');
    });

    test('整批里有一份拒发,后面的照样跑完,也不 bump', () async {
      final before = vaultRevision.value;
      final me = await _currentProfile();
      await runCloudExtractions([
        (outcome: _stored(12), ocr: const OcrResult('a', 0.9), profile: me, vaultRoot: _root),
        (outcome: _stored(13), ocr: const OcrResult('b', 0.9), profile: me, vaultRoot: _root),
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
        profile: await _currentProfile(),
        vaultRoot: _root,
      );
      expect(r, isNull);
    });

    test('没登录 → null,不发、不报错', () async {
      // AccountSession.instance.access 未登录时为 null;不注入 api 就该在这一步
      // 直接返回,碰不到 FRB(测试环境里没有 Rust 库,碰到就会炸)。
      final r = await runCloudExtraction(
        ImportOutcomeDto(name: 'a.jpg', sourceFileId: 1, status: 'stored', documentId: 7, pagesWithoutText: _noPages),
        ocr,
        profile: await _currentProfile(),
        vaultRoot: _root,
      );
      expect(r, isNull);
    });

    test('捕获的成员没有 secretHex → null(没有稳定的日期偏移就不发)', () async {
      final r = await runCloudExtraction(
        _stored(9),
        ocr,
        profile: const Profile(id: 'p-x', name: '张建国'),
        vaultRoot: _root,
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
        (outcome: _stored(21, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9), profile: await _currentProfile(), vaultRoot: _root),
      ]);
      expect(captured, isEmpty, reason: '开关关了在 runCloudExtractions 入口就该返回,压根没进到每一份的处理里');
      expect(vaultRevision.value, before, reason: '没跑就没有新结果,文档保持导入时落盘的样子');
    });

    test('开着(cloud_extract_enabled=true)→ 这份文档照旧被送进 runCloudExtraction(老行为不变)', () async {
      SharedPreferences.setMockInitialValues({'cloud_extract_enabled': true});
      await runCloudExtractions([
        (outcome: _stored(22, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9), profile: await _currentProfile(), vaultRoot: _root),
      ]);
      expect(captured, isNotEmpty, reason: '开关开着,新加的这道门不该拦下原来就会跑的那条路');
      expect(captured.single, contains('文档 22 退回本地正则'));
    });

    test('没写过这个键(默认)→ 当作开着,跟老版本行为一致', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadCloudExtractEnabled(), isTrue);
      await runCloudExtractions([
        (outcome: _stored(23, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9), profile: await _currentProfile(), vaultRoot: _root),
      ]);
      expect(captured, isNotEmpty);
    });

    /// 评审 I3:开关原先只在**每批开头**读一次 —— 用户在一批导入跑到一半时去设置里
    /// 关掉,剩下的几份照发。现在每份都重读。
    test('一批跑到一半关掉 → 后面那份不再送出去(按份读,不是按批读)', () async {
      SharedPreferences.setMockInitialValues({'cloud_extract_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      final me = await _currentProfile();
      // 第一份进到 `runCloudExtraction` 内部时必打那行 debugPrint(见组注释)——
      // 就在那一刻关掉开关,正是"用户在一批跑到一半时去设置里关了云端整理"。
      // 不 await:`setBool` 同步更新 SharedPreferences 的本地缓存,下一份读到的
      // 就是 false(见 shared_preferences 的 `_setValue`)。
      debugPrint = (String? message, {int? wrapWidth}) {
        captured.add(message);
        if (message != null && message.contains('文档 26')) {
          prefs.setBool(cloudExtractEnabledKey, false);
        }
      };
      await runCloudExtractions([
        (outcome: _stored(26, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9), profile: me, vaultRoot: _root),
        (outcome: _stored(27, detectedName: '张建国'), ocr: const OcrResult('白细胞 5.6', 0.9), profile: me, vaultRoot: _root),
      ]);
      expect(captured.where((m) => m!.contains('文档 26')), hasLength(1), reason: '第一份照常跑');
      expect(
        captured.any((m) => m!.contains('文档 27')),
        isFalse,
        reason: '开关在这一批中途被关掉,第二份就不该再被送进 runCloudExtraction',
      );
    });

    test('存读一致:save(false) 之后 load 读到 false;save(true) 之后读到 true', () async {
      SharedPreferences.setMockInitialValues({});
      await saveCloudExtractEnabled(false);
      expect(await loadCloudExtractEnabled(), isFalse);
      await saveCloudExtractEnabled(true);
      expect(await loadCloudExtractEnabled(), isTrue);
    });
  });

  /// 评审 C2:整批抽取要跑好几分钟(每份一次 LLM 往返,最长 90 秒),这中间用户
  /// 切一次成员——而 `documentId` 是**每个 vault 各自自增的 rowid**,vault 又是
  /// 进程级单例。旧代码每轮重读「当前成员」,于是 prepare 会拿**新成员**库里同号
  /// 文档的 OCR 原文、配**旧成员**的 knownName 脱敏后发出去,commit 也写进新成员
  /// 的库。现在捕获的成员一路带到 prepare/commit 前核对。
  ///
  /// 同上一组:host 上没有 Rust 库,`vault_cloud_*` 一律抛 → 只要这份进到了
  /// `runCloudExtraction` 的 FRB 那步,那条 catch 的 debugPrint 就一定响。于是
  /// 「有没有响」正好区分「被身份核对挡在动 vault 之前」和「照常走到了 vault」。
  group('C2 成员切换:捕获的成员对不上就不碰 vault', () {
    final captured = <String?>[];
    late DebugPrintCallback originalDebugPrint;
    late String originalCurrentId;

    setUp(() async {
      captured.clear();
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => captured.add(message);
      SharedPreferences.setMockInitialValues({'cloud_extract_enabled': true});
      final support = await Directory.systemTemp.createTemp('medme-cloud-extract-c2');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      await ProfileManager.instance.ensureLoaded();
      originalCurrentId = ProfileManager.instance.currentId.value;
      AccountSession.instance.access = 'test-token';
      AccountSession.instance.accountId = 'acc-test';
    });
    tearDown(() async {
      debugPrint = originalDebugPrint;
      AccountSession.instance.access = null;
      AccountSession.instance.accountId = null;
      // `ProfileManager` 是单例,别把"当前是谁"留给下一个用例。
      await ProfileManager.instance.switchTo(originalCurrentId);
    });

    test('prepare 之前切走 → 不碰 vault、不发网络', () async {
      final captured0 = await _currentProfile();
      // `create` 会把 current 切到新建的那个成员(见它的文档)= 用户切了成员。
      final other = await ProfileManager.instance.create('李秀英');
      expect(ProfileManager.instance.current.id, other);

      final r = await runCloudExtraction(
        _stored(31, detectedName: '张建国'),
        const OcrResult('白细胞 5.6', 0.9),
        profile: captured0,
        vaultRoot: _root,
      );
      expect(r, isNull);
      expect(
        captured.single,
        contains('成员已从 ${captured0.id} 切到 $other,跳过文档 31'),
      );
      expect(
        captured.any((m) => m!.contains('退回本地正则')),
        isFalse,
        reason: '压根没走到 FRB/vault 那一步,不是"跑了但失败了"',
      );
    });

    test('整批里只跳过成员对不上的那几份,当前成员那份照常跑', () async {
      final me = await _currentProfile();
      final stale = const Profile(id: 'p-已经不是当前', name: '张建国', secretHex: 'ab');
      await runCloudExtractions([
        (outcome: _stored(32, detectedName: '张建国'), ocr: const OcrResult('a', 0.9), profile: me, vaultRoot: _root),
        (outcome: _stored(33, detectedName: '张建国'), ocr: const OcrResult('b', 0.9), profile: stale, vaultRoot: _root),
      ]);
      expect(captured.any((m) => m!.contains('文档 32')), isTrue, reason: '当前成员那份照常跑');
      expect(captured.any((m) => m!.contains('文档 33')), isFalse, reason: '对不上的那份连网络都不用跑');
      expect(captured.last, contains('成员已切换,跳过 1 份'));
    });

    /// 复审 round 2(Important):只比成员 id 还留着一扇门 —— `openProxyPatientVault`
    /// (医生代拍)换掉的是进程级 vault,**根本不碰 `ProfileManager`**;A→B→A
    /// 连切两次同理。患者模式导入 → 后台抽取跑着 → 医生切去代拍开始采集,排在队列里
    /// 的 prepare 就会打在**病人的箱子**上(`documentId` 是各库自增 rowid)。
    test('成员没变但箱子被换掉(代拍)→ 不碰 vault', () async {
      final me = await _currentProfile();
      readCurrentVaultRoot = () async => '/docs/proxy/patient-7/vault';

      final r = await runCloudExtraction(
        _stored(34, detectedName: '张建国'),
        const OcrResult('白细胞 5.6', 0.9),
        profile: me,
        vaultRoot: _root,
      );
      expect(r, isNull);
      expect(captured.single, contains('保险箱已不是导入时那个'));
      expect(captured.single, contains('跳过文档 34'));
      expect(
        captured.any((m) => m!.contains('退回本地正则')),
        isFalse,
        reason: '连 FRB 都没调:被队列里那道核对挡在动手之前',
      );
    });

    test('箱子没换 → 这道新核对不拦原来就会跑的那条路', () async {
      final me = await _currentProfile();
      readCurrentVaultRoot = () async => _root;

      final r = await runCloudExtraction(
        _stored(35, detectedName: '张建国'),
        const OcrResult('白细胞 5.6', 0.9),
        profile: me,
        vaultRoot: _root,
      );
      expect(r, isNull, reason: 'host 上没有 Rust 库,prepare 照样抛');
      expect(captured.single, contains('文档 35 退回本地正则'), reason: '走到了 FRB 那一步');
    });
  });
}
