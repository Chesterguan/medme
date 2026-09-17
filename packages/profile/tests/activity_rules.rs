//! 每条活动度规则一个**阈值边界**用例:恰好在阈上、恰好在阈下各一次。
//! 数值全部来自 `.superpowers/sdd/disease-profile/sle-clinical-sources.md` §B.1/§B.2
//! 的 VERBATIM 行。
use chrono::NaiveDate;

mod common;
use common::{activity_pkg, lab_doc, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn score(docs: &[(&str, &str)]) -> serde_json::Value {
    let texts: Vec<String> = docs.iter().map(|(_, t)| t.to_string()).collect();
    let src: Vec<parser::SourceDoc> = docs
        .iter()
        .zip(&texts)
        .enumerate()
        .map(|(i, ((d, _), t))| parser::SourceDoc {
            index: i,
            date: Some(day(d)),
            text: t,
            doc_type: Some("lab_report".into()),
            title: None,
            extraction_json: None,
        })
        .collect();
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&src, &events, &activity_pkg(), day(TODAY));
    v.sections
        .iter()
        .find(|s| s.kind == "score_card")
        .expect("有化验就该有 score_card")
        .body
        .clone()
}

fn hit_ids(body: &serde_json::Value) -> Vec<String> {
    body["hits"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["id"].as_str().unwrap().into())
        .collect()
}

#[test]
fn leukopenia_boundary_is_strictly_below_three() {
    // VERBATIM:「< 3,000 white blood cells / x10⁹/L」→ 实现为 WBC < 3.0 ×10⁹/L。
    let b = score(&[(TODAY, &lab_doc("白细胞 2.9 10^9/L 3.5-9.5"))]);
    assert!(hit_ids(&b).contains(&"leukopenia".to_string()));
    assert_eq!(b["score"], 1);

    let b = score(&[(TODAY, &lab_doc("白细胞 3.0 10^9/L 3.5-9.5"))]);
    assert!(
        !hit_ids(&b).contains(&"leukopenia".to_string()),
        "恰好 3.0 不计分"
    );
}

#[test]
fn thrombocytopenia_boundary_is_strictly_below_one_hundred() {
    let b = score(&[(TODAY, &lab_doc("血小板 99 10^9/L 125-350"))]);
    assert_eq!(b["score"], 1);
    let b = score(&[(TODAY, &lab_doc("血小板 100 10^9/L 125-350"))]);
    assert_eq!(b["score"], 0);
}

#[test]
fn proteinuria_boundary_is_strictly_above_half_a_gram_per_day() {
    // VERBATIM:「>0.5 gram/24 hours」,权重 4。词典 canonical 是 mg/24h。
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.51 g/24h"))]);
    assert_eq!(b["score"], 4);
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.50 g/24h"))]);
    assert_eq!(b["score"], 0, "恰好 0.5 g/24h 不计分");
}

#[test]
fn upcr_never_scores_it_is_display_only() {
    // spec §5.2:UPCR 不能替代 24h 尿蛋白计分,只单独展示。
    let b = score(&[(TODAY, &lab_doc("尿蛋白肌酐比 1200 mg/g"))]);
    assert_eq!(b["score"], 0);
    assert!(!hit_ids(&b).contains(&"proteinuria".to_string()));
}

#[test]
fn low_complement_uses_the_reports_own_lower_limit_not_a_fixed_number() {
    // VERBATIM:「below the lower limit of normal for testing laboratory」。
    // 同一个 0.85 g/L,在下限 0.9 的医院算低,在下限 0.8 的医院不算。
    let b = score(&[(TODAY, &lab_doc("补体C3 0.85 g/L 0.9-1.8"))]);
    assert_eq!(b["score"], 2);
    let b = score(&[(TODAY, &lab_doc("补体C3 0.85 g/L 0.8-1.8"))]);
    assert_eq!(b["score"], 0);
}

#[test]
fn low_complement_scores_only_once_even_when_c3_and_c4_are_both_low() {
    // 一条描述符 = 一次 2 分(CH50/C3/C4 是同一条 "Low complement")。
    let b = score(&[(
        TODAY,
        &lab_doc("补体C3 0.4 g/L 0.9-1.8\n补体C4 0.05 g/L 0.1-0.4"),
    )]);
    assert_eq!(b["score"], 2);
}

#[test]
fn a_result_older_than_the_window_does_not_score() {
    // VERBATIM:「present at the time of the visit or in the preceding 10 days」。
    let b = score(&[("2026-09-05", &lab_doc("白细胞 2.0 10^9/L 3.5-9.5"))]); // 11 天前
    assert_eq!(b["score"], 0);
    let b = score(&[("2026-09-06", &lab_doc("白细胞 2.0 10^9/L 3.5-9.5"))]); // 10 天前
    assert_eq!(b["score"], 1);
}

#[test]
fn casts_are_detected_from_the_report_text_not_from_a_number() {
    let b = score(&[(TODAY, &lab_doc("尿沉渣:可见红细胞管型"))]);
    assert!(hit_ids(&b).contains(&"casts".to_string()));
    assert_eq!(b["score"], 4);
}

#[test]
fn the_score_is_labelled_as_the_lab_computable_part_and_capped_at_eighteen() {
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    assert_eq!(b["max"], 18);
    assert_eq!(b["label"], "化验可算部分");
    assert_eq!(b["window_days"], 10);
    // 界面不许把它说成 SLEDAI 总分。
    let s = serde_json::to_string(&b).unwrap();
    assert!(!s.contains("SLEDAI 总分"));
}

#[test]
fn every_hit_carries_its_source_id_and_the_reports_it_used() {
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    let h = &b["hits"][0];
    assert_eq!(h["source"], "S1");
    assert_eq!(h["evidence"][0]["document_index"], 0);
    assert_eq!(h["evidence"][0]["analyte"], "complement_c3");
}

#[test]
fn a_qualitative_positive_dsdna_scores_but_is_flagged_as_a_deviation() {
    // §B.2:表格写的是 Farr 法;中国实验室多用 ELISA/CLIFT,定性「阳性」也计分,
    // 但必须标出偏差 —— 不标就是把一个方法学差异藏起来。
    let extraction = r#"{"labs":[{"name":"抗双链DNA抗体","value":"阳性","unit":"","ref_low":"","ref_high":"","flag":""}],"facts":[]}"#;
    let text = lab_doc("抗双链DNA抗体 阳性");
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day(TODAY)),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: Some(extraction),
    }];
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&docs, &events, &activity_pkg(), day(TODAY));
    let b = &v
        .sections
        .iter()
        .find(|s| s.kind == "score_card")
        .unwrap()
        .body;
    assert_eq!(b["score"], 2);
    assert!(b["hits"][0]["caveat"].as_str().unwrap().contains("Farr"));
}

#[test]
fn a_descriptor_with_nothing_to_read_is_listed_unscored_never_as_a_clean_miss() {
    // 「算过了、没达到」和「这次算不出来」是两回事:窗口里只有一张血常规时,
    // 补体那条既不是 ✔ 也不是 ✘,是未知 —— 混成 0 分就等于替医生说「补体正常」。
    let b = score(&[(TODAY, &lab_doc("白细胞 5.0 10^9/L 3.5-9.5"))]);
    let unscored: Vec<String> = b["unscored"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| u["id"].as_str().unwrap().into())
        .collect();
    assert_eq!(b["score"], 0);
    assert!(hit_ids(&b).is_empty());
    // 没做的:未知。
    assert!(unscored.contains(&"low_complement".to_string()));
    assert!(unscored.contains(&"thrombocytopenia".to_string()));
    // 做了、正常的:✘ —— 既不计分,也不叫未知。
    assert!(
        !unscored.contains(&"leukopenia".to_string()),
        "白细胞这次是真算过了"
    );
    for u in b["unscored"].as_array().unwrap() {
        assert!(
            !u["reason"].as_str().unwrap().is_empty(),
            "每条未知都要说清为什么算不出来"
        );
    }
}
