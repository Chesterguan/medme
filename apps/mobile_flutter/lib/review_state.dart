import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 「新导入待审核」本地状态。持久化一份「已审核文档 id 集」到沙盒
/// `<support>/review_state.json`,不进保险箱(纯本设备的 UI 状态,不需要跨设备同步)。
///
/// 语义:
/// - 首次运行(未初始化)把当前所有文档设为「已审核」作基线——已有数据不算「新」。
/// - 之后凡不在集里的文档 = 新导入 = 「待确认」,在健康档案顶部标「新」。
/// - 用户点「审核通过」→ 加入集 → 归入正常时间线,不再置顶。
///
/// 这样完全不动共享 vault 格式 / core-model / 桌面(零 spine 风险),新导入的识别
/// 结果(类型/日期可能被 OCR 猜错)先让用户过一眼再正式并入。
class ReviewState {
  ReviewState._();
  static final ReviewState instance = ReviewState._();

  final Set<int> _reviewed = {};
  bool _initialized = false;
  bool _loaded = false;
  File? _file;

  Future<File> _stateFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/review_state.json');
  }

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _initialized = json['initialized'] == true;
        _reviewed
          ..clear()
          ..addAll((json['reviewed'] as List).map((e) => e as int));
      }
    } catch (_) {
      // 读坏了不致命:当作未初始化,下次导入基线会重建。
    }
    _loaded = true;
  }

  Future<void> _save() async {
    try {
      final f = await _stateFile();
      await f.writeAsString(
        jsonEncode({
          'initialized': _initialized,
          'reviewed': _reviewed.toList(),
        }),
      );
    } catch (_) {
      // 写失败不致命(下次再写);至少本次会话内存里状态是对的。
    }
  }

  /// 加载状态,并在首次运行时用 [currentDocIds] 建立基线(现有数据视为已审)。
  /// 每次进健康档案调一次即可(幂等)。
  Future<void> ensureBaseline(List<int> currentDocIds) async {
    await _load();
    if (!_initialized) {
      _reviewed
        ..clear()
        ..addAll(currentDocIds);
      _initialized = true;
      await _save();
    }
  }

  /// 该文档是否是「新导入·待确认」(未审核)。
  bool isNew(int docId) => !_reviewed.contains(docId);

  /// 标记一份文档已审核通过(归入正常时间线)。
  Future<void> markReviewed(int docId) async {
    await _load();
    if (_reviewed.add(docId)) await _save();
  }

  /// 一键把当前所有「新」文档都标为已审(顶部「全部审核」用)。
  Future<void> markAllReviewed(Iterable<int> docIds) async {
    await _load();
    var changed = false;
    for (final id in docIds) {
      changed = _reviewed.add(id) || changed;
    }
    if (changed) await _save();
  }
}
