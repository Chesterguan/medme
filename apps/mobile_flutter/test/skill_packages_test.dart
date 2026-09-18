import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/skill_packages.dart';

/// 一份"验过的清单"长什么样 —— 与 `vault_profile_verify_index` 的返回形状一致
/// (id/version/min_engine/name)。
String _verified(List<Map<String, Object>> skills) => jsonEncode({'skills': skills});

const _sle = {'id': 'sle', 'version': '2026.09.1', 'min_engine': 1, 'name': '系统性红斑狼疮'};

void main() {
  // 中间人把 version 改成 "../../x" 或一个不存在的号,只要客户端不先验签就照拉。
  // 这条钉的是顺序:**验签在拼路径之前**。
  test('清单没验过就不许发第二个请求', () async {
    final seen = <String>[];
    final pkgs = SkillPackages(
      dir: '/tmp/skills-cache',
      httpGet: (path, headers) async {
        seen.add(path);
        return '{"sig":"AA","package":"{}"}';
      },
      verifyIndex: (envelope) async => throw Exception('包签名验证不通过'),
      install: (dir, envelope) async => fail('清单都没验过,不该装任何东西'),
    );

    expect(await pkgs.refreshIndex(), isEmpty, reason: '失败静默:不抛,退回缓存里那份');
    expect(seen, [skillsIndexPath], reason: '清单没验过就不许发第二个请求');
  });

  // 隐私断言,不是网络断言(spec §8):请求里除了包 id/版本,**也不能带账号**——
  // 否则服务端能把「谁」和「开了哪个病」对上。
  test('拉包不带任何账号头', () async {
    final captured = <String, String>{};
    final pkgs = SkillPackages(
      dir: '/tmp/skills-cache',
      httpGet: (path, headers) async {
        captured.addAll(headers);
        return 'envelope-$path';
      },
      verifyIndex: (envelope) async => _verified([_sle]),
      install: (dir, envelope) async => 'sle',
    );

    await pkgs.refreshIndex();
    expect(captured, isEmpty);
    expect(captured.containsKey('Authorization'), isFalse);
    expect(captured.containsKey('X-Device-Id'), isFalse);
  });

  test('验过的清单才拿去拼路径,信封原样交给 Rust', () async {
    final seen = <String>[];
    String? installedInto;
    String? installedEnvelope;
    final pkgs = SkillPackages(
      dir: '/tmp/skills-cache',
      httpGet: (path, headers) async {
        seen.add(path);
        return path == skillsIndexPath ? '{"sig":"real","package":"…"}' : '包信封原文';
      },
      verifyIndex: (_) async => _verified([_sle]),
      install: (dir, envelopeJson) async {
        installedInto = dir;
        installedEnvelope = envelopeJson;
        return 'sle';
      },
    );

    expect(await pkgs.refreshIndex(), ['sle']);
    expect(seen, [skillsIndexPath, '/v1/skills/sle/2026.09.1.json']);
    expect(installedInto, '/tmp/skills-cache');
    expect(installedEnvelope, '包信封原文', reason: 'Dart 不解读包体,原样转交');
  });

  test('一个包装不上(引擎太老/拒绝降级),别的照装', () async {
    var calls = 0;
    final pkgs = SkillPackages(
      dir: '/tmp/skills-cache',
      httpGet: (path, headers) async => 'envelope',
      verifyIndex: (envelope) async => _verified([
        _sle,
        {'id': 'future', 'version': '2027.01.1', 'min_engine': 99, 'name': '未来病'},
      ]),
      install: (dir, envelopeJson) async {
        // 清单里 sle 在前、future 在后:第二次装的那个是引擎太老的那份。
        calls++;
        if (calls == 2) throw Exception('这个病种包需要 App 引擎 v99,当前是 v1');
        return 'sle';
      },
    );

    expect(await pkgs.refreshIndex(), ['sle'], reason: '装不上的那个只是这次没更新');
    expect(calls, 2, reason: '第一个失败不该让循环提前结束');
  });
}
