import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/proxy_patient_manager.dart';
import 'package:mobile_flutter/screens/doctor/doctor_delivery_count.dart';
import 'package:mobile_flutter/screens/doctor/proxy_intake_flow.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 医生模式主界面——不放进「导出·分享」tab,是独立的应用根(见 `main.dart` 的
/// `AppRoot`)。「为病人代拍」按钮 + **今日病历表**:代拍过的病人按姓名列在这里,
/// 本机最多留 12 小时(到点由 [ProxyPatientManager] 自动删),期间可点回去补拍、
/// 继续核对、重新交付。右上「清空」一次删干净。
///
/// 视觉:主色走 `MedColors.proxy`(紫),不是个人模式的 `seal`(蓝)——医生模式
/// 的每一屏都靠这个颜色宣告「这不是你自己的档案」。除主色外的一切(中性色、字阶、
/// 圆角、阴影、卡片)与个人模式同源。
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
          style: FilledButton.styleFrom(
            backgroundColor: MedColors.of(context).critical,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
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
              padding: const EdgeInsets.fromLTRB(
                MedShape.s5,
                MedShape.s5,
                MedShape.s5,
                MedShape.s1,
              ),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: c.proxyWash,
                    child: Icon(
                      Icons.medical_services_outlined,
                      color: c.proxy,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: MedShape.s2),
                  Text('为病人代建档', style: MedType.title.copyWith(color: c.ink)),
                  const SizedBox(height: 6),
                  Text(
                    '当面征得同意后拍摄病人的纸质病历材料,拍完生成一个认领码让病人当场扫走;'
                    '网络不畅时退回加密文件+口令。本机最多留 12 小时,到时间自动删。',
                    textAlign: TextAlign.center,
                    style: MedType.secondary.copyWith(
                      color: c.ink2,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: MedShape.s4),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton.icon(
                      // 一屏唯一的主按钮:紫色纯色不用渐变(规范 §六)。
                      style: FilledButton.styleFrom(backgroundColor: c.proxy),
                      onPressed: _startCapture,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('为病人代拍'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildList()),
            Padding(
              padding: const EdgeInsets.only(bottom: MedShape.s2, top: 4),
              child: Text(
                '今日已交付 ${_todayCount ?? 0} 份',
                // 数字要等宽:一天下来这行只有它在变。
                style: MedType.secondary.copyWith(
                  color: c.ink3,
                  fontFeatures: MedType.tabular,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final c = MedColors.of(context);
    if (_patients.isEmpty) {
      // 空态给虚线框(规范 §六)——出路就在框正上方那个主按钮,不再重复一个。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MedShape.s6),
          child: DottedBorderBox(
            child: Text(
              '还没有代拍的病人。\n代拍过的会列在这里,12 小时内可以随时回来补拍或重发。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        MedShape.s3,
        MedShape.s1,
        MedShape.s3,
        MedShape.s1,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, MedShape.s1),
          child: Text('今日病历表', style: MedType.caption.copyWith(color: c.ink3)),
        ),
        for (final p in _patients)
          Padding(
            padding: const EdgeInsets.only(bottom: MedShape.s1),
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
///
/// **不带骑缝线。** 这是一张派生卡:名字是从若干份原件里识别出来的、份数是数出来
/// 的,背后没有「某一张纸」可点进去(点进去是这个病人的清单)。骑缝线只给点得进
/// 原件的卡(规范 §五),当装饰用就把「可溯源」这句话说成了假话。
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
    final c = MedColors.of(context);
    return MedCard(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MedShape.s2,
              MedShape.s2,
              4,
              MedShape.s2,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.proxyWash,
                    borderRadius: BorderRadius.circular(MedShape.radiusControl),
                  ),
                  child: Icon(Icons.person_outline, size: 19, color: c.proxy),
                ),
                const SizedBox(width: MedShape.s2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        patient.displayName,
                        style: MedType.subtitle.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${patient.docCount} 份 · ${_remainingLabel(patient.remaining)}',
                        // 份数与倒计时都是数字,等宽才对得齐。
                        style: MedType.secondary.copyWith(
                          color: c.ink2,
                          fontFeatures: MedType.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: c.ink3,
                  tooltip: '删除这个病人',
                  onPressed: onDelete,
                ),
              ],
            ),
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
