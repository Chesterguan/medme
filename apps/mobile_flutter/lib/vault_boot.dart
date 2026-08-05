import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobile_flutter/src/rust/api/vault.dart';
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

Future<void> _serializedOpen(Future<void> Function() open) {
  final done = _vaultQueue.then((_) => open());
  // 队列本身吞掉异常(否则一次开箱失败会毒死后面所有开箱);异常照常抛给调用方。
  _vaultQueue = done.then((_) {}, onError: (_) {});
  return done;
}

/// 打开「当前成员」的保险箱:按 [ProfileManager] 组合本机/iCloud 路径,调 Rust
/// `open_vault`(Rust 的进程级 vault 会被替换成该成员的)。启动 + 切换成员后都调它。
///
/// data 目录(设备 id、iCloud 全局开关标记、导入临时文件)所有成员共用——iCloud 是
/// 全局开关(开了对所有成员生效);派生库则每成员独立(见 Rust `resolve_vault_paths`)。
Future<void> openCurrentProfileVault() => _serializedOpen(() async {
  await ProfileManager.instance.ensureLoaded();
  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final support = (await getApplicationSupportDirectory()).path;
  final containerRoot = await IcloudBridge.containerPath();

  await openVault(
    docsDir: ProfileManager.instance.localBase(docsRoot),
    dataDir: support,
    icloudContainerDir: ProfileManager.instance.containerBase(containerRoot),
  );
});

/// 打开某个**代拍病人**的保险箱(医生模式)。与「切成员」不是一回事:代拍病人不在
/// [ProfileManager] 里,走 [ProxyPatientManager] 的独立命名空间。
///
/// `dataDir` 用该病人自己的 `data/`:每个病人一个一次性 device id(不带医生的设备
/// 身份),且那里没有 `icloud_enabled` 标记 —— 别人的病历永远不进医生的 iCloud。
Future<void> openProxyPatientVault(String patientId) =>
    _serializedOpen(() async {
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
Future<void> switchProfileAndReopen(String id) async {
  await ProfileManager.instance.switchTo(id);
  await openCurrentProfileVault();
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
/// (删的若是当前成员,`remove` 已把 current 切回第一个)并刷新各屏。
///
/// 两处都删的理由与 [wipeAllData] 第 4 步同源:关掉 iCloud 时容器副本会被保留,
/// 只删活跃那处的话,数据还在容器里躺着,再开 iCloud 会被 adopt 回来 —— 用户以为
/// 删干净了,过一阵又冒出来。
///
/// 删到只剩一个时不给删(见 [ProfileManager.canRemove]),这里再挡一道:`remove`
/// 返回 false 就直接返回,绝不去删任何目录。
Future<bool> removeProfileAndReopen(String id) async {
  await ProfileManager.instance.ensureLoaded();
  if (!ProfileManager.instance.canRemove(id)) return false;

  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final containerRoot = await IcloudBridge.containerPath();
  final localBase = ProfileManager.instance.localBaseOf(docsRoot, id);
  final cloudBase = ProfileManager.instance.containerBaseOf(containerRoot, id);

  if (!await ProfileManager.instance.remove(id)) return false;
  await ReviewState.instance.removeMember(id);

  for (final base in [localBase, ?cloudBase]) {
    final d = Directory(base);
    if (await d.exists()) await d.delete(recursive: true);
  }

  await openCurrentProfileVault();
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
