//! 包**自己定义**的分析物,阈值也要能换算 —— 否则「加病不发版」在规则那一侧是缺一块的:
//! 包按源行单位逐字写阈值(global-constraints:包里每个数值都带出处 id),分析物又是包
//! 自带的,`threshold_in` 查不到它就返回 `None`,那条规则**静默**按「未知」出。
//!
//! 独占一个测试二进制:`terminology::set_overlay` 是进程级全局状态,这里前后两段
//! (不装包 / 装包)必须按顺序跑。
mod common;
use chrono::NaiveDate;
use common::{lab_doc, TODAY};

/// 抗 C1q 抗体:内置词典没有。`U/L → U/mL` 的 0.001 是纯单位代数(1 U/L = 0.001 U/mL),
/// 不是临床系数。包把阈值按**源行单位** U/L 写成 20,序列的规范单位是 U/mL —— 这一步
/// 换算正是本用例要钉的。
const PKG: &str = r#"{"manifest":{"id":"t","family":"immune","version":"2026.09.1","min_engine":1,
  "display":{"name":"测试病","short":"测试"},"disclaimer":"仅整理你的病历,不做诊断",
  "sources":[{"id":"S1","cite":"test","url":null}]},
  "triggers":{"diagnosis_patterns":[],"serology_any_two":[]},
  "terms":{"aliases":{},"analytes":[
    {"key":"anti_c1q","name":"抗C1q抗体","panel":"风湿免疫","canonical_unit":"U/mL",
     "units":[{"unit":"U/L","slope":0.001,"intercept":0}],"aliases":["抗C1q抗体"]}]},
  "markers":[],"drugs":[],
  "rules":{"activity":{"window_days":10,"max":4,"items":[
    {"id":"anti_c1q_high","label":"抗C1q升高","weight":4,"kind":"gt","key":"anti_c1q",
     "threshold":20,"threshold_unit":"U/L","source":"S1"}]},
   "states":[],"monitoring":[],"milestones":[]},
  "views":{"sections":[],"handoff":[]}}"#;

/// 包的 `terms.analytes` 那一条,转成覆盖层条目 —— Task 20 的 FFI 要做的就是这个转换。
fn overlay_entry() -> terminology::Entry {
    serde_json::from_value(serde_json::json!({
        "key": "anti_c1q", "canonical_name": "抗C1q抗体", "category": "lab",
        "system": "serum/plasma", "panel": "风湿免疫", "codes": {}, "canonical_unit": "U/mL",
        "units": [{"unit": "U/mL", "slope": 1.0, "intercept": 0.0},
                  {"unit": "U/L", "slope": 0.001, "intercept": 0.0}],
        "aliases": ["抗C1q抗体"]
    }))
    .expect("夹具条目必须解析")
}

fn day(s: &str) -> NaiveDate {
    s.parse().expect("测试里的日期必须是 YYYY-MM-DD")
}

/// 一份只有抗 C1q 一行的报告 → `score_card` 的 body。
fn score(row: &str) -> serde_json::Value {
    let pkg: profile::Package = serde_json::from_str(PKG).expect("夹具包必须解析");
    let text = lab_doc(row);
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day(TODAY)),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: None,
    }];
    let ev = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    profile::materialize(&docs, &ev, &pkg, day(TODAY))
        .sections
        .into_iter()
        .find(|s| s.kind == "score_card")
        .expect("有化验就该有 score_card")
        .body
}

fn ids(body: &serde_json::Value, array: &str) -> Vec<String> {
    body[array]
        .as_array()
        .unwrap_or_else(|| panic!("body 里要有 {array} 数组"))
        .iter()
        .map(|h| h["id"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[test]
fn a_package_defined_analytes_threshold_converts_through_the_overlay() {
    // ① 不装包:这一项连认都认不出来,如实进 unscored,一分不给(fail-safe)。
    terminology::set_overlay(vec![]);
    let b = score("抗C1q抗体 100 U/L 0-20");
    assert_eq!(b["score"], 0);
    assert!(
        ids(&b, "unscored").contains(&"anti_c1q_high".to_string()),
        "覆盖层没装,这一项只能是未知"
    );

    // ② 装上包:阈值 20 U/L 换算到序列的规范单位 = 0.02 U/mL,100 U/L = 0.1 U/mL,过阈。
    terminology::set_overlay(vec![overlay_entry()]);
    let b = score("抗C1q抗体 100 U/L 0-20");
    assert!(
        ids(&b, "hits").contains(&"anti_c1q_high".to_string()),
        "包自带的分析物,阈值也要能换算"
    );
    assert_eq!(b["score"], 4);

    // ③ 阈下的那一档要真的比过了(✘,不是未知)—— 证明比的是换算后的数,
    //    不是「谁都算命中」。10 U/L = 0.01 U/mL < 0.02。
    let b = score("抗C1q抗体 10 U/L 0-20");
    assert_eq!(b["score"], 0);
    assert!(ids(&b, "missed").contains(&"anti_c1q_high".to_string()));
    assert!(!ids(&b, "unscored").contains(&"anti_c1q_high".to_string()));

    terminology::set_overlay(vec![]);
}
