import 'package:flutter/material.dart';

import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/screens/doctor/doctor_delivery_count.dart';
import 'package:mobile_flutter/screens/doctor/proxy_intake_flow.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/theme.dart';

/// 医生模式主界面——不放进「导出·分享」tab,是独立的应用根(见 `main.dart` 的
/// `AppRoot`)。「为病人代拍」按钮 + **今日病历表**:代拍过的病人按姓名列在这里,
/// 本机最多留 12 小时(到点由 [ProxyPatientManager] 自动删),期间可点回去补拍、
/// 继续核对、重新交付。右上「清空」一次删干净。
class DoctorHomeScreen extends StatefulWidget {
  const DoctorHomeScreen({super.key});

  @override
  State<DoctorHomeScreen> createState() => _DoctorHomeScreenState();
}

class _DoctorHomeScreenState extends State<DoctorHomeScreen> {
  int? _todayCount;
  List<ProxyPatient> _patients = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 每次回到这一屏都重读:`ensureLoaded` 顺手执行 12 小时 TTL,所以过期的病人是在
  /// 这里消失的——不需要后台定时器。
  Future<void> _refresh() async {
    final n = await DoctorDeliveryCount.instance.todayCount();
    await ProxyPatientManager.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _todayCount = n;
      _patients = ProxyPatientManager.instance.patients;
    });
  }

  Future<void> _startCapture() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const ProxyIntakeFlow(),
      ),
    );
    await _refresh();
  }

  /// 点回一个已建档的病人:开他的箱子继续核对/补拍/交付(同意已经签过)。
  Future<void> _openPatient(ProxyPatient p) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ProxyIntakeFlow(patientId: p.id),
      ),
    );
    await _refresh();
  }

  Future<void> _removeOne(ProxyPatient p) async {
    final ok = await _confirm(
      '删掉「${p.displayName}」?',
      '这个病人在本机的病历材料会立刻删除,不可撤销。已经交给病人的加密文件不受影响。',
    );
    if (ok != true) return;
    await ProxyPatientManager.instance.remove(p.id);
    await _refresh();
  }

  Future<void> _removeAll() async {
    final ok = await _confirm(
      '清空今日病历表?',
      '${_patients.length} 位病人在本机的材料会立刻全部删除,不可撤销。'
          '你自己的档案不受影响。',
    );
    if (ok != true) return;
    await ProxyPatientManager.instance.removeAll();
    await _refresh();
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: MedMe.danger),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('医生模式'),
        actions: [
          if (_patients.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空今日病历表',
              onPressed: _removeAll,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 8),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: MedMe.proxyOrangeSoft,
                    child: const Icon(
                      Icons.medical_services_outlined,
                      color: MedMe.proxyOrange,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '为病人代建档',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '当面征得同意后拍摄病人的纸质病历材料,拍完生成一个认领码让病人当场扫走;'
                    '网络不畅时退回加密文件+口令。本机最多留 12 小时,到时间自动删。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: MedMe.faint, height: 1.5),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: MedMe.proxyOrange,
                      ),
                      onPressed: _startCapture,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text(
                        '为病人代拍',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildList()),
            Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 4),
              child: Text(
                '今日已交付 ${_todayCount ?? 0} 份',
                style: const TextStyle(fontSize: 13, color: MedMe.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_patients.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '还没有代拍的病人。\n代拍过的会列在这里,12 小时内可以随时回来补拍或重发。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: MedMe.faint, height: 1.6),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text(
            '今日病历表',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: MedMe.faint,
            ),
          ),
        ),
        for (final p in _patients)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PatientRow(
              patient: p,
              onTap: () => _openPatient(p),
              onDelete: () => _removeOne(p),
            ),
          ),
      ],
    );
  }
}

/// 今日病历表一行:病人名 + 份数 + 还剩多久自动删 + 删除按钮。
class _PatientRow extends StatelessWidget {
  const _PatientRow({
    required this.patient,
    required this.onTap,
    required this.onDelete,
  });

  final ProxyPatient patient;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MedMe.panel,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: MedMe.line),
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: MedMe.proxyOrangeSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.person_outline,
                  size: 19,
                  color: MedMe.proxyOrange,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patient.displayName,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${patient.docCount} 份 · ${_remainingLabel(patient.remaining)}',
                      style: const TextStyle(fontSize: 12.5, color: MedMe.faint),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: MedMe.faint,
                tooltip: '删除这个病人',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「还剩 N 小时/分钟自动删」。不到一分钟就说「即将自动删除」,不显示 0 分钟。
String _remainingLabel(Duration d) {
  if (d.inMinutes < 1) return '即将自动删除';
  if (d.inHours < 1) return '还剩 ${d.inMinutes} 分钟自动删';
  return '还剩 ${d.inHours} 小时自动删';
}
