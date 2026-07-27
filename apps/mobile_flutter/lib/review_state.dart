import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:mobile_flutter/profile_manager.dart';

/// 「新导入待确认」本地状态,**按成员分命名空间**(每个成员独立的待确认集,不同
/// 成员的保险箱各自从 id 1 起,共用一个集合会撞车)。持久化到沙盒
/// `<support>/review_state.json`(纯本设备 UI 状态,不进保险箱)。
///
/// 除了待确认集,还记录每份新导入报告里**识别到的患者姓名**——若它和当前成员档案
/// 名字不一致([_flagged]),说明可能导错了人,健康档案会给这份标红警告。
///
/// 分区键是**成员 id**,不是名字:名字是可变标签(自动命名会改),用它当键的话改一次
/// 名这些状态就全丢了;而且不同成员可以重名。
///
/// 语义:导入时把本次新建文档 id 显式加入**当前成员**的待确认集([markPending]);
/// 健康档案顶部把当前成员待确认集里的文档置顶让用户核对;点「确认」移除([markReviewed])。
class ReviewState {
  ReviewState._();
  static final ReviewState instance = ReviewState._();

  // 键是成员 id。
  final Map<String, Set<int>> _byMember = {};
  // 成员 id → (文档 id → 报告里识别到的、与该成员名字**不符**的患者姓名)。
  final Map<String, Map<int, String>> _flagged = {};
  bool _loaded = false;
  File? _file;

  Set<int> _cur() =>
      _byMember.putIfAbsent(ProfileManager.instance.currentId.value, () => <int>{});
  Map<int, String> _curFlagged() =>
      _flagged.putIfAbsent(
        ProfileManager.instance.currentId.value,
        () => <int, String>{},
      );

  Future<File> _stateFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/review_state.json');
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final pending = json['pending'] as Map<String, dynamic>?;
        if (pending != null) {
          _byMember.clear();
          pending.forEach((member, ids) {
            _byMember[member] = (ids as List).map((e) => e as int).toSet();
          });
        }
        final flagged = json['flagged'] as Map<String, dynamic>?;
        if (flagged != null) {
          _flagged.clear();
          flagged.forEach((member, m) {
            _flagged[member] = (m as Map<String, dynamic>).map(
              (k, v) => MapEntry(int.parse(k), v as String),
            );
          });
        }
      }
    } catch (_) {
      // 读坏了不致命:当空,后续导入会重填。
    }
    _loaded = true;
  }

  Future<void> _save() async {
    try {
      final f = await _stateFile();
      final pending = <String, List<int>>{};
      _byMember.forEach((m, ids) {
        if (ids.isNotEmpty) pending[m] = ids.toList();
      });
      final flagged = <String, Map<String, String>>{};
      _flagged.forEach((m, map) {
        if (map.isNotEmpty) {
          flagged[m] = map.map((k, v) => MapEntry(k.toString(), v));
        }
      });
      await f.writeAsString(jsonEncode({'pending': pending, 'flagged': flagged}));
    } catch (_) {}
  }

  /// 当前成员下,该文档是否「新导入·待确认」。
  bool isPending(int docId) => _cur().contains(docId);

  /// 该待确认文档识别到的、与当前成员名字不符的患者姓名;一致或无则 null。
  String? mismatchName(int docId) => _curFlagged()[docId];

  /// 导入后把新建文档加入当前成员的待确认集。`docs` = 文档 id → 报告里识别到的
  /// 患者姓名(识别不到为 null);姓名与当前成员不符的记为「疑似导错人」。
  Future<void> markPending(Map<int, String?> docs) async {
    await ensureLoaded();
    // 比的是**名字**(报告上印的姓名 vs 这个成员的显示名),而分区键是 id ——
    // 两者别搞混:id 用来分命名空间,名字用来判断「是不是导错人了」。
    final memberName = ProfileManager.instance.current.name;
    var changed = false;
    docs.forEach((id, detected) {
      changed = _cur().add(id) || changed;
      if (detected != null &&
          detected.trim().isNotEmpty &&
          detected != memberName) {
        _curFlagged()[id] = detected;
        changed = true;
      }
    });
    if (changed) await _save();
  }

  /// 确认通过一份 → 移出当前成员待确认集(连同标红)。
  Future<void> markReviewed(int docId) async {
    await ensureLoaded();
    final a = _cur().remove(docId);
    final b = _curFlagged().remove(docId) != null;
    if (a || b) await _save();
  }

  /// 一键全部确认(当前成员)。
  Future<void> markAllReviewed(Iterable<int> docIds) async {
    await ensureLoaded();
    var changed = false;
    for (final id in docIds) {
      changed = _cur().remove(id) || changed;
      changed = (_curFlagged().remove(id) != null) || changed;
    }
    if (changed) await _save();
  }

  /// 清空全部成员的待确认/标红状态(「清空所有数据」恢复出厂时调)。
  Future<void> clearAll() async {
    await ensureLoaded();
    _byMember.clear();
    _flagged.clear();
    await _save();
  }

  /// 成员被删除时清掉它的待确认/标红(**按成员 id**,不是名字 —— 名字会变、会重复)。
  Future<void> removeMember(String id) async {
    await ensureLoaded();
    final hadPending = _byMember.remove(id) != null;
    final hadFlagged = _flagged.remove(id) != null;
    if (hadPending || hadFlagged) await _save();
  }
}
