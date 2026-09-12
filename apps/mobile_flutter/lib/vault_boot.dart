import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/src/rust/api/vault_sync.dart' show syncOpenProfileVault, syncCurrentVaultIsKeyed;
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/icloud_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/vault_events.dart';

/// Rust 侧的 vault 是**进程级单例**:开一个箱子就顶掉上一个。医生代拍让「谁被顶掉」
/// 变成安全问题(代拍病人的箱子顶掉医生自己的档案),而各调用点的 `await` 先后并不
/// 保证 FFI 到达顺序 —— 「退出代拍时换回医生档案」和「紧接着开下一个病人」一旦反序,
/// 采集就会写进医生自己的档案。
///
/// 所以**所有开箱都排进这一条 FIFO 队列**:先发出的先生效,与调用方是否 await 无关。
/// 这是顺序保证;写入前还有一道内容校验,见 [ensureProxyVaultOpen]。
Future<void> _vaultQueue = Future<void>.value();

/// 本次启动开箱成没成(由 `main.dart` 的 `VaultBootstrap` 在开箱后写入)。
///
/// 存在的唯一原因:**首启同意页要补发一条 `app_open`**(本次启动那条发在同意门
/// 之前、统计还关着,被丢了),而它得带上真实的 `vault_ok`。那里曾硬编码 `true`,
/// 于是「首次运行开箱失败」在数据里永远是好的 —— 而 `app_open × vault_ok` 那张图
/// 正是为了看见开箱失败才建的。见 `screens/first_run_consent.dart`。
bool vaultOpenedOkThisLaunch = true;

/// 把任意一段"会碰进程级 vault"的操作排进同一条 FIFO 队列——不只是开箱本身。
/// 见 Task 15 review I2:`SyncEngine` 的推拉、按需补对象也要走这条队列,不能
/// 只有"开箱"排队;开箱和同步各自独立排队的话,两者之间没有互斥——同步的网络
/// 往返进行到一半,另一路把箱子切换掉,写入就会落进错的档案。
///
/// 排队保证的是**执行顺序**,不是"写之前箱子没变过"这件事本身——后者还要靠
/// 调用方在真正写入前再核一遍身份(`SyncEngine._assertVaultMatches`),两者
/// 配合:队列挡住"同一时刻有两段代码在动 vault",身份核对挡住"万一哪天有条
/// 路径没走队列"这种意外。
/// 「此刻这段代码是不是正跑在队列里」—— 用 Zone 而不是一个模块级布尔:布尔分不清
/// 「在 action 的调用栈里又排了一次」(重入,死锁)和「另一路在 action 跑着的时候
/// 正常排队」(合法,而且是这条队列存在的理由)。Zone 值只传给 action 自己及它
/// 派生出的异步回调。
final Object _inSerializedZoneKey = Object();

Future<T> runSerialized<T>(Future<T> Function() action) {
  // **不可重入**(复审 M15)。违反它的症状是死锁:新排的这一段挂在 `_vaultQueue`
  // 尾巴上,而尾巴正是外面那一段 —— 它等里面,里面等它。真机上看起来是"点了没反应、
  // 永远转圈",而原因在代码里一个字都不显眼。所以在 debug 下当场炸
  // (`assert` 在 release 里整段剥掉,生产行为一字不变;队列里要顺手开箱的调用方
  // 用不排队的那个本体,见 [openCurrentProfileVaultUnserialized])。
  assert(
    Zone.current[_inSerializedZoneKey] == null,
    'runSerialized 不可重入:已经在 vault 队列里了,再排一次就是自己等自己。'
    '队列里要开箱请调 openCurrentProfileVaultUnserialized。',
  );
  final done = _vaultQueue.then(
    (_) => runZoned(action, zoneValues: {_inSerializedZoneKey: true}),
  );
  // 队列本身吞掉异常(否则一次失败会毒死后面所有排队的操作);异常照常抛给调用方。
  _vaultQueue = done.then((_) {}, onError: (_) {});
  return done;
}

/// 测试专用:把队列砍回一个立即完成的 `Future`,不管上面挂着什么。
///
/// `_vaultQueue` 是模块级单例,`flutter test` 里一个测试文件的多个 `testWidgets`
/// 共用同一份——`SyncEngine` 走 [runSerialized] 之后,一个用例里排的操作即使
/// 已经"跑完"(该用例自己的 `pumpAndSettle()` 也确实等到了那次调用的结果),
/// 挂在 `_vaultQueue` 链条尾巴上、把队列本身继续往前推的那个收尾 `.then()`
/// 仍然可能落在这个用例自己的 fake-async/测试 zone 里没有真正推进——下一个用例
/// 再调 [runSerialized] 时就会追加在一个再也不会完成的 `Future` 后面,
/// `pumpAndSettle` 干等到超时(见 Task 15 review 修复 I2 时踩到的坑)。
/// 会用到 [runSerialized](`SyncEngine`/`vault_boot` 自己)的测试文件,在
/// `setUp`/`tearDown` 里调一下这个,把队列清成互不相干的状态。
@visibleForTesting
void resetVaultQueueForTest() {
  _vaultQueue = Future<void>.value();
}

/// 这个成员该走哪条开箱路径——纯函数,不碰任何 IO/FFI,只看有没有
/// [Profile.cloudId] 以及有没有拿到对应的档案密钥。抽出来是为了让这条判断能在
/// 不加载 Rust 原生库的 `flutter test` 里钉住——[openCurrentProfileVault] 本身
/// 调 FRB,测试环境一调就崩。
///
/// **没有 [Profile.cloudId]** → [VaultOpenPlan.unkeyed](原路径,一字不改,
/// 不登录 = 现状)。**有 cloudId 但拿不到密钥**(账号没解锁/密钥被清过)→
/// [VaultOpenPlan.locked]——这是一个必须显式拒绝的状态,**不能**悄悄退化成
/// unkeyed 打开:那样写进去的事件没有账号密钥的 MAC,下次真正 keyed 打开时会被
/// `probe_key_mismatch`/校验链判定为「不可信」,永久隔离在这台设备上写的这一段
/// 历史。**有 cloudId 且有密钥** → [VaultOpenPlan.keyed]。
enum VaultOpenPlan { unkeyed, keyed, locked }

@visibleForTesting
VaultOpenPlan planVaultOpen(Profile p, Uint8List? profileKey) {
  if (p.cloudId == null) return VaultOpenPlan.unkeyed;
  return profileKey == null ? VaultOpenPlan.locked : VaultOpenPlan.keyed;
}

/// 档案有 [Profile.cloudId] 但本机解不出对应的档案密钥(账号还没解锁,或密钥被
/// 清过)——[openCurrentProfileVault] 显式拒绝打开,而不是悄悄退回不加密的本地
/// 打开(见 [VaultOpenPlan] 文档)。调用方(账号屏/设置页)应该提示用户去解锁账号。
class ProfileLocked implements Exception {
  const ProfileLocked(this.cloudId);
  final String cloudId;

  /// C4:这句话原来是「这个档案已绑定云同步,但本机还没有它的密钥——需要解锁账号
  /// 才能打开(cloudId=prf_7f3a…)」。它**是启动时那块白屏上最显眼的一段字**,而
  /// 它里面每一个词都是我们自己的词汇:"绑定云同步"、"档案密钥"、"解锁账号",
  /// 末尾还挂着一串服务端内部 id。老人看完只知道打不开,不知道该做什么。
  ///
  /// 现在说两件事:为什么打不开(在云端是加密的)、要他做什么(输口令)。
  /// [cloudId] 仍然留在字段里(排查时用、也是这个异常的身份),但**只进 debug
  /// 日志**(见 [openCurrentProfileVault] 的 locked 分支),不进给用户看的字。
  @override
  String toString() => '你的病历在云端是加密的,需要你的口令才能打开。';
}

/// 打开「当前成员」的保险箱:按 [ProfileManager] 组合本机/iCloud 路径。启动 +
/// 切换成员后都调它,也是 `SyncEngine.enableCloud`(见 `sync_engine.dart`)开通
/// 云同步后重开箱唯一走的入口——**所有开箱都必须经过这个函数**(从而经过下面的
/// FIFO 队列),不许在别处直接调 `syncOpenProfileVault`。
///
/// data 目录(设备 id、iCloud 全局开关标记、导入临时文件)所有成员共用——iCloud 是
/// 全局开关(开了对所有成员生效);派生库则每成员独立(见 Rust `resolve_vault_paths`)。
Future<void> openCurrentProfileVault() => runSerialized(openCurrentProfileVaultUnserialized);

/// [openCurrentProfileVault] 的本体,**不自己排队**。给"已经在队列里、还要顺手开一次
/// 箱"的调用方用(见 [removeProfileAndReopenImpl] 的 M11 说明)——
/// `runSerialized` 不可重入:在队列里再调一次 `openCurrentProfileVault`,那次会排在
/// 自己这一段**后面**,于是互相等,死锁。
///
/// **除了那一处,任何人都该调 [openCurrentProfileVault]**(排队的那个)。不是
/// `@visibleForTesting`:`removeProfileAndReopen` 传的就是它(复审 M15)。
Future<void> openCurrentProfileVaultUnserialized() async {
  await ProfileManager.instance.ensureLoaded();
  final p = ProfileManager.instance.current;
  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final support = (await getApplicationSupportDirectory()).path;
  final key = p.cloudId == null ? null : await AccountSession.instance.profileKey(p.cloudId!);

  switch (planVaultOpen(p, key)) {
    case VaultOpenPlan.locked:
      // cloudId 只进 debug 日志(C4)——`assert` 的表达式在 release 里整个被剥掉。
      assert(() {
        debugPrint('ProfileLocked: cloudId=${p.cloudId}');
        return true;
      }());
      throw ProfileLocked(p.cloudId!);
    case VaultOpenPlan.keyed:
      await syncOpenProfileVault(
        docsDir: ProfileManager.instance.localBase(docsRoot),
        dataDir: support,
        profileKey: key!,
      );
      // 硬校验:keyed 和原路径开的是同一个目录,唯一能分辨"这次真的走对了分支"
      // 的办法是问 Rust 自己——同 [ensureProxyVaultOpen] 的思路,不靠调用点的
      // 分支逻辑自证。
      if (!await syncCurrentVaultIsKeyed()) {
        throw StateError('云档案 keyed 开箱后状态核对失败:期望 keyed,实际不是');
      }
    case VaultOpenPlan.unkeyed:
      final containerRoot = await IcloudBridge.containerPath();   // ← 原路径,一字不改
      await openVault(
        docsDir: ProfileManager.instance.localBase(docsRoot),
        dataDir: support,
        icloudContainerDir: ProfileManager.instance.containerBase(containerRoot),
      );
      if (await syncCurrentVaultIsKeyed()) {
        throw StateError('本地档案开箱后状态核对失败:不应为 keyed');
      }
  }
}

/// 打开某个**代拍病人**的保险箱(医生模式)。与「切成员」不是一回事:代拍病人不在
/// [ProfileManager] 里,走 [ProxyPatientManager] 的独立命名空间。
///
/// `dataDir` 用该病人自己的 `data/`:每个病人一个一次性 device id(不带医生的设备
/// 身份),且那里没有 `icloud_enabled` 标记 —— 别人的病历永远不进医生的 iCloud。
Future<void> openProxyPatientVault(String patientId) =>
    runSerialized(() async {
      final base = await ProxyPatientManager.instance.baseDir(patientId);
      await openVault(
        docsDir: base,
        dataDir: '$base/data',
        icloudContainerDir: null,
      );
    });

/// **写入前的硬校验**:确认此刻进程里开着的确实是 [patientId] 这个代拍病人的箱子。
/// 不是就重开;重开后仍不是就抛 —— 宁可这次采集失败,也绝不把病人的材料写进医生
/// 自己的档案。代拍流程每次落库/交付前都过这一关(见 `proxy_intake_flow.dart`),
/// 于是「顺序对不对」不再是靠注释维持的约定,而是每次动手前实际比对过的事实。
Future<void> ensureProxyVaultOpen(String patientId) async {
  final expected = '${await ProxyPatientManager.instance.baseDir(patientId)}/vault';
  // 一个箱子都没开时 `currentVaultRoot` 会抛(Rust 的「保险箱尚未打开」)——那也只是
  // 「不是这个病人的箱子」的一种,照样往下走去开,不该当成错误中止。
  String? actual;
  try {
    actual = await currentVaultRoot();
  } catch (_) {
    actual = null;
  }
  if (actual == expected) return;

  await openProxyPatientVault(patientId);
  final now = await currentVaultRoot();
  if (now != expected) {
    throw StateError('代拍保险箱未就位(期望 $expected,实际 $now),已中止写入');
  }
}

/// 切换到某成员(按 id)并重开其保险箱,然后通知各屏刷新。
///
/// **开箱失败(最常见是 [ProfileLocked])必须把"当前是谁"也退回去**,不能留在
/// 「`ProfileManager.currentId` 已经指向 B、但进程里那个箱子其实还是 A 的」这个
/// 不一致状态——那样接下来任何一次写入(手动录入/导入)都会把 B 的东西写进 A 的
/// 保险箱。异常照原样抛给调用方(UI 据此展示消息),不吞。
///
/// [revertTo]:回退到哪个成员。默认是"调用这个函数的那一刻 `currentId` 指着的
/// 那个",对"从 A 切到 B"这种场景就是对的。但有一类调用方在切换**之前**已经动过
/// `currentId` 了——`Grants.redeem` 里 `ProfileManager.create()` 自己会把 current
/// 切到新建的那个成员(见它的文档),于是等走到这里时"原来那个"早就不是 current
/// 了,默认值会把"回退"变成一次空操作。那种调用方显式把真正的起点传进来。
Future<void> switchProfileAndReopen(String id, {String? revertTo}) =>
    switchProfileAndReopenImpl(id, reopen: openCurrentProfileVault, revertTo: revertTo);

/// [switchProfileAndReopen] 的本体,`reopen` 抽成参数是为了让"开箱失败要回退"
/// 这条契约能在**不带 Rust 原生库**的 `flutter test` 里被钉住(见
/// `test/switch_profile_and_reopen_test.dart`)——同 [runWipeSequence] 的套路。
/// 产品代码里的唯一调用点就是 [switchProfileAndReopen],传的永远是真实现。
@visibleForTesting
Future<void> switchProfileAndReopenImpl(
  String id, {
  required Future<void> Function() reopen,
  String? revertTo,
}) async {
  final previousId = revertTo ?? ProfileManager.instance.currentId.value;
  await ProfileManager.instance.switchTo(id);
  try {
    await reopen();
  } catch (_) {
    // 回退:把 currentId 换回原来那个、重开它的箱子——这一步本身也可能失败
    // (比如原成员这会儿也解不开了),但不能因此掩盖**原始**错误,所以吞掉回退
    // 失败、原样 rethrow 第一次的异常。
    try {
      await ProfileManager.instance.switchTo(previousId);
      await reopen();
    } catch (_) {}
    rethrow;
  }
  bumpVaultRevision();
}

/// 「清空所有数据」= 恢复出厂:清**所有成员、所有位置**的 vault 数据(本机 + iCloud
/// 容器)+ 份数缓存 + 待确认,重置成单一默认档案,最后重开一个空箱子。
///
/// 实现是 [runWipeSequence];顺序契约与踩过的坑写在那上面。
Future<void> wipeAllData() async {
  await runWipeSequence(
    docsRoot: (await getApplicationDocumentsDirectory()).path,
    containerRoot: await IcloudBridge.containerPath(),
    releaseActiveVault: resetVault,
    openFreshRootVault: openCurrentProfileVault,
  );
  bumpVaultRevision();
}

/// [wipeAllData] 的本体。三个副作用抽成参数,只为让顺序契约能在**不带 Rust 原生库**
/// 的 `flutter test` 里被钉住(见 `test/wipe_all_data_test.dart`);产品代码里的唯一
/// 调用点就是 [wipeAllData],传的永远是真实现。
///
/// ## 顺序契约:**先松手,再删盘,最后开箱 —— 开箱永远是最后一步**
///
/// 这条契约不是风格偏好,它对应一个真实事故(BUG-3)。原先的顺序是「开箱 → 清箱 →
/// 删目录」,而删掉的目录里就包含刚开好的那个箱子:
///
/// * Rust 的 `open_vault` 会 `create_dir_all` 出目录并在里面攥着 sqlite 连接;
/// * **每个**成员 —— 包括恢复出厂后的 root `p-1` —— 都住在 `<root>/profiles/<id>/`
///   ([ProfileManager.localBaseOf];那个类的文档写着「成员一律平等,路径规则只有
///   一条」)。所以 `profiles/` 不是「**子**成员目录」,它是**全部**成员目录,含当前
///   这个。旧注释把它写成「子成员」,那句话是错的,也正是这个 bug 的来源。
///
/// 反序的后果不是「删不干净」,而是**箱子开在一个已经不存在的目录上**:读走的是已
/// 打开的连接/内存态,所以「已清空」这个反馈是真的;而之后每一次**写**(手动录入、
/// 导入、载入示例)都炸在 `No such file or directory`,直到 App 重启。用户此刻恰好
/// 处在「我刚清空,准备重新开始录」的状态。
///
/// 于是三步各自的理由:
///
///   ① [releaseActiveVault](`reset_vault`)—— 要的是它前半截「正常关连接 + 删 db/wal」,
///      让紧接着的 `rm -rf` 不落在一个还开着的 sqlite 上。它顺手在原地重开的那个空箱子
///      随即被 ② 删掉,不浪费也不留痕。**这一步允许失败**:本次启动压根没开过箱时
///      (`VaultBootstrap` 开箱失败)Rust 会抛「保险箱尚未打开」,那时本来也没有句柄
///      要松开 —— 不能因此让整个「清空」半途而废。
///   ② 删磁盘上**所有位置**:本机与 iCloud 容器两个根下的 `profiles/`(全部成员)
///      + 遗留的 `vault/`(多成员布局之前 root 待过的老位置)。两个根都删的理由:关掉
///      iCloud 时容器副本会被 `disable_icloud_sync` 保留,只删本机的话数据还躺在容器里,
///      再开 iCloud 会被 adopt 回来 —— 用户以为清干净了,过一阵又冒出来(评审 Critical)。
///      两处都无条件删,不再看 `icloudStatus()`:「哪一处是活跃的」这个判断在这里没有
///      意义,反正两处都要没。
///   ③ [openFreshRootVault] —— 目录删完之后才开,`open_vault` 的 `create_dir_all`
///      会把 `profiles/p-1/vault` 重新建出来,进程里于是攥着一个真实存在、且是空的箱子。
///
/// 加新步骤时守住这条:**任何 `rm` 都必须排在开箱之前**。
@visibleForTesting
Future<void> runWipeSequence({
  required String docsRoot,
  required String? containerRoot,
  required Future<void> Function() releaseActiveVault,
  required Future<void> Function() openFreshRootVault,
}) async {
  Future<void> rmDir(String path) async {
    final d = Directory(path);
    if (await d.exists()) await d.delete(recursive: true);
  }

  // 注册表恢复出厂(current→默认 root)+ 清待确认。必须在开箱之前 —— 否则 ③ 开的
  // 会是清空之前那个成员的箱子。
  await ProfileManager.instance.factoryReset();
  await ReviewState.instance.clearAll();

  // ① 松手。
  try {
    await releaseActiveVault();
  } catch (_) {
    // 没开过箱 → 没有句柄要松开,继续删。见上面 ① 的说明。
  }

  // ② 删盘。
  for (final root in [
    docsRoot,
    if (containerRoot != null) '$containerRoot/Documents',
  ]) {
    await rmDir('$root/profiles');
    await rmDir('$root/vault');
  }

  // ③ 开箱 —— 最后一步。
  await openFreshRootVault();
}

/// 用报告里识别到的患者姓名,给还没定过名的默认档案自动命名。幂等:只在首次未命名时
/// 生效。**不再需要迁移任何状态** —— 目录与 ReviewState 的键都认 id,改名只是换标签。
Future<void> autoNameCurrentProfileFrom(String? detectedName) async {
  if (detectedName == null || detectedName.trim().isEmpty) return;
  await ProfileManager.instance.maybeAutoNameCurrent(detectedName);
}

/// 删除一个成员:成员表移除 + **本机与 iCloud 容器两处**的数据目录都删掉,再重开
/// (删的若是当前成员,`remove` 已把 current 切回第一个)并刷新各屏。这是**唯一**
/// 移除成员的入口(手动删成员的设置页、`Grants.purgeExpired` 清过期授权都走这
/// 一条),云档案的密钥(`pk_<cloudId>`)也在这里统一清掉——不分别在每个调用方
/// 补一遍,免得漏掉哪一条路径(见 Task 16 item 3)。
///
/// 两处都删的理由与 [wipeAllData] 第 4 步同源:关掉 iCloud 时容器副本会被保留,
/// 只删活跃那处的话,数据还在容器里躺着,再开 iCloud 会被 adopt 回来 —— 用户以为
/// 删干净了,过一阵又冒出来。
///
/// 删到只剩一个时不给删(见 [ProfileManager.canRemove]),这里再挡一道:`remove`
/// 返回 false 就直接返回,绝不去删任何目录。
Future<bool> removeProfileAndReopen(String id) =>
    // 不是 `openCurrentProfileVault`:那一个自己排队,而这里整段已经在队列里了(M11)。
    removeProfileAndReopenImpl(id, reopen: openCurrentProfileVaultUnserialized);

/// [removeProfileAndReopen] 的本体,`reopen` 抽成参数是为了让"云档案的密钥
/// 随成员一起被清掉、本地档案不碰密钥"这条契约能在**不带 Rust 原生库**的
/// `flutter test` 里被钉住(同 [switchProfileAndReopenImpl]/[runWipeSequence]
/// 的套路)。产品代码里的唯一调用点就是 [removeProfileAndReopen],传的永远是
/// 真实现。
/// 删一个成员的目录之前:**如果此刻进程里开着的正是它的箱子,先松手**(评审
/// Minor 12)。Rust 的 vault 是进程级单例,开着就意味着它攥着
/// `<localBase>/vault` 下的 sqlite 连接。POSIX 的 unlink-while-open 让"先删后关"
/// 也能活下来,但那是巧合不是设计 —— 与 [runWipeSequence] 的 ① 步同一条契约
/// (「先松手,再删盘」);而这条路径现在跑在**启动序列**里(A5 删那个空的默认
/// 成员),正是最不该靠巧合的地方。
///
/// 两个 try 各有理由:没开过任何箱子时 `currentVaultRoot` 会抛(Rust 的「保险箱
/// 尚未打开」)—— 那只是"不是这个成员的箱子"的一种,不是错误;`resetVault` 失败
/// 也不能让整个删除半途而废(同 [runWipeSequence] ① 的说明)。
Future<void> _releaseVaultIfOpen(String localBase) async {
  try {
    if (await currentVaultRoot() != '$localBase/vault') return;
  } catch (_) {
    return;
  }
  try {
    await resetVault();
  } catch (_) {}
}

@visibleForTesting
Future<bool> removeProfileAndReopenImpl(
  String id, {
  required Future<void> Function() reopen,
  /// 同 `reopen`:真实现碰 Rust 原生库(`currentVaultRoot`/`resetVault`),
  /// `flutter test` 跑不到,所以抽成注入点。产品代码里永远是默认值。
  Future<void> Function(String localBase) releaseIfOpen = _releaseVaultIfOpen,
}) async {
  await ProfileManager.instance.ensureLoaded();
  if (!ProfileManager.instance.canRemove(id)) return false;

  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final containerRoot = await IcloudBridge.containerPath();
  final localBase = ProfileManager.instance.localBaseOf(docsRoot, id);
  final cloudBase = ProfileManager.instance.containerBaseOf(containerRoot, id);
  final cloudId = ProfileManager.instance.byId(id)?.cloudId;

  if (!await ProfileManager.instance.remove(id)) return false;
  await ReviewState.instance.removeMember(id);
  if (cloudId != null) {
    await AccountSession.instance.removeProfileKey(cloudId);
    // owner 授权服务端删不掉(`DELETE` 没有这个端点)——不记这一笔,换机/重新
    // 登录时 `AccountFlow.restoreProfileKeys` 拿 `GET /v1/profiles` 还是会看到
    // 这个档案,把用户刚删掉的成员原样建回来。见 `account.dart` 的说明。
    await AccountSession.instance.tombstoneCloudProfile(cloudId);
  }

  // **整段排进 FIFO 队列**(复审 M11)。`vault` 是进程级单例,而这三步之间任何一个
  // 插入点都会出事:另一路的开箱(切成员/同步/代拍)挤在"松手"与"删盘"之间 → 在一个
  // 正要被删的目录上开出箱子;挤在"删盘"与"reopen"之间 → 这里的 reopen 开的是别人
  // 刚切过去的那个成员。排队只保证顺序,不代替核对(见 `runSerialized` 的文档)。
  //
  // `reopen` 必须是**不自己排队**的那个(生产里是 `openCurrentProfileVaultUnserialized`)
  // —— `runSerialized` 不可重入:在队列里再排一次就是自己等自己。
  await runSerialized(() async {
    await releaseIfOpen(localBase);

    for (final base in [localBase, ?cloudBase]) {
      final d = Directory(base);
      if (await d.exists()) await d.delete(recursive: true);
    }

    await reopen();
  });
  bumpVaultRevision();
  return true;
}

/// 新建成员(空库)并切过去、重开、刷新。[userManaged] 见
/// [ProfileManager.create] —— 载入示例数据建的那个成员要传 false。
Future<String?> createProfileAndReopen(String name, {bool userManaged = true}) async {
  final id = await ProfileManager.instance.create(name, userManaged: userManaged);
  await openCurrentProfileVault();
  bumpVaultRevision();
  return id;
}
