// 「用药」tab(2026-10-23 spec §5):占位,正文在后续任务里落地。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';

class MedsScreen extends StatelessWidget {
  const MedsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('用药')),
      body: Center(
        child: Text('最近 180 天没有用药记录', style: MedType.body.copyWith(color: c.ink2)),
      ),
    );
  }
}
