// 通用视图 / 用药视图 / 化验族表的进程内缓存:同一 vault 版本只算一次(健康摘要在真实规模下
// 约 2 秒),切 tab、健康摘要与化验页共用时不重算;`vaultRevision` 变了下次取才重算。
import 'dart:convert';

import 'package:mobile_flutter/skill_packages.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;
import 'package:mobile_flutter/vault_events.dart';

class _Memo<T> {
  _Memo(this._compute);
  final Future<T> Function() _compute;
  int _rev = -1;
  Future<T>? _future;

  Future<T> get() {
    final rev = vaultRevision.value;
    if (_future == null || rev != _rev) {
      _rev = rev;
      // 失败不缓存:下一次取重算。
      _future = _compute().catchError((Object e, StackTrace s) {
        _future = null;
        return Future<T>.error(e, s);
      });
    }
    return _future!;
  }
}

final _general = _Memo<Map<String, dynamic>>(
  () async => jsonDecode(await rust_profile.vaultProfileViewGeneral(dir: await skillCacheDir())) as Map<String, dynamic>,
);
final _meds = _Memo<Map<String, dynamic>>(
  () async => jsonDecode(await rust_profile.vaultProfileMedsView(dir: await skillCacheDir())) as Map<String, dynamic>,
);
final _labFamilies = _Memo<Map<String, dynamic>>(
  () async => jsonDecode(await rust_profile.vaultProfileLabFamilies()) as Map<String, dynamic>,
);

Future<Map<String, dynamic>> cachedGeneralView() => _general.get();
Future<Map<String, dynamic>> cachedMedsView() => _meds.get();
Future<Map<String, dynamic>> cachedLabFamilies() => _labFamilies.get();
