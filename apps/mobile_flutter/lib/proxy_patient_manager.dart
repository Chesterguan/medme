import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:mobile_flutter/src/rust/api/dto.dart';

/// 医生代拍的「今日病历表」:每个代拍病人 = 一个**独立保险箱**(自己的目录、自己的
/// 一次性 device id),走与患者模式完全相同的 `openVault` + 普通导入路径 —— 姓名不
/// 匹配提示因此是白捡的。
///
/// 与患者模式 [ProfileManager] 是**两套互不可见的命名空间**:成员表在
/// `<support>/profiles.json`,代拍病人表在 `<support>/proxy_patients.json`;患者模式
/// 的任何文件、任何代码路径都不被本类触碰。
///
/// **12 小时保留**(不是「用完即焚」):医生需要几小时内把病历写完,期间可回来补拍/
/// 核对/重发。超过 [retention] 的病人在 [ensureLoaded] 时连目录一起删掉——这就是同意
/// 告知里「最多存 12 小时,到时间自动删掉」那句话的执行者。
///
/// 落在 `<applicationSupport>` 而不是系统临时目录:临时目录系统随时可清,撑不住 12
/// 小时的承诺。也不进 iCloud —— 代拍病人的数据是别人的隐私,不上医生的云备份
/// (`openProxyPatientVault` 传 `icloudContainerDir: null`,且每个病人有自己的
/// dataDir,那里没有 `icloud_enabled` 标记)。
class ProxyPatientManager {
  ProxyPatientManager._();
  static final ProxyPatientManager instance = ProxyPatientManager._();

  /// 本机保留时长。到点自动删,见 [ensureLoaded]。
  static const retention = Duration(hours: 12);

  /// 还没从报告里识别出姓名时的占位显示名。
  static const unnamed = '未命名病人';

  List<ProxyPatient> _patients = [];
  bool _loaded = false;
  File? _file;
  String? _supportDir;

  /// 按新→旧;已过期的不会出现在这里(加载时已删)。
  List<ProxyPatient> get patients => List.unmodifiable(_patients);

  ProxyPatient? byId(String id) {
    for (final p in _patients) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<String> _support() async =>
      _supportDir ??= (await getApplicationSupportDirectory()).path;

  Future<File> _stateFile() async =>
      _file ??= File('${await _support()}/proxy_patients.json');

  /// 某病人的基目录:其下 `vault/`(真相 + 派生库)与 `data/`(该病人独立的
  /// device id、导入临时文件)。删这一棵 = 这个病人在本机彻底消失。
  Future<String> baseDir(String id) async => '${await _support()}/proxy-patients/$id';

  /// 加载病人表,并**顺手执行 12 小时 TTL**:超时的连目录一起删。每次进医生主页/
  /// 开始代拍都会走到这里,不需要后台定时器(app 不在前台时本来也不该跑定时器)。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _patients = (json['patients'] as List? ?? [])
            .map((e) => ProxyPatient.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // 读坏了不致命:当成空表(目录清理下面照跑,不留孤儿数据)。
      _patients = [];
    }
    _loaded = true;
    await _purgeExpired();
  }

  /// 删掉过期病人的条目 + 目录;顺带清掉表里没有的孤儿目录(崩溃残留)。
  Future<void> _purgeExpired() async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - retention.inMilliseconds;
    final expired = _patients.where((p) => p.createdMs < cutoff).toList();
    _patients = _patients.where((p) => p.createdMs >= cutoff).toList();
    for (final p in expired) {
      await _rmDir(await baseDir(p.id));
    }

    final root = Directory('${await _support()}/proxy-patients');
    if (await root.exists()) {
      final live = _patients.map((p) => p.id).toSet();
      await for (final entry in root.list()) {
        if (!live.contains(entry.path.split('/').last)) {
          await _rmDir(entry.path);
        }
      }
    }
    if (expired.isNotEmpty) await _save();
  }

  Future<void> _rmDir(String path) async {
    try {
      final d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // 尽力而为:删不掉(文件被占用等)不该阻断 UI;下次 ensureLoaded 还会再试。
    }
  }

  Future<void> _save() async {
    try {
      final f = await _stateFile();
      await f.writeAsString(
        jsonEncode({'patients': _patients.map((p) => p.toJson()).toList()}),
      );
    } catch (_) {}
  }

  /// 新建一个代拍病人(空箱,占位名),返回其 id。调用方随后
  /// `openProxyPatientVault(id)` 开箱。
  Future<String> create() async {
    await ensureLoaded();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'p-$now-${_patients.length}';
    _patients = [ProxyPatient(id: id, createdMs: now), ..._patients];
    await _save();
    return id;
  }

  /// 用报告里识别到的患者姓名给这个病人命名。只在还是占位名时生效(幂等,后续
  /// 采集识别到别人的名字不会把已命名的病人改掉——那种情况该由「姓名不匹配」红条
  /// 提醒医生,而不是悄悄改名)。
  Future<void> autoName(String id, String? detected) async {
    final name = detected?.trim() ?? '';
    if (name.isEmpty) return;
    await _update(id, (p) => p.name == null ? p.copyWith(name: name) : p);
  }

  /// 记下拍前同意(签名/按住确认)。留到交付时打进加密包——12 小时里可能重启 app,
  /// 所以必须落盘,不能只放内存。
  Future<void> setConsent(String id, ConsentDto consent) =>
      _update(id, (p) => p.copyWith(consent: consent));

  /// 记下「这份单子上的姓名不是这个病人」(docId → 报告上的名字)。落盘而不是只放
  /// 内存:12 小时保留窗口里 app 会重启,重进来还得看得见这条提醒 —— 诊室里混进隔壁
  /// 病人的单子,是必须一直提示到医生处理掉为止的事。传 null 撤销(该份被删时)。
  Future<void> setMismatch(String id, int docId, String? otherName) =>
      _update(id, (p) {
        final next = {...p.mismatch};
        if (otherName == null || otherName.isEmpty) {
          if (!next.containsKey(docId)) return p;
          next.remove(docId);
        } else {
          if (next[docId] == otherName) return p;
          next[docId] = otherName;
        }
        return p.copyWith(mismatch: next);
      });

  /// 标记/取消一份文档「已确认」。Rust 侧不存这个状态(存了就要动保险箱格式),
  /// 落在这里,交付时作为 `confirmedIds` 传给 `createProxyShare`。
  Future<void> setConfirmed(String id, int docId, bool confirmed) => _update(id, (p) {
    final next = {...p.confirmedIds};
    confirmed ? next.add(docId) : next.remove(docId);
    return p.copyWith(confirmedIds: next);
  });

  /// 回填这个病人手里有几份(主页列表展示用,免得为了数数把箱子挨个开一遍)。
  Future<void> setDocCount(String id, int n) =>
      _update(id, (p) => p.docCount == n ? p : p.copyWith(docCount: n));

  Future<void> _update(String id, ProxyPatient Function(ProxyPatient) f) async {
    await ensureLoaded();
    var changed = false;
    _patients = _patients.map((p) {
      if (p.id != id) return p;
      final next = f(p);
      changed = !identical(next, p);
      return next;
    }).toList();
    if (changed) await _save();
  }

  /// 清掉一个病人:条目 + 整棵目录(原件字节、事件日志、OCR 文本、生成的分享件都在里面)。
  Future<void> remove(String id) async {
    await ensureLoaded();
    _patients = _patients.where((p) => p.id != id).toList();
    await _rmDir(await baseDir(id));
    await _save();
  }

  /// 「清空」:所有代拍病人一次删干净。患者模式的档案不受影响(不同命名空间)。
  Future<void> removeAll() async {
    await ensureLoaded();
    _patients = [];
    await _rmDir('${await _support()}/proxy-patients');
    await _save();
  }
}

/// 一个代拍病人:名字(从报告识别)、建档时刻(TTL 起点)、已确认的文档、拍前同意。
class ProxyPatient {
  const ProxyPatient({
    required this.id,
    required this.createdMs,
    this.name,
    this.docCount = 0,
    this.confirmedIds = const {},
    this.mismatch = const {},
    this.consent,
  });

  /// 目录名,也是主键。
  final String id;

  /// 建档时刻(本机毫秒);12 小时 TTL 从这里算。
  final int createdMs;

  /// 从报告 OCR 里识别到的患者姓名;还没识别到为 null(列表显示占位名)。
  final String? name;

  /// 已采集的文档份数(列表展示用的缓存值)。
  final int docCount;

  /// 医生逐份点过「确认这一份」的 document_id。
  final Set<int> confirmedIds;

  /// 报告上姓名与本病人不一致的文档(docId → 报告上的名字)。跨重启保留。
  final Map<int, String> mismatch;

  /// 拍前同意记录;交付时打进加密包。
  final ConsentDto? consent;

  String get displayName => name ?? ProxyPatientManager.unnamed;

  /// 还剩多久自动删(已过期为 [Duration.zero])。
  Duration get remaining {
    final left =
        createdMs + ProxyPatientManager.retention.inMilliseconds -
        DateTime.now().millisecondsSinceEpoch;
    return left <= 0 ? Duration.zero : Duration(milliseconds: left);
  }

  ProxyPatient copyWith({
    String? name,
    int? docCount,
    Set<int>? confirmedIds,
    Map<int, String>? mismatch,
    ConsentDto? consent,
  }) => ProxyPatient(
    id: id,
    createdMs: createdMs,
    name: name ?? this.name,
    docCount: docCount ?? this.docCount,
    confirmedIds: confirmedIds ?? this.confirmedIds,
    mismatch: mismatch ?? this.mismatch,
    consent: consent ?? this.consent,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdMs': createdMs,
    if (name != null) 'name': name,
    'docCount': docCount,
    'confirmedIds': confirmedIds.toList(),
    // JSON 的键只能是字符串,读回时再 parse 成 docId。
    'mismatch': mismatch.map((k, v) => MapEntry('$k', v)),
    if (consent case final c?)
      'consent': {
        'utcTs': c.utcTs,
        'consentTextVersion': c.consentTextVersion,
        'signaturePngBase64': c.signaturePngBase64,
        'method': c.method,
        'sessionId': c.sessionId,
      },
  };

  static ProxyPatient fromJson(Map<String, dynamic> j) {
    final c = j['consent'] as Map<String, dynamic>?;
    return ProxyPatient(
      id: j['id'] as String,
      createdMs: j['createdMs'] as int,
      name: j['name'] as String?,
      docCount: j['docCount'] as int? ?? 0,
      confirmedIds: ((j['confirmedIds'] as List?) ?? const [])
          .map((e) => e as int)
          .toSet(),
      mismatch: ((j['mismatch'] as Map?) ?? const {}).map(
        (k, v) => MapEntry(int.parse(k as String), v as String),
      ),
      consent: c == null
          ? null
          : ConsentDto(
              utcTs: c['utcTs'] as String,
              consentTextVersion: c['consentTextVersion'] as String,
              signaturePngBase64: c['signaturePngBase64'] as String?,
              method: c['method'] as String,
              sessionId: c['sessionId'] as String,
            ),
    );
  }
}
