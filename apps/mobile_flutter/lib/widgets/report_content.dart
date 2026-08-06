import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../report_content.dart' show LabFlag, LabRow, tryParseLabRun;
import 'med_card.dart';

// 内容感知渲染(维度 B):按文档类型富渲染,移植自桌面端
// apps/desktop/src/components/ReportContent.tsx。
//  - 化验 → 表格(指标/结果/单位/参考范围,按 ↑/↓ 着色)
//  - 处方 → 用药清单卡片
//  - 病理/影像/出院/病历/手术 → 分节(【…】/结论/诊断 等标题加粗)+ 行内标签加粗
//  - 其余/解析不到结构 → 退回干净段落 —— 永不比原文更糟(见 memory:
//    content-aware-rendering)。

/// 档案/文档详情屏复用的富文本渲染;`docType` 为空或未知类型时退回通用分块。
class ReportContent extends StatelessWidget {
  final String text;
  final String? docType;

  const ReportContent({super.key, required this.text, this.docType});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return Text(
        '无文本内容。',
        style: MedType.secondary.copyWith(color: MedColors.of(context).ink3),
      );
    }

    // 处方 → 用药清单
    if (docType == 'prescription') {
      final meds = _parseMeds(text);
      if (meds != null) {
        return _MedsView(meds: meds);
      }
    }

    // 其余类型(化验表格 / 病理·影像·出院·病历·手术 分节+行内标签 / 通用)
    final blocks = _parseBlocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: MedShape.s3),
          _blockView(blocks[i]),
        ],
      ],
    );
  }
}

// ── 分块模型(化验表 / 通用多空格表 / 分节标题 / 段落)──

sealed class _Block {}

class _LabTableBlock extends _Block {
  final List<LabRow> rows;
  _LabTableBlock(this.rows);
}

class _TableBlock extends _Block {
  final List<String>? header;
  final List<List<String>> rows;
  _TableBlock(this.header, this.rows);
}

class _SectionBlock extends _Block {
  final String text;
  _SectionBlock(this.text);
}

class _ParaBlock extends _Block {
  final String text;
  _ParaBlock(this.text);
}

Widget _blockView(_Block b) {
  return switch (b) {
    _LabTableBlock(:final rows) => _LabTableView(rows: rows),
    _TableBlock(:final header, :final rows) => _GenericTableView(
      header: header,
      rows: rows,
    ),
    _SectionBlock(:final text) => _SectionView(text: text),
    _ParaBlock(:final text) => _ParaView(text: text),
  };
}

final RegExp _sectionBracketRe = RegExp(r'^[【\[].+[】\]]$');
final RegExp _shortLabelColonRe = RegExp(r'[:：]$');

List<_Block> _parseBlocks(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final blocks = <_Block>[];
  var i = 0;
  while (i < lines.length) {
    final trimmed = lines[i].trim();
    if (trimmed.isEmpty) {
      i++;
      continue;
    }

    // 化验单单空格塌陷场景:先按结构尝试识别连续的化验行(见 ../report_content.dart),
    // 命中则优先于下面基于"多空格分列"的通用表格解析。
    final labRun = tryParseLabRun(lines, i);
    if (labRun != null) {
      blocks.add(_LabTableBlock(labRun.rows));
      i = labRun.next;
      continue;
    }

    if (_isTableHeader(trimmed) || _isDataRow(trimmed)) {
      final start = i;
      final header = _isTableHeader(trimmed) ? _splitCells(trimmed) : null;
      if (header != null) i++;
      final rows = <List<String>>[];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          _isDataRow(lines[i])) {
        rows.add(_splitCells(lines[i]));
        i++;
      }
      if (rows.length >= 2) {
        blocks.add(_TableBlock(header, rows));
        continue;
      }
      i = start;
    }

    if (_sectionBracketRe.hasMatch(trimmed) ||
        (trimmed.length <= 14 && _shortLabelColonRe.hasMatch(trimmed))) {
      blocks.add(_SectionBlock(trimmed));
    } else {
      blocks.add(_ParaBlock(lines[i]));
    }
    i++;
  }
  return blocks;
}

List<String> _splitCells(String line) {
  return line
      .trim()
      .split(RegExp(r'\s{2,}|\t'))
      .where((c) => c.isNotEmpty)
      .toList();
}

bool _isTableHeader(String line) {
  const keys = ['项目', '结果', '单位', '参考', '提示', '名称', '缩写'];
  final hits = keys.where((k) => line.contains(k)).length;
  return hits >= 2 && _splitCells(line).length >= 3;
}

bool _isDataRow(String line) {
  return _splitCells(line).length >= 3 && RegExp(r'\d').hasMatch(line);
}

LabFlag? _rowStatus(List<String> cells) {
  final j = cells.join(' ');
  if (cells.contains('↑') || RegExp(r'↑|偏高|升高').hasMatch(j)) {
    return LabFlag.high;
  }
  if (cells.contains('↓') || RegExp(r'↓|偏低|降低|减低').hasMatch(j)) {
    return LabFlag.low;
  }
  if (j.contains('正常')) return LabFlag.normal;
  return null;
}

/// 化验状态 → 前景色。色值来自设计系统 v1 令牌(`MedColors`),不在这里写死。
/// 正常与无标记**不上色**,继承正文墨色 —— 一份血常规 22 项通常只有 1–2 项异常,
/// 给正常配色会把异常淹没(规范 §二)。
Color _flagColor(BuildContext context, LabFlag? flag) {
  final c = MedColors.of(context);
  if (flag == LabFlag.high) return c.high;
  if (flag == LabFlag.low) return c.low;
  return c.ink;
}

/// 化验状态 → 左侧色条。正常/无标记是**透明**的,但色条本身照画 —— 3px 的占位
/// 恒定,异常行才有颜色,整列文字起点才不会因为有没有色条而左右跳。
Color _stripeColor(BuildContext context, LabFlag? flag) {
  final c = MedColors.of(context);
  if (flag == LabFlag.high) return c.high;
  if (flag == LabFlag.low) return c.low;
  return Colors.transparent;
}

/// 化验状态 → 文字 pill。正常/无标记不给 pill。
///
/// 状态**同时**编码在色条和 pill 上:色盲用户靠 pill 读「偏低/偏高」,正常视力
/// 扫视靠色条(规范 §二)。少任何一个,就有一类用户读不到这一行的结论。
///
/// ⚠️ 规范的第四级「危急值」这里画不出来:它得由 Rust 在 `LabFlag` 里给出,而
/// 现在的 `LabFlag` 只有 high/low/normal 三个值。**不在 UI 层拿参考区间反推**
/// —— 007 §2.5「所有『怎么算』在 Rust,UI 只『怎么显示』」。令牌 `critical` /
/// `criticalWash` 因此暂时无人消费,等抽取侧补上这一级。
Widget? _flagPill(BuildContext context, LabFlag? flag) {
  final c = MedColors.of(context);
  return switch (flag) {
    LabFlag.high => MedPill(
      text: '偏高',
      foreground: c.high,
      background: c.highWash,
    ),
    LabFlag.low => MedPill(
      text: '偏低',
      foreground: c.low,
      background: c.lowWash,
    ),
    _ => null,
  };
}

// ── 段落:行内"标签:内容" → 标签加粗(主诉:/病理诊断:/诊断意见:…)──

final RegExp _labelRe = RegExp(r'^([一-龥A-Za-z]{2,10})([:：])(.*)$');

class _ParaView extends StatelessWidget {
  final String text;
  const _ParaView({required this.text});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // body 15·400,行高 1.6 —— 大段中文识别文本,行距比字号更影响可读性。
    final style = MedType.body.copyWith(height: 1.6, color: c.ink);
    final t = text.trimRight();
    final m = _labelRe.firstMatch(t);
    if (m != null && m.group(3)!.trim().isNotEmpty) {
      return Text.rich(
        TextSpan(
          style: style,
          children: [
            TextSpan(
              text: '${m.group(1)}${m.group(2)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: m.group(3)),
          ],
        ),
      );
    }
    return Text(text, style: style);
  }
}

class _SectionView extends StatelessWidget {
  final String text;
  const _SectionView({required this.text});

  @override
  Widget build(BuildContext context) {
    // 分节标题(【…】/「主诉:」这类)走 subtitle 17·600,比正文明确高一档 ——
    // 原先 15·700 只靠字重区分,放大字号后两者几乎分不开。
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: MedType.subtitle.copyWith(color: MedColors.of(context).ink),
      ),
    );
  }
}

// ── 表格:化验表(结构化解析)与通用多空格表共用的外框/单元格样式 ──

/// 表格外框:卡内分块这一档圆角(14),边框 `line`。
class _TableFrame extends StatelessWidget {
  final Widget child;
  const _TableFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        border: Border.all(color: c.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 表头单元格文字:caption 12·600·字距 .05em,`ink3`。原先是 11px ——
/// 低于规范 12px 下限(007 §2.5「字号可放大,不可砍」),已提上来。
TableRow _headerRow(BuildContext context, List<String> headers) {
  final c = MedColors.of(context);
  return TableRow(
    decoration: BoxDecoration(
      color: c.paper,
      border: Border(bottom: BorderSide(color: c.line)),
    ),
    children: [
      for (final h in headers)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MedShape.s2,
            vertical: MedShape.s1,
          ),
          child: Text(h, style: MedType.caption.copyWith(color: c.ink3)),
        ),
    ],
  );
}

/// 通用表格的单元格。[numeric] 只加**等宽表格数字**,不换字体 —— 原先给所有
/// 「数值列」套 `fontFamily: monospace`,而这些列里混着中文(单位、「正常」这类
/// 提示),中文落到等宽字体上会掉字重、掉字形。对齐要的是 tabular figures,
/// 不是等宽字体本身。
Widget _cell(String text, Color color, {bool numeric = false}) {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: MedShape.s2,
      vertical: 7,
    ),
    child: Text(
      text,
      style: MedType.secondary.copyWith(
        color: color,
        fontFeatures: numeric ? MedType.tabular : null,
      ),
    ),
  );
}

/// 化验表:一行一项,状态编码在**左侧 3px 色条**与**文字 pill** 上。
///
/// 相对旧版(四列 `Table` + 斑马纹 + 整行文字统一上色)的两处结构性改动:
///  - 斑马纹去掉,行间改用 `line-2` 细线 —— 规范 §四「层次靠边框不靠阴影」,
///    斑马纹在 22 行的血常规上是纯噪声,还会和状态底色打架。
///  - 单位不再单占一列。手机宽度下四列会把中文项目名挤成竖条;改成左「项目」
///    右「结果 + 参考区间」两栏,数值右对齐 + 等宽表格数字,一列数字自然对齐。
class _LabTableView extends StatelessWidget {
  final List<LabRow> rows;
  const _LabTableView({required this.rows});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return _TableFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: c.paper,
            padding: const EdgeInsets.fromLTRB(
              MedShape.s2,
              MedShape.s1,
              MedShape.s2,
              MedShape.s1,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    '项目',
                    style: MedType.caption.copyWith(color: c.ink3),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '结果 / 参考区间',
                    textAlign: TextAlign.right,
                    style: MedType.caption.copyWith(color: c.ink3),
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < rows.length; i++)
            _LabRowView(row: rows[i], last: i == rows.length - 1),
        ],
      ),
    );
  }
}

class _LabRowView extends StatelessWidget {
  const _LabRowView({required this.row, required this.last});

  final LabRow row;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final fg = _flagColor(context, row.flag);
    final pill = _flagPill(context, row.flag);
    return Container(
      decoration: BoxDecoration(
        border: Border(
          // 3px 色条走边框而不是独立的 Container:边框天然铺满整行高度,
          // 不需要 IntrinsicHeight 去量一遍。
          left: BorderSide(color: _stripeColor(context, row.flag), width: 3),
          bottom: last ? BorderSide.none : BorderSide(color: c.line2),
        ),
      ),
      // 左内边距 9 + 3px 色条 = s2(12),与右侧对齐;有没有色条都不跳。
      padding: const EdgeInsets.fromLTRB(9, 9, MedShape.s2, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Wrap(
              spacing: MedShape.s1,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(row.name, style: MedType.body.copyWith(color: c.ink)),
                ?pill,
              ],
            ),
          ),
          const SizedBox(width: MedShape.s2),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: row.value,
                        style: MedType.body.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: MedType.tabular,
                          color: fg,
                        ),
                      ),
                      if (row.unit.isNotEmpty)
                        TextSpan(
                          text: ' ${row.unit}',
                          style: MedType.secondary.copyWith(color: c.ink3),
                        ),
                    ],
                  ),
                  textAlign: TextAlign.right,
                ),
                if (row.range.isNotEmpty)
                  Text(
                    row.range,
                    textAlign: TextAlign.right,
                    style: MedType.caption.copyWith(
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                      fontFeatures: MedType.tabular,
                      color: c.ink3,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GenericTableView extends StatelessWidget {
  final List<String>? header;
  final List<List<String>> rows;
  const _GenericTableView({required this.header, required this.rows});

  @override
  Widget build(BuildContext context) {
    final cols = [
      header?.length ?? 0,
      for (final r in rows) r.length,
    ].reduce((a, b) => a > b ? a : b);

    // 通用表格的列数由 OCR 文本里「≥2 空格」切出,躺倒转正后的横向报告会切出很多列。
    // 用 FlexColumnWidth 均分会把每列挤到 ~1 字宽 → 中文按字竖排,看着像「行列颠倒」。
    // 改成:列宽按内容自适应(IntrinsicColumnWidth,不换行),整表放进横向滚动 —— 宽了
    // 用户左右滑,和桌面查看器一致,绝不再把中文挤成竖条。
    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        if (header != null)
          _headerRow(context, [
            for (var c = 0; c < cols; c++)
              c < header!.length ? header![c] : '',
          ]),
        for (var i = 0; i < rows.length; i++)
          _dataRow(context, i, rows[i], cols),
      ],
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: _TableFrame(child: table),
    );
  }

  TableRow _dataRow(
    BuildContext context,
    int index,
    List<String> r,
    int cols,
  ) {
    final color = _flagColor(context, _rowStatus(r));
    // 行间用 `line-2` 细线替代原来的斑马纹(规范 §四:层次靠边框不靠阴影)。
    // 末行不画,免得和外框叠成两条。
    final last = index == rows.length - 1;
    return TableRow(
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: MedColors.of(context).line2),
              ),
            ),
      children: [
        for (var c = 0; c < cols; c++)
          _cell(c < r.length ? r[c] : '', color, numeric: true),
      ],
    );
  }
}

// ── 处方:用药清单(移植自桌面端 ReportContent.tsx 的 parseMeds)──

class _Med {
  final String name;
  final List<String> usage;
  const _Med({required this.name, required this.usage});
}

class _MedsResult {
  final List<String> intro;
  final List<_Med> meds;
  final List<String> footer;
  const _MedsResult({
    required this.intro,
    required this.meds,
    required this.footer,
  });
}

final RegExp _numberedRe = RegExp(r'^(\d+)\s*[.、)]\s*(.+)');
final RegExp _footerKeywordRe = RegExp(r'^(医师|药师|审核|备注|Rp\.?|处方)');
final RegExp _rpOnlyRe = RegExp(r'^Rp\.?$');

_MedsResult? _parseMeds(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final meds = <_Med>[];
  final intro = <String>[];
  final footer = <String>[];
  String? curName;
  var usage = <String>[];
  var started = false;
  var ended = false;

  void pushCur() {
    if (curName != null) {
      meds.add(_Med(name: curName!, usage: usage));
      curName = null;
      usage = <String>[];
    }
  }

  for (final raw in lines) {
    final line = raw.trim();
    final numbered = _numberedRe.firstMatch(line);
    if (numbered != null) {
      started = true;
      ended = false;
      pushCur();
      curName = numbered.group(2)!.trim();
      continue;
    }
    if (_footerKeywordRe.hasMatch(line)) {
      pushCur();
      if (started) ended = true;
      if (line.isNotEmpty && !_rpOnlyRe.hasMatch(line)) {
        if (started) {
          footer.add(line);
        } else {
          intro.add(line);
        }
      }
      continue;
    }
    if (curName != null && line.isNotEmpty) {
      usage.add(line);
      continue;
    }
    if (line.isNotEmpty) {
      if (!started) {
        intro.add(line);
      } else if (ended) {
        footer.add(line);
      }
    }
  }
  pushCur();
  return meds.isNotEmpty
      ? _MedsResult(intro: intro, meds: meds, footer: footer)
      : null;
}

class _MedsView extends StatelessWidget {
  final _MedsResult meds;
  const _MedsView({required this.meds});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (meds.intro.isNotEmpty) ...[
          for (final t in meds.intro) _ParaView(text: t),
          const SizedBox(height: MedShape.s3),
        ],
        // 小标签走 caption 12·600·字距 .05em。原先 11px 低于规范下限。
        Text('用药', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: MedShape.s1),
        for (var i = 0; i < meds.meds.length; i++) ...[
          if (i > 0) const SizedBox(height: MedShape.s1),
          _MedItemCard(index: i, med: meds.meds[i]),
        ],
        if (meds.footer.isNotEmpty) ...[
          const SizedBox(height: MedShape.s3),
          for (final t in meds.footer) _ParaView(text: t),
        ],
      ],
    );
  }
}

/// 单条用药。原先是 emerald 绿卡(#ECFDF5 / #D1FAE5 / #047857)—— 绿色不在
/// 规范色板里,而且「绿 = 正常/安全」正是规范 §二 刻意不做的暗示。改成中性
/// 分块(`paper` 底 + `line-2` 边),序号用主色 `seal`:清单要好数,不要好看。
class _MedItemCard extends StatelessWidget {
  final int index;
  final _Med med;
  const _MedItemCard({required this.index, required this.med});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      padding: const EdgeInsets.all(MedShape.s2),
      decoration: BoxDecoration(
        color: c.paper,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        border: Border.all(color: c.line2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.sealWash,
              borderRadius: BorderRadius.circular(MedShape.radiusControl),
            ),
            child: Text(
              '${index + 1}',
              style: MedType.caption.copyWith(
                color: c.sealInk,
                fontFeatures: MedType.tabular,
              ),
            ),
          ),
          const SizedBox(width: MedShape.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  med.name,
                  style: MedType.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                for (final u in med.usage)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      u,
                      style: MedType.secondary.copyWith(
                        color: c.ink2,
                        height: 1.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
