import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 家庭多成员管理:每个成员一个独立保险箱(子文件夹)。成员表持久化到沙盒
/// `<support>/profiles.json`,与 Apple ID 无关——纯本地 + 子文件夹。
///
/// **成员一律平等**:没有权限差别、没有特殊的那一个,路径规则只有一条 ——
/// 每个成员在 `<docs>/profiles/<id>/vault`(iCloud 则是
/// `<container>/Documents/profiles/<id>/vault`)。
///
/// **目录用 [Profile.id],不用名字。** 名字是给人看的标签,随时可改(报告里识别到真名
/// 会自动改,以后也可能让用户手改);拿会变的东西给文件夹命名,改一次名就等于搬一次
/// 数据,搬到一半失败就是丢病历。id 一旦生成永不变,于是改名只动标签、删除只影响
/// 自己、谁也不依赖谁的位置 —— 那些「删了第一个别人会不会出事」的保护逻辑因此全部
/// 不需要存在。
///
/// iCloud 是全局开关(在设置),开了后每个成员按自己的子路径同步进容器,天然覆盖全部成员。
class ProfileManager {
  ProfileManager._();
  static final ProfileManager instance = ProfileManager._();

  /// 保险箱默认名字(家庭/个人层面)。用户可在设置里改成「我家」「张建国的病历」等。
  static const defaultVaultName = '我的医疗档案';

  /// 初始成员的默认名字。**必须与 [defaultVaultName] 不同** —— 两者曾经用同一个字符串,
  /// 于是设置页会显示成「保险箱:我的医疗档案 → 成员:我的医疗档案」,同一个名字在两个
  /// 层级上各出现一次,用户看不懂谁包含谁。
  ///
  /// 而且成员名会进档案屏顶部那条**常驻 tab**(横向排列,见 `_MemberTabs`):六个字的名字
  /// 一个人就占掉半行,五人上限形同虚设。一个字的「我」让 tab 条真的能放下几个人。
  static const defaultMemberName = '我';

  /// 存储格式版本。产品尚未正式发布,没有需要迁移的存量安装 —— 读到旧格式(按**名字**
  /// 建目录的那版)直接当作全新开始,不做半迁移,免得留下「表里有人、目录对不上」的
  /// 中间状态。
  static const _storageVersion = 2;

  /// 初始成员的 id。固定值,让全新安装是确定的。
  static const _bootstrapId = 'p-1';

  /// 当前成员 **id** 变化时通知各屏重载(切换成员 = 重开保险箱)。用 id 而不是名字:
  /// 改名不该触发重开,换人才该。
  final ValueNotifier<String> currentId = ValueNotifier<String>(_bootstrapId);

  List<Profile> _profiles = const [
    Profile(id: _bootstrapId, name: defaultMemberName),
  ];
  // 整个保险箱的名字(家庭/个人层面,与「成员」是两回事);设置页展示 + 可改。
  String _vaultName = defaultVaultName;
  // 成员 id → 最近一次已知记录数(档案屏加载时回填);设置页展示每人多少份,不必开各自库去数。
  final Map<String, int> _counts = {};
  // 初始成员的名字是否仍是占位默认(未被用户/自动识别定过)。为 true 时,首次导入
  // 若从报告里识别到患者姓名,就把它改成那个名字(见 [maybeAutoNameCurrent])。
  bool _autoNamePending = true;
  bool _loaded = false;
  File? _file;

  List<Profile> get profiles => List.unmodifiable(_profiles);
  String get vaultName => _vaultName;

  /// 当前成员。成员表永不为空(删到只剩一个就不给删),所以这里总有值。
  Profile get current => byId(currentId.value) ?? _profiles.first;

  Profile? byId(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 档案屏顶部展示名:只有一个、且还没被数据/用户命过名的默认成员时,显示保险箱名
  /// (不把占位名露出来,彻底避开「我」);否则显示当前成员真名。
  String get displayName =>
      (_profiles.length == 1 && _autoNamePending) ? _vaultName : current.name;

  /// 某成员最近已知记录数(没加载过为 null)。
  int? countFor(String id) => _counts[id];

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
        // 旧格式(无 version,目录按名字建)忽略,当全新开始。
        if (json['version'] == _storageVersion) {
          final list = (json['profiles'] as List?)
              ?.map((e) => Profile.fromJson(e as Map<String, dynamic>))
              .toList();
          if (list != null && list.isNotEmpty) _profiles = list;
          final cur = json['currentId'] as String?;
          currentId.value = (cur != null && byId(cur) != null)
              ? cur
              : _profiles.first.id;
          _autoNamePending = json['autoNamePending'] as bool? ?? false;
          _vaultName = json['vaultName'] as String? ?? defaultVaultName;
          final counts = json['counts'] as Map<String, dynamic>?;
          if (counts != null) {
            _counts.clear();
            counts.forEach((k, v) => _counts[k] = v as int);
          }
        }
      }
    } catch (_) {
      // 读坏了不致命:退回单成员默认档案。
    }
    _loaded = true;
  }

  Future<void> _save() async {
    try {
      final f = await _stateFile();
      await f.writeAsString(
        jsonEncode({
          'version': _storageVersion,
          'profiles': _profiles.map((p) => p.toJson()).toList(),
          'currentId': currentId.value,
          'autoNamePending': _autoNamePending,
          'vaultName': _vaultName,
          'counts': _counts,
        }),
      );
    } catch (_) {}
  }

  /// 切到某成员(需已存在)。调用方随后重开保险箱(见 `openCurrentProfileVault`)。
  Future<void> switchTo(String id) async {
    await ensureLoaded();
    if (byId(id) == null || currentId.value == id) return;
    currentId.value = id;
    await _save();
  }

  /// 新增一个成员并切过去,返回它的 id(名字为空则返回 null)。**同名不去重** ——
  /// 名字只是标签,家里有两个「张伟」很正常,他们各有各的 id 和目录。
  ///
  /// [userManaged] 为 true(默认)表示这是**用户自己**在管理成员,于是关掉「首次导入
  /// 自动命名」——他既然会自己建成员,就别再替他改名。载入示例数据也建成员,但那不是
  /// 用户在管理档案,必须传 false:否则「先看示例、再导入自己的病历」这条最常见的
  /// 路径上,他的档案会永远停在占位名。
  Future<String?> create(String name, {bool userManaged = true}) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final p = Profile(id: _newId(), name: trimmed);
    _profiles = [..._profiles, p];
    if (userManaged) _autoNamePending = false;
    currentId.value = p.id;
    await _save();
    return p.id;
  }

  String _newId() =>
      'p-${DateTime.now().millisecondsSinceEpoch}-${_profiles.length}';

  /// 改名。**只动标签,不动任何文件** —— 这正是拿 id 建目录换来的:目录若按名字拼,
  /// 改名就得搬数据,搬到一半失败就丢病历,所以那时干脆不敢做这个功能。
  Future<void> rename(String id, String name) async {
    await ensureLoaded();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    var changed = false;
    _profiles = _profiles.map((p) {
      if (p.id != id || p.name == trimmed) return p;
      changed = true;
      return Profile(id: p.id, name: trimmed);
    }).toList();
    if (changed) {
      _autoNamePending = false;
      await _save();
    }
  }

  /// 能不能删这个成员。成员一律平等,**谁都能删**;删任何一个都只影响它自己
  /// (每人一个独立目录,没有谁的路径依赖别人)。唯一的限制是**不能删到一个不剩** ——
  /// 那等于清空整个保险箱,该走设置里「清空所有数据 · 重置保险箱」那条更明确的路。
  bool canRemove(String id) => _profiles.length > 1 && byId(id) != null;

  /// 删除一个成员(仅从成员表移除;**磁盘上的目录由调用方删**,见
  /// `vault_boot.removeProfileAndReopen` —— 那里才知道 iCloud 容器路径)。
  /// 删的是当前成员时自动切到剩下的第一个。返回是否真的删了。
  Future<bool> remove(String id) async {
    await ensureLoaded();
    if (!canRemove(id)) return false;
    _profiles = _profiles.where((p) => p.id != id).toList();
    _counts.remove(id);
    if (currentId.value == id) currentId.value = _profiles.first.id;
    await _save();
    return true;
  }

  /// 当前成员仍是占位默认名时,用报告里识别到的患者姓名给它命名。返回新名字或 null
  /// (未改)。只是换标签,不迁移文件 —— 目录认的是 id。
  Future<String?> maybeAutoNameCurrent(String detectedName) async {
    await ensureLoaded();
    final name = detectedName.trim();
    if (!_autoNamePending || _profiles.length != 1 || name.isEmpty) return null;
    final cur = current;
    if (cur.name == name) {
      _autoNamePending = false;
      await _save();
      return null;
    }
    await rename(cur.id, name); // rename 内部关掉 _autoNamePending 并落盘
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
  Future<void> setCount(String id, int n) async {
    await ensureLoaded();
    if (_counts[id] == n) return;
    _counts[id] = n;
    await _save();
  }

  /// 恢复出厂:成员表清回单一默认、清份数缓存、保险箱名回默认、允许自动命名。
  /// 「清空所有数据」调它(配合删各成员目录),而不是只清当前成员。
  Future<void> factoryReset() async {
    _profiles = const [Profile(id: _bootstrapId, name: defaultMemberName)];
    _vaultName = defaultVaultName;
    _counts.clear();
    _autoNamePending = true;
    currentId.value = _bootstrapId;
    await _save();
  }

  // ---- 路径组合:一条规则,人人相同,按 id ----

  /// 某成员的本机基目录(其下有 `vault/`)。
  String localBaseOf(String docsRoot, String id) => '$docsRoot/profiles/$id';

  /// 某成员的 iCloud 目录基;容器不可用返回 null。
  String? containerBaseOf(String? containerRoot, String id) =>
      containerRoot == null ? null : '$containerRoot/Documents/profiles/$id';

  /// 当前成员的本机基目录。
  String localBase(String docsRoot) => localBaseOf(docsRoot, currentId.value);

  /// 当前成员的 iCloud 目录基;容器不可用返回 null。
  String? containerBase(String? containerRoot) =>
      containerBaseOf(containerRoot, currentId.value);
}

/// 一个成员:[id] 是主键与目录名(生成后永不变),[name] 只是给人看的标签(随时可改)。
class Profile {
  const Profile({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static Profile fromJson(Map<String, dynamic> j) =>
      Profile(id: j['id'] as String, name: j['name'] as String);
}
