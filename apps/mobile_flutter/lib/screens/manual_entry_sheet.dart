import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mobile_flutter/analytics.dart';
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
/// **先删旧的,再写新的**(见 [_ManualEntrySheetState._save] 的详细注释——
/// 顺序反过来会在"编辑但没改任何字段"时把这条记录整个删没,因为 CAS
/// 内容寻址会把"新"文本判定成和旧文档同一份内容而拒绝重复建档)。没有专门的
/// 编辑 API(设计文档 §3.6:append-only,删除是墓碑事件,不是原地覆盖)。
///
/// 返回 `true` = 保存成功(调用方据此 `bumpVaultRevision`);`false`/`null` = 取消。
///
/// [initialKind] 让调用方跳过六选一,直接落在某一种类型上——目前唯一的用途是
/// 「看病带这个」的「我想问医生的」空态那颗「加一条」:用户已经点的是"记笔记"
/// 这个意图,没有理由让他再从六个图标里点一次「笔记」。`editing` 不为空时这个
/// 参数被忽略(编辑态的类型来自 `editing.kind`,见 [_ManualEntrySheetState]
/// 的初始化)。
Future<bool?> showManualEntrySheet(
  BuildContext context, {
  ManualEntryEditing? editing,
  ManualEntryKind? initialKind,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _ManualEntrySheet(editing: editing, initialKind: initialKind),
  );
}

/// 录入的六个封闭类型。血压是唯一"一次录入两个数"的类型(收缩压+舒张压共享
/// 同一份文档/同一个测量时间,见设计文档 §5.3)。
enum ManualEntryKind {
  bloodPressure,
  heartRate,
  weight,
  temperature,
  glucose,
  note,
}

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

/// `_when` 编成 Rust `parse_measured_at` 能解析、且带真实本地偏移的 RFC3339
/// 字符串——**不能**用 `_when.toUtc().toIso8601String()`(旧写法):那一步把
/// `_when` 真按时区换算成 UTC 瞬间,偏移量随之丢失,Rust 侧因此没法区分"北京
/// 时间早上 6:50"和"UTC 6:50",这正是自测记录早间测量整段错位到前一天那个
/// bug 的源头(另一半在 Rust 侧的 `parse_measured_at`,那边现在按同一约定处理:
/// 存的是字面挂钟读数,不做时区换算)。
///
/// 偏移取 `dt.timeZoneOffset`——设备当时的真实时区,动态读取、不写死
/// `+08:00`:用户出国就医/旅行中记录时,这里应该、也会带上当地的真实偏移。
///
/// `dt.isUtc` 时(仅出现在"编辑"回填路径——`document_detail.dart` 用
/// `DateTime.tryParse` 读回已带偏移标记的 `docDate`,若用户没碰日期/时间选择器
/// 就直接保存,`_when` 仍是那个 UTC 标记的 `DateTime`),`timeZoneOffset` 恒为
/// 零,`toIso8601String()` 已自带 `Z`,直接透传即可,不需要再拼偏移。
String _rfc3339WithLocalOffset(DateTime dt) {
  if (dt.isUtc) return dt.toIso8601String();
  final offset = dt.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return '${dt.toIso8601String()}$sign$hh:$mm';
}

double? _valueFor(List<SelfMeasuredValueDto> values, String analyteKey) {
  for (final v in values) {
    if (v.analyteKey == analyteKey) return v.value;
  }
  return null;
}

/// analyte_key → (中文标签, 展示用单位)。展示单位与写进 [SelfMeasuredValueDto]
/// 的规范单位不总相同(体温规范单位是 UCUM 的 `Cel`,展示给用户用更常见的
/// `°C`,与下面 [_SingleValueField] 的 `displayUnit` 取法一致)——这张表只用于
/// 拼错误提示文案,不影响实际写入的值/单位。
const _analyteDisplay = <String, (String, String)>{
  'bp_systolic': ('收缩压', 'mmHg'),
  'bp_diastolic': ('舒张压', 'mmHg'),
  'heart_rate': ('心率', '次/分'),
  'body_weight': ('体重', 'kg'),
  'body_temperature': ('体温', '°C'),
  'glucose': ('血糖', 'mmol/L'),
};

/// 一个自测项的「可能性范围」——挡的是打错(如华为 Mate 9 真机实测里,手填
/// 收缩压存进了 138388 mmHg)导致的、生理上不可能的值,**不是**判断
/// "正常/偏高"(那是家测参考区间的职责,见
/// `packages/parser/src/self_entry.rs` 的 `home_ref_range`,数值窄得多——
/// 血压 135/85)。两套东西各管各的:范围外直接拒绝保存;范围内但超参考区间
/// (例如 200/110 的高血压危象、40°C 的高热)必须照常存得进去,只是存进去之后
/// 会被标"偏高"。范围要宽到能容纳这些真实的危急值——这里只挡物理上不存在
/// 的数字。
///
/// 与 Rust 侧 `self_entry::validate_self_measured_values`
/// 是同一条判断规则的两份独立实现:这里挡在 UI 层,能给出更具体的"改哪个
/// 字段"引导文案;`add_self_measurement`(自测数据写入的唯一入口)里再挡
/// 一道兜底,防的是这层 UI 校验将来被别的录入入口绕过。
class _PlausibleRange {
  const _PlausibleRange(this.low, this.high);
  final double low;
  final double high;
}

/// 六项的可能性范围 + 出处(仿 `problem_map.json` 的 `source` 字段/
/// `self_entry.rs` 参考区间的做法——查不到可靠出处的,照实写"未核实到具体
/// 出处",不编一个看起来权威的引用)。
const _plausibleRanges = <String, _PlausibleRange>{
  // 未核实到具体出处,取值依据是生理学极限的保守外扩:收缩压低于 60 mmHg
  // 已属重度低血压/休克范畴,常规示波法血压计在此区间以下多半已测不出稳定
  // 读数;260 mmHg 高于临床上作为"高血压危象"报告的极端病例,取整数上限
  // 留出余量——不是某一部指南给出的切点。
  'bp_systolic': _PlausibleRange(60, 260),
  // 未核实到具体出处,取值依据同收缩压:30 mmHg 以下、160 mmHg 以上都超出
  // 常规血压计示波法测量的可信区间,是生理学极限的保守外扩,不是某一部
  // 指南给出的切点。
  'bp_diastolic': _PlausibleRange(30, 160),
  // 未核实到具体出处,取值依据是生理学极限的保守外扩:成人静息心率低于
  // 25 次/分已接近严重心动过缓/心脏停搏边缘,高于 250 次/分超出心脏电生理
  // 能维持有效搏出的上限,两端都留了余量。
  'heart_rate': _PlausibleRange(25, 250),
  // 未核实到具体出处,取值依据是生理学极限的保守外扩:体温低于 30°C 已属
  // 重度低体温,高于 45°C 已超出人类已知存活体温记录的保守外扩;常规体温计
  // 的量程也大多落在此区间之内。
  'body_temperature': _PlausibleRange(30, 45),
  // 未核实到具体出处,取值依据是生理学极限的保守外扩:1 kg 以下不是本应用
  // 自测场景会出现的体重,400 kg 超出常见家用体重秤的量程上限,也远高于
  // 已报道的极端病例体重。
  'body_weight': _PlausibleRange(1, 400),
  // 未核实到具体出处,取值依据是生理学极限的保守外扩:1 mmol/L 以下已低于
  // 可测出的血糖下限(严重低血糖昏迷阈值约 2.8 mmol/L 之下留了余量),
  // 40 mmol/L 远高于常见家用血糖仪的量程上限(通常 33.3 mmol/L 封顶),
  // 留出余量避免卡住真实的极端高血糖读数。
  'glucose': _PlausibleRange(1, 40),
};

/// 保存前的"可能性"校验:逐项查 [_plausibleRanges],再加一条单值范围查不出来
/// 的交叉校验——收缩压必须大于舒张压(88/138 是明显填反了,两个数各自都在
/// 各自的可能性范围内,只有配对比较才挡得住)。命中即返回给用户看的中文
/// 提示(说清哪项、什么值、该改成什么样),不静默截断或改写用户输入;
/// 通过则返回 `null`。
///
/// 非私有(与 [manualEntryKindForKeys] 同样的理由):`_save` 调这个决定能不能
/// 保存,测试也需要能直接调它——`flutter test` 不带 Rust 原生库,点「保存」
/// 走到 FFI 那一步就会崩(见 `manual_entry_sheet_test.dart` 顶部注释),所以
/// "范围内的危急值必须能存"这条只能靠直接调这个纯函数断言返回 `null` 来钉住,
/// 不能靠真的点「保存」看它有没有落库。
String? manualEntryRangeError(List<SelfMeasuredValueDto> values) {
  for (final v in values) {
    final range = _plausibleRanges[v.analyteKey];
    if (range == null || (v.value >= range.low && v.value <= range.high)) {
      continue;
    }
    final meta = _analyteDisplay[v.analyteKey];
    final label = meta?.$1 ?? v.analyteKey;
    final unit = meta?.$2 ?? v.unit;
    return '$label ${_fmtNum(v.value)} $unit 超出可能范围'
        '(${_fmtNum(range.low)}–${_fmtNum(range.high)} $unit),请检查后重新输入';
  }
  final sys = _valueFor(values, 'bp_systolic');
  final dia = _valueFor(values, 'bp_diastolic');
  if (sys != null && dia != null && sys <= dia) {
    return '收缩压(${_fmtNum(sys)})应大于舒张压(${_fmtNum(dia)}),请检查是否填反了';
  }
  return null;
}

/// `SelfMeasuredValueDto.analyteKey` 列表(`selfMeasurementValues` 读回来的)→
/// 该用哪个 [ManualEntryKind] 预填编辑表单。血压两个 key 都在场时归到血压;
/// 单值项按第一个 key 匹配;读不出/不认识的 key(理论上不会发生,五选一界面
/// 产出的 key 是封闭的)兜底成心率,不崩。供 `document_detail.dart` 的「编辑」
/// 入口使用。
ManualEntryKind manualEntryKindForKeys(List<String> analyteKeys) {
  if (analyteKeys.contains('bp_systolic') ||
      analyteKeys.contains('bp_diastolic')) {
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
  const _ManualEntrySheet({this.editing, this.initialKind});
  final ManualEntryEditing? editing;
  final ManualEntryKind? initialKind;

  @override
  State<_ManualEntrySheet> createState() => _ManualEntrySheetState();
}

class _ManualEntrySheetState extends State<_ManualEntrySheet> {
  late ManualEntryKind _kind =
      widget.editing?.kind ??
      widget.initialKind ??
      ManualEntryKind.bloodPressure;
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
        if (e.values.isNotEmpty) {
          _singleCtl.text = _fmtNum(e.values.first.value);
        }
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
        SelfMeasuredValueDto(
          analyteKey: 'bp_systolic',
          value: sys,
          unit: 'mmHg',
        ),
        SelfMeasuredValueDto(
          analyteKey: 'bp_diastolic',
          value: dia,
          unit: 'mmHg',
        ),
      ];
    }
    final analyte = _singleAnalyte;
    if (analyte == null) return null; // 笔记不经过这里
    final v = double.tryParse(_singleCtl.text.trim());
    if (v == null) return null;
    return [
      SelfMeasuredValueDto(analyteKey: analyte.$1, value: v, unit: analyte.$2),
    ];
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
    final measuredAt = _rfc3339WithLocalOffset(_when);

    if (_kind == ManualEntryKind.note) {
      final text = _noteCtl.text.trim();
      if (text.isEmpty) {
        setState(() => _error = '请输入笔记内容');
        return;
      }
      setState(() => _saving = true);
      try {
        // 编辑:先删旧的,再写新的。**顺序不能反过来**——写自测/笔记记录走的
        // 是 CAS(内容寻址):没改任何字段时,新文本和旧文档的合成文本逐字节
        // 相同。若先写新的,`vault.import` 会命中去重,判定"这份内容已经建过
        // 档"而直接把旧文档的 id 当成"新文档"返回(不建新记录);随后再删除
        // 这个 id,就把用户刚保存的记录整个删没了——静默丢数据,且用户毫无
        // 察觉("保存"按钮明明显示了成功)。先删再写,即使内容逐字节相同,
        // `vault.import` 也会因为旧文档已不存在而正常建出一份新的
        // (`core_model::materialize` 的 `HashReplayState`/`pending_deletes`
        // 就是为"内容相同、先删后建"这个序列设计的)。代价是:若中间那步写入
        // 真的失败(理论上只有存储层故障),旧记录已经删了、新的没建成——但这
        // 比"编辑时不改任何字段直接保存,记录消失"这个必现的 bug 要好得多。
        if (_editing) {
          await deleteDocument(documentId: widget.editing!.documentId);
        }
        await addNote(text: text, measuredAt: measuredAt);
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
    final rangeError = manualEntryRangeError(values);
    if (rangeError != null) {
      setState(() => _error = rangeError);
      return;
    }
    setState(() => _saving = true);
    try {
      // 见上面笔记分支的注释:同一条"先删再写"的理由。
      if (_editing) {
        await deleteDocument(documentId: widget.editing!.documentId);
      }
      await addSelfMeasurement(values: values, measuredAt: measuredAt);
      _finish();
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '保存失败:$e';
      });
    }
  }

  void _finish() {
    // 埋点:只报**「数值」还是「笔记」**,以及这次是新增还是编辑。
    //
    // 绝不报是哪一种(血压/心率/体重/体温/血糖)—— 「这台设备在测血糖」是对机主
    // 的健康推断,与「不采内容」同级。数值本身、单位、笔记原文、测量时间更是一个
    // 字都不出去。理由与取舍见 `analytics.dart` 的 [RecordKindGroup]。
    Analytics.track(AnalyticsEvent.recordAdded, {
      'kind_group': (_kind == ManualEntryKind.note
              ? RecordKindGroup.note
              : RecordKindGroup.measurement)
          .name,
      'edited': _editing,
    });
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
                Text(
                  _error!,
                  style: MedType.secondary.copyWith(color: c.critical),
                ),
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
        Expanded(
          child: _NumberBox(controller: controller, hint: label),
        ),
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
        // 这一行曾经是一个 `Row`:`[图标][「测量时间」][Spacer][日期时间][箭头]`,
        // 两个 `Text` 都是**非 flex 子项**。`RenderFlex` 给非 flex 子项的主轴约束
        // 是**无穷大**,于是它们各自按固有宽度铺开,谁也不会折行 —— 系统字号 ×2.0
        // 时 `Spacer` 先被挤成 0,还差 31px,直接横向溢出(×1.0/1.3/1.5 都干净,
        // 只有 ×2.0 露出来)。007 §2.5「字号可放大,不可砍」:不能截断日期、不能
        // 缩字号,只能让它换行。
        //
        // 改成 `Wrap` —— 与同屏 `QuickActions` 同一条处理。两组([图标+文字] 与
        // [日期+箭头])各自 `MainAxisSize.min`:放得下时同一行,`spaceBetween` 把
        // 日期推到最右边,与原来的观感一模一样;放不下时日期整组落到第二行,而不是
        // 溢出。两处文字再各套一层 `Flexible`,因为 ×2.0 时单是日期那一组就可能宽
        // 过一整行(十六个字符),那时它得自己折行。
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: MedShape.s2,
          runSpacing: MedShape.s1,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule, size: 18, color: c.ink3),
                const SizedBox(width: MedShape.s1),
                Flexible(
                  child: Text(
                    '测量时间',
                    style: MedType.body.copyWith(color: c.ink2),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: MedType.body.copyWith(
                      color: c.sealInk,
                      fontFeatures: MedType.tabular,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: c.ink3),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
