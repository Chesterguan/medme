import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 家庭多成员管理:每个成员一个独立保险箱(子文件夹),用**名字**区分(不设别名)。
/// 成员表持久化到沙盒 `<support>/profiles.json`,与 Apple ID 无关——纯本地 + 子文件夹。
///
/// 路径策略(零迁移):**第一个成员(默认「我」)用原有位置** `<docs>/vault`
/// (以及 iCloud `<container>/Documents/vault`),已有数据原地不动;新增成员用
/// `<docs>/profiles/<名字>/vault`(iCloud `<container>/Documents/profiles/<名字>/vault`)。
/// iCloud 是全局开关(在设置),开了后每个成员按自己的子路径同步进容器,天然覆盖全部成员。
class ProfileManager {
  ProfileManager._();
  static final ProfileManager instance = ProfileManager._();

  /// 保险箱默认名字(不用「我」这种身份词)。用户可在设置里改成「我家」「张建国的病历」等。
  static const defaultVaultName = '我的医疗档案';

  /// 当前成员变化时通知各屏重载(切换成员 = 重开保险箱)。
  final ValueNotifier<String> currentMember = ValueNotifier<String>(
    defaultVaultName,
  );

  List<String> _members = const [defaultVaultName];
  // 整个保险箱的名字(家庭/个人层面,与「成员」是两回事);设置页展示 + 可改。
  String _vaultName = defaultVaultName;
  // 成员 → 最近一次已知记录数(档案屏加载时回填);设置页展示每人多少份,不必开各自库去数。
  final Map<String, int> _counts = {};
  // 首个成员的名字是否仍是占位默认(未被用户/自动识别定过)。为 true 时,首次导入
  // 若从报告里识别到患者姓名,就把默认档案自动改成那个名字(见 [maybeAutoNameRoot])。
  bool _rootAutoNamed = true;
  bool _loaded = false;
  File? _file;

  List<String> get members => List.unmodifiable(_members);
  String get current => currentMember.value;
  String get vaultName => _vaultName;

  /// 档案屏顶部展示名:只有一个、且还没被数据/用户命过名的默认成员时,显示保险箱名
  /// (不把占位名露出来,彻底避开「我」);否则显示当前成员真名。
  String get displayName =>
      (_members.length == 1 && _rootAutoNamed) ? _vaultName : current;

  /// 某成员最近已知记录数(没加载过为 null)。
  int? countFor(String member) => _counts[member];

  Future<File> _stateFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/profiles.json');
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final list = (json['members'] as List?)
            ?.map((e) => e as String)
            .toList();
        if (list != null && list.isNotEmpty) _members = list;
        final cur = json['current'] as String?;
        currentMember.value = (cur != null && _members.contains(cur))
            ? cur
            : _members.first;
        _rootAutoNamed = json['rootAutoNamed'] as bool? ?? false;
        _vaultName = json['vaultName'] as String? ?? defaultVaultName;
        final counts = json['counts'] as Map<String, dynamic>?;
        if (counts != null) {
          _counts.clear();
          counts.forEach((k, v) => _counts[k] = v as int);
        }
      }
    } catch (_) {
      // 读坏了不致命:退回单成员「我」。
    }
    _loaded = true;
  }

  Future<void> _save() async {
    try {
      final f = await _stateFile();
      await f.writeAsString(
        jsonEncode({
          'members': _members,
          'current': current,
          'rootAutoNamed': _rootAutoNamed,
          'vaultName': _vaultName,
          'counts': _counts,
        }),
      );
    } catch (_) {}
  }

  /// 切到某成员(需已存在)。调用方随后重开保险箱(见 `openCurrentProfileVault`)。
  Future<void> switchTo(String name) async {
    await ensureLoaded();
    if (!_members.contains(name)) return;
    if (currentMember.value == name) return;
    currentMember.value = name;
    await _save();
  }

  /// 新增一个成员并切过去。名字为空或重名则忽略/直接切过去。
  Future<void> create(String name) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (!_members.contains(trimmed)) {
      _members = [..._members, trimmed];
    }
    _rootAutoNamed = false; // 用户已主动管理成员,别再自动改默认档案名
    currentMember.value = trimmed;
    await _save();
  }

  /// 能不能删这个成员。**第一个成员永远不能删** —— 见 [localBase]:第一个成员用的是
  /// 原始位置 `<docs>/vault`,其余在 `<docs>/profiles/<名字>/`。删掉第一个会让第二个
  /// 递补成「第一个」,它的数据路径随之从 `profiles/X` 漂到 `<docs>`,于是**它的病历
  /// 还在磁盘上却再也找不到**。这不是保守,是那套零迁移路径策略的直接推论。
  ///
  /// (真要支持删第一个,得先把递补成员的目录搬到原始位置再改表,那是另一件事。)
  bool canRemove(String name) =>
      _members.length > 1 && _members.isNotEmpty && name != _members.first;

  /// 删除一个成员(仅从成员表移除;**磁盘上的 vault 目录由调用方删**,见
  /// `vault_boot.removeProfileAndReopen` —— 那里才知道 iCloud 容器路径)。
  /// 删的是当前成员时,自动切回第一个成员。返回是否真的删了。
  Future<bool> remove(String name) async {
    await ensureLoaded();
    if (!canRemove(name)) return false;
    _members = _members.where((m) => m != name).toList();
    _counts.remove(name);
    if (currentMember.value == name) currentMember.value = _members.first;
    await _save();
    return true;
  }

  /// 某成员的本机基目录(其下有 `vault/`)。与 [localBase] 同一套拼法,但可以问
  /// **任意**成员而不只是当前成员 —— 删除时需要拿到「即将被删的那个」的路径。
  String localBaseOf(String docsRoot, String name) =>
      _isRoot(name) ? docsRoot : '$docsRoot/profiles/${_safe(name)}';

  /// 某成员的 iCloud 目录基;容器不可用返回 null。同 [containerBase],但可指定成员。
  String? containerBaseOf(String? containerRoot, String name) {
    if (containerRoot == null) return null;
    return _isRoot(name)
        ? '$containerRoot/Documents'
        : '$containerRoot/Documents/profiles/${_safe(name)}';
  }

  /// 首个(唯一)成员仍是占位默认时,用报告里识别到的患者姓名自动命名它。
  /// 返回被改成的新名字(发生了重命名)或 null(未改)。根成员路径与名字无关
  /// (见 [localBase]),重命名只是换标签,无需迁移文件/重开保险箱。
  Future<String?> maybeAutoNameRoot(String detectedName) async {
    await ensureLoaded();
    final name = detectedName.trim();
    if (!_rootAutoNamed || _members.length != 1 || name.isEmpty) return null;
    if (_members.first == name) {
      _rootAutoNamed = false;
      await _save();
      return null;
    }
    final old = _members.first;
    if (_counts.remove(old) case final n?) _counts[name] = n;
    _members = [name];
    _rootAutoNamed = false;
    currentMember.value = name;
    await _save();
    return name;
  }

  /// 改保险箱名字(设置页)。空或没变则忽略。
  Future<void> setVaultName(String name) async {
    await ensureLoaded();
    final t = name.trim();
    if (t.isEmpty || t == _vaultName) return;
    _vaultName = t;
    await _save();
  }

  /// 回填某成员的记录数(档案屏加载时调),供设置页展示每人多少份。
  Future<void> setCount(String member, int n) async {
    await ensureLoaded();
    if (_counts[member] == n) return;
    _counts[member] = n;
    await _save();
  }

  /// 恢复出厂:成员表清回单一默认(root)、清份数缓存、保险箱名回默认、允许自动命名。
  /// 「清空所有数据」调它(配合删各 profile 的 vault 目录),而不是只清当前 profile。
  Future<void> factoryReset() async {
    _members = const [defaultVaultName];
    _vaultName = defaultVaultName;
    _counts.clear();
    _rootAutoNamed = true;
    currentMember.value = defaultVaultName;
    await _save();
  }

  // ---- 路径组合(第一个成员用原位置,其余用子文件夹)----

  bool _isRoot(String name) => _members.isNotEmpty && name == _members.first;

  String _safe(String name) => name.replaceAll('/', '_');

  /// 当前成员的本机保险箱基目录(其下有 `vault/`)。
  String localBase(String docsRoot) =>
      _isRoot(current) ? docsRoot : '$docsRoot/profiles/${_safe(current)}';

  /// 当前成员的 iCloud 目录基(其下有 `vault/`);容器不可用返回 null。
  String? containerBase(String? containerRoot) {
    if (containerRoot == null) return null;
    return _isRoot(current)
        ? '$containerRoot/Documents'
        : '$containerRoot/Documents/profiles/${_safe(current)}';
  }
}
