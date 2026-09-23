# 首页待办 + 自测按周折叠 + 添加里记数 + 趋势重整 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 病历首页答「接下来要干什么」(待办块 + 只留事件的时间线,自测按周折一行);添加里能记数;趋势只收测过 ≥ 2 次的指标,类别 chip 筛整页,关键化验与折线合成一个带迷你折线的列表,删掉和病历页重合的块。

**Architecture:** Rust 投影层加一种时间线分组(`SelfWeek`)和两个只读查询(30 天异常项数、已开启档案的到期提醒);Flutter 侧新增 `HomeTodo` 卡与自测周行渲染,「添加」sheet 加一项直达现有录入弹层,趋势页把三个列表合成一个 `TrendRow` 列表。文案闸加一个与删除预算对称的「新增预算」。视觉规则沿用减法(白卡细边、颜色只说状态、无渐变阴影)。

**Tech Stack:** Flutter(`apps/mobile_flutter`),Rust(`apps/mobile_flutter/rust`、`packages/parser`、`packages/profile`),flutter_rust_bridge 代码生成。不加依赖。

**Spec:** `docs/superpowers/specs/2026-09-23-home-todo-and-trends-rework-design.md`

**Worktree / 分支:** `/Volumes/extraSupply/Projects/Medme-adv-a`,`feat/ia-rework`(基于减法分支 `feat/ux-stage3-5-subtraction`,PR #229)。路径相对 `apps/mobile_flutter/`,除非写明。

## Global Constraints

每个 Task 的要求都隐含包含这一节。

- **文案纪律**:用户可见的新字只许是本计划列出的这些(逐字):「只看异常」「只测过一次的 N 项」「最近 30 天有 N 项偏高或偏低」「自测 · M 月 D 日 – M 月 D 日」「N 次」;其余全部沿用现有字(「记录一下」「自己量的血压、体重,或者想记一句话」从趋势页**搬**到添加 sheet;「超期 N 天」与状态词沿用病程档案页;指标名 血压/心率/体重/体温/血糖 沿用录入弹层)。不用术语、不用禁词(`test/glossary_guard_test.dart`)。**每个 Task 结束时 `test/copy_unchanged_test.dart` 必须绿**:新增的段登记进 `kAddedByDecision`、删掉的段登记进 `kRemovedByDecision`,预算 = 闸报告的差值,**评审逐条核对登记的段都对应本计划的改动**,不许登记本计划之外的字。
- **视觉规则(减法)**:白卡 1px `line` 细边、行间 `line2` 分隔线、无渐变无阴影(`test/no_gradient_no_shadow_test.dart`)、颜色只说状态(`statusWord` / `high` / `low`)、图标只在需要区分时出现、字号不缩。每屏主按钮/主卡计数不变(病历 hero 0 / button 1,趋势 0 / 0)。
- **Rust / FRB 规则**:新的对外函数名必须按字典序排在 `recognize_image_pp` 之后(用 `view_*` / `vault_profile_*` 前缀);改 `dto.rs` 或加对外函数后运行 `cd apps/mobile_flutter && flutter_rust_bridge_codegen generate`,生成文件(`lib/src/rust/**`)一并提交;`cargo test frb_dispatch_indices`(在 `apps/mobile_flutter/rust`)必须绿。库代码不用 `unwrap()` / `expect()` / `unsafe`;不动 vault 存储格式(只读投影)。
- **不做判定**:UI 不从参考区间反推异常;30 天异常项数只数 Rust 已标 H/L 的化验,自测不算。
- **代拍模式不受影响**:`ArchiveScreen` 在 `doctor_home_screen.dart` 也被实例化,待办块只在个人模式出现(构造参数 `showTodo`,代拍传 `false`)。
- **不加依赖;不动隐私政策(数据流向不变)。**
- **每个 Task 收尾**:`/Users/ziyuanguan/flutter/bin/flutter analyze` 干净 + 该 Task 的测试绿(Rust 任务另加 `cargo test` 于 `apps/mobile_flutter/rust`)+ 一次 commit,message 末尾**必须**带:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
```

- **构建纪律**:只跑 `flutter analyze` / `flutter test` / `cargo test`;不跑 release、不跑全 ABI;预计超过 5 分钟的命令先停下来报。

---

### Task 1: Rust —— 时间线新分组 `SelfWeek`(自测按自然周折叠)

**Files:**
- Modify: `rust/src/api/dto.rs`(`TimelineGroupDto` 加变体;新增 `SelfWeekDocDto`、`SelfWeekItemDto`)
- Modify: `rust/src/api/vault.rs`(`load_archive`;新增 `self_week_groups`)
- Test: `rust/src/api/vault.rs` 的 `mod tests`
- Generated: `lib/src/rust/api/dto.dart`、`lib/src/rust/api/dto.freezed.dart`、`lib/src/rust/frb_generated.dart`、`rust/src/frb_generated.rs`(codegen 产物,一并提交)

**Interfaces:**
- Produces: `TimelineGroupDto::SelfWeek { week_start: String /*YYYY-MM-DD, 周一*/, week_end: String /*周日*/, docs: Vec<SelfWeekDocDto>, summary: Vec<SelfWeekItemDto> }`;`SelfWeekDocDto { doc: DocumentSummaryDto, values: Vec<SelfMeasuredValueDto> }`;`SelfWeekItemDto { analyte_key: String, count: i64, min: f64, max: f64, unit: String }`。Dart 侧生成 `TimelineGroupDto_SelfWeek`。
- 规则:有日期的 `self_measurement` 文档进周组(按 ISO 周,周一起);没日期的仍是 `Document`。周组的排序键 = `week_start` 当天 `T23:59:59+00:00`(与同日文档并列时排在前面)。周内 `docs` 按日期倒序。`summary` 按固定顺序 `bp_systolic, bp_diastolic, heart_rate, body_weight, body_temperature, glucose`,其余按 key 字典序追加;`unit` 取该指标第一条的单位。

- [ ] **Step 1: 写失败的测试**

`rust/src/api/vault.rs` 的 `mod tests` 里(沿用 `self_measured_bp_never_merges_with_hospital_bp_end_to_end` 那套 `TEST_LOCK` + `tempdir` + `open_vault` + `add_self_measurement` 写法):

```rust
    #[test]
    fn timeline_folds_self_measurements_into_iso_weeks() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempfile::tempdir().unwrap();
        let docs_dir = tmp.path().join("docs");
        let data_dir = tmp.path().join("data");
        std::fs::create_dir_all(&docs_dir).unwrap();
        std::fs::create_dir_all(&data_dir).unwrap();
        crate::api::vault::open_vault(docs_dir.to_string_lossy().into(), data_dir.to_string_lossy().into(), None).unwrap();
        let bp = |s: f64, d: f64| vec![
            SelfMeasuredValueDto { analyte_key: "bp_systolic".into(), value: s, unit: "mmHg".into() },
            SelfMeasuredValueDto { analyte_key: "bp_diastolic".into(), value: d, unit: "mmHg".into() },
        ];
        // 2026-04-27 是周一;4 月 27 日–5 月 3 日一周,跨月。
        crate::api::vault::add_self_measurement(bp(118.0, 74.0), Some("2026-04-27T08:00:00Z".into())).unwrap();
        crate::api::vault::add_self_measurement(bp(132.0, 80.0), Some("2026-05-02T08:00:00Z".into())).unwrap();
        crate::api::vault::add_self_measurement(
            vec![SelfMeasuredValueDto { analyte_key: "glucose".into(), value: 6.3, unit: "mmol/L".into() }],
            Some("2026-05-04T08:00:00Z".into()),
        ).unwrap();

        let groups = crate::api::vault::load_archive().unwrap();
        let weeks: Vec<_> = groups.iter().filter_map(|g| match g {
            TimelineGroupDto::SelfWeek { week_start, week_end, docs, summary } => Some((week_start.clone(), week_end.clone(), docs.len(), summary.clone())),
            _ => None,
        }).collect();
        assert_eq!(weeks.len(), 2, "两个自然周");
        // 倒序:5 月 4 日那周在前。
        assert_eq!((weeks[0].0.as_str(), weeks[0].1.as_str(), weeks[0].2), ("2026-05-04", "2026-05-10", 1));
        assert_eq!((weeks[1].0.as_str(), weeks[1].1.as_str(), weeks[1].2), ("2026-04-27", "2026-05-03", 2));
        let s = &weeks[1].3;
        assert_eq!(s[0].analyte_key, "bp_systolic");
        assert_eq!((s[0].count, s[0].min, s[0].max, s[0].unit.as_str()), (2, 118.0, 132.0, "mmHg"));
        assert_eq!(s[1].analyte_key, "bp_diastolic");
        assert_eq!((s[1].count, s[1].min, s[1].max), (2, 74.0, 80.0));
        // 没有任何 self_measurement 以 Document 变体出现(全部有日期)。
        assert!(groups.iter().all(|g| !matches!(g, TimelineGroupDto::Document { doc } if doc.doc_type == "self_measurement")));
        // 周组里的每份自测都带着结构化值。
        if let TimelineGroupDto::SelfWeek { docs, .. } = &groups[1] {
            assert!(docs.iter().all(|d| !d.values.is_empty()));
            assert!(docs[0].doc.doc_date.as_deref().unwrap() > docs[1].doc.doc_date.as_deref().unwrap(), "周内倒序");
        }
    }
```

跑:`cd apps/mobile_flutter/rust && cargo test timeline_folds_self_measurements_into_iso_weeks` —— 预期编译失败(`SelfWeek` 不存在)。

- [ ] **Step 2: DTO**

`rust/src/api/dto.rs`,`TimelineGroupDto` 旁边:

```rust
/// 「自测周」里的一份自测:文档摘要 + 它的结构化值(从 `###MEDME-SELF-V1###` 载荷读出,
/// 与 `self_measurement_values` 同一条读法,读不出就是空)。
#[derive(Debug, Clone)]
pub struct SelfWeekDocDto {
    pub doc: DocumentSummaryDto,
    pub values: Vec<SelfMeasuredValueDto>,
}

/// 一周里某个指标的汇总:次数与范围。**只汇总,不判定**——没有 flag,颜色由界面按
/// 规则决定(减法:自测周行本来就不上色)。
#[derive(Debug, Clone)]
pub struct SelfWeekItemDto {
    pub analyte_key: String,
    pub count: i64,
    pub min: f64,
    pub max: f64,
    pub unit: String,
}

pub enum TimelineGroupDto {
    Encounter { encounter: EncounterSummaryDto, docs: Vec<DocumentSummaryDto> },
    Document { doc: DocumentSummaryDto },
    /// 同一自然周(周一到周日)的自测记录折成一行(用户 2026-09-23:单次自测没意义,
    /// 一周才看得出东西)。`week_start`/`week_end` 是 `YYYY-MM-DD`。
    SelfWeek {
        week_start: String,
        week_end: String,
        docs: Vec<SelfWeekDocDto>,
        summary: Vec<SelfWeekItemDto>,
    },
}
```

(保留原有两个变体的 derive/注释;`SelfMeasuredValueDto` 已在同文件。)

- [ ] **Step 3: `load_archive` 分流**

`rust/src/api/vault.rs`:`standalone_documents()` 那段循环改成先分流:

```rust
        let mut self_docs: Vec<medme_core_model::Document> = Vec::new(); // 用文件里实际的 Document 类型路径
        for d in v.standalone_documents().map_err(|e| anyhow::anyhow!(e.to_string()))? {
            if d.doc_type.as_str() == "self_measurement" && d.doc_date.is_some() {
                self_docs.push(d);
                continue;
            }
            let sort = d.doc_date.map(|x| x.to_rfc3339());
            groups.push((sort, TimelineGroupDto::Document { doc: doc_summary(v, &d) }));
        }
        groups.extend(self_week_groups(v, self_docs)?);
```

新函数(同文件,`load_archive` 下面):

```rust
/// 把有日期的自测文档按 ISO 周(周一起)折成 [`TimelineGroupDto::SelfWeek`]。
/// 排序键取周一那天的 `T23:59:59+00:00`:同一天既有门诊又有自测时,周组排在门诊前面
/// (倒序列表里更靠上),而整周仍归到周一所在的月(`byMonth` 按 `week_start` 分月)。
fn self_week_groups(
    v: &Vault,
    docs: Vec<Document>,
) -> anyhow::Result<Vec<(Option<String>, TimelineGroupDto)>> {
    use chrono::Datelike;
    use std::collections::BTreeMap;
    const ORDER: [&str; 6] = ["bp_systolic", "bp_diastolic", "heart_rate", "body_weight", "body_temperature", "glucose"];

    let mut weeks: BTreeMap<chrono::NaiveDate, Vec<Document>> = BTreeMap::new();
    for d in docs {
        let Some(date) = d.doc_date else { continue };
        let day = date.date_naive();
        let monday = day - chrono::Duration::days(i64::from(day.weekday().num_days_from_monday()));
        weeks.entry(monday).or_default().push(d);
    }

    let mut out = Vec::new();
    for (monday, mut ds) in weeks {
        ds.sort_by(|a, b| b.doc_date.cmp(&a.doc_date));
        let mut agg: BTreeMap<String, (i64, f64, f64, String)> = BTreeMap::new();
        let mut week_docs = Vec::with_capacity(ds.len());
        for d in &ds {
            let text = v.ocr_text(d.id).map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let values: Vec<SelfMeasuredValueDto> = parser::parse_self_measurement_payload(&text)
                .unwrap_or_default()
                .into_iter()
                .map(|x| SelfMeasuredValueDto { analyte_key: x.analyte_key, value: x.value, unit: x.unit })
                .collect();
            for x in &values {
                let e = agg.entry(x.analyte_key.clone()).or_insert((0, x.value, x.value, x.unit.clone()));
                e.0 += 1;
                e.1 = e.1.min(x.value);
                e.2 = e.2.max(x.value);
            }
            week_docs.push(SelfWeekDocDto { doc: doc_summary(v, d), values });
        }
        let mut summary: Vec<SelfWeekItemDto> = Vec::new();
        for key in ORDER.iter().map(|k| k.to_string()).chain(agg.keys().filter(|k| !ORDER.contains(&k.as_str())).cloned()) {
            if let Some((count, min, max, unit)) = agg.get(&key) {
                if summary.iter().any(|s| s.analyte_key == key) { continue; }
                summary.push(SelfWeekItemDto { analyte_key: key.clone(), count: *count, min: *min, max: *max, unit: unit.clone() });
            }
        }
        let sunday = monday + chrono::Duration::days(6);
        let sort = Some(format!("{}T23:59:59+00:00", monday.format("%Y-%m-%d")));
        out.push((sort, TimelineGroupDto::SelfWeek {
            week_start: monday.format("%Y-%m-%d").to_string(),
            week_end: sunday.format("%Y-%m-%d").to_string(),
            docs: week_docs,
            summary,
        }));
    }
    Ok(out)
}
```

`Document` 的实际类型路径、`v.ocr_text` 的可见性按文件现状取(`self_measurement_values` 就在用 `state.vault.ocr_text(document_id)`)。`parser` 已被本文件引用。

- [ ] **Step 4: 跑 Rust 测试,生成绑定**

```bash
cd apps/mobile_flutter/rust && cargo test timeline_folds_self_measurements_into_iso_weeks && cargo test frb_dispatch_indices
cd apps/mobile_flutter && flutter_rust_bridge_codegen generate
git diff --stat lib/src/rust rust/src/frb_generated.rs   # 只增不改:frb_generated.rs 里已有的 `NN =>` 行一条不许变
/Users/ziyuanguan/flutter/bin/flutter analyze
```

`flutter analyze` 会报 Dart 侧 `switch` 不穷尽(archive_screen.dart 的几处 `switch (group)`)——**本 Task 只加最小的 `TimelineGroupDto_SelfWeek()` 分支让它们编译**:`_groupTitle`/`_groupDate`/`_groupDesc`/`_allDocs`/`_confirmedOnly`/`_TimelineItem` 里的 switch 各加一个分支,行为暂时与 `Document` 等价或返回空(`_groupTitle` 返回 `'自测记录'` 现有字、`_groupDate` 返回 `weekStart`、`_allDocs` 展开 `docs.map((d) => d.doc)`、`_confirmedOnly` 原样透传、`_TimelineItem` 不展开)。真正的渲染在 Task 4。

- [ ] **Step 5: 全量 + 提交**

`flutter test` 全绿(`copy_unchanged_test` 不该红:本 Task 没有新增或删除用户可见字;若红,是登记问题,回头看 Step 4 的临时分支有没有写新字)。提交:`feat(rust): 时间线把自测记录按自然周折成 SelfWeek 分组(投影层,带每周汇总与每份结构化值)`。

---

### Task 2: Rust —— 首页待办的两个只读查询

**Files:**
- Modify: `rust/src/api/vault_projections.rs`(`view_abnormal_30d`)
- Modify: `rust/src/api/vault_profile.rs`(`vault_profile_due_reminders`)
- Test: 两个文件各自的 `mod tests`
- Generated: FRB 产物(同 Task 1)

**Interfaces:**
- Produces: `pub fn view_abnormal_30d() -> anyhow::Result<u32>` —— 最近 30 天内(按今天算)最近一次标记为 `H`/`L` 的化验项数,自测不算;`pub fn vault_profile_due_reminders(dir: String) -> anyhow::Result<String>` —— JSON 数组,每项 `{package_id, package_name, id, text, state, due_at, overdue_days, basis}`,只含 `state ∈ {never, overdue}`(**pending 不进首页**——那是「规则还没核实」,留在档案页;这是对 spec 表格的收窄,记入 ledger),顺序沿用包内 `reminders` 节(never → overdue,超期天数降序),包与包之间按 `installed_packages` 顺序。

- [ ] **Step 1: 测试先行**

`vault_projections.rs` `mod tests`(沿用 `recent_changes_are_not_crowded_out_by_a_full_page_of_later_hospital_labs` 的真箱写法,喂两份化验文本:一份 20 天前含一项 `H`,一份 60 天前含一项 `L`;再加一条自测血压):

```rust
    #[test]
    fn abnormal_30d_counts_only_recent_hospital_h_l() {
        // ……open_vault + ingest_bytes 两份化验(日期用 chrono::Utc::now() 减 20 天 / 减 60 天,
        //   文本格式照抄同文件里现成的化验样本,把其中一行标成 H / L)+ add_self_measurement 一条……
        assert_eq!(crate::api::vault_projections::view_abnormal_30d().unwrap(), 1);
    }
```

`vault_profile.rs` `mod tests`(沿用 `open_temp_vault` 与现有「装 SLE 包 + 记 enable 事件」的测试):

```rust
    #[test]
    fn due_reminders_lists_never_items_for_enabled_package_only() {
        // ……open_temp_vault;vault_profile_install_package(dir, sle_envelope);先不开启……
        let before: serde_json::Value = serde_json::from_str(&vault_profile_due_reminders(dir.clone()).unwrap()).unwrap();
        assert_eq!(before.as_array().unwrap().len(), 0, "没开启 = 不提醒");
        // ……vault_profile_record_event(enable)……
        let after: serde_json::Value = serde_json::from_str(&vault_profile_due_reminders(dir).unwrap()).unwrap();
        let items = after.as_array().unwrap();
        assert!(!items.is_empty());
        assert!(items.iter().all(|i| matches!(i["state"].as_str(), Some("never") | Some("overdue"))));
        assert!(items.iter().all(|i| i["package_id"] == "sle" || i["package_id"].is_string()));
        assert!(items[0]["text"].is_string() && items[0]["basis"].is_string());
    }
```

- [ ] **Step 2: 实现**

`vault_projections.rs`(放在 `view_visit_summary` 附近;**判断 H/L 的写法逐字抄 `view_visit_summary` 里 `recent_changes` 那段**,不另发明):

```rust
/// 首页待办第 4 条:最近 30 天内、最近一次被 Rust 标为 H/L 的化验项数。自测不算
/// (自测的 flag 来自家测区间,不是化验单印的)。**只数,不判定。**
pub fn view_abnormal_30d() -> anyhow::Result<u32> {
    let p = gather()?;
    let src = source_docs(&p.docs);
    let agg = parser::aggregate(&src);
    let today = chrono::Utc::now().date_naive();
    let mut n = 0u32;
    for s in agg.labs.iter().filter(|s| !s.self_measured && is_renderable(s)) {
        let Some(last) = s.points.iter().filter(|pt| pt.date.is_some()).max_by_key(|pt| pt.date) else { continue };
        let Some(d) = last.date else { continue };
        if (today - d).num_days() > 30 { continue; }
        // 与 view_visit_summary 的 recent_changes 同一条判法:只认 "H" / "L",印的 "N" 不算。
        if matches!(last.flag.as_deref(), Some("H") | Some("L")) { n += 1; }
    }
    Ok(n)
}
```

`vault_profile.rs`(放在 `vault_profile_view` 下面):

```rust
/// 首页待办:所有**已开启**档案里到期的提醒(`never` / `overdue`)。整箱病历只读一次,
/// 每个包各算一遍 `materialize`;没开启的包一块都不算(spec §4)。`pending`(规则没
/// 核实)不进首页——那是档案页里「只显示不算日期」的东西。
pub fn vault_profile_due_reminders(dir: String) -> anyhow::Result<String> {
    let dir = Path::new(&dir);
    let events = vault_projections::gather_profile_events()?;
    let enabled: Vec<profile::Package> = installed_packages(dir)
        .into_iter()
        .filter(|p| profile::is_enabled(&events, &p.manifest.id))
        .collect();
    if enabled.is_empty() {
        return Ok("[]".into());
    }
    terminology::set_overlay(overlay_entries(dir, &events));
    let input = vault_projections::gather_for_profile()?;
    let docs = input.source_docs();
    let mut out: Vec<serde_json::Value> = Vec::new();
    for pkg in &enabled {
        let view = profile::materialize(&docs, &input.events, pkg, today());
        for sec in view.sections.iter().filter(|s| s.kind == "reminders") {
            let Some(items) = sec.body.get("items").and_then(|i| i.as_array()) else { continue };
            for it in items {
                let state = it.get("state").and_then(|s| s.as_str()).unwrap_or("");
                if !matches!(state, "never" | "overdue") { continue; }
                out.push(serde_json::json!({
                    "package_id": pkg.manifest.id,
                    "package_name": pkg.manifest.display.short,
                    "id": it.get("id").cloned().unwrap_or(serde_json::Value::Null),
                    "text": it.get("text").cloned().unwrap_or(serde_json::Value::Null),
                    "state": state,
                    "due_at": it.get("due_at").cloned().unwrap_or(serde_json::Value::Null),
                    "overdue_days": it.get("overdue_days").cloned().unwrap_or(serde_json::Value::Null),
                    "basis": it.get("basis").cloned().unwrap_or(serde_json::Value::Null),
                }));
            }
        }
    }
    Ok(serde_json::to_string(&out)?)
}
```

- [ ] **Step 3: 跑、生成、提交**

```bash
cd apps/mobile_flutter/rust && cargo test abnormal_30d && cargo test due_reminders && cargo test frb_dispatch_indices
cd apps/mobile_flutter && flutter_rust_bridge_codegen generate && /Users/ziyuanguan/flutter/bin/flutter analyze && /Users/ziyuanguan/flutter/bin/flutter test
```

提交:`feat(rust): 首页待办的两个只读查询 —— 30 天内异常项数、已开启档案的到期提醒`。

---

### Task 3: Flutter 地基 —— 文案闸新增预算、`MedChip` 无计数、`TrendChart` 紧凑模式、日期区间格式

**Files:**
- Modify: `test/copy_unchanged_test.dart`(`kAddedByDecision` + `_overBudgetAdditions` + 自测)
- Modify: `lib/widgets/med_card.dart`(`MedChip.count` 可空)
- Modify: `lib/widgets/trend_chart.dart`(`compact` 参数)
- Modify: `lib/doc_labels.dart`(`fmtDay`、`fmtDayRange`、`selfAnalyteLabel`)
- Test: `test/med_card_test.dart`、`test/motion_test.dart`(新增两条)、`test/doc_display_title_test.dart`(或新 `test/doc_labels_dates_test.dart`)

**Interfaces:**
- Produces: `const Map<String, int> kAddedByDecision`(闸:新增段允许多出的文件数);`MedChip({required label, int? count, required selected, required onTap})`(`count == null` → 只显示 label);`TrendChart({required series, height = 96, animate = true, compact = false})`(compact:内边距 2、点半径 1.2 / 末点 2.0、不画参考带与末点光环);`String fmtDay(String iso) → '4 月 27 日'`、`String fmtDayRange(String startIso, String endIso) → '4 月 27 日 – 5 月 3 日'`、`String selfAnalyteLabel(String key)`(`bp_systolic`/`bp_diastolic` → 血压,`heart_rate` → 心率,`body_weight` → 体重,`body_temperature` → 体温,`glucose` → 血糖,其余原样)——**这些中文标签若 `manual_entry_sheet.dart` 已有同一份,搬到 `doc_labels.dart` 并让录入弹层引用,不留两份。**

- [ ] **Step 1: 文案闸的新增预算**

`test/copy_unchanged_test.dart`:`kRemovedByDecision` 旁边加

```dart
/// 与 [kRemovedByDecision] 对称:这一阶段**允许多出来**的段,值 = 允许多出的文件数。
/// 只登记本阶段计划里列出的新字(见 docs/superpowers/plans/2026-09-23-home-todo-and-trends-rework.md
/// Global Constraints);登记之外的新字照旧红。每个 Task 只登记自己引入的段。
const Map<String, int> kAddedByDecision = {};
```

`_overBudgetRemovals` 旁加同形的 `_overBudgetAdditions(before, now, budget)`(`n > b && (n - b) > (budget[r] ?? 0)`),`_diffAgainstBaseline` 里 `added.add(...)` 改成只在 `overAdded.contains(r)` 时加。自测:预算 1 放行一处新增、拒绝两处(与删除预算的自测同形)。

- [ ] **Step 2: `MedChip.count` 可空**

```dart
  const MedChip({super.key, required this.label, this.count, required this.selected, required this.onTap});
  final int? count;
  ...
          count == null ? label : '$label $count',
```

`test/med_card_test.dart` 加一条:`MedChip(label: '只看异常', selected: true, ...)` 渲染文本恰为 `只看异常`。(「只看异常」是新字,由 Task 6 引入到 lib;测试文件不受闸管。)

- [ ] **Step 3: `TrendChart.compact`**

`lib/widgets/trend_chart.dart`:构造器加 `this.compact = false`;传给 `_TrendPainter`(新增字段 `compact`);`paint` 里 `compact` 时:内边距全部 2、`r = 1.2`、`rLast = 2.0`、跳过参考带与虚线边、跳过末点光环。其余逻辑(描画进度、reduced-motion)不动。`test/motion_test.dart` 加两条:
- `'compact 模式:24 高、78 宽也画得出来,不抛异常,animate:false 直接画完'`(`SizedBox(width: 78, height: 24, child: TrendChart(series: s, height: 24, compact: true, animate: false))`,断言 `takeException()` 为 null,painter.progress == 1.0)。
- `'compact 模式不画参考带'`(painter 的 `compact == true`;若参考带用单独的 paint 调用,可用 `paints` matcher 断言没有 `drawRect` 的带子——实现者按 painter 结构选一种,写明)。

- [ ] **Step 4: 日期与标签**

`lib/doc_labels.dart`:

```dart
/// 「4 月 27 日」:不补零,与 `monthLabel` 同一习惯。解析失败原样返回。
String fmtDay(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${d.month} 月 ${d.day} 日';
}

/// 「4 月 27 日 – 5 月 3 日」(en dash,两侧空格)。
String fmtDayRange(String startIso, String endIso) => '${fmtDay(startIso)} – ${fmtDay(endIso)}';

/// 自测指标的中文名。`bp_systolic` / `bp_diastolic` 都叫「血压」——界面把两者并成一行。
String selfAnalyteLabel(String key) => switch (key) {
  'bp_systolic' || 'bp_diastolic' => '血压',
  'heart_rate' => '心率',
  'body_weight' => '体重',
  'body_temperature' => '体温',
  'glucose' => '血糖',
  _ => key,
};
```

测试:`fmtDay('2026-04-27')` → `4 月 27 日`;`fmtDayRange('2026-04-27','2026-05-03')` → `4 月 27 日 – 5 月 3 日`;`selfAnalyteLabel` 六键。文案闸:「月」「日」「血压」… 若 `doc_labels.dart` 因此多出段,登记进 `kAddedByDecision`(预算 1),评审核对。

- [ ] **Step 5: 跑、提交**

`flutter analyze` + `flutter test test/copy_unchanged_test.dart test/med_card_test.dart test/motion_test.dart test/doc_display_title_test.dart`(及新测试文件)。提交:`feat(ui): 地基 —— 文案闸新增预算、MedChip 无计数、TrendChart 紧凑模式、日期区间与自测指标标签`。

---

### Task 4: 首页 —— 待办卡 + 自测周行

**Files:**
- Create: `lib/widgets/home_todo.dart`(`HomeTodo`、`HomeTodoItem`)
- Create: `lib/widgets/self_week.dart`(`selfWeekTitle`、`selfWeekDesc`、`selfValuesLine` 纯函数 + `SelfWeekRows` 展开列表)
- Modify: `lib/screens/archive_screen.dart`(装配待办;`SelfWeek` 各 switch 分支;`showTodo` 参数)
- Modify: `lib/screens/doctor/doctor_home_screen.dart`(`ArchiveScreen(showTodo: false)`)
- Test: `test/home_todo_test.dart`(新)、`test/self_week_test.dart`(新)、`test/archive_header_test.dart`、`test/archive_visual_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `TimelineGroupDto_SelfWeek`;Task 2 的 `viewAbnormal30d()`、`vaultProfileDueReminders(dir:)`;Task 3 的 `fmtDayRange`、`selfAnalyteLabel`。
- Produces:

```dart
class HomeTodoItem {
  const HomeTodoItem({required this.title, this.note, this.titleColor, required this.onTap});
  final String title; final String? note; final Color? titleColor; final VoidCallback onTap;
}
/// 首页「待办」卡:一张白卡,一行一条,没有条目整块不画。
class HomeTodo extends StatelessWidget { const HomeTodo({super.key, required this.items}); final List<HomeTodoItem> items; }
```

```dart
String selfWeekTitle(String weekStart, String weekEnd) => '自测 · ${fmtDayRange(weekStart, weekEnd)}';
/// 「血压 5 次 118–132 / 74–80 · 心率 5 次 66–74 · 血糖 3 次 6.1–6.8」:收缩/舒张并成一项;min == max 只写一个数。
String selfWeekDesc(List<SelfWeekItemDto> items);
/// 展开行里一份自测的值:「血压 122/76 mmHg」「血糖 6.3 mmol/L」。
String selfValuesLine(List<SelfMeasuredValueDto> values);
```

- [ ] **Step 1: 纯函数测试先行**(`test/self_week_test.dart`)

```dart
  test('selfWeekDesc:血压并成一项,范围用 en dash,单次只写一个数', () {
    final items = [
      SelfWeekItemDto(analyteKey: 'bp_systolic', count: 5, min: 118, max: 132, unit: 'mmHg'),
      SelfWeekItemDto(analyteKey: 'bp_diastolic', count: 5, min: 74, max: 80, unit: 'mmHg'),
      SelfWeekItemDto(analyteKey: 'heart_rate', count: 5, min: 66, max: 74, unit: '/min'),
      SelfWeekItemDto(analyteKey: 'glucose', count: 1, min: 6.3, max: 6.3, unit: 'mmol/L'),
    ];
    expect(selfWeekDesc(items), '血压 5 次 118–132 / 74–80 · 心率 5 次 66–74 · 血糖 1 次 6.3');
  });
  test('selfWeekTitle', () => expect(selfWeekTitle('2026-04-27', '2026-05-03'), '自测 · 4 月 27 日 – 5 月 3 日'));
  test('selfValuesLine:血压合成 122/76', () {
    expect(selfValuesLine([
      SelfMeasuredValueDto(analyteKey: 'bp_systolic', value: 122, unit: 'mmHg'),
      SelfMeasuredValueDto(analyteKey: 'bp_diastolic', value: 76, unit: 'mmHg'),
    ]), '血压 122/76 mmHg');
  });
```

数字用 `fmtLabNumber`(去 `.0`)。

- [ ] **Step 2: `HomeTodo` 测试先行**(`test/home_todo_test.dart`)

- 空列表 → 整棵树里没有 `MedCard`;
- 三条 → 三行、两条 `Divider`、每行 `title`/`note` 文本在、点第二行触发它的 `onTap`;
- 2× 字号 360×640 不溢出;
- `expectSurfaceBudget()`(0/0)+ `expectNoGradientAnywhere()`。

- [ ] **Step 3: 实现 `HomeTodo`**

```dart
class HomeTodo extends StatelessWidget {
  const HomeTodo({super.key, required this.items});
  final List<HomeTodoItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final c = MedColors.of(context);
    return MedCard(
      child: Column(children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
          InkWell(
            onTap: items[i].onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(items[i].title, style: MedType.body.copyWith(
                      color: items[i].titleColor ?? c.ink, fontWeight: FontWeight.w500, fontVariations: MedType.w500)),
                  if (items[i].note case final n?) ...[
                    const SizedBox(height: 2),
                    Text(n, style: MedType.secondary.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                  ],
                ])),
                const SizedBox(width: MedShape.s1),
                Icon(Icons.chevron_right, size: 20, color: c.ink3),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
```

- [ ] **Step 4: 装配进首页**

`ArchiveScreen` 加 `final bool showTodo;`(默认 `true`;`doctor_home_screen.dart` 那处传 `false`)。`_load()` 在个人模式下并行多拉两样:`viewAbnormal30d()` 与 `vaultProfileDueReminders(dir: <DiseaseProfileSource 用的同一个 dir>)`(取法照 `disease_profile_screen.dart` 的 `DiseaseProfileSource`;若 `ArchiveScreen` 没有 source,就地 `DiseaseProfileSource()` 默认构造,与趋势页同款)。任一失败 → 该来源为空,不影响时间线(`catchError` 回退空,**不吞时间线的错误**)。

列表里 `HomeTiles` 之下、`ImportQueueCard` 之上插:

```dart
                if (widget.showTodo) ...[
                  const SizedBox(height: MedShape.s3),
                  HomeTodo(items: [
                    for (final r in reminders)
                      HomeTodoItem(
                        title: r.text,
                        // 超期 N 天 / 从没查过 沿用档案页的状态标签与 basis 标签(profile_sections.dart 已有的映射,提成公开函数复用,不抄第二份)
                        note: reminderNote(r),
                        titleColor: r.state == 'overdue' ? c.high : null,
                        onTap: () => _openProfile(r.packageId),
                      ),
                    if (abnormal30d > 0)
                      HomeTodoItem(
                        title: '最近 30 天有 $abnormal30d 项偏高或偏低',
                        note: '给医生看',
                        onTap: _openForDoctor,
                      ),
                  ]),
                ],
```

`PendingReviewBanner` 与 `ImportQueueCard` 位置不动(它们已经是待办的前两条)。`_openProfile` → `DiseaseProfileScreen(packageId:, source:)`(整页,不定位到某条——现有构造器没有这个参数,记为后续)。JSON → `DueReminder` 小模型(`fromJson`)放在 `lib/widgets/home_todo.dart`。

- [ ] **Step 5: 时间线 `SelfWeek` 渲染**

`archive_screen.dart`:Task 1 临时分支换成真实现:`_groupTitle` → `selfWeekTitle(weekStart, weekEnd)`;`_groupDate` → `weekStart`;`_groupDesc` → `selfWeekDesc(summary)`;`_TimelineItem`:`isExpandable = group is Encounter || group is SelfWeek`,展开时 `SelfWeek` → `SelfWeekRows(docs: docs, onOpen: onOpenSubDoc, onDelete: onDelete)`——每行 `fmtDate(doc.docDate)` + `selfValuesLine(values)`,可点进原件、左滑删(照 `_SubDocList` 的 `Dismissible`);`_allDocs`/`_confirmedOnly` 照 Task 1 的分支。`_SubDocList` 不动。

- [ ] **Step 6: 测试与闸**

`test/archive_header_test.dart` 加:`byMonth` 对 `SelfWeek` 按 `weekStart` 分月(跨月周归周一所在月);`test/archive_visual_test.dart` 的源码级断言(`MedIcon(` 只有一处)不变;`copy_unchanged_test`:登记「自测」「次」「最近」「天有」「项偏高或偏低」「给医生看」(archive_screen 已有则不登)等闸报告的新增段——**逐条对照本计划 Global Constraints 的清单**。

- [ ] **Step 7: 跑、提交**

`flutter analyze`;`flutter test test/home_todo_test.dart test/self_week_test.dart test/archive_header_test.dart test/archive_visual_test.dart test/copy_unchanged_test.dart test/glossary_guard_test.dart test/no_gradient_no_shadow_test.dart`。提交:`feat(ui): 首页待办卡(档案到期 + 30 天异常)与自测周行`。

---

### Task 5: 「添加」里加「记录一下」,趋势页去掉录入卡

**Files:**
- Modify: `lib/import_flow.dart`(`ImportChoice.record`;`AddSheetBody` 第四项;`showImportSheet` 分流;`pickImportItems` 穷尽)
- Modify: `lib/screens/trends_screen.dart`(删 `RecordEntryCard`、`_addRecord`、`onRequestAddNote` 参数与文档)
- Modify: `integration_test/harness.dart`(`openRecordSheet()` 改走 添加 → 记录一下)
- Test: `test/sheets_visual_test.dart`(或 `test/import_sheet_test.dart`)、`test/trends_screen_test.dart`

**Interfaces:**
- Produces: `enum ImportChoice { camera, gallery, files, record }`;`showImportSheet` 在 `record` 时 `await showManualEntrySheet(context)` 并返回 `null`(录入弹层存完会 `bumpVaultRevision()`,首页/趋势靠既有监听刷新)。
- 删除:`RecordEntryCard`、`TrendsScreen.onRequestAddNote`、`_TrendsScreenState._addRecord`。

- [ ] **Step 1: 测试先行**

- sheet 测试:`AddSheetBody` 有四项,第四项标题 `记录一下`、副标 `自己量的血压、体重,或者想记一句话`,点它 `pop(ImportChoice.record)`。
- `trends_screen_test.dart`:删 `'记录一下:点得动'`、`'2× 字号不溢出'`(RecordEntryCard 的)、`'「趋势」里存完一条记录,化验快照当场重新拉一次'`(入口没了;刷新由 `vaultRevision` 监听保证,已有 `_onVaultChanged` 测试则不重写);顺序测试去掉 `'记录一下'`。

- [ ] **Step 2: 实现**

`AddSheetBody` 第三项之后:

```dart
        _SheetTile(
          icon: Icons.edit_note_outlined,
          title: '记录一下',
          subtitle: '自己量的血压、体重,或者想记一句话',
          choice: ImportChoice.record,
        ),
```

`showImportSheet`:

```dart
  if (choice == null || !context.mounted) return null;
  if (choice == ImportChoice.record) {
    await showManualEntrySheet(context);
    return null;
  }
  return runImport(context, choice);
```

`pickImportItems` 的 `switch` 加 `ImportChoice.record => const []`(不可达,穷尽即可)。趋势页删掉 `RecordEntryCard` 与它的装配、`_addRecord`、`onRequestAddNote`;`main.dart` / 其他调用方若传了 `onRequestAddNote` 一并删。

- [ ] **Step 3: 集成测试入口**

`integration_test/harness.dart` 的 `openRecordSheet()`:切到病历 tab → 点「添加」→ 点「记录一下」。

- [ ] **Step 4: 闸与提交**

`copy_unchanged_test`:「记录一下」「自己量的血压」等段是**搬家**(trends_screen → import_flow),多重集不变,不该登记;若闸报告差异,说明搬得不完整。提交:`feat(ui): 「添加」里加「记录一下」直达录入弹层;趋势页去掉录入卡`。

---

### Task 6: 趋势重整 —— 筛选语义、只看异常开关、≥2 次规则、`TrendRow`、删重合块

**Files:**
- Modify: `lib/screens/trends_screen.dart`(大改)
- Test: `test/mobile_ia_test.dart`(筛选纯函数组)、`test/trends_screen_test.dart`、`test/trends_visual_test.dart`、`test/lab_row_visual_test.dart`(不动)、`test/motion_test.dart`(不动)

**Interfaces:**
- Consumes: Task 3 的 `MedChip(count: null)`、`TrendChart(compact:)`;Task 5 已删录入卡。
- Produces(纯函数,全部公开可测):

```dart
/// 先按大类,再按搜索(搜索时忽略「只看异常」),最后按「只看异常」。大类与开关**叠加**。
List<TrendSeriesDto> trendVisible(List<TrendSeriesDto> all, {required String query, required bool abnormalOnly, String? panel});
/// 测过 ≥ 2 次(有日期的点)的才是趋势;单次的另放。趋势组内:有异常的在前(稳定排序),再按名称。
({List<TrendSeriesDto> multi, List<TrendSeriesDto> single}) trendSplit(List<TrendSeriesDto> visible);
```

页面结构(自上而下):`DiseaseProfileCard` → `_SectionHeader('关键化验')` → `PanelChipsRow(chips, selectedPanel, onSelectPanel, abnormalOnly, onToggleAbnormal)`(末尾多一颗 `MedChip(label: '只看异常', count: null, selected: abnormalOnly)`)→ `MedCard(Column[TrendRow × multi,行间 Divider])`(`multi` 为空且 `all` 非空时显示现有「没有结果」那句;`all` 为空时 `_EmptyTrends`)→ `_SinglesFold(single)`(`single` 非空时:一行 `只测过一次的 N 项` + ▾,展开为 `LabLine` 列表)→ `ProvenanceFooter`。**删除**:`KeyLabsSnapshot`、`_AbnormalOnlyRow`、`RecentVisitsCard`/`_VisitCard`/`visitCardShowsDate`/`visitCardDesc`。`_abnormalOnly` 默认 `false`。

`TrendRow`(由 `SeriesCard` 改名重排):折叠态 = 名称 + 状态词(左)| `SizedBox(width: 78, height: 24, child: TrendChart(series, height: 24, compact: true, animate: false))` | 最近值 + 单位(`ConstrainedBox(maxWidth: trendValueMaxWidth)`)| ▾;展开态 = 原 `SeriesCard` 的展开区换成真图 `TrendChart(series: series)`(96 高,`expandedChartBg` 底)+ 原有的图例/换算/出处/「查看最新一次的原件」。行自己不再是 `MedCard`(整列表一张卡)。

- [ ] **Step 1: 纯函数测试先行**(`test/mobile_ia_test.dart` 现有两组改写)

- `'只看异常与大类叠加:选肾功能 + 开关开 = 肾功能里的异常项'`;
- `'搜索时忽略只看异常,但仍受大类约束'`;
- `'默认开关关:全部趋势项都列'`;
- `'trendSplit:有日期点 < 2 的进 single;multi 里有异常的在前,同组保序'`;
- 删掉「让位」两条测试。

- [ ] **Step 2: widget 测试先行**(`test/trends_screen_test.dart` / `test/trends_visual_test.dart`)

- 顺序:`病程档案` < `关键化验` < 第一条趋势名 < `只测过一次的`(有单次项时);没有 `最近就诊`、没有 `记录一下`;
- 点「肾功能」chip → 列表只剩肾功能项;再点「只看异常」→ 只剩异常;搜索「肌酐」→ 只剩肌酐且开关不影响;
- `single` 为空时 `只测过一次的` 不出现;非空时点它展开出 `LabLine`;
- 每条 `TrendRow` 折叠态含一个 `TrendChart`(`compact == true`、`animate == false`);点开后再出现一个 96 高的 `TrendChart`;
- `expectSurfaceBudget()` 0/0、`expectNoGradientAnywhere()`、360×640 @2× 不溢出;
- `Analytics.trendsFilterUsed` 在开关切换时仍发(沿用现有测试若有)。

- [ ] **Step 3: 实现**

```dart
List<TrendSeriesDto> trendVisible(List<TrendSeriesDto> all, {required String query, required bool abnormalOnly, String? panel}) {
  final byPanel = panel == null ? all : all.where((s) => trendPanelMatches(s, panel)).toList();
  if (query.isNotEmpty) return byPanel.where((s) => trendNameMatches(s.name, query)).toList();
  return abnormalOnly ? byPanel.where((s) => s.anyAbnormal).toList() : byPanel;
}

({List<TrendSeriesDto> multi, List<TrendSeriesDto> single}) trendSplit(List<TrendSeriesDto> visible) {
  final multi = <TrendSeriesDto>[], single = <TrendSeriesDto>[];
  for (final s in visible) {
    (trendDatedPoints(s).length >= 2 ? multi : single).add(s);
  }
  // 稳定:先异常后正常,各自保持原顺序(Rust 给的顺序已按名称)。
  final ab = multi.where((s) => s.anyAbnormal).toList();
  final ok = multi.where((s) => !s.anyAbnormal).toList();
  return (multi: [...ab, ...ok], single: single);
}
```

`_SinglesFold`(StatefulWidget,`_open = false`):

```dart
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, MedShape.s4, 4, 6),
          child: Row(children: [
            Expanded(child: Text('只测过一次的 ${widget.series.length} 项', style: MedType.secondary.copyWith(color: c.ink3))),
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: c.ink3),
          ]),
        ),
      ),
      if (_open)
        MedCard(child: Column(children: [
          for (var i = 0; i < widget.series.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
            // 单次:最近(唯一)那个点,按化验行画,无折线
            LabLine(name: s.name, value: p.value, unit: p.unit ?? s.unit, flag: p.flag, refLow: s.refLow, refHigh: s.refHigh,
                    meta: p.date, unverified: p.unverified, onTap: () => widget.onOpenDoc(p.documentId)),
          ],
        ])),
    ]);
```

(`p = trendDatedPoints(s).single`。)

`PanelChipsRow` 末尾:

```dart
          // 末尾一颗开关 chip:与大类叠加,不再互相让位。
          MedChip(label: '只看异常', count: null, selected: abnormalOnly, onTap: onToggleAbnormal),
```

(itemCount + 1,最后一项走这颗;分隔照旧。)

`TrendRow` 按 Interfaces 描述从 `SeriesCard` 改:去掉外层 `MedCard`,`SizedBox(width: 78, height: 24)` 换成 compact 图,`Container(height: 82, expandedChartBg)` 换成 `Container(color: MedBrand.expandedChartBg, padding: s2, child: TrendChart(series: widget.series))`。其它内容(图例、换算说明、出处、「查看最新一次的原件」)原样保留。

- [ ] **Step 4: 删除与闸**

删 `KeyLabsSnapshot`、`_AbnormalOnlyRow`、`RecentVisitsCard`、`_VisitCard`、`visitCardShowsDate`、`visitCardDesc` 及其测试;`copy_unchanged_test`:删掉的段(「最近就诊」「全部」「份」「还没有添加过病历。」「已添加的病历里还没有读到可显示的化验数值。拍一张化验单试试。」「只看非正常项」「另有」「条正常或判断不了」「搜索时不过滤」「正常项也一起找」「下不过滤」「这类检查查过的都在这」等,以闸报告为准)登记进 `kRemovedByDecision`;新增(「只看异常」「只测过一次的」)登记进 `kAddedByDecision`。评审逐条核对。`_SectionHeader` 保留。文件头与各处注释同步(不再有「关键化验卡」「最近就诊搬进趋势」的说法)。

- [ ] **Step 5: 跑、提交**

`flutter analyze`;`flutter test test/mobile_ia_test.dart test/trends_screen_test.dart test/trends_visual_test.dart test/motion_test.dart test/lab_row_visual_test.dart test/copy_unchanged_test.dart test/glossary_guard_test.dart test/no_gradient_no_shadow_test.dart`;然后全量。提交:`feat(ui): 趋势重整 —— 大类与只看异常叠加、≥2 次才算趋势、关键化验与折线合成带迷你折线的 TrendRow、删最近就诊`。

---

### Task 7: 收尾 —— 闸对账、注释清扫、全量、log

**Files:**
- Modify: `test/copy_unchanged_test.dart`(核对 `kAddedByDecision` / `kRemovedByDecision` 的总集合 = 本计划清单)
- Modify: 触到的文件里过时的注释
- Create: `docs/log/2026-09-23-home-todo-and-trends-rework.md`(仓库根,≤ 40 行)
- Modify: `docs/superpowers/specs/2026-09-23-home-todo-and-trends-rework-design.md`(状态 → 已实现;pending 不进首页那条收窄写进去)

- [ ] **Step 1: 闸对账**

把两个预算表打印出来,逐条对照 Global Constraints 的新字清单与 Task 5/6 的删除清单:多出的登记项一律删掉再跑闸(闸红 = 有本计划之外的文案改动,回去改代码,不改登记)。

- [ ] **Step 2: 注释清扫**

`grep -rn "关键化验卡\|最近就诊\|记录一下\|让位\|只看非正常\|SeriesCard\|KeyLabsSnapshot\|RecentVisitsCard\|RecordEntryCard" lib test integration_test` —— 每个剩余命中要么是准确的现状描述,要么删。

- [ ] **Step 3: 全量**

```bash
cd apps/mobile_flutter/rust && cargo test
cd apps/mobile_flutter && /Users/ziyuanguan/flutter/bin/flutter analyze && /Users/ziyuanguan/flutter/bin/flutter test
```

- [ ] **Step 4: log + 提交**

log 写:为什么(用户四句话)、每页答的问题、做了什么(一行一条)、Rust 新增的三样(SelfWeek / view_abnormal_30d / vault_profile_due_reminders)、闸怎么变(新增预算)、与 spec 的一处收窄(pending 不进首页)、没做的(笔记折叠、按条深链到档案提醒、上次给医生看的时间)。提交:`chore(ui): 首页待办与趋势重整收尾 —— 闸对账、注释、log`。

---

## 执行后(控制者)

- 模拟器截 病历 / 趋势 两屏(示例数据 + 一条自测周 + 开启 SLE 档案的待办)发用户;开 PR(基于 #229 合并后的 main,或 stacked 在 #229 上);合并后按 workflow:删本计划文件、删 `.superpowers/sdd/<plan>/`、spec 留。
- 待用户拍板后再开的:档案推开(接种等)spec;Journey 串联。

## 已知分歧(计划作者自查)

1. 首页待办**不含 pending 档提醒**(spec 表格写了三档,这里收窄成两档:pending = 规则没核实,不该催人)。写进 ledger 与 spec。
2. 「记一个数」不新造,沿用「记录一下」两句(零新增文案,用户已熟悉)。
3. 待办里的档案提醒点进去是整页档案,不定位到那一条(`DiseaseProfileScreen` 没有该参数;后续)。
4. `_abnormalOnly` 默认从 `true` 改 `false`:合并后的列表把异常排在前面已经给了信号,默认藏正常项反而让「只有一次」和「趋势」分不清;这是对 2026-08 那条「唯一替用户排序的默认」的推翻,记入 ledger。
5. 自测周行不上色、不给状态词(汇总不做判定);单次自测在趋势页「只测过一次」里按化验行画,颜色来自 flag。
