//! 趋势(`series_chart`)与时间轴(`timeline`)两块 section。
//!
//! 两条硬规矩在这里各有一组用例钉着:**各院参考区间用各自单子上印的那对数**、
//! **UPCR 与 24h 尿蛋白永远是两条线**。
use chrono::NaiveDate;
mod common;
use common::{full_json, full_pkg, lab_doc, mk_docs, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().expect("测试里的日期必须是 YYYY-MM-DD")
}

fn sections_of<'a>(
    pkg: &profile::Package,
    docs: &'a [(&str, String)],
    ex: Option<&'a str>,
) -> Vec<profile::Section> {
    let mut src = mk_docs(docs);
    if let Some(j) = ex {
        src[0].extraction_json = Some(j);
    }
    let ev = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    profile::materialize(&src, &ev, pkg, day(TODAY)).sections
}

fn sections<'a>(docs: &'a [(&str, String)], ex: Option<&'a str>) -> Vec<profile::Section> {
    sections_of(&full_pkg(), docs, ex)
}

fn section<'s>(secs: &'s [profile::Section], kind: &str) -> &'s profile::Section {
    secs.iter()
        .find(|s| s.kind == kind)
        .unwrap_or_else(|| panic!("有 {kind}"))
}

fn body(secs: &[profile::Section], kind: &str) -> serde_json::Value {
    section(secs, kind).body.clone()
}

/// 所有分组里的全部序列,按出现顺序拍平。
fn all_series(b: &serde_json::Value) -> Vec<serde_json::Value> {
    b["groups"]
        .as_array()
        .expect("groups 是数组")
        .iter()
        .flat_map(|g| g["series"].as_array().expect("series 是数组").clone())
        .collect()
}

fn one_series(b: &serde_json::Value, key: &str) -> serde_json::Value {
    all_series(b)
        .into_iter()
        .find(|s| s["analyte_key"] == key)
        .unwrap_or_else(|| panic!("有 {key} 这条线"))
}

fn keys(b: &serde_json::Value) -> Vec<String> {
    all_series(b)
        .iter()
        .map(|s| s["analyte_key"].as_str().unwrap_or_default().to_string())
        .collect()
}

fn missing_keys(b: &serde_json::Value) -> Vec<String> {
    b["missing"]
        .as_array()
        .expect("missing 是数组")
        .iter()
        .map(|m| m["key"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[test]
fn each_series_keeps_the_reference_range_printed_on_its_own_report() {
    // 硬规矩:各院参考区间用各自单子的。把它换成指南目标值,用户拿手里那张纸
    // 一对就对不上,而且「正常/异常」的判定会跟着医院变 —— 那是医院的事实。
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], None);
    let g = body(&s, "series_chart");
    let one = &g["groups"][0]["series"][0];
    assert_eq!(one["analyte_key"], "complement_c3");
    assert_eq!(one["ref_low"], 0.9);
    assert_eq!(one["ref_high"], 1.8);
    // 值与单位是纸上印的那一对(与 Task 11 的 `Evidence` 同一条约定)。
    assert_eq!(one["unit"], "g/L");
    assert_eq!(one["points"][0]["value"], 0.4);
    assert_eq!(one["points"][0]["flag"], "L");
    assert_eq!(one["points"][0]["document_index"], 0);
}

#[test]
fn upcr_and_twenty_four_hour_protein_are_two_separate_lines() {
    // §11 已知边界:UPCR ≠ 24h 尿蛋白。画成一条线是把两个不同的量当成同一个。
    //
    // Task 15 写这条时 `urine_pcr` 还不在内置词典里 —— 「尿蛋白肌酐比」按 1 字编辑
    // 距离被模糊配成了 `urine_acr`(尿**白**蛋白/肌酐比,另一个化验),UPCR 只能进
    // `missing`,用例也就只钉得住「那个没有发生的合并」。词典补上 `urine_pcr` 之后
    // (terminology 的 `upcr_is_its_own_concept_and_never_lands_on_acr`),两条线的
    // 断言才加得回来。
    let s = sections(
        &[(
            TODAY,
            lab_doc("尿蛋白肌酐比 1200 mg/g\n24小时尿蛋白定量 1.1 g/24h"),
        )],
        None,
    );
    let g = body(&s, "series_chart");
    assert!(keys(&g).contains(&"urine_pcr".to_string()));
    assert!(keys(&g).contains(&"urine_protein_24h".to_string()));
    assert!(
        !missing_keys(&g).contains(&"urine_pcr".to_string()),
        "UPCR 已经有自己的序列了,不该还挂在 missing 里"
    );
    let pcr = one_series(&g, "urine_pcr");
    assert_eq!(
        pcr["points"].as_array().expect("points 是数组").len(),
        1,
        "UPCR 那条线上只有 UPCR 那一个点"
    );
    assert_eq!(pcr["points"][0]["value"], 1200.0);
    let p24 = one_series(&g, "urine_protein_24h");
    assert_eq!(
        p24["points"].as_array().expect("points 是数组").len(),
        1,
        "24h 那条线上只有 24h 自己的点"
    );
    assert_eq!(p24["points"][0]["value"], 1.1);
}

#[test]
fn an_unverified_point_stays_flagged_all_the_way_out() {
    let ex = r#"{"labs":[{"name":"补体C3","value":"0.4","unit":"g/L","ref_low":"0.9",
                 "ref_high":"1.8","flag":"","unverified":true}],"facts":[]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let one = &body(&s, "series_chart")["groups"][0]["series"][0];
    assert_eq!(one["needs_review_count"], 1);
    assert_eq!(one["points"][0]["unverified"], true);
}

#[test]
fn a_marker_with_no_data_is_listed_as_missing_not_silently_dropped() {
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], None);
    let g = body(&s, "series_chart");
    assert!(
        missing_keys(&g).contains(&"anti_dsdna".to_string()),
        "包里点了名却一次都没查过要说出来"
    );
    // 词典认得的 key 带上中文名,渲染层不必自己去查(认不得的给 null,不编)。
    let dsdna = g["missing"]
        .as_array()
        .expect("missing 是数组")
        .iter()
        .find(|m| m["key"] == "anti_dsdna")
        .expect("有 anti_dsdna")
        .clone();
    assert_eq!(dsdna["name"], "抗双链DNA抗体");
    // 一条 fact、一条医嘱都没有的保险箱,时间轴折叠成一行。
    assert!(section(&s, "timeline").empty_hint.is_some());
}

#[test]
fn the_timeline_groups_facts_by_year_and_marks_flares() {
    let ex = r#"{"labs":[],"facts":[
        {"type":"flare","date":"2024-03-02","text":"病情活动加重","evidence":"病情活动加重"},
        {"type":"biopsy","organ":"kidney","date":"2024-03-10","result":"ISN/RPS IV 型",
         "evidence":"ISN/RPS IV 型"},
        {"type":"infusion","drug":"贝利尤单抗","dose":"400mg","date":"2026-08-01",
         "evidence":"贝利尤单抗 400mg"}]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let t = body(&s, "timeline");
    let years = t["years"].as_array().expect("years 是数组").clone();
    let y2024 = years
        .iter()
        .find(|y| y["year"] == 2024)
        .expect("2024 那一年");
    assert_eq!(y2024["events"].as_array().expect("events 是数组").len(), 2);
    let flare = y2024["events"][0].clone();
    assert_eq!(flare["type"], "flare");
    assert_eq!(flare["severity"], "high", "复发标红");
    assert_eq!(flare["text"], "病情活动加重", "原文逐字,不改写");
    assert_eq!(flare["document_index"], 0);
    // 年内按日期升序:活检(03-10)排在复发(03-02)后面。
    assert_eq!(y2024["events"][1]["type"], "biopsy");
    // 自己没有 `text` 的类型退回 `evidence`(同样是原文逐字),不合成一句话。
    assert_eq!(y2024["events"][1]["text"], "ISN/RPS IV 型");
    assert!(years.iter().any(|y| y["year"] == 2026));
    assert!(section(&s, "timeline").empty_hint.is_none());
}

#[test]
fn a_fact_without_its_own_date_falls_back_to_the_document_date() {
    let ex = r#"{"labs":[],"facts":[{"type":"infection","date":"","text":"带状疱疹",
                 "evidence":"带状疱疹"}]}"#;
    let s = sections(
        &[("2025-06-01", lab_doc("补体C3 0.4 g/L 0.9-1.8"))],
        Some(ex),
    );
    let years = body(&s, "timeline")["years"]
        .as_array()
        .expect("years 是数组")
        .clone();
    assert!(years.iter().any(|y| y["year"] == 2025));
}

#[test]
fn a_hospitalization_lands_on_the_year_its_admission_date_says() {
    // 住院那一类的 schema 里**没有** `date`,只有 `date_start`/`date_end`
    // (`extract_v2_system.txt`)。只认 `date` 的话,每一次住院都会退回文档日期 ——
    // 一份 2026 年的出院小结会把 2023 年那次住院画在 2026 年那一格。
    let ex = r#"{"labs":[],"facts":[{"type":"hospitalization","date_start":"2023-04-05",
                 "date_end":"2023-04-20","reason":"狼疮肾炎","evidence":"因狼疮肾炎住院"}]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let years = body(&s, "timeline")["years"]
        .as_array()
        .expect("years 是数组")
        .clone();
    let y = years
        .iter()
        .find(|y| y["year"] == 2023)
        .expect("2023 那一年");
    assert_eq!(y["events"][0]["type"], "hospitalization");
    assert_eq!(y["events"][0]["date"], "2023-04-05");
    assert!(
        !years.iter().any(|y| y["year"] == 2026),
        "不许退回文档日期,那次住院不在 2026 年"
    );
}

#[test]
fn a_fact_with_no_date_anywhere_goes_to_its_own_list_not_the_bin() {
    // 文档也没日期时不许丢:丢掉的那条住院记录,用户永远不会知道它没显示。
    let ex = r#"{"labs":[],"facts":[{"type":"hospitalization","date_start":"","date_end":"",
                 "reason":"狼疮肾炎","evidence":"因狼疮肾炎住院"}]}"#;
    let s = sections(&[("", lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let t = body(&s, "timeline");
    assert!(t["years"].as_array().expect("years 是数组").is_empty());
    let undated = t["undated"].as_array().expect("undated 是数组").clone();
    assert_eq!(undated.len(), 1);
    assert_eq!(undated[0]["type"], "hospitalization");
    assert_eq!(undated[0]["text"], "因狼疮肾炎住院");
}

#[test]
fn an_unverified_fact_stays_on_the_timeline_and_says_so() {
    let ex = r#"{"labs":[],"facts":[{"type":"flare","date":"2026-05-01","text":"复发",
                 "evidence":"复发","unverified":true}]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let years = body(&s, "timeline")["years"]
        .as_array()
        .expect("years 是数组")
        .clone();
    let e = years
        .iter()
        .find(|y| y["year"] == 2026)
        .expect("2026 那一年")["events"][0]
        .clone();
    assert_eq!(e["unverified"], true, "核不实的事实要标出来,不是删掉");
}

#[test]
fn severity_comes_from_the_package_not_from_the_engine() {
    // 「复发标红」是包说的,不是引擎自己认定的临床判断:包里不写,谁都不红。
    let ex = r#"{"labs":[],"facts":[
        {"type":"flare","date":"2026-05-01","text":"复发","evidence":"复发"},
        {"type":"infusion","drug":"贝利尤单抗","date":"2026-05-02","evidence":"贝利尤单抗"}]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let evs = body(&s, "timeline")["years"][0]["events"].clone();
    assert_eq!(evs[0]["severity"], "high");
    assert_eq!(evs[1]["severity"], "normal", "包里没点名的类型不许自己标红");

    let mut v = full_json();
    v["views"]["sections"] = serde_json::Value::Array(
        v["views"]["sections"]
            .as_array()
            .expect("views.sections 是数组")
            .iter()
            .filter(|x| x["kind"] != "timeline")
            .cloned()
            .collect(),
    );
    let bare: profile::Package = serde_json::from_value(v).expect("改过的夹具包必须解析");
    let s = sections_of(
        &bare,
        &[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))],
        Some(ex),
    );
    let evs = body(&s, "timeline")["years"][0]["events"].clone();
    assert_eq!(evs[0]["severity"], "normal", "包没说红,引擎就不红");
}

#[test]
fn a_future_dated_point_is_counted_out_loud_not_charted() {
    // OCR 把 2026 读成 2026-12 的单子不该在趋势图上画出一段未来的「趋势」;
    // 但它也不许无声消失 —— 数出来,让渲染层说「有 1 个点的日期在今天之后」。
    let s = sections(
        &[
            (TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8")),
            ("2026-12-31", lab_doc("补体C3 0.6 g/L 0.9-1.8")),
        ],
        None,
    );
    let one = one_series(&body(&s, "series_chart"), "complement_c3");
    assert_eq!(one["points"].as_array().expect("points 是数组").len(), 1);
    assert_eq!(one["future_points"], 1);
}

#[test]
fn an_undated_point_goes_to_its_own_list() {
    let s = sections(
        &[
            ("", lab_doc("补体C3 0.5 g/L 0.9-1.8")),
            (TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8")),
        ],
        None,
    );
    let one = one_series(&body(&s, "series_chart"), "complement_c3");
    assert_eq!(one["points"].as_array().expect("points 是数组").len(), 1);
    let undated = one["undated"].as_array().expect("undated 是数组").clone();
    assert_eq!(undated.len(), 1);
    assert_eq!(undated[0]["value"], 0.5);
    assert!(undated[0]["date"].is_null());
}

#[test]
fn a_mixed_unit_series_says_the_values_were_converted() {
    // `parser` 把整条线统一换算过之后,纸上找不到这个数 —— 与 Task 11 的 `Evidence`
    // 同一条约定,这面旗必须原样传到渲染层。
    let s = sections(
        &[
            ("2026-09-01", lab_doc("补体C3 0.4 g/L 0.9-1.8")),
            ("2026-09-10", lab_doc("补体C3 40 mg/dL 90-180")),
        ],
        None,
    );
    let one = one_series(&body(&s, "series_chart"), "complement_c3");
    assert_eq!(one["values_converted"], true);
    assert_eq!(one["unit"], "g/L");
}

#[test]
fn a_qualitative_only_marker_keeps_the_printed_words() {
    // 抗 dsDNA 报「阳性」的单子解析不出数值,整行在 `aggregate` 那层就没了。
    // `qualitative_ok` 的指标要从抽取结果的原始行里把那句话原样带出来。
    let ex = r#"{"labs":[{"name":"抗dsDNA抗体","value":"阳性","unit":"","ref_low":"",
                 "ref_high":"","flag":"","unverified":false}],"facts":[]}"#;
    let s = sections(&[(TODAY, lab_doc("抗dsDNA抗体 阳性"))], Some(ex));
    let g = body(&s, "series_chart");
    assert!(
        !missing_keys(&g).contains(&"anti_dsdna".to_string()),
        "定性结果也是结果,不算「一次都没查过」"
    );
    let one = one_series(&g, "anti_dsdna");
    assert_eq!(one["qualitative"][0]["value"], "阳性");
    assert_eq!(one["qualitative"][0]["date"], TODAY);
    assert_eq!(one["qualitative"][0]["document_index"], 0);
    assert!(one["points"].as_array().expect("points 是数组").is_empty());
}

#[test]
fn a_future_dated_qualitative_result_is_not_called_never_tested() {
    // 唯一那次定性结果的日期在今天之后(OCR 读错年份):它不画,但**查过就是查过**。
    // 落进 `missing`(「包里点了名却一次都没查过」)是一句不实的话。
    let ex = r#"{"labs":[{"name":"抗dsDNA抗体","value":"阳性","unit":"","ref_low":"",
                 "ref_high":"","flag":"","unverified":false}],"facts":[]}"#;
    let s = sections(&[("2027-01-05", lab_doc("抗dsDNA抗体 阳性"))], Some(ex));
    let g = body(&s, "series_chart");
    assert!(
        !missing_keys(&g).contains(&"anti_dsdna".to_string()),
        "查过了,只是日期在今天之后 —— 不是「一次都没查过」"
    );
    let one = one_series(&g, "anti_dsdna");
    assert_eq!(one["future_points"], 1);
    assert!(one["qualitative"]
        .as_array()
        .expect("qualitative 是数组")
        .is_empty());
    assert!(one["points"].as_array().expect("points 是数组").is_empty());
}
