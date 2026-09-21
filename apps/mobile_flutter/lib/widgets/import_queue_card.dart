import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/import_queue.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 档案屏顶部那几行「识别中」。
///
/// 导入改成后台跑之后,用户点完「导入」就回到档案了 —— 这张卡是他**唯一**能看见
/// 「东西确实在处理」的地方。所以它:
/// * 挂在模块级的 [importJobs] 上,不挂本屏 state —— 切去概览再切回来,这几行
///   还在(队列本来就不属于哪一屏);
/// * 跑完就自己撤掉,只留下还有话要说的那几行(失败 / 仅存原件 / 该重拍);
/// * 失败那一行带「重试」——**静默丢掉一份病历是不可接受的**,这是那道兜底。
class ImportQueueCard extends StatelessWidget {
  const ImportQueueCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ImportJob>>(
      valueListenable: importJobs,
      builder: (context, jobs, _) => ValueListenableBuilder<String?>(
        valueListenable: importQueueNotice,
        builder: (context, notice, _) {
          if (jobs.isEmpty && notice == null) return const SizedBox.shrink();
          final c = MedColors.of(context);
          final running = jobs
              .where(
                (j) =>
                    j.state == ImportJobState.queued ||
                    j.state == ImportJobState.running,
              )
              .length;
          return Padding(
            padding: const EdgeInsets.only(bottom: MedShape.s2),
            child: MedCard(
              child: Padding(
                padding: const EdgeInsets.all(MedShape.s2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (running > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: MedShape.s1),
                        child: Text(
                          '正在后台识别 $running 份 —— 可以先去做别的,识别完会自己出现',
                          style: MedType.secondary.copyWith(
                            color: c.ink2,
                            fontFeatures: MedType.tabular,
                          ),
                        ),
                      ),
                    for (final job in jobs) _JobRow(job: job),
                    if (notice != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              notice,
                              style: MedType.secondary.copyWith(color: c.high),
                            ),
                          ),
                          IconButton(
                            onPressed: () => importQueueNotice.value = null,
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: '知道了',
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job});

  final ImportJob job;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final failed = job.state == ImportJobState.failed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: switch (job.state) {
              ImportJobState.running => CircularProgressIndicator(
                strokeWidth: 2,
                color: c.seal,
              ),
              ImportJobState.queued => Icon(
                Icons.schedule,
                size: 18,
                color: c.ink3,
              ),
              ImportJobState.failed => Icon(
                Icons.error_outline,
                size: 18,
                color: c.critical,
              ),
              ImportJobState.done => Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: c.high,
              ),
            },
          ),
          const SizedBox(width: MedShape.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.label,
                  style: MedType.body.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _statusLine(job),
                  style: MedType.caption.copyWith(
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                    color: failed ? c.critical : c.ink2,
                  ),
                ),
              ],
            ),
          ),
          if (failed)
            TextButton(
              onPressed: () => retryImportJob(job),
              child: const Text('重试'),
            ),
          if (job.state == ImportJobState.done || failed)
            IconButton(
              onPressed: () => dismissImportJob(job),
              icon: const Icon(Icons.close, size: 18),
              tooltip: '不再提示',
            ),
        ],
      ),
    );
  }
}

/// 这一行下面那句状态。跑完还留着的行一定是**有话要说**的(见
/// [ImportJob.needsAttention]),所以这里没有「已完成」这种废话。
String _statusLine(ImportJob job) => switch (job.state) {
  ImportJobState.queued => '排队中',
  ImportJobState.running => '正在识别…',
  ImportJobState.failed => job.error ?? '没能处理这一份',
  ImportJobState.done when job.lowOcrYield =>
    '已入库,但本机只认出几个字,没有送云端整理 —— 建议重拍',
  ImportJobState.done => job.row?.statusLabel ?? '已入库',
};
