import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart'
    show TrendPointDto, TrendSeriesDto;
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

/// 病程档案渲染引擎 —— `ProfileView.sections[]`(`packages/profile/src/view.rs`)
/// 的**唯一**渲染入口。按 `section['kind']` 分派到 7 种卡片:`status_card` /
/// `score_card` / `series_chart` / `reminders` / `timeline` / `checklist` /
/// `handoff`。
///
/// ## 这个文件里不许出现的东西
///
/// **任何一句写死的病种文案。** 标题、空态提示、每一条规则的措辞全部来自
/// `section['title']` / `section['empty_hint']` / body 里的字段——这是「加一个病
/// 不发版」的前提(`view.rs` 头部同一条)。这里允许出现的中文字面量只是**引擎级、
/// 跨病种通用**的结构词:`basis`/`verdict`/`state` 这几个固定枚举的翻译(与
/// spec §6 表格同源)、`gc`/`hcq` 这两个 `status_card` 固定 schema key 对应的药物
/// 类名——不是任何一个包自己的措辞,换一个病种包这些词还是这几个。
///
/// ## 认不出的 kind
///
/// 整块跳过,返回 [SizedBox.shrink]——不抛异常,给引擎日后加新 kind 留后路。
///
/// ## 数值原则
///
/// 能拿到「化验单原文那个字符串」的地方(`evidence[].value`)一律显示那个字符串,
/// 不显示旁边算好的 `value_canonical`——前者是原文逐字,后者是引擎为了比较造的
/// 数,两者在极少数进制/单位场景下可能不是同一个打印形式。其余没有原文可退的数值
/// (`score`/`mg_per_kg` 这类本来就是算出来的)直接 `toString()`,不在这里四舍五入。
class ProfileSectionView extends StatelessWidget {
  const ProfileSectionView(this.section, {super.key});

  /// 一个 `ProfileView.sections[]` 元素:`{kind,id,title,empty_hint,body}`。
  final Map<String, dynamic> section;

  @override
  Widget build(BuildContext context) {
    final kind = section['kind'] as String?;
    final icon = _kIconFor[kind];
    if (icon == null) return const SizedBox.shrink();

    final emptyHint = section['empty_hint'] as String?;
    if (emptyHint != null) {
      return _SectionCard(
        icon: icon,
        child: _HintLine(emptyHint),
      );
    }

    final body = _asMap(section['body']);
    final child = switch (kind) {
      'status_card' => _StatusCardBody(body),
      'score_card' => _ScoreCardBody(body),
      'series_chart' => _SeriesChartBody(body),
      'reminders' => _RemindersBody(body),
      'timeline' => _TimelineBody(body),
      'checklist' => _ChecklistBody(
        sectionId: section['id'] as String?,
        body: body,
      ),
      'handoff' => _HandoffBody(body),
      _ => const SizedBox.shrink(), // 上面已经守过一遍 kind,理论上到不了这里。
    };

    return _SectionCard(
      icon: icon,
      title: section['title'] as String?,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// 引擎级枚举 → 中文标签。四张表跨病种通用(spec §5.4/§5.3/§6),不是包的措辞。
// ---------------------------------------------------------------------------

const Map<String, IconData> _kIconFor = {
  'status_card': Icons.medication_outlined,
  'score_card': Icons.science_outlined,
  'series_chart': Icons.show_chart_outlined,
  'reminders': Icons.notifications_outlined,
  'timeline': Icons.timeline,
  'checklist': Icons.checklist,
  'handoff': Icons.share_outlined,
};

/// `basis` 四档(spec §5.4):监测提醒到底是指南写的、说明书写的、文献写的,
/// 还是包作者自己给的默认值——**必须**分得开,包默认不能冒充指南。
const Map<String, String> _kBasisLabel = {
  'guideline': '指南',
  'label': '说明书',
  'literature': '文献',
  'package_default': '包默认',
};

const Map<String, String> _kVerdictLabel = {
  'yes': '满足',
  'no': '未满足',
  'unknown': '未知',
};

const Map<String, IconData> _kVerdictIcon = {
  'yes': Icons.check_circle_outline,
  'no': Icons.cancel_outlined,
  'unknown': Icons.help_outline,
};

/// 时间轴事件类型(`packages/profile/src/rules.rs` 的 `TIMELINE_TYPES`,固定
/// 7 个,引擎级常量、不是包的措辞——与 `basis` 同一档次)。
const Map<String, String> _kTimelineTypeLabel = {
  'flare': '复发',
  'hospitalization': '住院',
  'biopsy': '活检',
  'infusion': '输注',
  'dose_change': '调整用药',
  'infection': '感染',
  'pregnancy': '妊娠',
};

const Map<String, String> _kReminderStateLabel = {
  'overdue': '逾期',
  'never': '没查到',
  'unknown': '未知',
  'pending': '待核',
};

/// `hcq_body` 的体重来源(`rules.rs::latest_weight_kg`),只有这两个值。
const Map<String, String> _kWeightSourceLabel = {
  'self_reported': '自测',
  'record': '病历',
};

String? _basisLabel(dynamic v) =>
    v == null ? null : (_kBasisLabel[v] ?? v.toString());

String _verdictLabel(dynamic v) => _kVerdictLabel[v] ?? '未知';

IconData _verdictIcon(dynamic v) => _kVerdictIcon[v] ?? Icons.help_outline;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

List<Map<String, dynamic>> _asMapList(dynamic v) =>
    v is List ? v.map(_asMap).toList() : <Map<String, dynamic>>[];

/// `actual` + 单位,单位缺失就不留一个悬空空格。数值不四舍五入——见文件头。
String? _actualText(dynamic actual, String? unit) {
  if (actual == null) return null;
  return (unit == null || unit.isEmpty) ? '$actual' : '$actual $unit';
}

/// `evidence[]` → 一行可读文本:**原文字符串** `value`(不是算好的
/// `value_canonical`)+ 单位 + 日期,见文件头「数值原则」。
String? _evidenceText(List<Map<String, dynamic>> evidence) {
  if (evidence.isEmpty) return null;
  return evidence
      .map((e) {
        final unit = e['unit'] as String?;
        final date = fmtDate(e['date'] as String?);
        final head = (unit == null || unit.isEmpty)
            ? '${e['value']}'
            : '${e['value']} $unit';
        return date.isEmpty ? head : '$head · $date';
      })
      .join('; ');
}

/// 次要说明行:日期、出处这类只在需要时才读的信息,`·` 分隔,空值自动跳过。
/// 空结果返回 `null`——调用方据此决定要不要留一行空隙。
Widget? _metaLine(BuildContext context, List<String?> parts) {
  final items = parts.whereType<String>().where((s) => s.isNotEmpty).toList();
  if (items.isEmpty) return null;
  final c = MedColors.of(context);
  return Text(
    items.join(' · '),
    style: MedType.secondary.copyWith(
      color: c.ink3,
      fontFeatures: MedType.tabular,
    ),
  );
}

// ---------------------------------------------------------------------------
// 共用外壳
// ---------------------------------------------------------------------------

/// 一块 section 的外壳:白卡 + 图标 + 标题(可选,来自包)+ 内容。
///
/// **一个 section 只有一个 [MedCard]**,不嵌套第二张卡——同一屏里的卡不互相
/// 抢注意力,层次交给字号和留白分。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    this.title,
    required this.child,
  });

  final IconData icon;
  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s3),
      child: MedCard(
        child: Padding(
          padding: const EdgeInsets.all(MedShape.s4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MedIcon(icon),
              const SizedBox(width: MedShape.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title case final t? when t.isNotEmpty) ...[
                      Text(t, style: MedType.title.copyWith(color: c.ink)),
                      const SizedBox(height: MedShape.s3),
                    ],
                    child,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 折叠态的那一行提示——`empty_hint` 原样显示,不额外拼标题上去(拼了就不再是
/// 「这一个字符串」,`profile_sections_test.dart` 的 `find.text` 会找不到)。
class _HintLine extends StatelessWidget {
  const _HintLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Text(text, style: MedType.body.copyWith(color: c.ink2));
  }
}

/// 一行条目的通用外壳:图标 + 可换行的标题(旁边可带一枚 trailing)+ 次要说明行
/// + 可选的整段长文本。**长文本永远独占一行**,不挤在标题右边——挤会把长句从
/// 中间切断(mockup 的「长文字走整行」)。
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    this.icon,
    this.leading,
    required this.label,
    this.labelColor,
    this.trailing,
    this.meta = const [],
    this.longText,
    this.note,
  });

  /// 左边那颗 18px 小图标,`null` 就不画。时间轴那一路传 `null`——圆点已经是
  /// 它的标记,两个标记会打架,见 `_TimelineEventRow`。其余调用点都传,原样画出。
  final IconData? icon;

  /// 整枚替换掉左边那颗小图标(R26:提醒行要一枚 44×44 `MedIcon`,不是
  /// 18px 的小图标)。非空时优先于 [icon]——mockup `.banner` 的签名
  /// 元素就是这枚大图标,`MedBanner` 本身用不了(见 `_ReminderRow` 类文档),
  /// 但左边那颗图标不该跟着退化成小图标。默认 `null`,其余调用点一个像素都不变。
  ///
  /// R26 fix round 1 顺带删掉了原来的 `iconColor` 参数:那颗小图标唯一会变色的
  /// 调用点(`_ReminderRow` 的琥珀提醒)已经改用 [leading] 整个换成大图标块,
  /// `iconColor` 从此没有任何调用点传值,`flutter analyze` 会报
  /// `unused_element_parameter`——删掉比留一个死参数干净。其余调用点的小图标
  /// 一直就是固定的 `c.ink2`,不受影响。
  final Widget? leading;
  final String label;

  /// 标题文字色。默认 `null` → `c.ink`(原有调用点不变)。R26:琥珀提醒行要
  /// `MedBrand.bannerAmberInk`,与 `MedBanner.title` 同一处理。
  final Color? labelColor;
  final Widget? trailing;
  final List<String?> meta;
  final String? longText;

  /// 包里那条「与指南口径有差」的话(`gfr_80_baseline.note`、`biopsy_indication.note`
  /// 都带 ⚠️ 段)。引擎特意把包的 `note` 原样带进 body,**就是要医生看见**
  /// (`rules.rs::gfr_item` / `biopsy_item` 的文档写了这件事);与 `longText` 分两行,
  /// 不拼在一起 —— 拼了就核不到这一句的逐字原文(与 score_card 的 `caveat` 同一手法)。
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final metaLine = _metaLine(context, meta);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: MedShape.s2),
          ] else if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 18, color: c.ink2),
            ),
            const SizedBox(width: MedShape.s2),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: MedShape.s1,
                  runSpacing: 4,
                  children: [
                    Text(label, style: MedType.body.copyWith(color: labelColor ?? c.ink)),
                    ?trailing,
                  ],
                ),
                if (metaLine != null) ...[
                  const SizedBox(height: 2),
                  metaLine,
                ],
                for (final t in [longText, note])
                  if (t case final s? when s.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(s, style: MedType.secondary.copyWith(color: c.ink)),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
    return row;
  }
}

// ---------------------------------------------------------------------------
// status_card —— 现行方案
// ---------------------------------------------------------------------------

class _StatusCardBody extends StatelessWidget {
  const _StatusCardBody(this.body);

  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    final gc = _asMap(body['gc']);
    final hcq = body['hcq'] == null ? null : _asMap(body['hcq']);
    final others = _asMapList(body['others']);
    final lastVisit = body['last_visit'] == null
        ? null
        : _asMap(body['last_visit']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GcBlock(gc),
        if (hcq != null) ...[
          const SizedBox(height: MedShape.s3),
          _HcqBlock(hcq),
        ],
        for (final o in others) ...[
          const SizedBox(height: MedShape.s2),
          _OtherDrugRow(o),
        ],
        if (lastVisit != null) ...[
          const SizedBox(height: MedShape.s3),
          const Divider(height: 1),
          const SizedBox(height: MedShape.s2),
          _LastVisitRow(lastVisit),
        ],
      ],
    );
  }
}

class _GcBlock extends StatelessWidget {
  const _GcBlock(this.gc);

  final Map<String, dynamic> gc;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final drug = gc['drug'] as String?;
    final targets = _asMapList(gc['targets']);
    final unconvertible = _asMapList(gc['unconvertible']);
    if (drug == null && targets.isEmpty && unconvertible.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('激素', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: 4),
        if (drug != null)
          _ItemRow(
            icon: Icons.medication_outlined,
            label: [
              drug,
              if (gc['dose'] != null) gc['dose'],
              if (gc['daily_pred_equiv_mg'] != null)
                '(等效 ${gc['daily_pred_equiv_mg']} mg/日)',
            ].join(' '),
            meta: [
              [
                fmtDate(gc['since'] as String?),
                fmtDate(gc['as_of'] as String?),
              ].where((s) => s.isNotEmpty).join(' – '),
            ],
          )
        else if (unconvertible.isEmpty)
          // 一条激素都没读到,但包里配了维持目标线(下面的 `targets` 循环)——不
          // 说明白为什么会展开这张卡时,只剩两行光秃秃的「维持目标」,像是漏了
          // 内容而不是「这个人没有对应记录」。`unconvertible` 非空时不重复这句:
          // 那边逐条已经带着同一句 `reason`(见 `rules.rs::regimen_eval` 的
          // 同一天多条医嘱分支),两处都画就是同一句话说两遍。
          _ItemRow(
            icon: Icons.medication_outlined,
            label: '激素',
            longText: gc['blocked_reason'] as String?,
          ),
        for (final t in targets)
          Padding(
            padding: const EdgeInsets.only(
              left: MedShape.s4 + MedShape.s1,
              top: 2,
            ),
            child: Text(
              '维持目标 ${t['value']} mg/日 · ${t['label']}',
              style: MedType.secondary.copyWith(color: c.ink3),
            ),
          ),
        for (final u in unconvertible)
          _ItemRow(
            icon: Icons.error_outline,
            label: [
              u['name'],
              u['dose'],
            ].where((s) => s != null).join(' '),
            // `reason` 是 Rust 那边给的原串(如「换算表待核」),这里原样显示,
            // 不另写一句——两处各写一句,改了一处另一处就悄悄留在旧措辞上。
            longText: u['reason'] as String?,
          ),
      ],
    );
  }
}

class _HcqBlock extends StatelessWidget {
  const _HcqBlock(this.hcq);

  final Map<String, dynamic> hcq;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final dailyMg = hcq['daily_mg'];
    final dose = hcq['dose'] as String?;
    final doseAt = fmtDate(hcq['dose_at'] as String?);
    final weightKg = hcq['weight_kg'];
    final weightAt = fmtDate(hcq['weight_at'] as String?);
    final weightSource = _kWeightSourceLabel[hcq['weight_source']];
    final mgPerKg = hcq['mg_per_kg'];
    final target = hcq['target'];
    final labelRule = hcq['label_rule'] as String?;
    final labelRulePending = hcq['label_rule_pending'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('羟氯喹', style: MedType.caption.copyWith(color: c.ink3)),
        const SizedBox(height: 4),
        if (dailyMg != null)
          _ItemRow(
            icon: Icons.medication_outlined,
            label: [
              ?dose,
              '$dailyMg mg/日',
            ].join(' '),
            meta: [
              doseAt.isEmpty ? null : '剂量 $doseAt',
              weightKg == null
                  ? null
                  : '体重 $weightKg kg'
                        '${weightSource == null ? '' : '($weightSource)'}'
                        '${weightAt.isEmpty ? '' : ' $weightAt'}',
              mgPerKg == null
                  ? null
                  : 'mg/kg $mgPerKg${target == null ? '' : '(目标 ≤ $target)'}',
            ],
          )
        else
          // `reason` 永远说明白剂量算不出来的原因(处方缺、剂量缺、体重缺三选
          // 一),原样显示,不另写一句——同一条理由见 `_GcBlock` 的 unconvertible。
          _ItemRow(
            icon: Icons.medication_outlined,
            label: '羟氯喹',
            longText: hcq['reason'] as String?,
          ),
        if (labelRule != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            // brief §形「指南更新」那段引用文字换蓝横幅——这里只借它的两个色token
            // (`MedBrand.bannerBlue`/`bannerBlueInk`)与横幅圆角,文字和 pill
            // 原样不动。
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: MedShape.s2,
                vertical: MedShape.s1,
              ),
              decoration: BoxDecoration(
                color: MedBrand.bannerBlue,
                borderRadius: BorderRadius.circular(MedShape.radiusBanner),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '说明书:$labelRule',
                      style: MedType.secondary.copyWith(
                        color: MedBrand.bannerBlueInk,
                      ),
                    ),
                  ),
                  const SizedBox(width: MedShape.s1),
                  // `label_rule_pending` 只能显示成「待核」,不许显示成任何一种
                  // 判定——fail closed,见 `rules.rs::hcq_body` 头部注释。
                  MedPill(
                    text: labelRulePending ? '待核' : '已核对',
                    foreground: c.ink2,
                    background: c.line2,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _OtherDrugRow extends StatelessWidget {
  const _OtherDrugRow(this.med);

  final Map<String, dynamic> med;

  @override
  Widget build(BuildContext context) {
    final infusion = med['infusion'] == null ? null : _asMap(med['infusion']);
    // 给药途径的 key(`"iv"`/`"sc"`,`package.rs::Drug.infusion`)必须留着——同一个
    // 药不同途径的剂量常常不一样(贝利尤单抗 IV 与 SC 的方案原文都不同),丢了 key
    // 只拼 value 会把两句话读成一句,分不出哪半句是哪种给药方式。
    final infusionText = infusion?.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(' / ');
    return _ItemRow(
      icon: Icons.medication_outlined,
      label: [
        med['name'],
        med['latest_dose'],
      ].where((s) => s != null).join(' '),
      meta: [
        [
          fmtDate(med['since'] as String?),
          fmtDate(med['as_of'] as String?),
        ].where((s) => s.isNotEmpty).join(' – '),
      ],
      longText: infusionText,
    );
  }
}

class _LastVisitRow extends StatelessWidget {
  const _LastVisitRow(this.visit);

  final Map<String, dynamic> visit;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final date = fmtDate(visit['date'] as String?);
    final title = visit['title'] as String?;
    // 只是「最近一份病历」,不是「上次就诊」——这里没有科室信息,不许替它加一个
    // 没有的意思(`rules.rs::last_visit_doc` 头部注释,Task 21 明确写了这条)。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.event_note_outlined, size: 16, color: c.ink3),
        const SizedBox(width: MedShape.s1),
        Expanded(
          child: Text(
            [
              '最近一份病历',
              if (date.isNotEmpty) date,
              if (title != null && title.isNotEmpty) title,
            ].join(' · '),
            style: MedType.secondary.copyWith(
              color: c.ink3,
              fontFeatures: MedType.tabular,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// score_card —— 活动度(化验可算部分)
// ---------------------------------------------------------------------------

class _ScoreCardBody extends StatelessWidget {
  const _ScoreCardBody(this.body);

  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final hits = _asMapList(body['hits']);
    final missed = _asMapList(body['missed']);
    final unscored = _asMapList(body['unscored']);
    final label = body['label'] as String?;
    final asOf = fmtDate(body['as_of'] as String?);
    final windowDays = body['window_days'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('${body['score']}', style: MedType.value.copyWith(color: c.ink)),
            Text(
              ' / ${body['max']}',
              style: MedType.body.copyWith(
                color: c.ink3,
                fontFeatures: MedType.tabular,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: MedShape.s1,
            runSpacing: 4,
            children: [
              if (label case final l? when l.isNotEmpty)
                MedPill(text: l, foreground: c.ink2, background: c.line2),
              ?_metaLine(context, [
                windowDays == null ? null : '窗口 $windowDays 天',
                asOf,
              ]),
            ],
          ),
        ),
        if (hits.isNotEmpty || missed.isNotEmpty || unscored.isNotEmpty) ...[
          const SizedBox(height: MedShape.s2),
          const Divider(height: 1),
          for (final h in hits) _hitRow(c, h),
          for (final m in missed) _missedRow(m),
          for (final u in unscored) _unscoredRow(u),
        ],
      ],
    );
  }

  Widget _hitRow(MedColors c, Map<String, dynamic> h) {
    final weight = h['weight'];
    final row = _ItemRow(
      icon: Icons.check_circle_outline,
      label: '${h['label']}',
      trailing: weight == null
          ? null
          : MedPill(text: '+$weight 分', foreground: c.ink2, background: c.line2),
      meta: [h['source'] == null ? null : '出处 ${h['source']}'],
      longText: _evidenceText(_asMapList(h['evidence'])),
    );
    final caveat = h['caveat'] as String?;
    if (caveat == null || caveat.isEmpty) return row;
    // `caveat`(spec §5.2 的临床限定语,如「非 Farr 法,按定义有偏差」)与证据行是
    // 两句不同的话,原样单独成行——与 `unconvertible[].reason` 同一处理方式,不
    // 拼进 `longText` 里(拼了就核不到这一句的逐字原文)。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        Padding(
          padding: const EdgeInsets.only(
            left: 18 + MedShape.s2,
            bottom: MedShape.s1,
          ),
          child: Text(caveat, style: MedType.secondary.copyWith(color: c.ink)),
        ),
      ],
    );
  }

  Widget _missedRow(Map<String, dynamic> m) {
    return _ItemRow(
      icon: Icons.cancel_outlined,
      label: '${m['label']}',
      longText: _evidenceText(_asMapList(m['evidence'])),
    );
  }

  Widget _unscoredRow(Map<String, dynamic> u) {
    return _ItemRow(
      icon: Icons.help_outline,
      label: '${u['label']}',
      longText: u['reason'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// series_chart —— 指标趋势
// ---------------------------------------------------------------------------

class _SeriesChartBody extends StatelessWidget {
  const _SeriesChartBody(this.body);

  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    final groups = _asMapList(body['groups']);
    final missing = _asMapList(body['missing']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) const SizedBox(height: MedShape.s3),
          _SeriesGroup(groups[i]),
        ],
        if (missing.isNotEmpty) ...[
          const SizedBox(height: MedShape.s2),
          for (final m in missing)
            _MissingRow((m['name'] as String?) ?? (m['key'] as String?) ?? ''),
        ],
      ],
    );
  }
}

class _MissingRow extends StatelessWidget {
  const _MissingRow(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text('没查到 · $name', style: MedType.secondary.copyWith(color: c.ink3)),
    );
  }
}

class _SeriesGroup extends StatelessWidget {
  const _SeriesGroup(this.group);

  final Map<String, dynamic> group;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final series = _asMapList(group['series']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${group['name']}', style: MedType.subtitle.copyWith(color: c.ink)),
        for (final s in series) ...[
          const SizedBox(height: MedShape.s2),
          _SeriesCard(s),
        ],
      ],
    );
  }
}

/// 一条序列:标题行(名字 + 单位 + 需核对/已换算 chip)+ 折线图(复用
/// `widgets/trend_chart.dart`)+ 未标日期/未来点计数 + 定性结果原文。
///
/// **`TrendChart` 目前只按 `selfMeasured` 画空心点,不认逐点的 `unverified`**
/// (`widgets/trend_chart.dart::_TrendPainter`)。序列级「需核对 ×N」chip 已经把
/// 这件事说给用户听,点本身暂时还是实心画——`_TrendPainter` 要扩展成认
/// `TrendPointDto.unverified` 才能补上空心标记,这个改动会影响所有调用
/// `TrendChart` 的既有屏(`trends_screen.dart`),不在本任务范围内单独去动。
/// ponytail: 序列级 chip 已经诚实,逐点空心留给 trend_chart.dart 扩展。
class _SeriesCard extends StatelessWidget {
  const _SeriesCard(this.series);

  final Map<String, dynamic> series;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final name = (series['name'] as String?) ?? (series['analyte_key'] as String?) ?? '';
    final unit = series['unit'] as String?;
    final valuesConverted = series['values_converted'] == true;
    final needsReview = series['needs_review_count'];
    final points = _asMapList(series['points']);
    final undated = _asMapList(series['undated']);
    final futurePoints = series['future_points'];
    final qualitative = _asMapList(series['qualitative']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: MedShape.s1,
          runSpacing: 4,
          children: [
            Text(
              [name, if (unit != null && unit.isNotEmpty) unit].join(' · '),
              style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w600),
            ),
            if (needsReview is num && needsReview > 0)
              MedPill(
                text: '需核对 ×$needsReview',
                foreground: c.ink2,
                background: c.line2,
              ),
            if (valuesConverted)
              // 「已换算」——这条线上混了不同印刷单位,画的是统一后的规范单位,
              // 用户在自己那张化验单上找不到这个数(`AnalyteSeries.values_converted`
              // 的既有约定)。措辞与 `widgets/lab_status.dart::unitConvertedNote`
              // 不完全一样(那边是「已统一换算」)——两处说的是同一件事,这里
              // 单独起名是因为这张卡片的字面量必须包含「已换算」这个子串
              // (Task 21 brief 的钉子测试),不是又发明了一套新说法。
              MedPill(text: '已换算', foreground: c.ink2, background: c.line2),
          ],
        ),
        if (_seriesDto(name, unit, series, points) case final dto when dto.points.isNotEmpty) ...[
          const SizedBox(height: MedShape.s1),
          TrendChart(series: dto),
        ],
        if (_metaLine(context, [
          undated.isEmpty ? null : '另有 ${undated.length} 项没有日期',
          (futurePoints is num && futurePoints > 0) ? '$futurePoints 项日期在未来' : null,
        ])
            case final m?)
          Padding(padding: const EdgeInsets.only(top: 4), child: m),
        for (final q in qualitative)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [fmtDate(q['date'] as String?), '${q['value']}']
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              style: MedType.secondary.copyWith(color: c.ink2),
            ),
          ),
      ],
    );
  }

  TrendSeriesDto _seriesDto(
    String name,
    String? unit,
    Map<String, dynamic> series,
    List<Map<String, dynamic>> points,
  ) {
    final pts = <TrendPointDto>[
      for (final p in points)
        if (p['value'] is num)
          TrendPointDto(
            date: p['date'] as String?,
            value: (p['value'] as num).toDouble(),
            unit: unit,
            flag: p['flag'] as String?,
            documentId: (p['document_index'] as num?)?.toInt() ?? 0,
            unverified: p['unverified'] == true,
          ),
    ];
    return TrendSeriesDto(
      name: name,
      analyteKey: series['analyte_key'] as String?,
      unit: unit,
      refLow: (series['ref_low'] as num?)?.toDouble(),
      refHigh: (series['ref_high'] as num?)?.toDouble(),
      valuesConverted: series['values_converted'] == true,
      anyAbnormal: pts.any((p) => p.flag == 'H' || p.flag == 'L'),
      points: pts,
      selfMeasured: false,
    );
  }
}

// ---------------------------------------------------------------------------
// reminders —— 待补 / 逾期
// ---------------------------------------------------------------------------

class _RemindersBody extends StatelessWidget {
  const _RemindersBody(this.body);

  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    final items = _asMapList(body['items']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final it in items) ...[
          _ReminderRow(it),
          if (it != items.last) const SizedBox(height: MedShape.s1),
        ],
      ],
    );
  }
}

/// 每一条待补 / 逾期都是一枚琥珀横幅(brief §形:「血常规逾期 8 个月」「眼底
/// 检查还没查过」这类提醒)。**不直接套 `MedBanner`**:它只有 title/subtitle 两个
/// 插槽,而一条提醒真实带着的信息(状态 pill、指南出处 pill、超期天数、活动期/
/// 稳定期、日期区间、出处、`reason`/`note`)比这两个插槽能装的多得多——套上去
/// 就要么截断信息,要么把好几个独立 pill 拼成一句话(两者都会被
/// `test/profile_sections_test.dart` 的「every reminder shows its basis
/// label」「a reminder row prints the package note it was handed」逮到)。这里
/// 借的是 `MedBanner` 的颜色 token(`MedBrand.bannerAmber`/`bannerAmberInk`)与
/// 圆角,连同它的签名元素——44×44 `MedIcon`(R26:`_ItemRow.leading`)与
/// 标题字色(R26:`_ItemRow.labelColor`)——内容仍是 `_ItemRow` 的既有排法,视觉
/// 是琥珀横幅,信息一个字不丢。
class _ReminderRow extends StatelessWidget {
  const _ReminderRow(this.item);

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // `pending:true` = 这条规则的数没核实,只显示不算到期——永远显示成「待核」,
    // 不许显示成一个算出来的到期日(brief 的硬约束)。
    final pending = item['pending'] == true;
    final stateLabel = pending
        ? '待核'
        : (_kReminderStateLabel[item['state']] ?? '未知');
    final basis = _basisLabel(item['basis']);
    final text =
        (item['text'] as String?) ??
        (item['action'] as String?) ??
        (item['id'] as String? ?? '');
    final overdueDays = item['overdue_days'];
    final diseaseState = switch (item['disease_state']) {
      'active' => '活动期',
      'stable' => '稳定期',
      _ => null,
    };

    return Container(
      decoration: BoxDecoration(
        color: MedBrand.bannerAmber,
        borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      ),
      padding: const EdgeInsets.symmetric(horizontal: MedShape.s2),
      child: _ItemRow(
        icon: Icons.notifications_outlined,
        leading: const MedIcon(Icons.notifications_outlined),
        label: text,
        labelColor: MedBrand.bannerAmberInk,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MedPill(text: stateLabel, foreground: c.ink2, background: c.line2),
            if (basis != null) ...[
              const SizedBox(width: 4),
              MedPill(text: basis, foreground: c.ink2, background: c.line2),
            ],
          ],
        ),
        meta: [
          (!pending && item['state'] == 'overdue' && overdueDays != null)
              ? '超期 $overdueDays 天'
              : null,
          diseaseState,
          [
            fmtDate(item['since'] as String?),
            fmtDate(item['as_of'] as String?),
          ].where((s) => s.isNotEmpty).join(' – '),
          item['source'] == null ? null : '出处 ${item['source']}',
        ],
        longText: item['reason'] as String?,
        note: item['note'] as String?,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// timeline —— 病程时间轴
// ---------------------------------------------------------------------------

class _TimelineBody extends StatelessWidget {
  const _TimelineBody(this.body);

  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    final years = _asMapList(body['years']);
    final undated = _asMapList(body['undated']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final y in years) _YearGroup(y),
        // 没有日期的事件**必须自己一组**:跟在最后一个年份后面等于把它们说成那一年
        // 发生的(一条没有日期的活检排在 `2026` 表头下,只会被读成 2026 年做的)。
        // 引擎的原意是「不进年,但不丢」(`rules.rs::timeline_section`)。
        // 「日期不详」是引擎级结构词,不是哪个病的措辞;查看器 `pfTimeline` 同一个词。
        if (undated.isNotEmpty) _YearGroup({'year': '日期不详', 'events': undated}),
      ],
    );
  }
}

class _YearGroup extends StatelessWidget {
  const _YearGroup(this.year);

  final Map<String, dynamic> year;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final events = _asMapList(year['events']);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${year['year']}', style: MedType.subtitle.copyWith(color: c.ink)),
          for (final e in events) _TimelineEventRow(e),
        ],
      ),
    );
  }
}

/// 一条病程事件:左边是竖线 + 圆点的「轨道」,右边是既有的 `_ItemRow` 内容
/// (不传 [_ItemRow.icon]——圆点已经是这一行的标记,两个标记会打架)。
///
/// 竖线用 `IntrinsicHeight` 撑满这一行的实际高度(内容行数不定:有的事件只有
/// 一个日期,有的还带 `note`/`longText`),再用 `Positioned(top:0, bottom:0)`
/// 让线在那个高度里拉满——单靠 `Expanded`/`Align` 接不住:轨道那一列自己没有
/// 内容撑高度,拿到的是 0,得先由 `IntrinsicHeight` 把整行的高度喂给它。
class _TimelineEventRow extends StatelessWidget {
  const _TimelineEventRow(this.event);

  final Map<String, dynamic> event;

  /// 轨道(竖线 + 圆点)那一栏的宽度:圆点外圈直径 16(见 [_TimelineDot]),
  /// 两边各留 2 呼吸空间。
  static const double _railWidth = 20;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final severityHigh = event['severity'] == 'high';
    final typeLabel = _kTimelineTypeLabel[event['type']];
    final date = fmtDate(event['date'] as String?);
    final text = event['text'] as String?;

    final content = _ItemRow(
      label: text ?? typeLabel ?? (event['type'] as String? ?? ''),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (typeLabel != null && text != null)
            MedPill(text: typeLabel, foreground: c.ink2, background: c.line2),
          if (event['unverified'] == true) ...[
            const SizedBox(width: 4),
            // R4:「需核对」只许用 `MedPill.check`,不许再各写各的配色。
            MedPill.check('需核对'),
          ],
        ],
      ),
      meta: [date],
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _railWidth,
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: (_railWidth - 2) / 2,
                  width: 2,
                  child: Container(color: MedBrand.timelineLine),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: _TimelineDot(critical: severityHigh),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// 时间轴圆点:10×10 实心 `seal`(异常事件换 `MedColors.critical`)、2px 白边、
/// 外面再一圈 1px `MedBrand.timelineLine`——三层同心圆,逐层套 `Container`
/// (Flutter 没有 CSS 那种叠 `box-shadow`/多层 border,套色块是最省事的等价画法)。
class _TimelineDot extends StatelessWidget {
  const _TimelineDot({required this.critical});

  final bool critical;

  static const double _core = 10;
  static const double _whiteRing = 2;
  static const double _outerRing = 1;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      width: _core + 2 * (_whiteRing + _outerRing),
      height: _core + 2 * (_whiteRing + _outerRing),
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: MedBrand.timelineLine,
      ),
      child: Container(
        width: _core + 2 * _whiteRing,
        height: _core + 2 * _whiteRing,
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
        child: Container(
          width: _core,
          height: _core,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: critical ? c.critical : c.seal,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// checklist —— 达标情况 / 狼疮肾炎治疗里程碑(同一个 kind,复用同一套渲染)
// ---------------------------------------------------------------------------

class _ChecklistBody extends StatelessWidget {
  const _ChecklistBody({required this.sectionId, required this.body});

  final String? sectionId;
  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    // 按 `section.id` 认里程碑表(`ln_milestones`),body 形状只当兜底——两块
    // checklist 复用同一个 kind,id 才是渲染层认它们的唯一钥匙
    // (`packages/profile/src/view.rs` 里 `Section.id` 那段文档明确写了这条,
    // 不许靠「body 里有哪个键」去猜)。
    final isMilestones =
        sectionId == 'ln_milestones' ||
        (body['states'] == null && body['items'] != null);
    if (isMilestones) {
      final items = _asMapList(body['items']);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final it in items) _ChecklistItemRow(it)],
      );
    }
    final states = _asMapList(body['states']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < states.length; i++) ...[
          if (i > 0) const Padding(
            padding: EdgeInsets.symmetric(vertical: MedShape.s1),
            child: Divider(height: 1),
          ),
          _ChecklistStateGroup(states[i]),
        ],
      ],
    );
  }
}

class _ChecklistStateGroup extends StatelessWidget {
  const _ChecklistStateGroup(this.state);

  final Map<String, dynamic> state;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final items = _asMapList(state['items']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // 组头只用图标提示整体走向,不重复item 已经在下面逐条说的
            // 「满足/未满足/未知」这几个字——两处都写会在同一屏里重复计数,
            // 且「逐条对照,不下结论」本就不该在组一级再喊一遍结论
            // (global-constraints:达标表逐条 ✔/✘/未知,不下结论)。
            Icon(_verdictIcon(state['verdict']), size: 18, color: c.ink2),
            const SizedBox(width: MedShape.s1),
            Expanded(
              child: Text(
                '${state['label']}',
                style: MedType.subtitle.copyWith(color: c.ink),
              ),
            ),
          ],
        ),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(left: MedShape.s4 + MedShape.s1),
            child: _ChecklistItemRow(it),
          ),
      ],
    );
  }
}

class _ChecklistItemRow extends StatelessWidget {
  const _ChecklistItemRow(this.item);

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final verdict = item['verdict'];
    final actualAt = fmtDate(item['actual_at'] as String?);
    return _ItemRow(
      icon: _verdictIcon(verdict),
      label: '${item['label']}',
      trailing: MedPill(
        text: _verdictLabel(verdict),
        foreground: c.ink2,
        background: c.line2,
      ),
      meta: [
        _actualText(item['actual'], item['actual_unit'] as String?),
        actualAt,
        item['source'] == null ? null : '出处 ${item['source']}',
      ],
      // `reason` 只有 unknown 才有(`states_section`/`eval_milestone` 的约定),
      // 原样显示。
      longText: item['reason'] as String?,
      note: item['note'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// handoff —— 医生交接单
// ---------------------------------------------------------------------------

/// `handoff` 目前还没有引擎会往 `ProfileView.sections[]` 里放的实例
/// (`packages/profile/src/rules.rs` 没有 `handoff_section` 构建函数,
/// `testdata/golden_profile_view.json` 也没有这一种 section;spec §6 把它列为
/// 7 种之一,内容留给后续任务)。这里按已知的 `{blocks:[{title?,text?}]}` 形状
/// 通用渲染,保证它是「认识但暂时没数据」而不是「跳过」——kind 一旦真的开始出现
/// 就有地方接,不会静默消失。
/// ponytail: 只画 `title`/`text` 两个通用字段,body 形状一旦定下来再补齐。
class _HandoffBody extends StatelessWidget {
  const _HandoffBody(this.body);

  final Map<String, dynamic> body;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final blocks = _asMapList(body['blocks']);
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blocks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: MedShape.s1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (b['title'] case final String t when t.isNotEmpty)
                  Text(t, style: MedType.subtitle.copyWith(color: c.ink)),
                if (b['text'] case final String t when t.isNotEmpty)
                  Text(t, style: MedType.body.copyWith(color: c.ink)),
              ],
            ),
          ),
      ],
    );
  }
}
