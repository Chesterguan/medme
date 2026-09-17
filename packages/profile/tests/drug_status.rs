//! 现行方案卡(`status_card`):激素等效日剂量、羟氯喹 mg/kg、其它药、上次就诊。
//! 临床数值全部来自 `.superpowers/sdd/disease-profile/sle-clinical-sources.md`
//! §C.3 / §C.4 / §D.2.1 / §D.8 的 VERBATIM 行。
use chrono::NaiveDate;

mod common;
use common::{full_pkg, mk_docs, rx_doc, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn status(docs: &[(&str, String)], events: Vec<parser::ProfileEvent>) -> serde_json::Value {
    let src = mk_docs(docs);
    profile::materialize(&src, &events, &full_pkg(), day(TODAY))
        .sections
        .iter()
        .find(|s| s.kind == "status_card")
        .expect("有 status_card")
        .body
        .clone()
}

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }
}

fn weight(at: &str, kg: f64) -> parser::ProfileEvent {
    parser::ProfileEvent {
        kind: "weight".into(),
        package: "t".into(),
        at: at.into(),
        payload: serde_json::json!({ "kg": kg }),
    }
}

#[test]
fn prednisone_daily_dose_is_read_from_the_prescription() {
    let b = status(
        &[(TODAY, rx_doc("泼尼松片 10mg 每日一次 口服"))],
        vec![enable()],
    );
    assert_eq!(b["gc"]["daily_pred_equiv_mg"], 10.0);
    assert_eq!(b["gc"]["drug"], "泼尼松");
}

#[test]
fn another_glucocorticoid_is_not_silently_converted_while_the_table_is_unverified() {
    // 包里 pred_equiv 是 null(换算表还没核实,sle-clinical-sources §G)。
    // 编一个系数比不显示更糟:剂量会直接进 DORIS「<5 mg」那一条的判定。
    let b = status(
        &[(TODAY, rx_doc("甲泼尼龙片 8mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(b["gc"]["unconvertible"][0]["name"], "甲泼尼龙");
    // 界面上原样显示这五个字(Task 21 的 status_card 断言同一串),不是一句模糊的
    // 「无法计算」—— 用户和医生要知道缺的是**换算表**,不是缺药。
    assert_eq!(b["gc"]["unconvertible"][0]["reason"], "换算表待核");
}

#[test]
fn prednisolone_does_not_get_a_hard_coded_factor_of_one() {
    // 泼尼松龙临床上确实按 1:1 算(DORIS Box 1 原文用的就是 prednisolone),但那是
    // 一个**没有出处 id 的临床数值**;写进引擎就违反了 global-constraints「包里每个
    // 数值都带出处 id」。系数 1 只留给规范名逐字等于「泼尼松」的那一个。
    let b = status(
        &[(TODAY, rx_doc("泼尼松龙片 10mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(b["gc"]["unconvertible"][0]["name"], "泼尼松龙片");
    assert_eq!(b["gc"]["unconvertible"][0]["reason"], "换算表待核");
}

#[test]
fn methylprednisolone_spelled_the_other_way_is_still_unconvertible() {
    // 「甲泼尼松龙」是甲泼尼龙在中国处方上的另一种写法,词典里没有,逐字含
    // 「泼尼松」。按「规范名 == 泼尼松」判就不会误伤。
    let b = status(
        &[(TODAY, rx_doc("甲泼尼松龙片 8mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(b["gc"]["unconvertible"][0]["reason"], "换算表待核");
}

#[test]
fn a_steroid_neither_the_package_nor_the_dictionary_knows_still_shows_up() {
    // 倍他米松 / 曲安西龙 / 可的松今天既不在词典的 H02A* 里(只有 4 个),也不在包的
    // `drugs[gc].names` 里。认不出**不等于**可以让它从界面上消失 —— 医生至少要看见
    // 「他还在吃这个」。
    let b = status(
        &[(TODAY, rx_doc("倍他米松片 0.5mg 每日一次 口服"))],
        vec![enable()],
    );
    assert!(b["gc"]["drug"].is_null(), "认不出就别当成现行激素方案");
    let o = b["others"].as_array().unwrap();
    let row = o
        .iter()
        .find(|x| x["name"] == "倍他米松片")
        .expect("认不出的药也要列出来");
    assert!(row["class"].is_null(), "不知道是哪一类就写 null,不编一个");
    assert_eq!(row["latest_dose"], "0.5mg qd");
}

#[test]
fn the_regimen_says_which_day_it_is_from() {
    // 引擎不设时效(与 PGA 同一条:多久算过期由包/渲染层说),但**日期必须说出来**:
    // 没有它,一张 2019 年的处方在界面上就是「现行方案:泼尼松 4 mg/天」。
    // `since` 是起始日期,读起来像「一直吃到现在」,答不了这个问题。
    let b = status(
        &[("2019-06-01", rx_doc("泼尼松片 4mg 每日一次 口服"))],
        vec![enable()],
    );
    assert_eq!(b["gc"]["daily_pred_equiv_mg"], 4.0);
    assert_eq!(b["gc"]["as_of"], "2019-06-01", "最后一次见到是哪天");
    assert_eq!(b["gc"]["since"], "2019-06-01");
}

#[test]
fn the_headline_doses_carry_their_own_evidence() {
    // 这两个是卡上最重的数,之前反而是 body 里唯一不带原剂量串和出处文档的。
    let b = status(
        &[(
            TODAY,
            rx_doc("泼尼松片 5mg 每日一次 口服\n硫酸羟氯喹片 0.2g 每日两次 口服"),
        )],
        vec![enable()],
    );
    assert_eq!(b["gc"]["dose"], "5mg qd");
    assert_eq!(b["gc"]["sources"], serde_json::json!([0]));
    assert_eq!(b["hcq"]["dose"], "0.2g bid");
    assert_eq!(b["hcq"]["sources"], serde_json::json!([0]));
}

#[test]
fn hcq_says_which_day_the_dose_is_from_separately_from_the_weight() {
    // 一张 2019 年的处方配今天的体重,算出来的 mg/kg 看着像今天的。两个日期各带各的。
    let b = status(
        &[("2019-06-01", rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        vec![enable(), weight(TODAY, 60.0)],
    );
    assert!((b["hcq"]["mg_per_kg"].as_f64().unwrap() - 6.667).abs() < 0.01);
    assert_eq!(b["hcq"]["dose_at"], "2019-06-01");
    assert_eq!(b["hcq"]["weight_at"], TODAY);
}

#[test]
fn two_steroids_on_the_same_day_are_never_summed_or_picked_between() {
    // 同一天两条激素:可能是换药、可能是冲击后减量、也可能是 OCR 把一行读成两行。
    // 求和得出一个谁也没开过的剂量,挑一个是替医生猜 —— 而少算的方向正好制造
    // DORIS 的假 ✔(10 + 20 里挑 10,就落在 <5 那条线的同一侧逻辑上被当成真值)。
    let b = status(
        &[(
            TODAY,
            rx_doc("泼尼松片 10mg 每日一次 口服\n泼尼松龙片 20mg 每日一次 口服"),
        )],
        vec![enable()],
    );
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert!(b["gc"]["drug"].is_null());
    assert_eq!(b["gc"]["as_of"], TODAY, "日期照样说出来:要核对的是哪天");
    let u = b["gc"]["unconvertible"].as_array().unwrap();
    assert_eq!(u.len(), 2, "那天的每一条都要列出来,不能静悄悄丢一条");
    assert!(u
        .iter()
        .all(|x| x["reason"] == "同一天有多条激素记录,请核对"));
    assert!(u.iter().any(|x| x["name"] == "泼尼松"));
    assert!(u.iter().any(|x| x["name"] == "泼尼松龙片"));
}

#[test]
fn a_topical_steroid_is_not_a_systemic_regimen() {
    // 复方地塞米松乳膏按口服等效表换算是几十毫克泼尼松等效,直接进 DORIS/LLDAS;
    // 在那之前它还会因为「最近」把真正在吃的口服激素挤掉。
    let b = status(
        &[(
            TODAY,
            rx_doc("复方地塞米松乳膏 5mg 每日一次 外用\n泼尼松片 5mg 每日一次 口服"),
        )],
        vec![enable()],
    );
    assert_eq!(b["gc"]["drug"], "泼尼松", "口服那条才是现行方案");
    assert_eq!(b["gc"]["daily_pred_equiv_mg"], 5.0);
    let o = b["others"].as_array().unwrap();
    let cream = o
        .iter()
        .find(|x| x["name"] == "复方地塞米松乳膏")
        .expect("外用的也要列出来,只是不计入全身剂量");
    assert_eq!(cream["class"], "gc_nonsystemic");
    // 外用那条不该出现在「没算进日剂量的激素」里 —— 它压根不是全身激素。
    assert!(b["gc"]["unconvertible"].as_array().unwrap().is_empty());
}

#[test]
fn an_injection_written_into_the_drug_name_is_not_converted_as_an_oral_dose() {
    // 冲击治疗一次 500 mg 与口服 5 mg/天不是一回事,等效表(待核)覆盖的也只是口服。
    let b = status(
        &[(TODAY, rx_doc("泼尼松龙注射液 500mg 每日一次"))],
        vec![enable()],
    );
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(
        b["gc"]["unconvertible"][0]["reason"],
        "注射剂型,不按口服换算"
    );
}

#[test]
fn a_route_the_parser_already_swallowed_is_invisible_to_this_layer() {
    // ⚠️ **已知边界,不是期望行为 —— 这是给 Task 19 的绊线。**
    // 剂型/途径在到达这一层之前就没了,两条路各丢一半:
    //  - 写在剂量**后面**的(「甲泼尼龙 40mg 静滴」)被 `meds.rs` 的
    //    `strip_trailing_route` 剥掉,`dose_string` 也只拼「剂量 频次」;
    //  - 写在**药名里**的(「地塞米松注射液」)被词典归一成规范名「地塞米松」。
    // 所以这道门只挡得住**词典认不出**的那些注射剂型(上一条测试)。今天靠
    // 「换算表待核」兜住,一旦 Task 19 把 pred_equiv 填上,这一条就会按口服换算出
    // 一个几倍于实际的泼尼松等效剂量并直接进 DORIS —— **填表之前必须先让途径到达
    // 这一层**(交接清单)。这条测试到时候会红,那正是它的作用。
    let b = status(
        &[(TODAY, rx_doc("地塞米松注射液 5mg 每日一次"))],
        vec![enable()],
    );
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(
        b["gc"]["unconvertible"][0]["name"], "地塞米松",
        "词典把「注射液」三个字归一掉了"
    );
    assert_eq!(
        b["gc"]["unconvertible"][0]["reason"], "换算表待核",
        "**不是**「注射剂型」—— 剂型门根本没看见它"
    );
}

#[test]
fn a_verified_conversion_table_turns_that_same_steroid_into_a_number() {
    // Task 19 把 §G 那张表核到原始出处、填进包之后,这条分支自然生效,引擎代码
    // 一个字都不用改 —— 这就是「等效系数放包里、不放引擎里」的全部意义。
    // 表里的 1.25 是 spec §2 示例里那个(本身也标着「待核」),这里只验通路。
    let mut v = common::full_json();
    v["drugs"][0]["pred_equiv"] = serde_json::json!({"泼尼松":1,"甲泼尼龙":1.25});
    v["drugs"][0]["pred_equiv_source"] = serde_json::json!("S_TODO");
    let pkg: profile::Package = serde_json::from_value(v).expect("夹具包必须解析");
    let docs = [(TODAY, rx_doc("甲泼尼龙片 8mg 每日一次 口服"))];
    let src = mk_docs(&docs);
    let b = profile::materialize(&src, &[enable()], &pkg, day(TODAY))
        .sections
        .into_iter()
        .find(|s| s.kind == "status_card")
        .expect("有 status_card")
        .body;
    assert_eq!(b["gc"]["daily_pred_equiv_mg"], 10.0, "8 mg × 1.25");
    assert!(b["gc"]["unconvertible"].as_array().unwrap().is_empty());
}

#[test]
fn a_dose_without_a_frequency_is_not_assumed_to_be_once_a_day() {
    // 「泼尼松 10mg」没写一天几次:按 qd 算就是 10,按 bid 算就是 20,而 DORIS 的
    // 那条线在 5。默认成 1 次/天是在替处方笺补一个它没写的字。
    let b = status(&[(TODAY, rx_doc("泼尼松片 10mg 口服"))], vec![enable()]);
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(b["gc"]["unconvertible"][0]["name"], "泼尼松");
}

#[test]
fn hcq_mg_per_kg_uses_the_most_recent_weight_and_says_where_it_came_from() {
    let events = vec![enable(), weight("2026-09-10", 60.0)];
    let b = status(
        &[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        events,
    );
    assert_eq!(b["hcq"]["daily_mg"], 400.0);
    assert_eq!(b["hcq"]["weight_kg"], 60.0);
    assert!((b["hcq"]["mg_per_kg"].as_f64().unwrap() - 6.667).abs() < 0.01);
    assert_eq!(b["hcq"]["target"], 5.0);
    assert_eq!(b["hcq"]["weight_source"], "self_reported");
}

#[test]
fn a_newer_weight_replaces_an_older_one() {
    // 「最近一次」是按日期比出来的,不是按日志顺序:补录一条去年的体重不能把今年
    // 的顶掉,而 mg/kg 的分母错一次,整条 5 mg/kg 的判定就错一次。
    let events = vec![
        enable(),
        weight("2026-09-10", 60.0),
        weight("2025-01-05", 90.0),
    ];
    let b = status(
        &[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        events,
    );
    assert_eq!(b["hcq"]["weight_kg"], 60.0);
    assert_eq!(b["hcq"]["weight_at"], "2026-09-10");
}

#[test]
fn hcq_without_a_weight_shows_the_dose_but_no_mg_per_kg() {
    let b = status(
        &[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        vec![enable()],
    );
    assert_eq!(b["hcq"]["daily_mg"], 400.0);
    assert!(
        b["hcq"]["mg_per_kg"].is_null(),
        "没有体重就不给 mg/kg,别拿理想体重猜"
    );
    // 未知必须带一句为什么,不然界面上的空白和「这项我们不打算算」长得一样。
    assert!(b["hcq"]["reason"].as_str().unwrap().contains("体重"));
}

#[test]
fn hcq_card_states_both_the_guideline_rule_and_the_package_insert_rule() {
    // sle-clinical-sources §D.2.1:指南 5 mg/kg 真实体重 vs 说明书 6.5 mg/kg 理想体重。
    // 用户手里那张说明书写的就是另一个数,界面只说一个就是在制造矛盾。
    let b = status(
        &[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        vec![enable()],
    );
    let insert = b["hcq"]["label_rule"].as_str().unwrap();
    assert!(insert.contains("6.5"));
    assert!(insert.contains("理想体重"));
    assert_eq!(b["hcq"]["target_source"], "S4");
    // 说明书那串还没有人对着纸核过 —— 界面必须让医生知道这一点。
    assert_eq!(b["hcq"]["label_rule_pending"], true);
}

/// 按 `verify_status` 改一份包,取出 `hcq.label_rule_pending`。
/// `status` 为 `None` = 包里**压根没写** `verify_status` 这个键。
fn label_rule_pending(status: Option<&str>) -> bool {
    let mut v = common::full_json();
    let lr = &mut v["rules"]["targets"]["hcq"]["label_rule"];
    match status {
        Some(s) => lr["verify_status"] = serde_json::json!(s),
        None => {
            lr.as_object_mut()
                .expect("label_rule 是对象")
                .remove("verify_status");
        }
    }
    let pkg: profile::Package = serde_json::from_value(v).expect("夹具包必须解析");
    let docs = [(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))];
    let src = mk_docs(&docs);
    profile::materialize(&src, &[enable()], &pkg, day(TODAY))
        .sections
        .into_iter()
        .find(|s| s.kind == "status_card")
        .expect("有 status_card")
        .body["hcq"]["label_rule_pending"]
        .as_bool()
        .expect("label_rule_pending 是 bool")
}

#[test]
fn a_label_rule_with_no_verify_status_is_still_pending() {
    // fail closed:包作者漏写 `verify_status` 时,默认必须是「待核」。反过来
    // (缺省即已核实)会把一句没人核过的说明书原文当成核过的送到医生眼前 ——
    // 而说明书那几个数和指南的数**不一样**(§D.2.1 的三重冲突)。
    assert!(label_rule_pending(None), "漏写就是待核");
    // 拼错、写成别的值,同样不清旗:只有逐字的 "verified" 算数。
    assert!(label_rule_pending(Some("pendng")));
    assert!(label_rule_pending(Some("")));
}

#[test]
fn only_the_literal_verified_clears_the_label_rule_flag() {
    // Task 19 逐条核完、把 `verify_status` 改成 "verified" 之后,界面上那句
    // 「待核」才消失,引擎代码不用改。
    assert!(!label_rule_pending(Some("verified")));
    assert!(label_rule_pending(Some("pending")), "核之前照旧是待核");
}

#[test]
fn gc_targets_carry_both_years_because_the_two_guidelines_differ() {
    let b = status(
        &[(TODAY, rx_doc("泼尼松片 10mg 每日一次 口服"))],
        vec![enable()],
    );
    let t = b["gc"]["targets"].as_array().unwrap();
    assert_eq!(t.len(), 2);
    assert!(t
        .iter()
        .any(|x| x["value"] == 7.5 && x["label"].as_str().unwrap().contains("2019")));
    assert!(t
        .iter()
        .any(|x| x["value"] == 5.0 && x["label"].as_str().unwrap().contains("2023")));
}

#[test]
fn biologics_show_their_infusion_rhythm_from_the_package() {
    let b = status(
        &[(TODAY, rx_doc("贝利尤单抗 400mg 静脉滴注"))],
        vec![enable()],
    );
    let o = b["others"].as_array().unwrap();
    let bel = o
        .iter()
        .find(|x| x["class"] == "belimumab")
        .expect("认出贝利尤单抗");
    assert!(bel["infusion"]["iv"].as_str().unwrap().contains("每 4 周"));
}

#[test]
fn the_steroid_and_hcq_are_not_repeated_in_others() {
    // `others` 是「激素与羟氯喹之外」的那一格;重复一遍会在界面上变成两条方案。
    let b = status(
        &[(
            TODAY,
            rx_doc("泼尼松片 10mg 每日一次 口服\n硫酸羟氯喹片 0.2g 每日两次 口服"),
        )],
        vec![enable()],
    );
    let o = b["others"].as_array().unwrap();
    assert!(o.iter().all(|x| x["class"] != "gc" && x["class"] != "hcq"));
}

#[test]
fn the_last_visit_shows_the_document_it_came_from() {
    let b = status(
        &[
            ("2026-03-02", rx_doc("泼尼松片 10mg 每日一次 口服")),
            (TODAY, common::lab_doc("补体C3 0.4 g/L 0.9-1.8")),
        ],
        vec![enable()],
    );
    assert_eq!(b["last_visit"]["date"], TODAY, "最近那份");
    assert_eq!(b["last_visit"]["title"], "检验报告单");
}

#[test]
fn an_empty_vault_collapses_the_card_instead_of_showing_a_blank_regimen() {
    let src = mk_docs(&[]);
    let s = profile::materialize(&src, &[enable()], &full_pkg(), day(TODAY))
        .sections
        .into_iter()
        .find(|s| s.kind == "status_card")
        .expect("开启了就有卡,只是折叠");
    assert!(s.empty_hint.is_some(), "没读到任何处方时折叠成一行");
    assert!(s.body["gc"]["daily_pred_equiv_mg"].is_null());
}

#[test]
fn the_card_never_says_the_dose_is_too_high_in_its_own_words() {
    // 说明书与指南两套规则同时成立(§D.2.1 的三重冲突),引擎不许挑一份下结论。
    let b = status(
        &[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))],
        vec![enable(), weight(TODAY, 60.0)],
    );
    let s = serde_json::to_string(&b).unwrap();
    for banned in ["超量", "剂量过高", "超过上限", "不安全"] {
        assert!(!s.contains(banned), "{banned}");
    }
}
