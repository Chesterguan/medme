//! DORIS 2021 / LLDAS 的边界。数值逐字取自 sle-clinical-sources §C.1 / §C.2。
use chrono::NaiveDate;

mod common;
use common::{full_pkg, lab_doc, mk_docs, ACTIVITY, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn sections(
    pkg: &profile::Package,
    docs: &[(&str, String)],
    events: Vec<parser::ProfileEvent>,
) -> Vec<profile::Section> {
    let src = mk_docs(docs);
    profile::materialize(&src, &events, pkg, day(TODAY)).sections
}

fn checklist_of(
    pkg: &profile::Package,
    docs: &[(&str, String)],
    events: Vec<parser::ProfileEvent>,
) -> serde_json::Value {
    sections(pkg, docs, events)
        .iter()
        .find(|s| s.kind == "checklist")
        .expect("有 checklist")
        .body
        .clone()
}

fn checklist(docs: &[(&str, String)], events: Vec<parser::ProfileEvent>) -> serde_json::Value {
    checklist_of(&full_pkg(), docs, events)
}

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }
}

fn pga(at: &str, value: f64) -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "pga".into(),
        package: "t".into(),
        at: at.into(),
        payload: serde_json::json!({ "value": value }),
    }
}

fn state<'a>(b: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    b["states"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == id)
        .unwrap()
}

fn item<'a>(s: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    s["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == id)
        .unwrap()
}

#[test]
fn pga_never_recorded_is_unknown_not_a_failure() {
    let b = checklist(&[], vec![enable()]);
    assert_eq!(item(state(&b, "doris"), "phga")["verdict"], "unknown");
    assert_eq!(
        state(&b, "doris")["verdict"],
        "unknown",
        "有未知项时整表就是未知"
    );
}

#[test]
fn doris_phga_boundary_is_strictly_below_zero_point_five() {
    // VERBATIM Box 1:「Physician Global Assessment <0.5」。
    let b = checklist(&[], vec![enable(), pga(TODAY, 0.4)]);
    assert_eq!(item(state(&b, "doris"), "phga")["verdict"], "yes");
    let b = checklist(&[], vec![enable(), pga(TODAY, 0.5)]);
    assert_eq!(item(state(&b, "doris"), "phga")["verdict"], "no");
    // 两份指南在这个点上不一致,必须在界面上说出来。
    assert!(item(state(&b, "doris"), "phga")["note"]
        .as_str()
        .unwrap()
        .contains("≤0.5"));
}

#[test]
fn lldas_pga_boundary_is_at_most_one() {
    let b = checklist(&[], vec![enable(), pga(TODAY, 1.0)]);
    assert_eq!(item(state(&b, "lldas"), "pga_le1")["verdict"], "yes");
    let b = checklist(&[], vec![enable(), pga(TODAY, 1.1)]);
    assert_eq!(item(state(&b, "lldas"), "pga_le1")["verdict"], "no");
}

#[test]
fn csledai_drops_the_two_serology_descriptors() {
    // DORIS 的 cSLEDAI「irrespective of serology」:去掉低补体(2)与 dsDNA(2)。
    // 只有低补体时,化验可算分 = 2,但 cSLEDAI = 0 → 这一条应当是 yes。
    let b = checklist(
        &[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))],
        vec![enable(), pga(TODAY, 0.2)],
    );
    assert_eq!(item(state(&b, "doris"), "csledai_zero")["verdict"], "yes");

    // 白细胞减少(1 分,非血清学)一出现,cSLEDAI 就不是 0。
    let b = checklist(
        &[(
            TODAY,
            lab_doc("补体C3 0.4 g/L 0.9-1.8\n白细胞 2.0 10^9/L 3.5-9.5"),
        )],
        vec![enable(), pga(TODAY, 0.2)],
    );
    assert_eq!(item(state(&b, "doris"), "csledai_zero")["verdict"], "no");
    assert_eq!(item(state(&b, "doris"), "csledai_zero")["actual"], 1);
}

#[test]
fn lldas_sledai_boundary_is_at_most_four() {
    // 化验可算部分 5 分(蛋白尿 4 + 白细胞减少 1)> 4。
    let b = checklist(
        &[(
            TODAY,
            lab_doc("24小时尿蛋白定量 0.8 g/24h\n白细胞 2.0 10^9/L 3.5-9.5"),
        )],
        vec![enable(), pga(TODAY, 0.5)],
    );
    assert_eq!(item(state(&b, "lldas"), "sledai_le4")["verdict"], "no");
    let b = checklist(
        &[(TODAY, lab_doc("24小时尿蛋白定量 0.8 g/24h"))],
        vec![enable(), pga(TODAY, 0.5)],
    );
    assert_eq!(item(state(&b, "lldas"), "sledai_le4")["verdict"], "yes");
}

#[test]
fn a_manual_item_is_unknown_until_someone_answers_it() {
    // LLDAS 的「无重要脏器活动」「与上次比无新活动」不是化验能答的。
    assert_eq!(
        item(
            state(&checklist(&[], vec![enable()]), "lldas"),
            "no_major_organ"
        )["verdict"],
        "unknown"
    );
}

#[test]
fn a_steroid_dose_item_is_unknown_until_the_drug_reading_lands() {
    // Task 13 才读用药记录 —— 在那之前每条 `pred_*` 都是未知,且说清为什么。
    // 绝不在引擎里补一张没核实的等效换算表(global-constraints)。
    let b = checklist(&[], vec![enable(), pga(TODAY, 0.2)]);
    let pred = item(state(&b, "doris"), "pred");
    assert_eq!(pred["verdict"], "unknown");
    assert_eq!(pred["actual"], serde_json::Value::Null);
    assert_eq!(pred["reason"], "还没读到用药记录");
    assert_eq!(item(state(&b, "lldas"), "pred_le75")["verdict"], "unknown");
}

#[test]
fn a_target_value_the_package_has_not_verified_yet_is_unknown_not_zero() {
    // global-constraints:没核实的数一律写 `null` + 待核。`null` 当成 0 去比,
    // 会把「还不知道」变成一个看起来很确定的 ✔/✘。
    let mut v: serde_json::Value = serde_json::from_str(ACTIVITY).unwrap();
    v["rules"]["states"] = serde_json::json!([{"id":"x","label":"待核的表","source":"S1",
      "items":[{"id":"todo","label":"SLEDAI-2K ≤ ?","kind":"sledai_le","value":null,
                "source":"S1","note":"待核"}]}]);
    v["views"]["sections"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({"kind":"checklist","title":"达标情况(逐条对照)"}));
    let pkg: profile::Package = serde_json::from_value(v).unwrap();

    let b = checklist_of(&pkg, &[], vec![enable()]);
    assert_eq!(item(state(&b, "x"), "todo")["verdict"], "unknown");
    assert_eq!(state(&b, "x")["verdict"], "unknown");
}

#[test]
fn every_section_title_comes_from_the_package() {
    // spec §6:section 的顺序、标题、空态文案全来自包 —— 引擎里不写死任何一句。
    let titles: Vec<(String, String)> = sections(&full_pkg(), &[], vec![enable()])
        .iter()
        .map(|s| (s.kind.clone(), s.title.clone()))
        .collect();
    assert!(titles.contains(&("checklist".into(), "达标情况(逐条对照)".into())));
    assert!(titles.contains(&("score_card".into(), "活动度(化验可算部分)".into())));
}

#[test]
fn the_checklist_never_says_remission_in_its_own_words() {
    let s = serde_json::to_string(&checklist(&[], vec![enable(), pga(TODAY, 0.2)])).unwrap();
    for banned in ["已缓解", "判断缓解", "达到缓解"] {
        assert!(!s.contains(banned), "{banned}");
    }
}
