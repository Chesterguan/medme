//! 覆盖层加的分析物必须一路走到 `aggregate` 的序列里,**含单位换算** —— 否则
//! 「加病不发版」只是加了个名字,画不出线。
//!
//! 这个用例改的是**进程级**全局状态(`terminology::set_overlay`),所以它独占一个
//! 测试二进制:同文件里再加用例就要跟着上串行锁。
use std::sync::Mutex;

static SERIAL: Mutex<()> = Mutex::new(());

#[test]
fn an_overlay_analyte_becomes_a_real_series_with_canonical_values() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    // `U/L → U/mL` 的 0.001 是纯单位代数(1 U/L = 0.001 U/mL),不是临床换算。
    let ch50: terminology::Entry = serde_json::from_value(serde_json::json!({
        "key": "ch50", "canonical_name": "总补体溶血活性", "category": "lab",
        "system": "serum/plasma", "panel": "风湿免疫", "codes": {}, "canonical_unit": "U/mL",
        "units": [{"unit": "U/mL", "slope": 1.0, "intercept": 0.0},
                  {"unit": "U/L", "slope": 0.001, "intercept": 0.0}],
        "aliases": ["总补体溶血活性", "CH50"]
    }))
    .expect("夹具条目必须解析");
    terminology::set_overlay(vec![ch50]);

    let text = "检验报告单\n总补体溶血活性 100 U/L 23-46\n";
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: "2026-09-01".parse().ok(),
        text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: None,
    }];
    let out = parser::aggregate(&docs);
    let s = out
        .labs
        .iter()
        .find(|s| s.analyte_key.as_deref() == Some("ch50"))
        .expect("覆盖层分析物要变成序列");
    assert_eq!(s.unit_canonical.as_deref(), Some("U/mL"));
    let v = s.points[0].value_canonical.expect("规范值要换算得出来");
    assert!((v - 0.1).abs() < 1e-9, "100 U/L = 0.1 U/mL,实际 {v}");
    terminology::set_overlay(vec![]);
}
