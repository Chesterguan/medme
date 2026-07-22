import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 「今日已交付」计数——纯本地、纯数字,**不存任何病人数据**(不存文件名、不存
/// 图片、不存同意记录),只在临时会话成功交付(生成加密文件并即焚退出)后 +1。
/// 与 `ProfileManager`/`ReviewState`/`AppMode` 同一持久化约定:沙盒 support 目录
/// 下一个小 JSON 文件。按日期比较自动归零,不需要后台任务。
class DoctorDeliveryCount {
  DoctorDeliveryCount._();
  static final DoctorDeliveryCount instance = DoctorDeliveryCount._();

  File? _file;

  Future<File> _stateFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/doctor_delivery_count.json');
  }

  static String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// 今日已交付份数(跨日自动归零)。读取失败视为 0,不阻塞主界面。
  Future<int> todayCount() async {
    try {
      final f = await _stateFile();
      if (!await f.exists()) return 0;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (json['date'] != _today()) return 0;
      return json['count'] as int? ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 一次交付成功后 +1(跨日先归零再 +1)。返回递增后的计数。
  Future<int> increment() async {
    final current = await todayCount();
    final next = current + 1;
    try {
      final f = await _stateFile();
      await f.writeAsString(jsonEncode({'date': _today(), 'count': next}));
    } catch (_) {}
    return next;
  }
}
