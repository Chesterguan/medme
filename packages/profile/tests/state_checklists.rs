//! DORIS 2021 / LLDAS 的边界。数值逐字取自 sle-clinical-sources §C.1 / §C.2。
use chrono::NaiveDate;

mod common;
use common::{full_json, full_pkg, lab_doc, mk_docs, rx_doc, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn from_json(v: serde_json::Value) -> profile::Package {
    serde_json::from_value(v).expect("夹具包必须解析")
}

/// 把今天术语表还认不出的两条(尿红细胞 / 尿白细胞 —— `activity_rules.rs` 的
/// `a_report_the_engine_cannot_score_still_expands_…` 钉着这个缺口)从活动度规则里
/// 去掉。剩下 6 条都能被 [`answered`] 那份报告答掉,「算全了」这个前提才成立 ——
/// 只有在这种包上 ✔ 才是算全了得出来的。**真包里这两条还在**,所以今天真实的
/// cSLEDAI 一直是未知(见 `todays_terminology_gaps_keep_the_target_unknown`),
/// 要等 Task 17/18 的术语覆盖层补上尿沉渣才会变。
fn evaluable_pkg() -> profile::Package {
    let mut v = full_json();
    v["rules"]["activity"]["items"]
        .as_array_mut()
        .unwrap()
        .retain(|i| i["id"] != "hematuria" && i["id"] != "pyuria");
    from_json(v)
}

/// 一份把**其余每一条**描述符都答掉的报告:dsDNA 在区间内、24h 尿蛋白在阈下、尿沉渣
/// 写明未见红细胞管型、血常规正常 —— 全是「算过了、没达到」,不是「没读到」。
/// 补体那行由用例自己给(低补体命不命中,正是要验的那件事)。
fn answered(own_rows: &str) -> String {
    lab_doc(&format!(
        "{own_rows}\n抗双链DNA抗体 10 IU/mL 0-20\n24小时尿蛋白定量 0.3 g/24h\n\
         尿沉渣:未见红细胞管型\n白细胞 5.0 10^9/L 3.5-9.5\n血小板 200 10^9/L 125-350"
    ))
}

fn reason(it: &serde_json::Value) -> String {
    it["reason"]
        .as_str()
        .unwrap_or_else(|| panic!("未知的条目必须带一句理由:{it}"))
        .to_string()
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
    // 低补体命中 2 分,**其余非血清学描述符全部算过了、没达到** —— cSLEDAI = 0。
    // 这个 ✔ 立在证据上:不是「没读到所以是 0」,是「读到了、都不成立」。
    let b = checklist_of(
        &evaluable_pkg(),
        &[(TODAY, answered("补体C3 0.4 g/L 0.9-1.8"))],
        vec![enable(), pga(TODAY, 0.2)],
    );
    let it = item(state(&b, "doris"), "csledai_zero");
    assert_eq!(it["verdict"], "yes");
    assert_eq!(it["actual"], 0, "低补体那 2 分不进 cSLEDAI");

    // 白细胞减少(1 分,非血清学)一出现,cSLEDAI 就不是 0。
    let b = checklist_of(
        &evaluable_pkg(),
        &[(
            TODAY,
            answered("补体C3 0.4 g/L 0.9-1.8\n白细胞 2.0 10^9/L 3.5-9.5"),
        )],
        vec![enable(), pga(TODAY, 0.2)],
    );
    let it = item(state(&b, "doris"), "csledai_zero");
    assert_eq!(it["verdict"], "no");
    assert_eq!(it["actual"], 1);
}

#[test]
fn lldas_sledai_boundary_is_at_most_four() {
    // 化验可算部分恰好 4 分(蛋白尿 0.8 g/24h > 0.5),其余描述符都算过了没达到。
    let b = checklist_of(
        &evaluable_pkg(),
        &[(
            TODAY,
            answered("补体C3 1.20 g/L 0.9-1.8\n24小时尿蛋白定量 0.8 g/24h"),
        )],
        vec![enable(), pga(TODAY, 0.5)],
    );
    let it = item(state(&b, "lldas"), "sledai_le4");
    assert_eq!(it["verdict"], "yes", "恰好 4 分算达标");
    assert_eq!(it["actual"], 4);

    // 再加一条白细胞减少 → 5 分。超了就是超了,不必等其它项算全 —— 权重非负,
    // 没读到的那几项只会让分更高。
    let b = checklist_of(
        &evaluable_pkg(),
        &[(
            TODAY,
            answered(
                "补体C3 1.20 g/L 0.9-1.8\n24小时尿蛋白定量 0.8 g/24h\n白细胞 2.0 10^9/L 3.5-9.5",
            ),
        )],
        vec![enable(), pga(TODAY, 0.5)],
    );
    let it = item(state(&b, "lldas"), "sledai_le4");
    assert_eq!(it["verdict"], "no");
    assert_eq!(it["actual"], 5);
}

#[test]
fn an_empty_vault_is_unknown_not_a_clean_zero() {
    // 一份文档都没有时 8 条描述符全在 `unscored`:按分数直接判就成了「临床 SLEDAI
    // = 0 ✔」,而旁边的活动度卡片正说着「最近 10 天还没有化验结果」。这是「未知不
    // 许塌成 ✘」的镜像错法,方向反过来更危险。
    let b = checklist(&[], vec![enable(), pga(TODAY, 0.2)]);
    let csledai = item(state(&b, "doris"), "csledai_zero");
    assert_eq!(csledai["verdict"], "unknown");
    assert_eq!(csledai["actual"], serde_json::Value::Null);
    assert!(
        reason(csledai).contains("算不全"),
        "理由要说清是没算全:{}",
        reason(csledai)
    );
    assert_eq!(item(state(&b, "lldas"), "sledai_le4")["verdict"], "unknown");
}

#[test]
fn todays_terminology_gaps_keep_the_target_unknown() {
    // 真包里血尿/脓尿两条还在,而术语表今天认不出「尿红细胞/尿白细胞」
    // (`activity_rules.rs` 钉着这个缺口)。所以哪怕交了一份很完整的报告,
    // cSLEDAI 今天也只能是未知 —— 这是诚实的状态,不许糊过去。
    let b = checklist(
        &[(TODAY, answered("补体C3 1.20 g/L 0.9-1.8"))],
        vec![enable(), pga(TODAY, 0.2)],
    );
    let it = item(state(&b, "doris"), "csledai_zero");
    assert_eq!(it["verdict"], "unknown");
    assert!(
        reason(it).contains("血尿") || reason(it).contains("脓尿"),
        "理由要点名是哪一项没读到:{}",
        reason(it)
    );
}

#[test]
fn an_exclude_id_the_activity_rules_do_not_have_makes_the_item_unknown() {
    // `exclude` 拼错一个字母,减项就静悄悄失效、cSLEDAI 偏高,界面上是一条看起来
    // 很正常的 ✘。宁可整条未知。
    let mut v = full_json();
    v["rules"]["states"][0]["items"][0]["exclude"] =
        serde_json::json!(["low_complement", "dsdna_hi"]);
    let b = checklist_of(&from_json(v), &[], vec![enable()]);
    let it = item(state(&b, "doris"), "csledai_zero");
    assert_eq!(it["verdict"], "unknown");
    assert!(reason(it).contains("dsdna_hi"), "理由要点名:{}", reason(it));
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
fn a_prednisone_prescription_answers_both_steroid_items() {
    // DORIS 的 <5 与 LLDAS 的 ≤7.5 是两个不同的边界(§C.1 / §C.2 原文),5 mg/天
    // 恰好卡在中间:一条 ✘、一条 ✔。同一个数在两张表上给出不同结论,正是「两份
    // 指南不一样」这件事在界面上该有的样子。
    let b = checklist(
        &[(TODAY, rx_doc("泼尼松片 5mg 每日一次 口服"))],
        vec![enable()],
    );
    let lt = item(state(&b, "doris"), "pred");
    assert_eq!(lt["verdict"], "no", "DORIS Box 1 是严格 <5,恰好 5 不算");
    assert_eq!(lt["actual"], 5.0);
    let le = item(state(&b, "lldas"), "pred_le75");
    assert_eq!(le["verdict"], "yes");
    assert_eq!(le["actual"], 5.0);
}

#[test]
fn an_unconvertible_steroid_leaves_the_dose_items_unknown_not_met() {
    // 换算表待核期间,甲泼尼龙算不出泼尼松等效剂量。**未知不许塌成 ✔** ——
    // 「没算出来」显示成「< 5 mg,达标」是这个功能最坏的一种错法。
    let b = checklist(
        &[(TODAY, rx_doc("甲泼尼龙片 8mg 每日一次 口服"))],
        vec![enable()],
    );
    assert_eq!(item(state(&b, "doris"), "pred")["verdict"], "unknown");
    assert_eq!(item(state(&b, "lldas"), "pred_le75")["verdict"], "unknown");
}

#[test]
fn a_target_value_the_package_has_not_verified_yet_is_unknown_not_zero() {
    // global-constraints:没核实的数一律写 `null` + 待核。`null` 当成 0 去比,
    // 会把「还不知道」变成一个看起来很确定的 ✔/✘。
    let mut v = full_json();
    v["rules"]["states"] = serde_json::json!([{"id":"x","label":"待核的表","source":"S1",
      "items":[{"id":"todo","label":"SLEDAI-2K ≤ ?","kind":"sledai_le","value":null,
                "source":"S1","note":"待核"}]}]);

    let b = checklist_of(&from_json(v), &[], vec![enable()]);
    assert_eq!(item(state(&b, "x"), "todo")["verdict"], "unknown");
    assert_eq!(state(&b, "x")["verdict"], "unknown");
}

#[test]
fn the_pga_item_carries_the_day_that_score_was_recorded() {
    // 引擎不设时效(多久算过期由包/渲染层说),但日期必须带出去 —— body 里只有一个
    // 分值的话,三年前录的 PGA 和今天刚录的在界面上长得一模一样。
    let b = checklist(&[], vec![enable(), pga("2023-04-01", 2.0), pga(TODAY, 0.2)]);
    let phga = item(state(&b, "doris"), "phga");
    assert_eq!(phga["actual"], 0.2, "取最近一条");
    assert_eq!(phga["actual_at"], TODAY);

    let b = checklist(&[], vec![enable(), pga("2023-04-01", 0.2)]);
    let phga = item(state(&b, "doris"), "phga");
    assert_eq!(phga["verdict"], "yes", "引擎这边不因为旧就不算");
    assert_eq!(phga["actual_at"], "2023-04-01");
}

#[test]
fn a_pga_outside_the_zero_to_three_scale_is_unknown() {
    // §C.2 专门强调量表是 SELENA-SLEDAI PGA 的 0–3,不是任何 0–10 VAS。按 0–10 录
    // 进来的 2 分拿去和 0.5 比会安静地判成 ✘ —— 那是拿另一把尺量出来的结论。
    let b = checklist(&[], vec![enable(), pga(TODAY, 5.0)]);
    let phga = item(state(&b, "doris"), "phga");
    assert_eq!(phga["verdict"], "unknown");
    assert_eq!(reason(phga), "PGA 超出 0–3 范围");
    // 0 和 3 本身在量表里,照常算。
    let b = checklist(&[], vec![enable(), pga(TODAY, 3.0)]);
    assert_eq!(item(state(&b, "lldas"), "pga_le1")["verdict"], "no");
}

#[test]
fn every_section_title_comes_from_the_package() {
    // spec §6:section 的顺序、标题、空态文案全来自包 —— 引擎里不写死任何一句。
    let titles: Vec<(String, Option<String>)> = sections(&full_pkg(), &[], vec![enable()])
        .iter()
        .map(|s| (s.kind.clone(), s.title.clone()))
        .collect();
    assert!(titles.contains(&("checklist".into(), Some("达标情况(逐条对照)".into()))));
    assert!(titles.contains(&("score_card".into(), Some("活动度(化验可算部分)".into()))));

    // 包里没写标题就是 `null`,不是空字符串 —— 渲染层要分得出「包漏了」。
    let mut v = full_json();
    v["views"]["sections"] = serde_json::json!([]);
    let s = sections(&from_json(v), &[], vec![enable()]);
    assert!(s.iter().all(|s| s.title.is_none()), "包没给标题就别编一个");
}

#[test]
fn the_checklist_never_says_remission_in_its_own_words() {
    let s = serde_json::to_string(&checklist(&[], vec![enable(), pga(TODAY, 0.2)])).unwrap();
    for banned in ["已缓解", "判断缓解", "达到缓解"] {
        assert!(!s.contains(banned), "{banned}");
    }
}
