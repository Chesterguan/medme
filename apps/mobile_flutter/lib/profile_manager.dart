import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 家庭多成员管理:每个成员一个独立保险箱(子文件夹),用**名字**区分(不设别名)。
/// 成员表持久化到沙盒 `<support>/profiles.json`,与 Apple ID 无关——纯本地 + 子文件夹。
///
/// 路径策略(零迁移):**有一个成员用原有位置** `<docs>/vault`(以及 iCloud
/// `<container>/Documents/vault`),让升级上来的老用户数据原地不动;其余成员用
/// `<docs>/profiles/<名字>/vault`(iCloud `<container>/Documents/profiles/<名字>/vault`)。
///
/// **是谁占着那个原始位置,由 [_rootMember] 显式记名,不由「排第几」推断。** 早先是按
/// `members.first` 推的,后果是删掉第一个成员会让第二个递补并**继承那个位置** —— 它的
/// 病历还躺在 `profiles/<名字>/` 却再也找不到。成员本该各自独立、删也独立,所以把身份
/// 记死。老的 `profiles.json` 没有这个字段,加载时取首位补上,向后兼容。
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
  // 占着原始位置 `<docs>/vault` 的那个成员的名字;它被删掉后置 null(那个位置随之
  // 空出,不再有人用),其余成员的路径不受任何影响。
  String? _rootMember = defaultVaultName;
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
        // 老版本没有 rootMember 字段:那时「第一个成员」就是占着原始位置的那个。
        final storedRoot = json['rootMember'] as String?;
        _rootMember = (storedRoot != null && _members.contains(storedRoot))
            ? storedRoot
            : (json.containsKey('rootMember') ? null : _members.first);
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
          'rootMember': _rootMember,
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
  ///
  /// [userManaged] 为 true(默认)表示这是**用户自己**在管理成员,于是关掉「首次导入
  /// 自动命名默认档案」——他既然会自己建成员,就别再替他改名。载入示例数据也会建一个
  /// 成员,但那不是用户在管理档案,必须传 false:否则「先看示例、再导入自己的病历」
  /// 这条最常见的路径上,他的档案会永远停在占位名「我的医疗档案」。
  Future<void> create(String name, {bool userManaged = true}) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (!_members.contains(trimmed)) {
      _members = [..._members, trimmed];
    }
    if (userManaged) _rootAutoNamed = false;
    currentMember.value = trimmed;
    await _save();
  }

  /// 能不能删这个成员。成员各自独立,**谁都能删,与排第几无关**(路径由 [_rootMember]
  /// 记名,不随顺序漂移)。唯一的限制是**不能删到一个不剩** —— 那等于清空整个保险箱,
  /// 该走设置里「清空所有数据 · 重置保险箱」那条更明确的路,而不是从成员列表里悄悄清光。
  bool canRemove(String name) => _members.length > 1 && _members.contains(name);

  /// 删除一个成员(仅从成员表移除;**磁盘上的 vault 目录由调用方删**,见
  /// `vault_boot.removeProfileAndReopen` —— 那里才知道 iCloud 容器路径)。
  /// 删的是当前成员时,自动切回第一个成员。返回是否真的删了。
  Future<bool> remove(String name) async {
    await ensureLoaded();
    if (!canRemove(name)) return false;
    _members = _members.where((m) => m != name).toList();
    _counts.remove(name);
    // 删的正好是占着原始位置的那个:位置空出来,不转交给任何人 —— 转交就意味着
    // 要搬目录,而其余成员本来在自己的 `profiles/<名字>/` 里待得好好的。
    if (_rootMember == name) _rootMember = null;
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
    // 路径认的是名字,改名必须同步搬身份,否则这个成员会从 `<docs>/vault` 漂到
    // `profiles/<新名字>/`,数据当场找不到。
    if (_rootMember == old) _rootMember = name;
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
    _rootMember = defaultVaultName;
    _vaultName = defaultVaultName;
    _counts.clear();
    _rootAutoNamed = true;
    currentMember.value = defaultVaultName;
    await _save();
  }

  // ---- 路径组合(第一个成员用原位置,其余用子文件夹)----

  bool _isRoot(String name) => _rootMember != null && name == _rootMember;

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
