//! 复查提醒(`reminders`):**只有三种来源**,没有第四种。
//! 间隔与阈值全部来自 `.superpowers/sdd/disease-profile/sle-clinical-sources.md`
//! §A.1 / §D.1 / §D.3 的 VERBATIM 行;核不实的那几条(以及说明书写完之后包作者
//! 外推的那一档)在包里标 `verify_status` 不是 `"verified"`,只显示、永远不算到期。
use chrono::NaiveDate;

mod common;
use common::{full_json, full_pkg, lab_doc, mk_docs, rx_doc, TODAY};
use profile::Package;

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

/// 吗替麦考酚酯的起始日:落在**说明书逐字覆盖的第一年之内**(第 107 天 → 第三档
/// 「每月」)。第一年之后那一档是包作者的外推,单独由
/// `the_extrapolated_phase_goes_out_as_package_default_and_never_comes_due` 钉住。
const MMF_START: &str = "2026-06-01";

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "enable".into(),
        package: "sle".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }
}

fn dismiss(at: &str, id: &str) -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "dismiss_reminder".into(),
        package: "sle".into(),
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

fn has(items: &[serde_json::Value], id: &str) -> bool {
    ids(items).contains(&id.to_string())
}

/// 一份「就诊过了、但没带回任何化验」的文档(门诊病历)。
fn visit_doc(date: &str) -> parser::SourceDoc<'static> {
    parser::SourceDoc {
        index: 0,
        date: Some(day(date)),
        text: "门诊病历\n主诉:随诊。查体未见明显异常,继续原方案。",
        doc_type: Some("outpatient".into()),
        title: Some("门诊病历".into()),
        extraction_json: None,
    }
}

/// [`full_pkg`],但活动度只留「管型」一条、窗口放宽到 400 天。
///
/// 两处改动都是为了让 active / stable 两条分支能被测到:8 条全留时只要有一条读不
/// 出来,节律就落进「没算全 → 按活动期提醒」那一档;而 10 天的窗口下,能算出活动度
/// 的文档必然是一次「刚刚的就诊」,节律永远不到期(复诊提醒按上次就诊算)。窗口是
/// 包里的旋钮,这里调它不涉及任何临床主张。
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
    v["rules"]["activity"]["window_days"] = serde_json::json!(400);
    serde_json::from_value(v).expect("夹具包必须解析")
}

// --- 逾期 / 从没查过 -------------------------------------------------------

#[test]
fn a_cbc_that_is_due_but_not_yet_overdue_does_not_nag() {
    // MMF 第 4 个月起每月一次血常规(说明书 VERBATIM)。1.2 倍宽限 = 36 天。
    let items = reminders(
        &[
            (MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-08-20", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ], // 27 天前
        vec![enable()],
    );
    assert!(!has(&items, "mmf_cbc"));
}

#[test]
fn the_same_cbc_past_one_point_two_intervals_is_overdue() {
    let items = reminders(
        &[
            (MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ], // 39 天前 > 36
        vec![enable()],
    );
    let r = find(&items, "mmf_cbc");
    assert_eq!(r["state"], "overdue");
    assert_eq!(r["basis"], "label");
    assert_eq!(r["pending"], false);
    // 「该查的那天」是最近一次 + 间隔,不是 + 宽限:宽限只用来决定要不要开口。
    assert_eq!(r["due_at"], "2026-09-07");
    assert_eq!(r["overdue_days"], 9);
    assert_eq!(r["every_days"], 30, "第 107 天落在说明书的第三档");
}

#[test]
fn a_test_that_was_never_done_says_never_not_overdue() {
    let items = reminders(
        &[(MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
        vec![enable()],
    );
    let r = find(&items, "mmf_cbc");
    assert_eq!(r["state"], "never");
    assert!(r["due_at"].is_null(), "从没查过就没有「该查的那天」");
}

#[test]
fn a_lab_dated_in_the_future_does_not_hide_an_overdue_reminder() {
    // OCR 把 2026 读成 2027 的化验单,过去能把整张卡按下去 —— 而「按下去」正是
    // 这条线上最不该出错的方向。
    let items = reminders(
        &[
            (MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
            ("2027-01-01", lab_doc("白细胞 5.1 10^9/L 3.5-9.5")),
        ],
        vec![enable()],
    );
    let r = find(&items, "mmf_cbc");
    assert_eq!(r["state"], "overdue");
    assert_eq!(r["due_at"], "2026-09-07", "按 2026-08-08 那次算,不是 2027");
}

// --- 病级复诊节律 ---------------------------------------------------------

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
fn a_clinic_visit_without_a_lab_sheet_still_counts_as_having_gone() {
    // 上周刚看完门诊、那次没开化验(或化验单还没拍进来),今天不该被告知「该复诊了」。
    let items = reminders_of(&full_pkg(), &[visit_doc("2026-09-01")], vec![enable()]);
    assert!(!has(&items, "visit_active"), "15 天前刚看过门诊");
    assert!(
        items.is_empty(),
        "没吃药、刚看过门诊 → 没什么要补的:{items:?}"
    );
}

#[test]
fn a_lab_sheet_counts_as_the_visit_too() {
    // 反过来:拍进来一张化验单本身就说明去过医院了。
    let recent = [("2026-09-01", lab_doc("补体C3 1.0 g/L 0.9-1.8"))];
    assert!(!has(&reminders(&recent, vec![enable()]), "visit_active"));
    // 同一张单子挪到 4 个多月前就该提了(活动期 30 天,宽限 36 天)。
    let old = [("2026-05-01", lab_doc("补体C3 1.0 g/L 0.9-1.8"))];
    assert_eq!(
        find(&reminders(&old, vec![enable()]), "visit_active")["state"],
        "overdue"
    );
}

#[test]
fn an_active_disease_gets_the_denser_cadence_and_a_stable_one_the_looser() {
    let pkg = casts_only_pkg();
    let active = [("2026-01-01", lab_doc("尿沉渣:可见红细胞管型"))];
    let items = reminders_of(&pkg, &mk_docs(&active), vec![enable()]);
    let r = find(&items, "visit_active");
    assert_eq!(r["disease_state"], "active");
    assert_eq!(r["every_days"], 30, "中国指南推荐 3:活动期至少每月一次");
    assert!(!has(&items, "visit_stable"));

    let stable = [("2026-01-01", lab_doc("尿沉渣镜检:未见红细胞管型及颗粒管型"))];
    let items = reminders_of(&pkg, &mk_docs(&stable), vec![enable()]);
    let r = find(&items, "visit_stable");
    assert_eq!(r["disease_state"], "stable");
    assert_eq!(r["every_days"], 90, "稳定期 3—6 个月,取更密的一端");
    assert!(!has(&items, "visit_active"));
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
    // 算全了就不该有这句。
    let scored = [("2026-01-01", lab_doc("尿沉渣:可见红细胞管型"))];
    let items = reminders_of(&casts_only_pkg(), &mk_docs(&scored), vec![enable()]);
    assert!(!find(&items, "visit_active")["text"]
        .as_str()
        .unwrap()
        .contains("活动度还没算全"));
}

// --- 药物阈值 -------------------------------------------------------------

#[test]
fn calcium_and_vitamin_d_fire_only_past_seven_point_five_mg_for_three_months() {
    // VERBATIM:「started on prednisone ⩾7.5 mg daily and continues for more than 3 months」。
    let long_ago = "2026-01-01"; // > 3 个月
    let items = reminders(
        &[(long_ago, rx_doc("泼尼松片 7.5mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(has(&items, "gc_ca_vitd"));

    let items = reminders(
        &[(long_ago, rx_doc("泼尼松片 5mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(!has(&items, "gc_ca_vitd"), "5 mg 不到 7.5 的阈");

    let recent = "2026-08-20"; // < 3 个月
    let items = reminders(
        &[(recent, rx_doc("泼尼松片 10mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(!has(&items, "gc_ca_vitd"), "不满 3 个月不提醒");
}

#[test]
fn the_three_month_boundary_is_more_than_not_at_least() {
    // 原文是 more than 3 months(超过、不含),所以包里的下限写 91 天:正好 90 天
    // 那天还不提,第 91 天才提。
    let ninety = [("2026-06-18", rx_doc("泼尼松片 10mg 每日一次 口服"))];
    assert!(!has(&reminders(&ninety, vec![enable()]), "gc_ca_vitd"));
    let ninety_one = [("2026-06-17", rx_doc("泼尼松片 10mg 每日一次 口服"))];
    assert!(has(&reminders(&ninety_one, vec![enable()]), "gc_ca_vitd"));
}

#[test]
fn a_dose_below_the_threshold_is_not_a_reminder_at_all_even_while_the_rule_is_unverified() {
    // 吃 1 mg 泼尼松 2 天的人不该看到「做一次骨密度」:待核该挡住的是那个没核过的
    // 数(≥40 岁 FRAX),不是这条规则的适用人群。逐字的剂量/时长门槛先算。
    let items = reminders(
        &[("2026-09-14", rx_doc("泼尼松片 1mg 每日一次 口服"))],
        vec![enable()],
    );
    // 两条阈值规则一条都不该出。(`gc_cv_annual` 是**排期**规则、不看剂量门槛,
    // 吃上激素就会出 —— 它测的是另一件事,不在这条的射程里。)
    for id in ["gc_ca_vitd", "gc_dxa"] {
        assert!(!has(&items, id), "{id} 不该出:{items:?}");
    }
}

/// 7.5 mg × 120 天:剂量和时长两道逐字门槛都过了,才轮到「我们能不能开口」。
/// `min_age` 按参数改,用来分出「写了一个真年龄」与「写了 null」两条路。
fn dxa_with_min_age(min_age: serde_json::Value) -> serde_json::Value {
    let mut v = full_json();
    for m in v["rules"]["monitoring"].as_array_mut().expect("monitoring") {
        if m["id"] == "gc_dxa" {
            m["min_age"] = min_age.clone();
        }
    }
    let pkg: Package = serde_json::from_value(v).expect("包要能解析");
    let docs = [("2026-05-19", rx_doc("泼尼松片 7.5mg 每日一次 口服"))];
    let items = reminders_of(&pkg, &mk_docs(&docs), vec![enable()]);
    find(&items, "gc_dxa").clone()
}

#[test]
fn a_threshold_that_is_met_but_needs_an_age_says_that_and_keeps_the_pending_flag() {
    let r = dxa_with_min_age(serde_json::json!(40));
    assert_eq!(r["state"], "unknown");
    assert!(
        r["reason"].as_str().unwrap().contains("年龄"),
        "{}",
        r["reason"]
    );
    // 「这条规则的数还没核实」这面旗不能因为落进 unknown 就不举了。
    assert_eq!(r["pending"], true);
    let items = reminders(
        &[("2026-05-19", rx_doc("泼尼松片 7.5mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(has(&items, "gc_ca_vitd"), "同一份处方过了 7.5 mg 那条线");
}

#[test]
fn a_null_min_age_means_the_number_is_unverified_not_that_we_need_your_age() {
    // 包里的 `null` = 「这个阈值还没核实」(global-constraints:没核实的一律 null +
    // 待核),不是「这条要看年龄」。`serde_json::Value::get` 对 `null` 返回
    // `Some(Value::Null)`,不显式排掉的话两者完全同路 —— 动作一样(都不提醒),但
    // 用户看到的理由会是「档案里还没有年龄」,让人以为补上年龄就能算。
    let r = dxa_with_min_age(serde_json::Value::Null);
    assert_eq!(r["state"], "pending", "落到「这条规则的数还没核实」那一档");
    assert!(
        r["reason"].is_null(),
        "pending 不带 unknown 的理由:{}",
        r["reason"]
    );
    assert_eq!(r["pending"], true);
    assert!(r["due_at"].is_null(), "没核实的数永远不算出到期日");
}

#[test]
fn a_threshold_whose_drug_was_never_prescribed_stays_off_the_list() {
    // 没在吃激素的人不该看到「该补钙了」,哪怕那条规则在包里。
    let items = reminders(
        &[(MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
        vec![enable()],
    );
    for id in ["gc_ca_vitd", "gc_dxa", "hcq_eye"] {
        assert!(!has(&items, id), "{id}");
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
fn a_stale_prescription_still_fires_but_carries_the_dates_that_say_so() {
    // 引擎不推断停药(`MedSpan.status` 恒为 active),所以 2020 年那张处方今天照样
    // 会亮。日期是唯一能让用户和医生看出这件事的东西 —— 渲染层要有数据才说得出口。
    let items = reminders(
        &[("2020-01-01", rx_doc("泼尼松片 7.5mg 每日一次 口服"))],
        vec![enable()],
    );
    let r = find(&items, "gc_ca_vitd");
    assert_eq!(r["state"], "never");
    assert_eq!(r["since"], "2020-01-01");
    assert_eq!(r["as_of"], "2020-01-01");
}

// --- 没核实的间隔 ---------------------------------------------------------

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
    assert_eq!(r["as_of"], "2020-01-01");
}

#[test]
fn the_extrapolated_phase_goes_out_as_package_default_and_never_comes_due() {
    // 说明书逐字只写到「the remainder of the first year」。第一年之后那一档是包作者
    // 按每月沿用的外推 —— 它必须以自己的身份出去,不能顶着「出处=说明书」的标签。
    let items = reminders(
        &[
            ("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")), // 第 623 天
            ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ],
        vec![enable()],
    );
    let r = find(&items, "mmf_cbc");
    assert_eq!(r["basis"], "package_default", "不是 label");
    assert_eq!(r["state"], "pending");
    assert_eq!(r["pending"], true);
    assert!(r["due_at"].is_null(), "外推出来的间隔不算到期日");
    assert!(r["every_days"].is_null());
    assert!(r["note"].as_str().unwrap().contains("外推"));
    assert_eq!(r["source"], "L1", "数还是说明书那个 30 天,沿用它的出处");
}

#[test]
fn a_rule_with_no_phases_says_that_instead_of_pretending_the_phases_ran_out() {
    let mut v = full_json();
    v["rules"]["monitoring"] = serde_json::json!([{
        "kind":"drug_schedule","id":"probe_empty","drug_class":"gc","target":"血常规",
        "panel_keys":["wbc"],"phases":[],"text":"测试用,不是临床规则",
        "basis":"package_default","source":"S1","verify_status":"verified"}]);
    let pkg: Package = serde_json::from_value(v).expect("夹具包必须解析");
    let docs = [("2026-01-01", rx_doc("泼尼松片 5mg 每日一次 口服"))];
    let r = &reminders_of(&pkg, &mk_docs(&docs), vec![enable()])[0];
    assert_eq!(r["state"], "unknown");
    assert!(r["reason"]
        .as_str()
        .unwrap()
        .contains("没给这一条写监测频率"));
}

// --- 忽略 -----------------------------------------------------------------

#[test]
fn dismissing_a_reminder_hides_it_until_the_next_due_date() {
    let docs = [
        (MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
        ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
    ];
    assert!(!has(
        &reminders(&docs, vec![enable(), dismiss("2026-09-15", "mmf_cbc")]),
        "mmf_cbc"
    ));
    // 忽略发生在**上一次到期之前**就不算数了(又到期了要再提)。
    assert!(has(
        &reminders(&docs, vec![enable(), dismiss("2026-07-01", "mmf_cbc")]),
        "mmf_cbc"
    ));
    // 忽略的是这一条,不是整张卡。
    assert!(has(
        &reminders(&docs, vec![enable(), dismiss("2026-09-15", "mmf_cbc")]),
        "visit_active"
    ));
}

#[test]
fn dismissing_a_never_done_check_brings_it_back_after_one_interval() {
    // 从没查过的那条没有「上一次到期」可比,忽略就按「压住一个完整间隔」算:
    // 间隔过完还是没查,就该再提 —— 否则一次忽略等于永久关掉。
    let docs = [(MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))];
    let fresh = reminders(&docs, vec![enable(), dismiss("2026-09-01", "mmf_cbc")]); // 15 天前 < 30
    assert!(!has(&fresh, "mmf_cbc"));
    let stale = reminders(&docs, vec![enable(), dismiss("2026-08-01", "mmf_cbc")]); // 46 天前 > 30
    assert!(has(&stale, "mmf_cbc"));
}

#[test]
fn a_dismissal_dated_in_the_future_does_not_hide_anything() {
    // 日志是用户自己录的,一条 2027 年的忽略会把提醒静静压住一年多。
    let docs = [(MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))];
    assert!(has(
        &reminders(&docs, vec![enable(), dismiss("2027-05-01", "mmf_cbc")]),
        "mmf_cbc"
    ));
}

// --- 出口形状与守卫 -------------------------------------------------------

#[test]
fn every_reminder_carries_a_basis_and_a_source() {
    // 起始日特意用第一年之后的那一天:分档覆盖了 `basis` 之后,它照样得是四选一的
    // 合法值、照样得带出处。
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
    // 「还没查过」是更硬的缺口,排在逾期前面;算不了的和没核实的排最后 —— 它们连
    // 到期日都算不出来,不该占着列表最上面那一屏。
    let items = reminders(
        &[
            (MMF_START, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
            ("2026-01-01", rx_doc("泼尼松片 7.5mg 每日一次 口服")),
            ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5")),
        ],
        vec![enable()],
    );
    // 同档内按包里的顺序稳定排(`gc_ca_vitd` 在 `gc_cv_annual` 前面)。
    assert_eq!(
        ids(&items),
        [
            "gc_ca_vitd",
            "gc_cv_annual",
            "visit_active",
            "mmf_cbc",
            "gc_dxa"
        ]
    );
    // `gc_dxa` 的 `min_age` 是 null(阈值未核实)→ `pending`,排在最后一档:
    // 它连到期日都算不出来,不该占着列表最上面那一屏。
    let states: Vec<&str> = items.iter().map(|i| i["state"].as_str().unwrap()).collect();
    assert_eq!(states, ["never", "never", "overdue", "overdue", "pending"]);
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

#[test]
fn every_monitoring_rule_has_an_id_and_a_source_the_manifest_declares() {
    // 没有 id 的规则忽略不掉、在界面上也定位不住,引擎只能静默跳过 —— 那种条目得在
    // 包这一层挡住。出处 id 同理:`ProfileView.sources` 里解不出来的话,界面上那个
    // 出处点开是空的(global-constraints:包里每个数值都带出处 id)。
    let pkg = full_pkg();
    let declared: Vec<&str> = pkg.manifest.sources.iter().map(|s| s.id.as_str()).collect();
    for m in &pkg.rules.monitoring {
        let o = m.as_object().expect("每条规则都得是 object");
        let id = o.get("id").and_then(|v| v.as_str()).unwrap_or_default();
        assert!(!id.is_empty(), "有条规则没有 id:{m}");
        assert!(o.contains_key("source"), "{id} 一个出处都没写");
        // 分档可以自带出处(外推那一档),自带了也得声明过。
        let phases = m["phases"].as_array().cloned().unwrap_or_default();
        for src in std::iter::once(m.clone())
            .chain(phases)
            .filter_map(|v| v.get("source").and_then(|s| s.as_str()).map(str::to_string))
        {
            assert!(
                declared.contains(&src.as_str()),
                "{id} 的出处 {src} 没在 manifest.sources 里声明"
            );
        }
    }
}
