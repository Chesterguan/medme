import 'package:flutter/material.dart';

import 'package:mobile_flutter/screens/doctor/doctor_delivery_count.dart';
import 'package:mobile_flutter/screens/doctor/proxy_intake_flow.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/theme.dart';

/// 医生模式主界面——不放进「导出·分享」tab,是独立的应用根(见 `main.dart` 的
/// `AppRoot`)。简洁全屏:主体一个大按钮「为病人代拍」,顶部可进「设置」
/// (切换回个人模式、看自己的家庭档案在那里)。
class DoctorHomeScreen extends StatefulWidget {
  const DoctorHomeScreen({super.key});

  @override
  State<DoctorHomeScreen> createState() => _DoctorHomeScreenState();
}

class _DoctorHomeScreenState extends State<DoctorHomeScreen> {
  int? _todayCount;

  @override
  void initState() {
    super.initState();
    _refreshCount();
  }

  Future<void> _refreshCount() async {
    final n = await DoctorDeliveryCount.instance.todayCount();
    if (mounted) setState(() => _todayCount = n);
  }

  Future<void> _startCapture() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const ProxyIntakeFlow(),
      ),
    );
    // 交付成功时 `ProxyIntakeFlow` 已自己 +1 计数;这里统一重新读一次——交付/
    // 取消都对,读到的永远是当下真实值。
    await _refreshCount();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('医生模式'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 44,
                backgroundColor: MedMe.proxyOrangeSoft,
                child: const Icon(
                  Icons.medical_services_outlined,
                  color: MedMe.proxyOrange,
                  size: 42,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '为病人代建档',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                '当面征得同意后拍摄病人的纸质病历材料,生成一份加密文件当场交给病人;'
                '这台设备不会留底。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: MedMe.faint, height: 1.5),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: MedMe.proxyOrange),
                  onPressed: _startCapture,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text(
                    '为病人代拍',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '今日已交付 ${_todayCount ?? 0} 份',
                style: const TextStyle(fontSize: 13, color: MedMe.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
