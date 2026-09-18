import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/theme.dart';

import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 从「给医生看」页的「导出文件」那一行进(Task 17 之后不再是底栏 tab)——只做
/// 可打印文件(HTML,可按日期区间筛选)。**出码不在这里**:那条路全 App 只有
/// 一条,就是「给医生看」页钉底的那颗「出码给医生看」(终审 I2)。手机端只做
/// 「轻」的导出/筛选;全文搜索、趋势等「重」功能在桌面端与医生查看器。导出全在
/// Rust core(`medme_share`),这里只调 FFI + 分享。
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  bool _busy = false;
  String? _progress;

  /// iOS 的分享面板(尤其 iPad)必须知道从哪个位置弹出(popover 锚点矩形),否则
  /// `SharePlus` 抛 `argument must be set {{0,0},{0,0}} must be non-zero`。用本屏渲染框作锚点。
  Rect _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && !box.size.isEmpty) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return const Rect.fromLTWH(0, 0, 1, 1);
  }

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _exportTimeline() async {
    DateTime? from;
    DateTime? to;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          Future<void> pickDate(bool isFrom) async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: (isFrom ? from : to) ?? now,
              firstDate: DateTime(1970),
              lastDate: DateTime(now.year + 1),
            );
            if (picked != null) {
              setDialog(() => isFrom ? from = picked : to = picked);
            }
          }

          return AlertDialog(
            title: const Text('导出时间线'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '导出病历时间线为可打印文件(HTML),未加密,用浏览器打开后可直接打印或另存为 PDF,适合报销或给医生留档。',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: MedMe.faint,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '时间范围(可选,留空即导出全部)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => pickDate(true),
                        child: Text('从:${from == null ? '不限' : _ymd(from!)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => pickDate(false),
                        child: Text('到:${to == null ? '不限' : _ymd(to!)}'),
                      ),
                    ),
                  ],
                ),
                if (from != null || to != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setDialog(() {
                        from = null;
                        to = null;
                      }),
                      child: const Text('清除范围'),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  if (from != null && to != null && from!.isAfter(to!)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      appSnackBar(content: Text('起始日期不能晚于结束日期')),
                    );
                    return;
                  }
                  Navigator.of(context).pop(true);
                },
                child: const Text('导出'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _progress = '正在生成导出文件…';
    });
    try {
      final result = await exportTimelineHtml(
        fromDate: from == null ? null : _ymd(from!),
        toDate: to == null ? null : _ymd(to!),
      );
      // 「导出完成」= 文件已生成。之后的系统分享面板用户可能取消,那是另一回事,
      // 也拿不到可靠回调 —— 与代拍交付同一条口径(文件生成即算数)。
      // `ranged` 只报「用没用日期筛选」这个布尔,**不报是哪段日期**(那是就诊时间)。
      Analytics.track(AnalyticsEvent.exportCompleted, {
        'ranged': from != null || to != null,
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(result.path)],
          subject: 'MedMe 病历时间线导出',
          sharePositionOrigin: _shareOrigin(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
      });
      await _showError('导出失败', '$e');
    }
  }

  // 注:「加密分享给医生」(自包含加密 HTML + 口令)**只撤了移动端入口**,能力全留着 ——
  // 二维码扩展到完整数据与原件之后,它与二维码抢同一个心智位,所以先拿掉;这块位置
  // 以后可能改成别的功能。
  //
  // 不要顺手删底层:桌面端仍在用 `create_share`,认领密文与它共用同一段装配代码
  // (`build_share_blob_inner`),而且**已经发出去的分享文件必须仍能用查看器的口令模式
  // 打开** —— 删了就等于让别人手里的文件变成死文件。

  Future<void> _showError(String title, String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导出文件')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // 出码只有一条路:「病历 → 给医生看 → 出码给医生看」那颗钉底的按钮。
              // 这一屏原来也放过一张「当面给医生看 / 出示二维码」的卡,那是第二扇
              // 同名的门(深度 4,超过硬约束的「核心流程 ≤3」),终审 I2 删掉。
              _ActionCard(
                icon: Icons.description_outlined,
                title: '导出时间线',
                subtitle: '导出可打印文件(HTML),可按日期区间筛选;适合报销、留档或给医生。',
                buttonLabel: '选择范围并导出',
                onPressed: _busy ? null : _exportTimeline,
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: MedColors.of(context).scrimLight,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                          const SizedBox(width: 16),
                          Text(_progress ?? '处理中…'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 导出/分享的大动作卡:图标 + 标题 + 说明 + 主按钮。
class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: MedMe.teal, size: 26),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: MedMe.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 13.5,
                color: MedMe.faint,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onPressed,
                child: Text(buttonLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
