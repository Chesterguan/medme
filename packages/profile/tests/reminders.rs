//! 复查提醒(`reminders`):**只有三种来源**,没有第四种。
//! 间隔与阈值全部来自 `.superpowers/sdd/disease-profile/sle-clinical-sources.md`
//! §A.1 / §D.1 / §D.3 的 VERBATIM 行;核不实的那几条在包里标 `verify_status`
//! 不是 `"verified"`,只显示、永远不算到期(§D.1 的骨密度、§D.2.1 的眼科间隔)。
use chrono::NaiveDate;

mod common;
use common::{full_json, full_pkg, lab_doc, mk_docs, rx_doc, TODAY};
use profile::Package;

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }
}

fn dismiss(at: &str, id: &str) -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "dismiss_reminder".into(),
        package: "t".into(),
        at: at.into(),
        payload: serde_json::json!({ "id": id }),
    }
}

fn reminders_of(
    pkg: &Package,
    docs: &[parser::SourceDoc<'_>],
    events: Vec<parser::ProfileEvent>,
) -> Vec<serde_json::Value> {
    profile::materialize(docs, &events, pkg, day(TODAY))
        .sections
        .iter()
        .find(|s| s.kind == "reminders")
        .map(|s| s.body["items"].as_array().cloned().expect("items 是数组"))
        .unwrap_or_default()
}

fn reminders(docs: &[(&str, String)], events: Vec<parser::ProfileEvent>) -> Vec<serde_json::Value> {
    reminders_of(&full_pkg(), &mk_docs(docs), events)
}

fn ids(items: &[serde_json::Value]) -> Vec<String> {
    items
        .iter()
        .map(|i| i["id"].as_str().unwrap().to_string())
        .collect()
}

fn find<'i>(items: &'i [serde_json::Value], id: &str) -> &'i serde_json::Value {
    items.iter().find(|i| i["id"] == id).expect("该有这一条")
}

/// [`full_pkg`],但活动度只留「管型」一条。8 条全留时只要有一条读不出来,病级节律
/// 就落进「没算全 → 按活动期提醒」那一档,active / stable 两条分支永远测不到。
fn casts_only_pkg() -> Package {
    let mut v = full_json();
    let kept: Vec<serde_json::Value> = v["rules"]["activity"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["id"] == "casts")
        .cloned()
        .collect();
    v["rules"]["activity"]["items"] = serde_json::json!(kept);
    serde_json::from_value(v).expect("夹具包必须解析")
}

#[test]
fn a_cbc_that_is_due_but_not_yet_overdue_does_not_nag() {
    // MMF 第 4 个月起每月一次血常规(说明书 VERBATIM)。1.2 倍宽限 = 36 天。
    let start = "2025-01-01";
    let items = reminders(
        &[
            (start, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-08-20", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ], // 27 天前
        vec![enable()],
    );
    assert!(!ids(&items).contains(&"mmf_cbc".to_string()));
}

#[test]
fn the_same_cbc_past_one_point_two_intervals_is_overdue() {
    let items = reminders(
        &[
            ("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ], // 39 天前 > 36
        vec![enable()],
    );
    let r = find(&items, "mmf_cbc");
    assert_eq!(r["state"], "overdue");
    assert_eq!(r["basis"], "label");
    // 「该查的那天」是最近一次 + 间隔,不是 + 宽限:宽限只用来决定要不要开口。
    assert_eq!(r["due_at"], "2026-09-07");
    assert_eq!(r["overdue_days"], 9);
    assert_eq!(r["every_days"], 30, "第一年之后落在最后一档");
}

#[test]
fn a_test_that_was_never_done_says_never_not_overdue() {
    let items = reminders(
        &[("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
        vec![enable()],
    );
    let r = find(&items, "mmf_cbc");
    assert_eq!(r["state"], "never");
    assert!(r["due_at"].is_null(), "从没查过就没有「该查的那天」");
}

#[test]
fn the_visit_reminder_talks_about_the_visit_not_about_one_lab() {
    // spec §5.4:没有任何指南给 dsDNA/补体/尿蛋白单项间隔。文案必须是「该复诊了,
    // 通常会查…」,不能是「你的 dsDNA 过期了」。
    let items = reminders(&[], vec![enable()]);
    let v = items
        .iter()
        .find(|i| i["id"].as_str().unwrap().starts_with("visit_"))
        .expect("该有复诊提醒");
    let text = v["text"].as_str().unwrap();
    assert!(text.contains("复诊"));
    for banned in ["dsDNA 过期", "补体该复查了", "尿蛋白到期"] {
        assert!(!text.contains(banned));
    }
    assert!(
        v["panel_keys"].as_array().unwrap().len() >= 3,
        "复诊时该查的一组指标由包列出"
    );
}

#[test]
fn every_reminder_carries_a_basis_and_a_source() {
    let items = reminders(
        &[("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
        vec![enable()],
    );
    assert!(!items.is_empty(), "夹具包该出几条,不然这条测了个寂寞");
    for r in items {
        let basis = r["basis"].as_str().unwrap();
        assert!(
            ["guideline", "label", "literature", "package_default"].contains(&basis),
            "{basis}"
        );
        assert!(!r["source"].as_str().unwrap().is_empty());
    }
}

#[test]
fn calcium_and_vitamin_d_fire_only_past_seven_point_five_mg_for_three_months() {
    // VERBATIM:「started on prednisone ⩾7.5 mg daily and continues for more than 3 months」。
    let long_ago = "2026-01-01"; // > 3 个月
    let items = reminders(
        &[(long_ago, rx_doc("泼尼松片 7.5mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(ids(&items).contains(&"gc_ca_vitd".to_string()));

    let items = reminders(
        &[(long_ago, rx_doc("泼尼松片 5mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(
        !ids(&items).contains(&"gc_ca_vitd".to_string()),
        "5 mg 不到 7.5 的阈"
    );

    let recent = "2026-08-20"; // < 3 个月
    let items = reminders(
        &[(recent, rx_doc("泼尼松片 10mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(
        !ids(&items).contains(&"gc_ca_vitd".to_string()),
        "不满 3 个月不提醒"
    );
}

#[test]
fn a_threshold_whose_drug_was_never_prescribed_stays_off_the_list() {
    // 没在吃激素的人不该看到「该补钙了」,哪怕那条规则在包里。
    let items = reminders(
        &[("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
        vec![enable()],
    );
    for id in ["gc_ca_vitd", "gc_dxa_frax", "hcq_eye"] {
        assert!(!ids(&items).contains(&id.to_string()), "{id}");
    }
}

#[test]
fn a_glucocorticoid_we_cannot_convert_is_unknown_not_silently_skipped() {
    // 甲泼尼龙:等效换算表还没核实(包里 `pred_equiv: null`),日剂量算不出来。
    // 「算不出来」不等于「没到阈值」—— 静默跳过会让一条该提的提醒消失得无声无息。
    let items = reminders(
        &[("2026-01-01", rx_doc("甲泼尼龙片 8mg 每日一次 口服"))],
        vec![enable()],
    );
    let r = find(&items, "gc_ca_vitd");
    assert_eq!(r["state"], "unknown");
    assert!(
        r["reason"].as_str().unwrap().contains("换算表待核"),
        "理由要说清缺的是换算表,不是缺药:{}",
        r["reason"]
    );
}

#[test]
fn an_interval_nobody_verified_is_shown_but_never_becomes_a_due_date() {
    // §D.2.1:两份国内说明书连彼此都对不上(每 3 月 vs 每年至少一次),且都只经
    // 摘要管道。核不实的间隔只许显示,不许算出一个到期日。
    let items = reminders(
        &[("2020-01-01", rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        vec![enable()],
    );
    let r = find(&items, "hcq_eye");
    assert_eq!(r["state"], "pending");
    assert_eq!(r["pending"], true);
    assert!(r["due_at"].is_null());
    assert!(r["every_days"].is_null(), "没有核实过的间隔就没有间隔");
}

#[test]
fn dismissing_a_reminder_hides_it_until_the_next_due_date() {
    let docs = [
        ("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
        ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
    ];
    assert!(!ids(&reminders(
        &docs,
        vec![enable(), dismiss("2026-09-15", "mmf_cbc")]
    ))
    .contains(&"mmf_cbc".to_string()));
    // 忽略发生在**上一次到期之前**就不算数了(又到期了要再提)。
    assert!(ids(&reminders(
        &docs,
        vec![enable(), dismiss("2026-07-01", "mmf_cbc")]
    ))
    .contains(&"mmf_cbc".to_string()));
    // 忽略的是这一条,不是整张卡。
    assert!(ids(&reminders(
        &docs,
        vec![enable(), dismiss("2026-09-15", "mmf_cbc")]
    ))
    .contains(&"visit_active".to_string()));
}

#[test]
fn dismissing_a_never_done_check_brings_it_back_after_one_interval() {
    // 从没查过的那条没有「上一次到期」可比,忽略就按「压住一个完整间隔」算:
    // 间隔过完还是没查,就该再提 —— 否则一次忽略等于永久关掉。
    let docs = [("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))];
    let fresh = reminders(&docs, vec![enable(), dismiss("2026-09-01", "mmf_cbc")]); // 15 天前 < 30
    assert!(!ids(&fresh).contains(&"mmf_cbc".to_string()));
    let stale = reminders(&docs, vec![enable(), dismiss("2026-08-01", "mmf_cbc")]); // 46 天前 > 30
    assert!(ids(&stale).contains(&"mmf_cbc".to_string()));
}

#[test]
fn an_active_disease_gets_the_denser_cadence_and_a_stable_one_the_looser() {
    let pkg = casts_only_pkg();
    let active = [(TODAY, lab_doc("尿沉渣:可见红细胞管型"))];
    let items = reminders_of(&pkg, &mk_docs(&active), vec![enable()]);
    let r = find(&items, "visit_active");
    assert_eq!(r["disease_state"], "active");
    assert_eq!(r["every_days"], 30, "中国指南推荐 3:活动期至少每月一次");
    assert!(!ids(&items).contains(&"visit_stable".to_string()));

    let stable = [(TODAY, lab_doc("尿沉渣镜检:未见红细胞管型及颗粒管型"))];
    let items = reminders_of(&pkg, &mk_docs(&stable), vec![enable()]);
    let r = find(&items, "visit_stable");
    assert_eq!(r["disease_state"], "stable");
    assert_eq!(r["every_days"], 90, "稳定期 3—6 个月,取更密的一端");
    assert!(!ids(&items).contains(&"visit_active".to_string()));
}

#[test]
fn an_activity_we_could_not_score_falls_back_to_the_denser_cadence_and_says_so() {
    // 一份文档都没有 = 8 条描述符全算不出来。这时候按「稳定」提醒,等于拿
    // 「这次没读到」当「病情稳定」,把复诊间隔从 1 个月拉到 3 个月。
    let items = reminders(&[], vec![enable()]);
    let r = find(&items, "visit_active");
    assert_eq!(r["every_days"], 30);
    assert!(
        r["text"].as_str().unwrap().contains("活动度还没算全"),
        "按较密的节律提醒这件事要在文案里说出来:{}",
        r["text"]
    );
    // 算全了就不该有这句(上一条用例里的 active 分支)。
    let one = casts_only_pkg();
    let hit = [(TODAY, lab_doc("尿沉渣:可见红细胞管型"))];
    let items = reminders_of(&one, &mk_docs(&hit), vec![enable()]);
    assert!(!find(&items, "visit_active")["text"]
        .as_str()
        .unwrap()
        .contains("活动度还没算全"));
}

#[test]
fn an_exam_done_fact_counts_as_having_been_checked() {
    // 眼底/骨密度这类检查不会变成化验序列,只会以 `exam_done` fact 进来。
    // 包里那条真的眼科规则永远是 pending(§D.2.1),所以这里用一条**自造的**
    // 规则测管道:间隔是编的,`basis` 如实写 package_default。
    let mut v = full_json();
    v["rules"]["monitoring"] = serde_json::json!([{
        "kind":"drug_schedule","id":"probe_dxa","drug_class":"gc","target":"骨密度",
        "exam_names":["骨密度"],"phases":[{"every_days":365}],
        "text":"测试用,不是临床规则","basis":"package_default","source":"S1",
        "verify_status":"verified"}]);
    let pkg: Package = serde_json::from_value(v).expect("夹具包必须解析");

    let rx = [("2025-01-01", rx_doc("泼尼松片 5mg 每日一次 口服"))];
    let mut docs = mk_docs(&rx);
    assert_eq!(
        reminders_of(&pkg, &docs, vec![enable()])[0]["state"],
        "never",
        "没有任何检查记录时是「还没查过」"
    );

    let facts = r#"{"facts":[{"type":"exam_done","name":"骨密度","date":"2026-06-01",
                              "evidence":"骨密度检查"}]}"#;
    docs.push(parser::SourceDoc {
        index: 1,
        date: Some(day("2026-06-01")),
        text: "骨密度检查",
        doc_type: Some("exam_report".into()),
        title: None,
        extraction_json: Some(facts),
    });
    assert!(
        reminders_of(&pkg, &docs, vec![enable()]).is_empty(),
        "107 天前做过,365 天的间隔还没到"
    );
}

#[test]
fn the_ones_nobody_ever_did_sort_above_the_overdue_ones() {
    // 「还没查过」是更硬的缺口,排在逾期前面;核不实的那几条排最后 —— 它们连
    // 到期日都算不出来,不该占着列表最上面那一屏。
    let items = reminders(
        &[
            ("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-01-01", rx_doc("泼尼松片 7.5mg 每日一次 口服")),
            ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ],
        vec![enable()],
    );
    assert_eq!(
        ids(&items),
        ["gc_ca_vitd", "visit_active", "mmf_cbc", "gc_dxa_frax"]
    );
}

#[test]
fn the_package_only_ever_contains_the_three_allowed_monitoring_kinds() {
    // 这条是**红线守卫**:多一种 kind 就意味着有人在按单项指标造间隔。
    for m in &full_pkg().rules.monitoring {
        let k = m["kind"].as_str().unwrap();
        assert!(
            ["disease_cadence", "drug_schedule", "drug_threshold"].contains(&k),
            "{k}"
        );
    }
}
