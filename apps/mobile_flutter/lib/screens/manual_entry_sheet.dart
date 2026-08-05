import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/vault_events.dart';

/// 「记录」入口的录入弹层 —— MANUAL-ENTRY-DESIGN.md 的落地实现。
///
/// 封闭六选一(血压/心率/体重/体温/血糖/笔记),**不提供任意化验项的输入框**——
/// 这是设计文档反复强调的硬约束:「屏上每个数字都能一键回到那张纸」,自测值
/// 不破坏这条不变量是因为用户自己就是数据源本身,但任意化验值手打进去就会和
/// 从化验单读出来的长得一模一样却没有出处。
///
/// 数值项写 `addSelfMeasurement`,笔记写 `addNote`——两条 FFI 都在 `api::vault`,
/// 与 DICOM/文本导入同构(没有原件,合成文本本身当"文件",见 Rust 侧的文档)。
///
/// 编辑复用同一个弹层:传入 [editing](已有文档 id + 预填的值)时,保存动作变成
/// **先成功写入新的,再删旧的**——这样万一保存失败,原记录不受影响。没有专门的
/// 编辑 API(设计文档 §3.6:append-only,删除是墓碑事件,不是原地覆盖)。
///
/// 返回 `true` = 保存成功(调用方据此 `bumpVaultRevision`);`false`/`null` = 取消。
Future<bool?> showManualEntrySheet(
  BuildContext context, {
  ManualEntryEditing? editing,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ManualEntrySheet(editing: editing),
  );
}

/// 录入的六个封闭类型。血压是唯一"一次录入两个数"的类型(收缩压+舒张压共享
/// 同一份文档/同一个测量时间,见设计文档 §5.3)。
enum ManualEntryKind { bloodPressure, heartRate, weight, temperature, glucose, note }

extension _KindMeta on ManualEntryKind {
  String get label => switch (this) {
    ManualEntryKind.bloodPressure => '血压',
    ManualEntryKind.heartRate => '心率',
    ManualEntryKind.weight => '体重',
    ManualEntryKind.temperature => '体温',
    ManualEntryKind.glucose => '血糖',
    ManualEntryKind.note => '笔记',
  };

  IconData get icon => switch (this) {
    ManualEntryKind.bloodPressure => Icons.favorite_border,
    ManualEntryKind.heartRate => Icons.monitor_heart_outlined,
    ManualEntryKind.weight => Icons.scale_outlined,
    ManualEntryKind.temperature => Icons.thermostat_outlined,
    ManualEntryKind.glucose => Icons.water_drop_outlined,
    ManualEntryKind.note => Icons.sticky_note_2_outlined,
  };
}

/// 编辑一份已有手动录入文档所需的最小信息:要删的旧文档 id + 类型 + 预填的值。
/// 数值项用 [values](`self_measurement_values` 读回来的),笔记用 [noteText]
/// (直接就是 `DocumentDetailDto.ocrText`,笔记原文即内容,不需要额外解码)。
class ManualEntryEditing {
  const ManualEntryEditing({
    required this.documentId,
    required this.kind,
    this.values = const [],
    this.noteText,
    this.measuredAt,
  });

  final int documentId;
  final ManualEntryKind kind;
  final List<SelfMeasuredValueDto> values;
  final String? noteText;
  final DateTime? measuredAt;
}

/// 数值 → 显示文本,去掉 IEEE 754 的 `.0`(与 `lab_status.dart` 的 `fmtLabNumber`
/// 同一取法)。
String _fmtNum(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toStringAsFixed(0);
  return v.toString();
}

double? _valueFor(List<SelfMeasuredValueDto> values, String analyteKey) {
  for (final v in values) {
    if (v.analyteKey == analyteKey) return v.value;
  }
  return null;
}

/// `SelfMeasuredValueDto.analyteKey` 列表(`selfMeasurementValues` 读回来的)→
/// 该用哪个 [ManualEntryKind] 预填编辑表单。血压两个 key 都在场时归到血压;
/// 单值项按第一个 key 匹配;读不出/不认识的 key(理论上不会发生,五选一界面
/// 产出的 key 是封闭的)兜底成心率,不崩。供 `document_detail.dart` 的「编辑」
/// 入口使用。
ManualEntryKind manualEntryKindForKeys(List<String> analyteKeys) {
  if (analyteKeys.contains('bp_systolic') || analyteKeys.contains('bp_diastolic')) {
    return ManualEntryKind.bloodPressure;
  }
  final first = analyteKeys.isEmpty ? null : analyteKeys.first;
  return switch (first) {
    'body_weight' => ManualEntryKind.weight,
    'body_temperature' => ManualEntryKind.temperature,
    'glucose' => ManualEntryKind.glucose,
    _ => ManualEntryKind.heartRate,
  };
}

class _ManualEntrySheet extends StatefulWidget {
  const _ManualEntrySheet({this.editing});
  final ManualEntryEditing? editing;

  @override
  State<_ManualEntrySheet> createState() => _ManualEntrySheetState();
}

class _ManualEntrySheetState extends State<_ManualEntrySheet> {
  late ManualEntryKind _kind = widget.editing?.kind ?? ManualEntryKind.bloodPressure;
  late DateTime _when = widget.editing?.measuredAt ?? DateTime.now();
  final _systolicCtl = TextEditingController();
  final _diastolicCtl = TextEditingController();
  final _singleCtl = TextEditingController();
  final _noteCtl = TextEditingController();
  bool _saving = false;
  String? _error;

  bool get _editing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e == null) return;
    switch (e.kind) {
      case ManualEntryKind.bloodPressure:
        final sys = _valueFor(e.values, 'bp_systolic');
        final dia = _valueFor(e.values, 'bp_diastolic');
        if (sys != null) _systolicCtl.text = _fmtNum(sys);
        if (dia != null) _diastolicCtl.text = _fmtNum(dia);
      case ManualEntryKind.note:
        _noteCtl.text = e.noteText ?? '';
      default:
        if (e.values.isNotEmpty) _singleCtl.text = _fmtNum(e.values.first.value);
    }
  }

  @override
  void dispose() {
    _systolicCtl.dispose();
    _diastolicCtl.dispose();
    _singleCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  /// 该类型对应的 analyte_key/单位(血压/笔记走各自专门的分支,不经过这个表)。
  (String, String)? get _singleAnalyte => switch (_kind) {
    ManualEntryKind.heartRate => ('heart_rate', '/min'),
    ManualEntryKind.weight => ('body_weight', 'kg'),
    ManualEntryKind.temperature => ('body_temperature', 'Cel'),
    ManualEntryKind.glucose => ('glucose', 'mmol/L'),
    ManualEntryKind.bloodPressure || ManualEntryKind.note => null,
  };

  List<SelfMeasuredValueDto>? _collectValues() {
    if (_kind == ManualEntryKind.bloodPressure) {
      final sys = double.tryParse(_systolicCtl.text.trim());
      final dia = double.tryParse(_diastolicCtl.text.trim());
      if (sys == null || dia == null) return null;
      return [
        SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: sys, unit: 'mmHg'),
        SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: dia, unit: 'mmHg'),
      ];
    }
    final analyte = _singleAnalyte;
    if (analyte == null) return null; // 笔记不经过这里
    final v = double.tryParse(_singleCtl.text.trim());
    if (v == null) return null;
    return [SelfMeasuredValueDto(analyteKey: analyte.$1, value: v, unit: analyte.$2)];
  }

  Future<void> _pickWhen() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _when,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_when),
    );
    if (!mounted) return;
    setState(() {
      _when = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? _when.hour,
        time?.minute ?? _when.minute,
      );
    });
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final measuredAt = _when.toUtc().toIso8601String();

    if (_kind == ManualEntryKind.note) {
      final text = _noteCtl.text.trim();
      if (text.isEmpty) {
        setState(() => _error = '请输入笔记内容');
        return;
      }
      setState(() => _saving = true);
      try {
        await addNote(text: text, measuredAt: measuredAt);
        // 编辑:新的已经写成功了,再删旧的 —— 顺序反过来的话,一旦上面那步
        // 失败,用户会发现自己的旧记录凭空消失了。
        if (_editing) {
          await deleteDocument(documentId: widget.editing!.documentId);
        }
        _finish();
      } catch (e) {
        setState(() {
          _saving = false;
          _error = '保存失败:$e';
        });
      }
      return;
    }

    final values = _collectValues();
    if (values == null) {
      setState(() => _error = '请输入完整的数值');
      return;
    }
    setState(() => _saving = true);
    try {
      await addSelfMeasurement(values: values, measuredAt: measuredAt);
      if (_editing) {
        await deleteDocument(documentId: widget.editing!.documentId);
      }
      _finish();
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '保存失败:$e';
      });
    }
  }

  void _finish() {
    bumpVaultRevision();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return SafeArea(
      child: Padding(
        // 键盘弹起时随之上移,不被挡住。
        padding: EdgeInsets.only(
          left: MedShape.s4,
          right: MedShape.s4,
          top: MedShape.s2,
          bottom: MedShape.s4 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _editing ? '编辑记录' : '记录',
                style: MedType.title.copyWith(color: c.ink),
              ),
              const SizedBox(height: MedShape.s3),
              if (!_editing) ...[
                _KindPicker(
                  selected: _kind,
                  onSelect: (k) => setState(() => _kind = k),
                ),
                const SizedBox(height: MedShape.s3),
              ],
              if (_kind == ManualEntryKind.bloodPressure)
                _BloodPressureFields(
                  systolicCtl: _systolicCtl,
                  diastolicCtl: _diastolicCtl,
                )
              else if (_kind == ManualEntryKind.note)
                _NoteField(controller: _noteCtl)
              else
                _SingleValueField(
                  controller: _singleCtl,
                  label: _kind.label,
                  // 显示给用户看的单位用更常见的写法(°C 而不是 UCUM 的 Cel);
                  // 真正写进记录的规范单位在 `_singleAnalyte` 里,两者不是一回事。
                  displayUnit: switch (_kind) {
                    ManualEntryKind.temperature => '°C',
                    ManualEntryKind.heartRate => '次/分',
                    _ => _singleAnalyte?.$2 ?? '',
                  },
                ),
              const SizedBox(height: MedShape.s3),
              _WhenRow(when: _when, onTap: _pickWhen),
              if (_error != null) ...[
                const SizedBox(height: MedShape.s2),
                Text(_error!, style: MedType.secondary.copyWith(color: c.critical)),
              ],
              const SizedBox(height: MedShape.s4),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: c.sealInk,
                  foregroundColor: c.surface,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KindPicker extends StatelessWidget {
  const _KindPicker({required this.selected, required this.onSelect});

  final ManualEntryKind selected;
  final ValueChanged<ManualEntryKind> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Wrap(
      spacing: MedShape.s1,
      runSpacing: MedShape.s1,
      children: [
        for (final k in ManualEntryKind.values)
          InkWell(
            onTap: () => onSelect(k),
            borderRadius: BorderRadius.circular(MedShape.radiusPill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MedShape.s2,
                vertical: MedShape.s1,
              ),
              decoration: BoxDecoration(
                color: k == selected ? c.sealWash : c.surface,
                borderRadius: BorderRadius.circular(MedShape.radiusPill),
                border: Border.all(color: k == selected ? c.sealInk : c.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    k.icon,
                    size: 16,
                    color: k == selected ? c.sealInk : c.ink2,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    k.label,
                    style: MedType.body.copyWith(
                      color: k == selected ? c.sealInk : c.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 一个只接受数字(含一位小数点)的输入框,统一样式。**不打字键盘** ——
/// `keyboardType: decimal` 在多数设备上直接弹数字键盘,契合设计文档「10 秒内,
/// 不打字」的场景 A。
class _NumberBox extends StatelessWidget {
  const _NumberBox({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return TextField(
      controller: controller,
      autofocus: false,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
      ],
      style: MedType.value.copyWith(color: c.ink),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: MedType.value.copyWith(color: c.ink3),
        filled: true,
        fillColor: c.sealWash,
        contentPadding: const EdgeInsets.symmetric(vertical: MedShape.s2),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.sealInk, width: 1.5),
        ),
      ),
    );
  }
}

class _BloodPressureFields extends StatelessWidget {
  const _BloodPressureFields({
    required this.systolicCtl,
    required this.diastolicCtl,
  });

  final TextEditingController systolicCtl;
  final TextEditingController diastolicCtl;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('收缩压', style: MedType.secondary.copyWith(color: c.ink2)),
              const SizedBox(height: 4),
              _NumberBox(controller: systolicCtl, hint: '128'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: MedShape.s3),
          child: Text('/', style: MedType.title.copyWith(color: c.ink3)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('舒张压', style: MedType.secondary.copyWith(color: c.ink2)),
              const SizedBox(height: 4),
              _NumberBox(controller: diastolicCtl, hint: '82'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: MedShape.s2, top: MedShape.s3),
          child: Text('mmHg', style: MedType.secondary.copyWith(color: c.ink3)),
        ),
      ],
    );
  }
}

class _SingleValueField extends StatelessWidget {
  const _SingleValueField({
    required this.controller,
    required this.label,
    required this.displayUnit,
  });

  final TextEditingController controller;
  final String label;
  final String displayUnit;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      children: [
        Expanded(child: _NumberBox(controller: controller, hint: label)),
        if (displayUnit.isNotEmpty) ...[
          const SizedBox(width: MedShape.s2),
          Text(displayUnit, style: MedType.secondary.copyWith(color: c.ink3)),
        ],
      ],
    );
  }
}

class _NoteField extends StatelessWidget {
  const _NoteField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return TextField(
      controller: controller,
      autofocus: true,
      maxLines: 4,
      minLines: 3,
      style: MedType.body.copyWith(color: c.ink),
      decoration: InputDecoration(
        hintText: '想问医生的问题、吃药后的感觉……随手记一句就行',
        hintStyle: MedType.body.copyWith(color: c.ink3),
        filled: true,
        fillColor: c.sealWash,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.sealInk, width: 1.5),
        ),
      ),
    );
  }
}

class _WhenRow extends StatelessWidget {
  const _WhenRow({required this.when, required this.onTap});

  final DateTime when;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final label =
        '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MedShape.radiusControl),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
        child: Row(
          children: [
            Icon(Icons.schedule, size: 18, color: c.ink3),
            const SizedBox(width: MedShape.s1),
            Text('测量时间', style: MedType.body.copyWith(color: c.ink2)),
            const Spacer(),
            Text(
              label,
              style: MedType.body.copyWith(
                color: c.sealInk,
                fontFeatures: MedType.tabular,
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
