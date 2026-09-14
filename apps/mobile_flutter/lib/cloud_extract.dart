/// 导入落库之后的**云抽取**:本机脱敏 → 代理(`POST /v1/extract`)→ 本机校验落盘。
///
/// 三步全在 Rust 侧(FRB `vault_cloud_*`,见 `rust/src/api/vault.rs`),这个文件只
/// 负责串:**决定走哪条臂、把脱敏后的东西发出去、把结果原样带回去**。
///
/// **原文一个字都不出本机。** 发出去的是 `vault_cloud_prepare_extraction` 的产物:
/// 文本档是脱敏文本,图片档是按检测框涂黑后的 JPEG;还原映射(`restore_map_json`)
/// 只在本机 Rust 侧使用,经这里只是原样带回下一次调用,不上传、不落盘。
///
/// **失败一律静默退回本地正则。** 没登录、没网、闸拒发、上游失败、JSON 坏——
/// 每一条都只是"这份文档没有云抽取结果",`parser` 那边照样跑正则出摘要,导入本身
/// 不受任何影响(见 `runCloudExtraction` 的 catch)。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart' as rust_vault;
import 'package:mobile_flutter/vault_boot.dart' show runSerialized;
import 'package:mobile_flutter/vault_events.dart';

/// 「云端整理」开关(键定在 `account.dart`,见 [cloudExtractEnabledKey])。默认
/// true——关掉这台设备的云抽取,不是关登录。读不到就当开着,跟别的"读不到"
/// 兜底不一样:这个开关一旦被用户关过,漏读成"开"会把用户已经关掉的东西又发出去。
/// 但 `getBool` 只会在真没写过时返回 null(未写=从没关过=default true 成立),
/// 写过之后一定读得到那次写的值,所以这条兜底是安全的。
Future<bool> loadCloudExtractEnabled() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(cloudExtractEnabledKey) ?? true;
  } catch (_) {
    return true;
  }
}

Future<void> saveCloudExtractEnabled(bool enabled) async {
  try {
    await (await SharedPreferences.getInstance()).setBool(cloudExtractEnabledKey, enabled);
  } catch (_) {}
}

/// 服务端对图片档 payload(base64 串本身)的上限,与 `services/api/app.py` 的
/// `EXTRACT_IMAGE_MAX_BYTES` 是同一个数。**在本机先量一次**:超了服务端回 413,
/// 白跑一趟几百 KB 的上行——而这一趟在手机上是用户流量和等待时间。
const int extractImageMaxBytes = 2 * 1024 * 1024;

/// 同上,文本档那条(`EXTRACT_TEXT_MAX_BYTES`,按 UTF-8 字节算)。超了没有别的办法
/// ——**不能截断**:`deid::verify` 认的是"原文逐字",截一半只会让整份都过不了校验。
/// 所以直接不发,退回正则。
const int extractTextMaxBytes = 64 * 1024;

/// 抽取用的空闲超时(见 [ApiClient.timeout])。服务端自己等 DeepSeek 的上游超时是
/// 60 秒(`services/api/extract.py` 的 `urlopen(..., timeout=60)`),所以这边必须比
/// 它宽,否则模型还在想、我们先把请求掐了,每次抽取都"失败"退回正则。
const Duration extractTimeout = Duration(seconds: 90);

/// 落盘记的模型版本**兜底值**。正常路径上用的是服务端在响应里回的 `model`
/// (`services/api/extract.py` 的 `run()`,那才是真正跑这次抽取的模型);老版本
/// 服务端不回这个字段时退到这里,值是那两个环境变量的默认值。
const String extractModelVersion = 'deepseek-flash';

/// 这次能不能走**图片档**(把涂黑后的图发出去),生产默认就是它。
///
/// 四个条件缺一不可,而且都是安全条件不是优化条件:
/// * [OcrResult.lines] 非空——涂黑框全靠它算;**没有框就没有涂黑依据**,这时候把图
///   发出去等于把整页 PHI 原样送走。识别不出行的图一律退文本档。
/// * [OcrResult.bytes] 非空——必须是**喂给识别引擎的那份字节**(iOS 上是 Vision
///   拉正之后的)。
/// * `frameW`/`frameH` 是正数——`vault_cloud_prepare_extraction` 拿它们当涂黑框的
///   坐标系尺寸,不是正数它会直接 `bail!`(见那边的文档:传错坐标系会静默漏涂)。
bool canRedactImage(OcrResult ocr) =>
    ocr.lines.isNotEmpty &&
    ocr.bytes.isNotEmpty &&
    ocr.frameW > 0 &&
    ocr.frameH > 0;

/// 脱敏的 K 层和发送前那道终闸(`deid::assert_clean`)要认的名字。
///
/// **是化验单上印的那个名字,不是成员标签。** 成员名是用户给档案起的标签:默认就是
/// 一个字的「我」(`ProfileManager.defaultMemberName`),而 `deid/gate.rs` 要求
/// `chars().count() >= 2` —— 传「我」进去等于整条姓名闸空转;家里叫「爸爸」的成员
/// 同理,闸检的是「爸爸」,纸上印的是「张建国」。
///
/// [ImportOutcomeDto.detectedName] 是 `parser::extract_demographics` 从这份报告文本
/// 里抽出来的患者姓名,就在手边。抽不到才退回成员名(总比什么都不给强)。
///
/// ⚠️ prepare 和 commit **必须拿到同一个值**:commit 那边要用同样的已知身份重算校验
/// 基准,身份不一致 → 占位符编号对不上 → 校验不诚实(见 `vault.rs` 那段长注释)。
String knownNameFor(ImportOutcomeDto outcome, Profile profile) {
  final detected = outcome.detectedName?.trim() ?? '';
  return detected.isNotEmpty ? detected : profile.name;
}

/// 把一份**已经脱敏**的 payload 发给代理,返回响应体原样。
///
/// `/v1/extract` 直接返回抽取结果对象本身(`services/api/extract.py` 的 `run()`
/// 返回 `parsed`),外加一个 `model`(这次真正用的模型名)。Dart **不解读、不改写**
/// 其中任何一个字段:`model` 拿去当落盘的模型版本,其余原样 `jsonEncode` 交给
/// `vault_cloud_commit_extraction` 校验。
Future<Map<String, dynamic>> postExtract(
  ApiClient api, {
  required String mode,
  required String payload,
}) => api.postJson(
  '/v1/extract',
  {'mode': mode, 'schema': 1, 'payload': payload},
);

/// 排队等云抽取的一份文档:落库结果 + 它**当次**的 OCR 结果(涂黑要用其中的
/// `bytes`/`lines`,拿不到第二次)+ **落库时的那个成员**。
///
/// [profile] 不是冗余信息:`outcome.documentId` 是**每个 vault 各自自增的 rowid**,
/// 而 Rust 侧的 vault 是进程级单例。整批抽取要跑好几分钟(每份一次 LLM 往返,最长
/// 90 秒),这中间用户切一次成员,同一个 id 就指向**另一个成员库里同号的文档** ——
/// prepare 会拿新成员的 OCR 原文配旧成员的 knownName 脱敏后发出去,commit 把结果
/// 写进新成员的库。所以捕获的这一份身份要一路带到 prepare/commit 前核对
/// (见 [runCloudExtraction] 里的 `_ifStillCurrent`),脱敏用的姓名和日期偏移
/// 秘密也一律取自它,不再重读「当前成员」。
typedef PendingCloudExtraction = ({
  ImportOutcomeDto outcome,
  OcrResult ocr,
  Profile profile,
});

/// 把这一批排队的文档逐份跑完。**导入流程不等它**(`unawaited`),用户点完
/// 「完成」就走人,结果自己回来。
///
/// **串行,不并发**:每份都是一次 LLM 往返,并发发只会一起变慢,还更容易撞到服务端
/// 的月度 token 天花板(`app.py` 的 `EXTRACT_MONTHLY_TOKEN_CAP`,超了整个账号 429)。
///
/// 每成功落盘一份就 [bumpVaultRevision] —— 概览/趋势/档案屏监听它,于是抽取结果是
/// 一份一份**长出来**的,而不是等整批跑完才一起出现。失败的那份不 bump(没有新东西
/// 可看),也不打断后面的。
Future<void> runCloudExtractions(List<PendingCloudExtraction> pending) async {
  if (pending.isEmpty) return;
  // 开关关了 = 这台设备只用本机识别,连队列都不排——不是"每份都拒发"那种
  // 一次一次的静默失败,是压根不碰网络。
  if (!await loadCloudExtractEnabled()) return;
  await ProfileManager.instance.ensureLoaded();
  var skipped = 0;
  for (final p in pending) {
    // 便宜的预检:已经切走了就连 LLM 那一趟都不用跑。**挡住写错库的不是这一行**,
    // 是 `runCloudExtraction` 里排在 vault 队列内的那两道核对 —— 这里只是省一趟网络
    // 并且把"跳过了几份"数出来。
    if (ProfileManager.instance.current.id != p.profile.id) {
      skipped++;
      continue;
    }
    if (await runCloudExtraction(p.outcome, p.ocr, profile: p.profile) != null) {
      bumpVaultRevision();
    }
  }
  if (skipped > 0) debugPrint('[cloud-extract] 成员已切换,跳过 $skipped 份');
}

/// 只在「当前成员仍是捕获时那个」的前提下,把 [action] 排进 **vault 队列**跑。
/// 切走了就返回 null,一个字节都不碰那个箱子。
///
/// 两件事缺一不可:
/// * **排队**([runSerialized]):开箱(切成员/同步/代拍)也走这条 FIFO,排进去
///   才能保证核对完到动手之间没有另一路把箱子换掉。
/// * **核对**:队列只保证顺序,不保证"箱子没变过"——身份得自己再看一眼。
///   同 `SyncEngine._assertVaultMatches` 的思路。
///
/// 网络往返**留在队列外**:一次 LLM 最长 90 秒,塞进 vault 队列会把开箱、同步、
/// 代拍统统堵住。所以 prepare 和 commit 各排一次,中间那趟自己在外面跑。
///
/// ⚠️ 不可重入:`runSerialized` 里不许再排队,所以 [action] 必须是直接的 FRB 调用。
Future<T?> _ifStillCurrent<T>(
  Profile captured,
  int docId,
  Future<T> Function() action,
) => runSerialized(() async {
  final now = ProfileManager.instance.current.id;
  if (now != captured.id) {
    // 只有成员 id,没有任何病历内容(同 `runCloudExtraction` 的 catch 那条纪律)。
    debugPrint('[cloud-extract] 成员已从 ${captured.id} 切到 $now,跳过文档 $docId');
    return null;
  }
  return action();
});

/// 一份文档落库之后跑云抽取。成功返回这次落盘的条数统计,**任何一步不成都返回
/// null**,调用方不必处理失败——摘要退回本地正则,导入结果不变。
///
/// [ocr] 必须是这份文档**当次**的 OCR 结果(涂黑要用它的 `bytes`/`lines`);
/// [profile] 是**落库那一刻的成员**(见 [PendingCloudExtraction]),脱敏用的姓名、
/// 日期偏移秘密、以及动 vault 之前的身份核对全都认它,过程中一次都不重读「当前
/// 成员」;[api] 只给测试注入,生产留空走当前账号会话。
Future<CloudExtractionResultDto?> runCloudExtraction(
  ImportOutcomeDto outcome,
  OcrResult ocr, {
  required Profile profile,
  ApiClient? api,
}) async {
  final docId = outcome.documentId;
  if (docId == null) return null;
  // 秘密缺了就没有稳定的日期偏移(`ProfileManager.ensureLoaded` 会补,这里只是不赌)。
  if (profile.secretHex.isEmpty) return null;
  // 没登录 = 没这个功能。不是错误,不提示,照常走本地那条路。
  final session = AccountSession.instance;
  // `background`,不是 `forSession`:抽取失败了最多是"这份文档没有云抽取结果",
  // **没有资格把用户整个账号态清掉**(见 `ApiClient.background`)。
  final client = api ??
      (session.access == null ? null : ApiClient.background(session, timeout: extractTimeout));
  if (client == null) return null;

  try {
    // 一个值,prepare 和 commit 共用(见 [knownNameFor] 的 ⚠️)。取自**捕获的**
    // 那个成员:重读「当前成员」的话,切了成员就会拿甲的名字给乙的报告脱敏。
    final knownName = knownNameFor(outcome, profile);

    final image = canRedactImage(ocr);
    // **一次 prepare 供两条臂用**:`payload_text` 与 `lines` 无关,`lines` 只影响
    // `paint`。所以图片档中途退回文本档时,直接用这次的 `payload_text` 即可——它与
    // `restore_map_json` 天然配套,不用再 prepare 一次(那会重算占位符编号)。
    //
    // 身份只给得出名字:App 目前不存证件号/手机号(`Profile` 里没有,病历解析出的
    // `PatientProfileDto` 也没有),所以 K 层只认名字,证件号/手机号由 deid 的 A/P
    // 层按锚点和模式兜。哪天真有了这两项,补在这两个参数上即可。
    final req = await _ifStillCurrent(
      profile,
      docId,
      () => rust_vault.vaultCloudPrepareExtraction(
        documentId: docId,
        lines: image ? ocr.lines : const [],
        knownName: knownName,
        profileSecretHex: profile.secretHex,
        pageW: image ? ocr.frameW : 0,
        pageH: image ? ocr.frameH : 0,
      ),
    );
    if (req == null) return null;

    String? redacted;
    if (image) {
      try {
        final jpg = await rust_vault.vaultCloudRedactImage(
          bytes: ocr.bytes,
          paint: req.paint,
        );
        final b64 = base64Encode(jpg);
        if (b64.length <= extractImageMaxBytes) redacted = b64;
      } catch (e) {
        // 涂黑这一步不可用(非 iOS/安卓构建、模型没就绪、图解不开)→ 退文本档。
        debugPrint('[cloud-extract] 涂黑失败,退文本档:$e');
      }
    }
    final mode = redacted == null ? 'text' : 'image';
    final payload = redacted ?? req.payloadText;
    // 图片档在涂黑那一步已经量过;文本档在这里量。超限的话服务端一律 413
    // (`app.py` 的 `_MAX_BYTES` 两条),白跑一趟上行。
    if (mode == 'text' && utf8.encode(payload).length > extractTextMaxBytes) {
      return null;
    }

    // 这一趟(最长 90 秒)在 vault 队列**外面**跑,见 [_ifStillCurrent]。
    final result = await postExtract(client, mode: mode, payload: payload);
    // 校验基准由 Rust 侧自己重算(不信这里传的任何文本),身份参数必须与 prepare
    // 那次逐字相同,否则占位符编号对不上、校验就不诚实了。
    return await _ifStillCurrent(
      profile,
      docId,
      () => rust_vault.vaultCloudCommitExtraction(
        documentId: docId,
        mode: mode,
        // 这次真正跑抽取的模型由服务端说了算(环境变量,运维随时能换);老版本
        // 服务端不回这个字段时才退到本地兜底值。
        modelVersion: (result['model'] as String?) ?? extractModelVersion,
        llmJson: jsonEncode(result),
        restoreMapJson: req.restoreMapJson,
        knownName: knownName,
      ),
    );
  } catch (e) {
    // ⚠️ **绝不进埋点**(异常文本可能带文档内容片段)。`debugPrint` 在 release 里
    // 并不会被剥离,一样会进系统日志 —— 这里打印的东西必须自己就是安全的:闸的错误
    // 只报类别不回显身份(`deid/gate.rs` 有测试钉),网络/解析异常带的是**脱敏后**的
    // 响应片段。要往这行里加内容的话,先确认新加的东西也满足这一条。
    debugPrint('[cloud-extract] 文档 $docId 退回本地正则:$e');
    return null;
  }
}
