//! 三视图(spec 2026-09-30 §2–§4):`state` / `journey` / `evidence` 三段。
//! 一份事件日志三个投影:状态是折叠到今天,轨迹是变更日志,依据是回链。
mod common;

use chrono::NaiveDate;
use serde_json::Value;

const TODAY: &str = "2026-09-16";

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn enable() -> Vec<parser::ProfileEvent> {
    vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: common::PKG_ID.into(),
        at: "2024-03-15".into(),
        payload: Value::Null,
    }]
}

fn view(docs: &[parser::SourceDoc<'_>], events: &[parser::ProfileEvent]) -> Value {
    let pkg = common::full_pkg();
    terminology::set_overlay(common::overlay_entries(&pkg));
    let v = profile::materialize(docs, events, &pkg, day(TODAY));
    terminology::set_overlay(vec![]);
    serde_json::to_value(v).unwrap()
}

fn section<'v>(v: &'v Value, kind: &str) -> &'v Value {
    v["sections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["kind"] == kind)
        .unwrap_or_else(|| panic!("没有 {kind} 段"))
}

fn state_row<'v>(v: &'v Value, key: &str) -> &'v Value {
    section(v, "state")["body"]["vars"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["key"] == key)
        .unwrap_or_else(|| panic!("state 里没有 {key}"))
}

fn lane<'v>(v: &'v Value, key: &str) -> &'v Value {
    section(v, "journey")["body"]["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == key)
        .unwrap_or_else(|| panic!("journey 里没有 {key} 泳道"))
}

fn evidence<'v>(v: &'v Value, id: &str) -> &'v Value {
    section(v, "evidence")["body"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == id)
        .unwrap_or_else(|| panic!("evidence 里没有 {id}"))
}

#[test]
fn gc_state_var_reports_latest_dose_as_of_and_stale() {
    let texts = [
        (
            "2024-09-20",
            common::rx_doc("醋酸泼尼松片 20mg 每日一次 口服"),
        ),
        (
            "2026-06-15",
            common::rx_doc("醋酸泼尼松片 7.5mg 每日一次 口服"),
        ),
    ];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(r["value"], "7.5");
    assert_eq!(r["unit"], "mg/天");
    assert_eq!(r["as_of"], "2026-06-15");
    // 2026-06-15 → 2026-09-16 = 93 天 > 包给的 90 天:陈旧,但值照样给,不说「可能已停药」。
    assert_eq!(r["stale"], true);
    assert_eq!(r["stale_after_days"], 90);
    assert_eq!(r["source"], "S10");
    let ids = r["evidence"].as_array().unwrap();
    assert_eq!(ids.len(), 1, "现在这个值只回链到它来自的那一份文档");
    let e = evidence(&v, ids[0].as_str().unwrap());
    assert_eq!(e["doc"], 1);
    assert_eq!(e["date"], "2026-06-15");
    assert!(
        e["quote"].as_str().unwrap().contains("醋酸泼尼松片 7.5mg"),
        "{e}"
    );
    assert_eq!(e["origin"], "regex");
    assert_eq!(e["verified"], true);
    let span = e["span"].as_array().expect("span");
    let text = texts[1].1.as_str();
    let (a, b) = (
        span[0].as_u64().unwrap() as usize,
        span[1].as_u64().unwrap() as usize,
    );
    assert_eq!(&text[a..b], "醋酸泼尼松片", "span 指向原文里的药名");
}

#[test]
fn recent_dose_is_not_stale() {
    let texts = [(
        "2026-09-01",
        common::rx_doc("醋酸泼尼松片 5mg 每日一次 口服"),
    )];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(r["value"], "5");
    assert_eq!(r["stale"], false);
}

#[test]
fn hcq_state_var_divides_by_latest_weight_and_cites_both() {
    let texts = [(
        "2026-06-15",
        common::rx_doc("硫酸羟氯喹片 0.2g 每日一次 口服"),
    )];
    let docs = common::mk_docs(&texts);
    let mut events = enable();
    events.push(parser::ProfileEvent {
        kind: "weight".into(),
        package: common::PKG_ID.into(),
        at: "2026-09-01".into(),
        payload: serde_json::json!({"kg": 50.0}),
    });
    let v = view(&docs, &events);
    let r = state_row(&v, "hcq_mg_per_kg");
    assert_eq!(r["value"], "4.0");
    assert_eq!(r["unit"], "mg/kg/天");
    assert_eq!(
        r["as_of"], "2026-06-15",
        "截至日期按剂量那份文档算,不按体重"
    );
    let ids: Vec<&str> = r["evidence"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap())
        .collect();
    assert_eq!(ids.len(), 2, "处方 + 体重各一条依据");
    let kinds: Vec<&str> = ids
        .iter()
        .map(|id| evidence(&v, id)["origin"].as_str().unwrap())
        .collect();
    assert!(
        kinds.contains(&"regex") && kinds.contains(&"self_entry"),
        "{kinds:?}"
    );
}

#[test]
fn band_state_var_maps_the_lab_score_to_rules_bands() {
    // 补体低(2)+ 24h 尿蛋白 >0.5 g(4)= 6 → 「轻度活动」(S10 分档 ≤6)。
    let texts = [(
        "2026-09-10",
        common::lab_doc("补体C3 0.60 g/L 0.90-1.80 ↓\n尿蛋白定量 3.20 g/24h 0.00-0.15 ↑"),
    )];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "activity_band");
    // 审查 C-1:分档表只用于症状项勾选后的总评分(包 bands.note 原文),化验可算部分
    // 单独套档就是替医生下「轻度活动」的结论。没有症状分就不出档名,分数照给。
    assert_eq!(r["value"], Value::Null);
    assert_eq!(r["note"], "化验可算部分 6/18 · 症状项未录,不分档");
    assert_eq!(r["as_of"], "2026-09-10");
    assert_eq!(
        r["evidence"].as_array().unwrap().len(),
        2,
        "两条命中各一条依据"
    );
}

#[test]
fn band_zero_lab_score_is_not_mild_activity() {
    let texts = [("2026-09-10", common::lab_doc("补体C3 1.20 g/L 0.90-1.80"))];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "activity_band");
    assert_eq!(r["value"], Value::Null, "0 分不是「轻度活动」");
    assert!(
        r["note"].as_str().unwrap().starts_with("化验可算部分 0/18"),
        "{r}"
    );
}

#[test]
fn lab_evidence_points_at_the_value_line_not_an_earlier_digit_match() {
    // 审查 I-2:门诊号里先出现了 88,依据必须指向化验那一行。
    let mut pkg_json: Value = serde_json::from_str(common::MINIMAL).unwrap();
    pkg_json["markers"] = serde_json::json!([{"key":"creatinine","role":"organ:kidney"}]);
    pkg_json["state_vars"] = serde_json::json!([{"key":"cr","label":"肌酐","unit":"µmol/L","derive":"latest_value","marker":"creatinine","stale_after_days":365}]);
    pkg_json["views"] = serde_json::json!({"sections":[{"kind":"state","title":"现在"},{"kind":"journey","title":"路"},{"kind":"evidence","title":"据"}]});
    let pkg: profile::Package = serde_json::from_value(pkg_json).unwrap();
    let text = "检验报告单\n姓名:李静  门诊号:PUMCH-20260301-0885\n项目 结果 单位 参考区间\n肌酐 88 μmol/L 59-104\n".to_string();
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2026-03-01")),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: None,
    }];
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: Value::Null,
    }];
    let v = serde_json::to_value(profile::materialize(&docs, &events, &pkg, day(TODAY))).unwrap();
    let e = evidence(&v, state_row(&v, "cr")["evidence"][0].as_str().unwrap());
    assert!(e["quote"].as_str().unwrap().contains("肌酐 88"), "{e}");
    let span = e["span"].as_array().unwrap();
    let (a, b) = (
        span[0].as_u64().unwrap() as usize,
        span[1].as_u64().unwrap() as usize,
    );
    assert_eq!(&text[a..b], "88");
    assert!(
        a > text.find("0885").unwrap(),
        "span 在化验行上,不在门诊号里"
    );
}

#[test]
fn unverified_lab_point_evidence_is_marked_unverified() {
    // 审查 I-3:图片模式没核上的化验点,依据页不能标已核。
    let mut pkg_json: Value = serde_json::from_str(common::MINIMAL).unwrap();
    pkg_json["markers"] = serde_json::json!([{"key":"creatinine","role":"organ:kidney"}]);
    pkg_json["state_vars"] = serde_json::json!([{"key":"cr","label":"肌酐","unit":"µmol/L","derive":"latest_value","marker":"creatinine","stale_after_days":365}]);
    pkg_json["views"] = serde_json::json!({"sections":[{"kind":"state","title":"现在"},{"kind":"journey","title":"路"},{"kind":"evidence","title":"据"}]});
    let pkg: profile::Package = serde_json::from_value(pkg_json).unwrap();
    let j = r#"{"labs":[{"name":"肌酐","value":"95","unit":"μmol/L","ref_low":"59","ref_high":"104","flag":"","unverified":true}]}"#;
    let text = "(图片档,正文为 OCR)".to_string();
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2026-08-01")),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: Some(j),
    }];
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: Value::Null,
    }];
    let v = serde_json::to_value(profile::materialize(&docs, &events, &pkg, day(TODAY))).unwrap();
    let r = state_row(&v, "cr");
    assert_eq!(r["value"], "95");
    let e = evidence(&v, r["evidence"][0].as_str().unwrap());
    assert_eq!(e["verified"], false);
    assert_eq!(
        e["span"],
        Value::Null,
        "原文里找不到的值没有 span,也不能冒充逐字"
    );
}

#[test]
fn nonsystemic_gc_does_not_become_the_current_dose_or_a_lane_node() {
    // 审查 I-5:外用激素(乳膏)不是全身用药,现行方案不算它,状态行与泳道也不能算。
    let texts = [
        (
            "2026-06-15",
            common::rx_doc("醋酸泼尼松片 7.5mg 每日一次 口服"),
        ),
        ("2026-08-01", common::rx_doc("氢化可的松乳膏 10g 外用")),
    ];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(r["value"], "7.5");
    assert_eq!(r["as_of"], "2026-06-15", "乳膏那份不能把截至日期往后拖");
    assert_eq!(evidence(&v, r["evidence"][0].as_str().unwrap())["doc"], 0);
    let l = lane(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(
        l["nodes"].as_array().unwrap().len(),
        1,
        "乳膏不进泼尼松等效泳道"
    );
}

#[test]
fn gc_lane_node_carries_drug_name_and_prednisone_equivalent() {
    // 审查 I-6:泼尼松 20mg 换成甲泼尼龙 16mg 是等效换药,不是减量 —— 节点要带药名和等效量。
    let texts = [
        (
            "2026-03-01",
            common::rx_doc("醋酸泼尼松片 20mg 每日一次 口服"),
        ),
        (
            "2026-06-01",
            common::rx_doc("甲泼尼龙片 16mg 每日一次 口服"),
        ),
    ];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let l = lane(&v, "gc_pred_equiv_mg_per_day");
    let nodes = l["nodes"].as_array().unwrap();
    assert_eq!(nodes.len(), 2);
    assert_eq!(nodes[0]["text"], "醋酸泼尼松片");
    assert_eq!(nodes[0]["equiv_mg_per_day"], 20.0);
    assert_eq!(nodes[1]["text"], "甲泼尼龙片");
    assert_eq!(nodes[1]["equiv_mg_per_day"], 20.0);
}

#[test]
fn other_drug_dose_change_gets_its_own_event_lane() {
    // 审查 I-7:吗替麦考酚酯的减量不属于任何状态变量,但不能从界面上消失。
    let text = "门诊病历\n评估:病情稳定,吗替麦考酚酯减至 0.5g 每日两次。".to_string();
    let json = r#"{"facts":[{"type":"dose_change","drug":"吗替麦考酚酯","from":"0.75g","to":"0.5g","date":"2025-09-12","evidence":"吗替麦考酚酯减至 0.5g 每日两次"}]}"#;
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2025-09-12")),
        text: &text,
        doc_type: Some("outpatient".into()),
        title: None,
        extraction_json: Some(json),
    }];
    let v = view(&docs, &enable());
    let l = lane(&v, "dose_change");
    assert_eq!(l["nodes"][0]["to"], "0.5g");
    assert_eq!(l["nodes"][0]["from"], "0.75g");
    assert_eq!(l["nodes"][0]["text"], "吗替麦考酚酯减至 0.5g 每日两次");
    assert_eq!(l["quality"], "verified");
}

#[test]
fn flare_lane_is_marked_high_severity_from_the_package() {
    let text = "门诊病历\n病情活动加重。".to_string();
    let json = r#"{"facts":[{"type":"flare","date":"2025-02-01","text":"病情活动加重","evidence":"病情活动加重"}]}"#;
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2025-02-01")),
        text: &text,
        doc_type: Some("outpatient".into()),
        title: None,
        extraction_json: Some(json),
    }];
    let v = view(&docs, &enable());
    assert_eq!(
        lane(&v, "flare")["severity"],
        "high",
        "复发标红是包说的(views.sections[timeline].severity_high)"
    );
    assert_eq!(lane(&v, "gc_pred_equiv_mg_per_day")["severity"], "normal");
}

#[test]
fn generic_hormone_alias_matches_the_whole_name_only() {
    // 审查 I-8:「激素」作 gc 别名只认整个名字就是「激素」;「雌激素」不是糖皮质激素。
    let texts = [("2026-06-15", common::rx_doc("雌激素 1mg 每日一次 口服"))];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(r["value"], Value::Null);
    assert!(r["note"].as_str().unwrap().contains("还没读到"), "{r}");
    // 光写「激素 10mg」:是 gc,但不知道哪一种,说清楚原因,不说「换算表待核」。
    let texts = [("2026-06-15", common::rx_doc("激素 10mg 每日一次"))];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(r["value"], Value::Null);
    assert!(r["note"].as_str().unwrap().contains("哪一种激素"), "{r}");
}

#[test]
fn band_is_unknown_when_no_lab_in_window() {
    let texts = [("2026-01-10", common::lab_doc("补体C3 0.60 g/L 0.90-1.80 ↓"))];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let r = state_row(&v, "activity_band");
    assert_eq!(r["value"], Value::Null, "窗口外的化验不算,也不算成 0 分");
    assert!(r["note"].as_str().unwrap().contains("10 天"), "{r}");
}

#[test]
fn latest_value_derive_reads_the_newest_marker_point() {
    // 用最小包 + 自己声明的变量:derive 是引擎级的,不绑 SLE。
    let mut pkg_json: Value = serde_json::from_str(common::MINIMAL).unwrap();
    pkg_json["markers"] = serde_json::json!([{"key":"creatinine","role":"organ:kidney"}]);
    pkg_json["state_vars"] = serde_json::json!([{"key":"cr","label":"肌酐","unit":"µmol/L","derive":"latest_value","marker":"creatinine","stale_after_days":365}]);
    pkg_json["views"] = serde_json::json!({"sections":[{"kind":"state","title":"现在"},{"kind":"journey","title":"路"},{"kind":"evidence","title":"据"}]});
    let pkg: profile::Package = serde_json::from_value(pkg_json).unwrap();
    let texts = [
        ("2026-03-01", common::lab_doc("肌酐 88 μmol/L 59-104")),
        ("2026-08-01", common::lab_doc("肌酐 95 μmol/L 59-104")),
    ];
    let docs = common::mk_docs(&texts);
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: Value::Null,
    }];
    let v = serde_json::to_value(profile::materialize(&docs, &events, &pkg, day(TODAY))).unwrap();
    let r = state_row(&v, "cr");
    assert_eq!(r["value"], "95");
    assert_eq!(r["as_of"], "2026-08-01");
    assert_eq!(r["stale"], false);
    let e = evidence(&v, r["evidence"][0].as_str().unwrap());
    assert_eq!(e["doc"], 1);
    assert!(e["quote"].as_str().unwrap().contains("肌酐 95"), "{e}");
}

#[test]
fn journey_gc_lane_has_a_node_per_dose_change_in_date_order() {
    let texts = [
        (
            "2026-06-15",
            common::rx_doc("醋酸泼尼松片 7.5mg 每日一次 口服"),
        ),
        (
            "2024-03-15",
            common::rx_doc("醋酸泼尼松片 50mg 每日一次 口服"),
        ),
        (
            "2024-09-20",
            common::rx_doc("醋酸泼尼松片 20mg 每日一次 口服"),
        ),
        (
            "2025-01-10",
            common::rx_doc("醋酸泼尼松片 20mg 每日一次 口服"),
        ),
    ];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let l = lane(&v, "gc_pred_equiv_mg_per_day");
    assert_eq!(l["quality"], "verified");
    let nodes: Vec<(&str, &str, &str)> = l["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| {
            (
                n["at"].as_str().unwrap(),
                n["from"].as_str().unwrap_or(""),
                n["to"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        nodes,
        vec![
            ("2024-03-15", "", "50mg qd"),
            ("2024-09-20", "50mg qd", "20mg qd"),
            ("2026-06-15", "20mg qd", "7.5mg qd"),
        ],
        "同剂量的重复处方不是变化,不出节点"
    );
    let first = &l["nodes"][0];
    assert_eq!(first["kind"], "first");
    assert_eq!(l["nodes"][1]["kind"], "change");
    let e = evidence(&v, first["evidence"][0].as_str().unwrap());
    assert_eq!(e["doc"], 1);
}

#[test]
fn dose_change_fact_lands_on_the_gc_lane_with_its_quote() {
    let text = "风湿免疫科门诊病历\n评估:病情稳定,激素继续缓慢减量至 10mg 每日一次,羟氯喹维持。"
        .to_string();
    let json = r#"{"facts":[{"type":"dose_change","drug":"激素","from":"","to":"10mg","date":"2025-09-12","evidence":"激素继续缓慢减量至 10mg 每日一次"}]}"#;
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2025-09-12")),
        text: &text,
        doc_type: Some("outpatient".into()),
        title: Some("门诊病历".into()),
        extraction_json: Some(json),
    }];
    let v = view(&docs, &enable());
    let l = lane(&v, "gc_pred_equiv_mg_per_day");
    let n = &l["nodes"][0];
    assert_eq!(n["kind"], "dose_change");
    assert_eq!(n["to"], "10mg");
    assert_eq!(n["at"], "2025-09-12");
    let e = evidence(&v, n["evidence"][0].as_str().unwrap());
    assert_eq!(e["quote"], "激素继续缓慢减量至 10mg 每日一次");
    assert_eq!(e["origin"], "llm");
    assert_eq!(e["verified"], true);
    let span = e["span"].as_array().unwrap();
    let (a, b) = (
        span[0].as_u64().unwrap() as usize,
        span[1].as_u64().unwrap() as usize,
    );
    assert_eq!(&text[a..b], "激素继续缓慢减量至 10mg 每日一次");
}

#[test]
fn event_facts_form_their_own_lanes_after_the_variables() {
    let text =
        "出院记录\n入院日期:2024-03-08    出院日期:2024-03-15\n出院医嘱:醋酸泼尼松片 50mg qd"
            .to_string();
    let json = r#"{"meds":[{"name":"醋酸泼尼松片","dose":"50mg","freq":"qd","route":""}],"facts":[{"type":"hospitalization","date_start":"2024-03-08","date_end":"2024-03-15","reason":"","evidence":"入院日期:2024-03-08    出院日期:2024-03-15"}]}"#;
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2024-03-15")),
        text: &text,
        doc_type: Some("discharge_summary".into()),
        title: Some("出院记录".into()),
        extraction_json: Some(json),
    }];
    let v = view(&docs, &enable());
    let lanes: Vec<&str> = section(&v, "journey")["body"]["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["key"].as_str().unwrap())
        .collect();
    let gc = lanes
        .iter()
        .position(|k| *k == "gc_pred_equiv_mg_per_day")
        .unwrap();
    let hosp = lanes.iter().position(|k| *k == "hospitalization").unwrap();
    assert!(gc < hosp, "有核过变更的变量泳道排在事件泳道前面:{lanes:?}");
    let empty = lanes.iter().position(|k| *k == "activity_band").unwrap();
    assert!(hosp < empty, "空泳道排最后:{lanes:?}");
    let h = lane(&v, "hospitalization");
    assert_eq!(h["nodes"][0]["at"], "2024-03-08");
    assert_eq!(h["nodes"][0]["to"], "2024-03-08 → 2024-03-15");
    assert_eq!(lane(&v, "activity_band")["quality"], "empty");
}

#[test]
fn unverified_fact_marks_its_lane_needs_review_and_evidence_unverified() {
    let text = "门诊病历\n(图片档,正文为 OCR)".to_string();
    let json = r#"{"facts":[{"type":"flare","date":"2025-02-01","text":"病情活动加重","evidence":"病情活动加重","unverified":true}]}"#;
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2025-02-01")),
        text: &text,
        doc_type: Some("outpatient".into()),
        title: None,
        extraction_json: Some(json),
    }];
    let v = view(&docs, &enable());
    let l = lane(&v, "flare");
    assert_eq!(l["quality"], "needs_review");
    let e = evidence(&v, l["nodes"][0]["evidence"][0].as_str().unwrap());
    assert_eq!(e["verified"], false);
    assert_eq!(e["span"], Value::Null, "原文里找不到的引文没有 span");
}

#[test]
fn evidence_ids_are_unique_and_every_citation_resolves() {
    let texts = [
        (
            "2024-09-20",
            common::rx_doc("醋酸泼尼松片 20mg 每日一次\n硫酸羟氯喹片 0.2g 每日两次"),
        ),
        ("2026-09-10", common::lab_doc("补体C3 0.60 g/L 0.90-1.80 ↓")),
    ];
    let docs = common::mk_docs(&texts);
    let v = view(&docs, &enable());
    let items = section(&v, "evidence")["body"]["items"].as_array().unwrap();
    let mut ids: Vec<&str> = items.iter().map(|e| e["id"].as_str().unwrap()).collect();
    let n = ids.len();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), n, "依据 id 不重复");
    let mut cited: Vec<&str> = Vec::new();
    for r in section(&v, "state")["body"]["vars"].as_array().unwrap() {
        cited.extend(
            r["evidence"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_str().unwrap()),
        );
    }
    for l in section(&v, "journey")["body"]["lanes"].as_array().unwrap() {
        for nd in l["nodes"].as_array().unwrap() {
            cited.extend(
                nd["evidence"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|x| x.as_str().unwrap()),
            );
        }
    }
    assert!(!cited.is_empty());
    for c in cited {
        assert!(ids.contains(&c), "{c} 没有对应的依据条目");
    }
}

#[test]
fn package_without_state_vars_emits_no_new_sections() {
    let pkg = common::minimal_pkg();
    let texts = [("2026-06-15", common::rx_doc("醋酸泼尼松片 7.5mg 每日一次"))];
    let docs = common::mk_docs(&texts);
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: Value::Null,
    }];
    let v = serde_json::to_value(profile::materialize(&docs, &events, &pkg, day(TODAY))).unwrap();
    let kinds: Vec<&str> = v["sections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["kind"].as_str().unwrap())
        .collect();
    assert!(
        !kinds.contains(&"state") && !kinds.contains(&"journey") && !kinds.contains(&"evidence"),
        "{kinds:?}"
    );
}
