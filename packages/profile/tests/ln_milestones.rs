//! 狼疮肾炎治疗里程碑的阈值边界(spec §5.5)。数值逐字取自
//! `.superpowers/sdd/disease-profile/sle-clinical-sources.md` §E.1/§E.2 里标
//! **VERBATIM** 的那几行(EULAR 2025 肾脏更新 = S8):
//!
//! - 「reduction in proteinuria of at least **25% by 3 months**, **50% by 6 months**」
//! - 「a **UPCR target <700 mg/g by 12 months**」
//! - 「**Complete renal response should be defined as UPCR <500 mg/g at any time point.**」
//! - 「stabilisation (if not improvement) of **GFR to ≥80% of baseline value**」
//! - 活检指征(§E.1 rec 1):「persistent proteinuria (**≥0.5 g/24 h or UPCR ≥500 mg/g**)」
//!
//! 每条一个「恰好在阈上」+ 一个「恰好在阈下」:`≥`/`≤` 是非严格,`<` 是严格,
//! 恰好等于那个数时两边的答案不一样,而这正是最容易写反的一处。
mod common;
use common::{full_pkg, lab_doc, rx_doc};

/// 起算日(T0):最早一次免疫抑制剂处方。语料里没有 schema 2 的 facts 时,这是
/// 唯一能拿到 T0 的路 —— 下面每个用例都以这张处方笺开头。
const T0: &str = "2024-03-15";

/// 一组 `(日期, 文本)` → 里程碑那块的 `items`。`today` 定在 2026-09-16,与 golden 同一天。
fn items(docs: &[(&str, String)]) -> Vec<serde_json::Value> {
    let pkg = full_pkg();
    let docs = common::mk_docs(docs);
    let ev = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2024-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let view = profile::materialize(&docs, &ev, &pkg, common::TODAY.parse().expect("今天"));
    view.sections
        .into_iter()
        // 两块都是 `checklist`(达标表与里程碑),**按 `Section::id` 认** —— id 原样
        // 来自包 `views.sections[].id`。不许靠「body 里有哪个键」去猜:那是隐式契约,
        // 另一块哪天在 body 里多一个同名键就会静默认错(`view::Section::id` 的文档)。
        .find(|s| s.id.as_deref() == Some("ln_milestones"))
        .expect("有尿蛋白结果就该出里程碑这块")
        .body["items"]
        .as_array()
        .expect("items 是数组")
        .clone()
}

fn row<'a>(items: &'a [serde_json::Value], id: &str) -> &'a serde_json::Value {
    items
        .iter()
        .find(|i| i["id"] == id)
        .unwrap_or_else(|| panic!("里程碑里没有 {id}"))
}

fn verdict(items: &[serde_json::Value], id: &str) -> String {
    row(items, id)["verdict"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

/// 处方笺(T0)+ 基线那张单子 + 复查那张单子。
fn course<'a>(
    baseline_at: &'a str,
    baseline: &str,
    follow_at: &'a str,
    follow: &str,
) -> Vec<(&'a str, String)> {
    vec![
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (baseline_at, lab_doc(baseline)),
        (follow_at, lab_doc(follow)),
    ]
}

// ---------------------------------------------------------------------------
// §E.2:3 个月降 ≥25%,6 个月降 ≥50%
// ---------------------------------------------------------------------------

#[test]
fn a_proteinuria_drop_exactly_on_the_threshold_counts() {
    // 基线 4.00 g/24h → 3.00 g/24h 恰好降 25.0%;「at least 25%」是非严格,算达到。
    let it = items(&course(
        "2024-03-10",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2024-06-10",
        "Upro       尿蛋白定量      3.00   g/24h   0.00 - 0.15   ↑",
    ));
    assert_eq!(verdict(&it, "upr_drop_25_3m"), "yes");
    assert_eq!(row(&it, "upr_drop_25_3m")["actual"], 25.0);
    assert_eq!(row(&it, "upr_drop_25_3m")["actual_at"], "2024-06-10");
    // 25% 没到 50%:6 个月那条在同一份输入上是 ✘,不是未知。
    assert_eq!(verdict(&it, "upr_drop_50_6m"), "no");
}

#[test]
fn a_proteinuria_drop_just_under_the_threshold_is_a_no() {
    // 4.00 → 3.04 = 降 24.0%,差一点点也是 ✘。
    let it = items(&course(
        "2024-03-10",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2024-06-10",
        "Upro       尿蛋白定量      3.04   g/24h   0.00 - 0.15   ↑",
    ));
    assert_eq!(verdict(&it, "upr_drop_25_3m"), "no");
    assert_eq!(row(&it, "upr_drop_25_3m")["actual"], 24.0);
}

#[test]
fn the_six_month_drop_counts_at_exactly_fifty_percent() {
    let it = items(&course(
        "2024-03-10",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2024-09-10",
        "Upro       尿蛋白定量      2.00   g/24h   0.00 - 0.15   ↑",
    ));
    assert_eq!(verdict(&it, "upr_drop_50_6m"), "yes");
    assert_eq!(row(&it, "upr_drop_50_6m")["actual"], 50.0);
}

#[test]
fn a_point_past_the_deadline_does_not_count_for_that_milestone() {
    // T0+90 = 2024-06-13。6-14 那次达标了,但它在 3 个月这条的窗口**之外** ——
    // 「by 3 months」是原文的硬要求,晚一天就不是这条里程碑答的问题。
    let it = items(&course(
        "2024-03-10",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2024-06-14",
        "Upro       尿蛋白定量      1.00   g/24h   0.00 - 0.15   ↑",
    ));
    assert_eq!(verdict(&it, "upr_drop_25_3m"), "unknown");
    assert!(
        row(&it, "upr_drop_25_3m")["reason"].is_string(),
        "未知必须带理由"
    );
    // 同一个点落在 6 个月那条的窗口里,照样算得出来。
    assert_eq!(verdict(&it, "upr_drop_50_6m"), "yes");
}

#[test]
fn without_a_baseline_the_drop_milestones_are_unknown_not_no() {
    // 基线窗口是 T0 ± 30 天;2024-01-20 在窗口外 —— 没有基线就没有「降了多少」
    // 这回事,答「没达到」是替医生下了一个他没下的结论。
    let it = items(&course(
        "2024-01-20",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2024-06-10",
        "Upro       尿蛋白定量      1.00   g/24h   0.00 - 0.15   ↑",
    ));
    assert_eq!(verdict(&it, "upr_drop_25_3m"), "unknown");
}

// ---------------------------------------------------------------------------
// §E.2:12 个月 UPCR <700 mg/g;完全肾应答 = 任一时点 UPCR <500 mg/g
// ---------------------------------------------------------------------------

#[test]
fn upcr_exactly_at_the_twelve_month_target_is_not_below_it() {
    // 原文是 `<700 mg/g`,严格小于:恰好 700 不算达到。
    let it = items(&course(
        "2024-03-10",
        "UPCR       尿蛋白/肌酐比    2800   mg/g    0 - 150   ↑",
        "2025-03-10",
        "UPCR       尿蛋白/肌酐比     700   mg/g    0 - 150   ↑",
    ));
    assert_eq!(verdict(&it, "upcr_below_700_12m"), "no");
    assert_eq!(row(&it, "upcr_below_700_12m")["actual"], 700.0);
}

#[test]
fn upcr_one_unit_below_the_twelve_month_target_counts() {
    let it = items(&course(
        "2024-03-10",
        "UPCR       尿蛋白/肌酐比    2800   mg/g    0 - 150   ↑",
        "2025-03-10",
        "UPCR       尿蛋白/肌酐比     699   mg/g    0 - 150   ↑",
    ));
    assert_eq!(verdict(&it, "upcr_below_700_12m"), "yes");
    assert_eq!(row(&it, "upcr_below_700_12m")["actual"], 699.0);
}

#[test]
fn complete_renal_response_is_strictly_below_five_hundred_at_any_time() {
    // 恰好 500 不算(原文 `<500 mg/g`)。
    let it = items(&course(
        "2024-03-10",
        "UPCR       尿蛋白/肌酐比    2800   mg/g    0 - 150   ↑",
        "2025-03-10",
        "UPCR       尿蛋白/肌酐比     500   mg/g    0 - 150   ↑",
    ));
    assert_eq!(verdict(&it, "upcr_below_500_any"), "no");

    // 499 算,而且 `actual_at` 指的是**第一次**达到的那天(「任一时点」)。
    let it = items(&course(
        "2024-03-10",
        "UPCR       尿蛋白/肌酐比    2800   mg/g    0 - 150   ↑",
        "2025-03-10",
        "UPCR       尿蛋白/肌酐比     499   mg/g    0 - 150   ↑",
    ));
    assert_eq!(verdict(&it, "upcr_below_500_any"), "yes");
    assert_eq!(row(&it, "upcr_below_500_any")["actual_at"], "2025-03-10");
}

#[test]
fn the_upcr_milestones_never_read_the_24h_protein_series() {
    // UPCR 与 24h 尿蛋白是两个量(spec §11 的已知边界),永远不合并:只有 24h
    // 尿蛋白时,UPCR 那两条只能是未知 —— 拿 0.35 g/24h 去和 700 mg/g 比是一句
    // 编出来的话。
    let it = items(&course(
        "2024-03-10",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2025-03-10",
        "Upro       尿蛋白定量      0.30   g/24h   0.00 - 0.15   ↑",
    ));
    assert_eq!(verdict(&it, "upcr_below_700_12m"), "unknown");
    assert_eq!(verdict(&it, "upcr_below_500_any"), "unknown");
}

#[test]
fn a_pre_treatment_result_below_the_target_is_not_a_response() {
    // 「任一时点」只数**起算日之后**的结果:2024-03-10 那次(T0 = 03-15 之前)就已经
    // <500,那说明的是起病时蛋白尿本来就不高,不是治疗达到了完全肾应答。
    let it = items(&course(
        "2024-03-10",
        "UPCR       尿蛋白/肌酐比     420   mg/g    0 - 150   ↑",
        "2025-03-10",
        "UPCR       尿蛋白/肌酐比     900   mg/g    0 - 150   ↑",
    ));
    assert_eq!(verdict(&it, "upcr_below_500_any"), "no");
    // 答的是起算后最低的那次(900),不是治疗前那个 420。
    assert_eq!(row(&it, "upcr_below_500_any")["actual"], 900.0);
    assert_eq!(row(&it, "upcr_below_500_any")["actual_at"], "2025-03-10");
}

// ---------------------------------------------------------------------------
// 单位:同一条序列里混了印刷单位时,**不许相除**
// ---------------------------------------------------------------------------

/// 24h 尿蛋白印成 `g/d`:词典不认这个单位(它只有 `mg/24h` 与 `g/24h`),于是这条
/// 序列落进 `parser::aggregate::finalize_lab_series` 的分支③ —— 混了印刷单位、又不是
/// 每个点都换算得出规范值,**每个点各自带自己的印刷单位**。
#[test]
fn a_mixed_unit_series_is_never_divided() {
    let it = items(&course(
        "2024-03-10",
        "Upro       尿蛋白定量      4.00   g/24h   0.00 - 0.15   ↑",
        "2024-06-10",
        "Upro       尿蛋白定量      0.45   g/d     0.00 - 0.15   ↑",
    ));
    // 硬除出来是「降了 88.75%」—— 一个凭空出现的 ✔。必须是未知。
    assert_eq!(verdict(&it, "upr_drop_25_3m"), "unknown");
    assert_eq!(row(&it, "upr_drop_25_3m")["reason"], "单位不一致,算不了");
    assert!(row(&it, "upr_drop_25_3m")["actual"].is_null());
}

#[test]
fn a_mixed_unit_gfr_series_is_never_divided() {
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2024-03-10",
            lab_doc("UPCR       尿蛋白/肌酐比    800   mg/g    0 - 150   ↑\neGFR       估算肾小球滤过率   100   mL/min/1.73m2   > 90"),
        ),
        (
            "2024-06-10",
            // `ml/min` 词典不认(大小写与 /1.73m2 都不一样),换算不出规范值。
            lab_doc("UPCR       尿蛋白/肌酐比    700   mg/g    0 - 150   ↑\neGFR       估算肾小球滤过率    80   ml/min   > 90"),
        ),
    ]);
    assert_eq!(verdict(&it, "gfr_80_baseline"), "unknown");
    assert_eq!(row(&it, "gfr_80_baseline")["reason"], "单位不一致,算不了");
}

// ---------------------------------------------------------------------------
// §E.2:GFR ≥ 基线 80%
// ---------------------------------------------------------------------------

/// eGFR 那两条用例的单子:GFR 单独一项不会让这块长出来(见本文件最后一条用例),
/// 所以按真实肾功能单子的样子,连尿蛋白一起印。
fn renal_panel(gfr: &str) -> String {
    lab_doc(&format!(
        "UPCR       尿蛋白/肌酐比    800   mg/g    0 - 150   ↑\neGFR       估算肾小球滤过率   {gfr}   mL/min/1.73m2   > 90"
    ))
}

#[test]
fn gfr_exactly_at_eighty_percent_of_baseline_counts() {
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        ("2024-03-10", renal_panel("100")),
        ("2024-06-10", renal_panel("80")),
    ]);
    assert_eq!(verdict(&it, "gfr_80_baseline"), "yes");
    assert_eq!(row(&it, "gfr_80_baseline")["actual"], 80.0);
}

#[test]
fn gfr_just_under_eighty_percent_of_baseline_is_a_no() {
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        ("2024-03-10", renal_panel("100")),
        ("2024-06-10", renal_panel("79")),
    ]);
    assert_eq!(verdict(&it, "gfr_80_baseline"), "no");
    assert_eq!(row(&it, "gfr_80_baseline")["actual"], 79.0);
}

#[test]
fn a_single_gfr_result_is_its_own_baseline_and_answers_nothing() {
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2024-03-10",
            lab_doc("UPCR       尿蛋白/肌酐比    2800   mg/g    0 - 150   ↑\neGFR       估算肾小球滤过率   100   mL/min/1.73m2   > 90"),
        ),
    ]);
    assert_eq!(verdict(&it, "gfr_80_baseline"), "unknown");
}

// ---------------------------------------------------------------------------
// §E.1:活检指征 ≥0.5 g/24h 或 UPCR ≥500 mg/g
// ---------------------------------------------------------------------------

#[test]
fn the_biopsy_threshold_is_met_exactly_at_half_a_gram() {
    // 原文 `≥0.5 g/24 h`,非严格:恰好 0.50 就满足。
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2026-09-10",
            lab_doc("Upro       尿蛋白定量      0.50   g/24h   0.00 - 0.15   ↑"),
        ),
    ]);
    assert_eq!(verdict(&it, "biopsy_indication"), "yes");
    assert!(
        !row(&it, "biopsy_indication")["evidence"]
            .as_array()
            .expect("证据是数组")
            .is_empty(),
        "判「满足」必须拿得出那一行"
    );
}

#[test]
fn just_under_half_a_gram_does_not_meet_the_biopsy_threshold() {
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2026-09-10",
            lab_doc("Upro       尿蛋白定量      0.49   g/24h   0.00 - 0.15   ↑"),
        ),
    ]);
    assert_eq!(verdict(&it, "biopsy_indication"), "no");
}

#[test]
fn the_biopsy_threshold_is_met_exactly_at_five_hundred_mg_per_g() {
    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2026-09-10",
            lab_doc("UPCR       尿蛋白/肌酐比     500   mg/g    0 - 150   ↑"),
        ),
    ]);
    assert_eq!(verdict(&it, "biopsy_indication"), "yes");

    let it = items(&[
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2026-09-10",
            lab_doc("UPCR       尿蛋白/肌酐比     499   mg/g    0 - 150   ↑"),
        ),
    ]);
    assert_eq!(verdict(&it, "biopsy_indication"), "no");
}

#[test]
fn a_milestone_still_using_the_old_field_name_fails_loudly() {
    // 阈值单位那个字段叫 `threshold_unit`(阈值**自己**写的单位),旧名 `canonical_unit`
    // **不做 serde 兼容**:拿旧名写的包在这里读不到单位,整条落「未知 + 理由」,而不是
    // 被默默当成另一个意思。
    let mut raw = common::full_json();
    for item in raw["rules"]["milestones"]
        .as_array_mut()
        .expect("milestones 是数组")
    {
        if let Some(u) = item
            .as_object_mut()
            .and_then(|o| o.remove("threshold_unit"))
        {
            item["canonical_unit"] = u;
        }
    }
    let pkg: profile::Package = serde_json::from_value(raw).expect("夹具包必须解析");
    let docs = [
        (T0, rx_doc("吗替麦考酚酯胶囊 0.75g bid")),
        (
            "2026-03-14",
            lab_doc("UPCR       尿蛋白/肌酐比     420   mg/g    0 - 150   ↑"),
        ),
    ];
    let docs = common::mk_docs(&docs);
    let ev = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2024-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let body = profile::materialize(&docs, &ev, &pkg, common::TODAY.parse().expect("今天"))
        .sections
        .into_iter()
        .find(|s| s.id.as_deref() == Some("ln_milestones"))
        .expect("有尿蛋白结果就该出里程碑这块")
        .body;
    let it = body["items"].as_array().expect("items 是数组").clone();
    // 420 < 500:旧名要是还认,这一条会答成「完全肾应答 ✔」。
    assert_eq!(verdict(&it, "upcr_below_500_any"), "unknown");
    assert_eq!(
        row(&it, "upcr_below_500_any")["reason"],
        "这一条没写阈值的单位(threshold_unit),比不了"
    );
}

// ---------------------------------------------------------------------------
// 出处与年份(spec §5.5:四个阈值都带出处与年份)
// ---------------------------------------------------------------------------

#[test]
fn every_milestone_carries_a_source_id_and_a_guideline_year() {
    let it = items(&course(
        "2024-03-10",
        "UPCR       尿蛋白/肌酐比    2800   mg/g    0 - 150   ↑",
        "2025-03-10",
        "UPCR       尿蛋白/肌酐比     699   mg/g    0 - 150   ↑",
    ));
    assert!(it.len() >= 4, "四种 kind 至少四条,实际 {}", it.len());
    let declared = common::SOURCES.map(|(id, _)| id.to_string());
    for row in &it {
        let id = row["id"].as_str().unwrap_or_default();
        let source = row["source"].as_str().unwrap_or_default();
        assert!(
            declared.contains(&source.to_string()),
            "{id} 的出处 {source:?} 没在 manifest.sources 里声明"
        );
        assert!(
            row["year"].as_u64().is_some(),
            "{id} 没带指南年份 —— 四个阈值在不同年份的指南里数不一样(§E.2)"
        );
    }
}

#[test]
fn the_section_stays_away_when_there_is_no_kidney_data_at_all() {
    // spec §5.5:仅当肾受累或出现 UPCR/24h 尿蛋白。只有补体的一张单子不该长出
    // 一整块全是「未知」的里程碑。
    let pkg = full_pkg();
    let only_complement = [(
        "2026-09-10",
        lab_doc("C3   补体C3   0.42   g/L   0.90 - 1.80   ↓"),
    )];
    let docs = common::mk_docs(&only_complement);
    let ev = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2024-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let view = profile::materialize(&docs, &ev, &pkg, common::TODAY.parse().expect("今天"));
    assert!(
        !view
            .sections
            .iter()
            .any(|s| s.kind == "checklist" && s.body.get("items").is_some()),
        "没有肾脏数据就不出这块"
    );
}
