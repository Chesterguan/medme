// 病程档案的几样原生能力拢在一个口子上:装着哪几个包、拉一次清单、算一份(单包)视图、
// 算通用视图、记一条动作。原在 `disease_profile_screen.dart`;2026-10-23 档案页删除后,
// 二维码分享(`qr_share_screen.dart` 的 `profileJsonForShare`)仍要单包视图,所以留下这个类。
// 摆成可注入的**只为 widget 测试**(与 `SkillPackages` 同一手法)。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mobile_flutter/doc_labels.dart' show fmtDate;
import 'package:mobile_flutter/skill_packages.dart';
import 'package:mobile_flutter/src/rust/api/vault_profile.dart' as rust_profile;

/// 病程档案这一块要碰的几样原生能力,拢在一个口子上:装着哪几个包、拉一次清单、
/// 算一份(单包)视图、算通用视图、记一条动作。
///
/// 摆成可注入的**只为 widget 测试**(与 `SkillPackages` 同一手法):这几件事全都
/// 要么走 FFI、要么走平台通道,`flutter test` 不带原生库,不注入就一条都跑不起来。
class DiseaseProfileSource {
  DiseaseProfileSource({
    Future<List<String>> Function()? installed,
    Future<String> Function(String packageId)? view,
    Future<void> Function(String kind, String packageId, String at)? record,
    Future<void> Function()? refresh,
    Future<String> Function()? general,
  }) : _installed = installed ?? _installedPackageIds,
       _view = view ?? _viewFromVault,
       _record = record ?? _recordToVault,
       _refresh = refresh ?? _refreshFromIndex,
       _general = general ?? _generalFromVault;

  final Future<List<String>> Function() _installed;
  final Future<String> Function(String packageId) _view;
  final Future<void> Function(String kind, String packageId, String at) _record;
  final Future<void> Function() _refresh;
  final Future<String> Function() _general;

  /// 缓存里装着哪几个病种包(id,已排序)。空 = 一个都没有。
  Future<List<String>> installedPackages() => _installed();

  /// 拉一次清单,把清单里列的包装上。**永不抛**(`SkillPackages.refreshIndex`
  /// 自己保证):没网、验签不过,都只是这次没更新,退回缓存里已经装着的那份。
  Future<void> refresh() => _refresh();

  /// 通用视图(`vault_profile_view_general`):通用段 + 每个开着的包的段 + 顶层
  /// `packages[]`(装着的包:id / display_name / enabled)+ `documents[]` 桥。
  /// **纯投影**,不写任何东西进病历箱。算不出来就抛给调用方(入口卡退到「还没准备好」)。
  Future<Map<String, dynamic>> general() async =>
      jsonDecode(await _general()) as Map<String, dynamic>;

  /// 单包视图。出码那条路要的是这个:那串原样塞进加密分享包交给医生
  /// (`qr_share_screen.dart` 的 `profileJsonForShare`)。
  ///
  /// **算不出来就先重新拉一遍包,再算一次。** 缓存在用户可写的磁盘上,是不可信
  /// 输入,`profile::cache_load` 每次读都重新验签 —— 「装着的那份被改过一个字节」
  /// 和「压根没装」在这里是同一种失败,重新拉一遍才是出路。
  Future<Map<String, dynamic>> view(String packageId) async {
    try {
      return await _viewMap(packageId);
    } catch (e) {
      // 只有包 id 和一句错误文本,没有病历内容,可以进日志。
      debugPrint('[profile] $packageId 这次算不出来,重新拉一遍包再试:$e');
      await _refresh();
      return await _viewMap(packageId);
    }
  }

  Future<Map<String, dynamic>> _viewMap(String packageId) async =>
      jsonDecode(await viewJson(packageId)) as Map<String, dynamic>;

  /// 同 [view],但给回**没解析过的原串**;**这一路不自愈**(出码是在诊室里按的,
  /// 没网时那一趟拉包要耗到连接超时)。包坏了就这一次不带档案。
  Future<String> viewJson(String packageId) => _view(packageId);

  /// 记一条 `enable`/`disable`,**真记上了才回 `true`**。
  ///
  /// `at` 是**今天**(设备本地日期,`YYYY-MM-DD`)—— 开关闸按 `at` 排序
  /// (`profile::is_enabled`),而 FFI 那一侧会把形状不对的日期直接挡回来。
  Future<bool> record(String kind, String packageId) async {
    try {
      await _record(kind, packageId, fmtDate(DateTime.now().toIso8601String()));
      return true;
    } catch (e) {
      debugPrint('[profile] $kind 这次没记上:$e');
      return false;
    }
  }
}

/// 缓存目录里装着的包 id。与 Rust 侧 `installed_packages` 读的是**同一个目录、
/// 同一种文件名**(`skills/<id>.json`)。只列文件名、不读内容:包体每次读都要重新验签。
Future<List<String>> _installedPackageIds() async {
  final d = Directory('${await skillCacheDir()}/skills');
  if (!d.existsSync()) return const [];
  return d
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.json'))
      .map((n) => n.substring(0, n.length - '.json'.length))
      .toList()
    ..sort();
}

Future<String> _viewFromVault(String packageId) async =>
    rust_profile.vaultProfileView(dir: await skillCacheDir(), packageId: packageId);

Future<String> _generalFromVault() async =>
    rust_profile.vaultProfileViewGeneral(dir: await skillCacheDir());

/// 载荷必须是 JSON **对象**(FFI 那一侧挡着):开关这两种动作没有别的要记的,给空对象。
Future<void> _recordToVault(String kind, String packageId, String at) async {
  await rust_profile.vaultProfileRecordEvent(
    kind: kind,
    package: packageId,
    at: at,
    payloadJson: '{}',
  );
}

Future<void> _refreshFromIndex() => SkillPackages().refreshIndex();
