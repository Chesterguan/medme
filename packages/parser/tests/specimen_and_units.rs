//! 修订 2 返工(2026-10-25):LOINC 是第一键、标本不混、截断单位并进完整单位。
use parser::{aggregate, SourceDoc};

fn doc(i: usize, date: &str, json: &str) -> SourceDoc<'static> {
    SourceDoc {
        index: i,
        date: date.parse().ok(),
        text: "",
        doc_type: Some("lab_report".into()),
        title: Some("Labs".into()),
        extraction_json: Some(Box::leak(json.to_string().into_boxed_str())),
    }
}

#[test]
fn serum_and_urine_creatinine_never_share_a_series() {
    // 血清肌酐带 LOINC(词典认得 14682-9 → creatinine);尿肌酐无码、名字带「, Ur」。
    let a = r#"{"labs":[
        {"name":"Creatinine","value":"1.1","unit":"mg/dL","ref_low":"0.6","ref_high":"1.2","flag":"","loinc":"14682-9"},
        {"name":"Creatinine, Ur","value":"85","unit":"mg/dL","ref_low":"","ref_high":"","flag":""}
    ]}"#;
    let b = r#"{"labs":[
        {"name":"Creatinine","value":"1.3","unit":"MG/DL","ref_low":"0.6","ref_high":"1.2","flag":"H","loinc":"14682-9"},
        {"name":"Creatinine, Urine","value":"97","unit":"mg/dL","ref_low":"","ref_high":"","flag":""}
    ]}"#;
    let docs = vec![doc(0, "2026-01-02", a), doc(1, "2026-03-04", b)];
    let agg = aggregate(&docs);
    let serum = agg
        .labs
        .iter()
        .find(|s| s.analyte_key.as_deref() == Some("creatinine"))
        .expect("血清肌酐序列");
    assert_eq!(
        serum.points.len(),
        2,
        "两份血清肌酐并成一条:{:?}",
        serum.points
    );
    assert!(
        serum.points.iter().all(|p| p.value < 10.0),
        "尿肌酐的 85 / 97 不许混进血清序列:{:?}",
        serum.points
    );
    assert_eq!(
        (serum.ref_low, serum.ref_high),
        (Some(0.6), Some(1.2)),
        "印刷单位只差大小写仍拿得到参考带"
    );
    let urine: Vec<_> = agg
        .labs
        .iter()
        .filter(|s| s.analyte_key.is_none() && s.group_name.to_lowercase().contains("creatinine"))
        .collect();
    assert!(
        !urine.is_empty(),
        "尿肌酐单独成序列:{:?}",
        agg.labs.iter().map(|s| &s.group_name).collect::<Vec<_>>()
    );
    assert!(parser::specimen_marker("Creatinine, Ur") == Some("尿"));
    assert!(parser::specimen_marker("Protein, UA") == Some("尿"));
    assert!(
        parser::specimen_marker("UA 尿酸 Uric Acid").is_none(),
        "单独 UA 是尿酸"
    );
    assert!(parser::specimen_marker("尿素").is_none());
    assert!(parser::specimen_ok("Urine Protein", "urine_protein"));
    assert!(!parser::specimen_ok("Urine Protein", "total_protein"));
}

#[test]
fn loinc_wins_over_name_when_dictionary_knows_the_code() {
    let a = r#"{"labs":[
        {"name":"Some odd label","value":"1.1","unit":"mg/dL","ref_low":"0.6","ref_high":"1.2","flag":"","loinc":"14682-9"}
    ]}"#;
    let docs = vec![doc(0, "2026-01-02", a)];
    let agg = aggregate(&docs);
    assert!(agg
        .labs
        .iter()
        .any(|s| s.analyte_key.as_deref() == Some("creatinine")));
}

#[test]
fn truncated_printed_unit_counts_as_the_full_unit() {
    // Epic 把 MG/DL 印成 MG/D:算同一种单位,参考带还在。
    let mk = |v: &str, u: &str| {
        format!(
            r#"{{"labs":[{{"name":"Creatinine","value":"{v}","unit":"{u}","ref_low":"0.6","ref_high":"1.2","flag":"","loinc":"14682-9"}}]}}"#
        )
    };
    let j: Vec<String> = vec![mk("1.0", "mg/dL"), mk("1.1", "MG/D"), mk("1.2", "MG/DL")];
    let docs = vec![
        doc(0, "2026-01-02", &j[0]),
        doc(1, "2026-02-02", &j[1]),
        doc(2, "2026-03-02", &j[2]),
    ];
    let agg = aggregate(&docs);
    let s = agg
        .labs
        .iter()
        .find(|s| s.analyte_key.as_deref() == Some("creatinine"))
        .unwrap();
    assert_eq!(s.points.len(), 3);
    assert_eq!((s.ref_low, s.ref_high), (Some(0.6), Some(1.2)), "{s:?}");
}
