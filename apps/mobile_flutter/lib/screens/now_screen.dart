// 「现在」tab(2026-10-23 spec §4):占位,正文在后续任务里落地。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';

class NowScreen extends StatelessWidget {
  const NowScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('现在')),
      body: Center(
        child: Text('还没有诊断或化验记录', style: MedType.body.copyWith(color: c.ink2)),
      ),
    );
  }
}
