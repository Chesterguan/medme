import 'dart:io';

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

/// 切换到某成员并重开其保险箱,然后通知各屏刷新。
Future<void> switchProfileAndReopen(String name) async {
  await ProfileManager.instance.switchTo(name);
  await openCurrentProfileVault();
  bumpVaultRevision();
}

/// 「清空所有数据」= 恢复出厂:清**所有成员、所有位置**的 vault 数据(本机 + iCloud
/// 容器)+ 份数缓存 + 待确认,重置成单一默认档案。
///
/// ⚠️ root 成员有**两处** vault:本机 `<docs>/vault` 与 iCloud `<container>/Documents/vault`
/// (关 iCloud 时容器副本会被 `disable_icloud_sync` 保留)。`resetVault` 只干净清掉**当前
/// 活跃**那处(正常关连接 + 删 db/wal + 重开空);另一处必须显式删,否则清空后容器里仍留
/// 整份病历、再开 iCloud 会 adopt 回来(评审 Critical)。子成员整个 `profiles/` 删掉。
Future<void> wipeAllData() async {
  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final containerRoot = await IcloudBridge.containerPath();

  Future<void> rmDir(String path) async {
    final d = Directory(path);
    if (await d.exists()) await d.delete(recursive: true);
  }

  // 1. 注册表恢复出厂(current→默认 root)+ 清待确认。
  await ProfileManager.instance.factoryReset();
  await ReviewState.instance.clearAll();

  // 2. 重开默认(root)vault → 活跃 = root;3. resetVault 干净清活跃那处(含 db/wal)+ 重开空。
  await openCurrentProfileVault();
  await resetVault();

  // 4. 删 root 的**非活跃**那处 vault 副本(resetVault 没碰到的):iCloud 开时活跃=容器,
  //    非活跃=本机;关时反之。icloudStatus().enabled 与 Rust 的路径决策同源(同一 marker)。
  final icloudOn = (await icloudStatus()).enabled;
  if (icloudOn) {
    await rmDir('$docsRoot/vault');
  } else if (containerRoot != null) {
    await rmDir('$containerRoot/Documents/vault');
  }

  // 5. 删所有子成员数据(各自 vault + 派生库都在 profiles/ 内);本机 + iCloud 容器都删。
  for (final root in [docsRoot, if (containerRoot != null) '$containerRoot/Documents']) {
    await rmDir('$root/profiles');
  }

  bumpVaultRevision();
}

/// 用报告里识别到的患者姓名,给还没定过名的默认档案自动命名(迁移其待确认/标红键)。
/// 导入、载入示例、档案加载等任一有患者姓名的地方都可调,幂等:只在首次未命名时生效。
Future<void> autoNameCurrentProfileFrom(String? detectedName) async {
  if (detectedName == null || detectedName.trim().isEmpty) return;
  final old = ProfileManager.instance.current;
  final renamed = await ProfileManager.instance.maybeAutoNameRoot(detectedName);
  if (renamed != null) await ReviewState.instance.renameMember(old, renamed);
}

/// 删除一个成员:成员表移除 + **本机与 iCloud 容器两处**的数据目录都删掉,再重开
/// (删的若是当前成员,`remove` 已把 current 切回第一个)并刷新各屏。
///
/// 两处都删的理由与 [wipeAllData] 第 4 步同源:关掉 iCloud 时容器副本会被保留,
/// 只删活跃那处的话,数据还在容器里躺着,再开 iCloud 会被 adopt 回来 —— 用户以为
/// 删干净了,过一阵又冒出来。
///
/// 第一个成员删不了(见 [ProfileManager.canRemove] 的路径说明),这里再挡一道:
/// `remove` 返回 false 就直接返回,绝不去删任何目录。
Future<bool> removeProfileAndReopen(String name) async {
  await ProfileManager.instance.ensureLoaded();
  if (!ProfileManager.instance.canRemove(name)) return false;

  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final containerRoot = await IcloudBridge.containerPath();
  // 路径必须在把成员从表里摘掉**之前**算好:`localBaseOf` 依赖成员表判断谁是第一个。
  final localBase = ProfileManager.instance.localBaseOf(docsRoot, name);
  final cloudBase = ProfileManager.instance.containerBaseOf(containerRoot, name);

  if (!await ProfileManager.instance.remove(name)) return false;
  await ReviewState.instance.removeMember(name);

  for (final base in [localBase, ?cloudBase]) {
    final d = Directory(base);
    if (await d.exists()) await d.delete(recursive: true);
  }

  await openCurrentProfileVault();
  bumpVaultRevision();
  return true;
}

/// 新建成员(空库)并切过去、重开、刷新。
Future<void> createProfileAndReopen(String name) async {
  await ProfileManager.instance.create(name);
  await openCurrentProfileVault();
  bumpVaultRevision();
}
