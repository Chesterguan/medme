import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 「医生代拍」交付结果弹窗:记录数说明 + 可复制的口令 + 「分享文件」按钮。
///
/// 与 `screens/export_screen.dart` 的 `_showShareResult` 是**同一份 UI/文案的
/// 独立副本**,不是共享组件——两者交付方向相反(患者→医生 vs 医生→病人),
/// 措辞不能共用同一句话;拆开维护也让「不碰普通人模式一行代码」这条硬规矩
/// 在这个文件上是显而易见成立的(`export_screen.dart` 完全不知道本文件存在)。
/// 宁可这 ~100 行重复,也不去改 `export_screen.dart` 抽公共组件。
Future<void> showDoctorShareResultDialog(
  BuildContext context,
  ShareResultDto result, {
  required Rect Function() shareOrigin,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) {
      final c = MedColors.of(context);
      return AlertDialog(
        title: const Text('加密文件已生成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '共 ${result.recordCount} 份记录,已打包为端到端加密文件。',
              style: MedType.body.copyWith(color: c.ink2),
            ),
            const SizedBox(height: MedShape.s1),
            Text(
              '请把这份文件交给病人本人保管,口令请当面口头告知或用不同渠道另发;'
              // 口径必须与拍前告知一致:现在是「本机留 12 小时后自动删」,不是「不留底」。
              // 说了留 12 小时却写「不会留底」= 对病人失信,红线(见 ProxyPatientManager)。
              '对方打开文件、输入口令即可查看,数据始终端到端加密。'
              '这台设备上的材料最多留 12 小时,到时间自动删。',
              style: MedType.body.copyWith(color: c.ink2, height: 1.5),
            ),
            const SizedBox(height: MedShape.s2),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MedShape.s2,
                vertical: MedShape.s1,
              ),
              decoration: BoxDecoration(
                color: c.paper,
                borderRadius: BorderRadius.circular(MedShape.radiusControl),
                border: Border.all(color: c.line),
              ),
              child: Row(
                children: [
                  // 「口令」小标签提到 12(规范下限),原先 11 低于下限。
                  Text('口令', style: MedType.caption.copyWith(color: c.ink3)),
                  const SizedBox(width: MedShape.s1),
                  Expanded(
                    // 口令要一个字一个字念给病人听 —— 等宽表格数字,字距放宽。
                    child: Text(
                      result.passphrase,
                      style: MedType.subtitle.copyWith(
                        color: c.ink,
                        letterSpacing: 0.5,
                        fontFeatures: MedType.tabular,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制口令',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: result.passphrase),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(appSnackBar(content: Text('口令已复制')));
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: c.proxy),
            icon: const Icon(Icons.ios_share),
            label: const Text('分享文件'),
            onPressed: () async {
              await SharePlus.instance.share(
                ShareParams(
                  files: [XFile(result.path)],
                  subject: 'MedMe 病历(代建档)',
                  sharePositionOrigin: shareOrigin(),
                ),
              );
            },
          ),
        ],
      );
    },
  );
}
