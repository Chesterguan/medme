//! 病种包按诊断自动出现(2026-10-23 底部四 tab spec §4.4):触发词或 ICD 前缀命中才算,
//! `enable`/`disable` 事件对通用视图不再有影响。
mod common;

use common::{corpus_docs, load_jane, load_lijing, CorpusDoc};

const TODAY: &str = "2026-10-22";

fn today() -> chrono::NaiveDate {
    TODAY.parse().unwrap()
}

fn enable_sle() -> Vec<parser::ProfileEvent> {
    vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "sle".into(),
        at: "2024-03-15".into(),
        payload: serde_json::json!({}),
    }]
}

fn package_ids(view: &profile::ProfileView) -> Vec<String> {
    view.sections
        .iter()
        .filter_map(|s| s.package_id.clone())
        .filter(|p| p != "general")
        .collect()
}

/// 最后一份门诊外加一条诊断(正文一行 + 侧文件一条),其余逐字不动。
fn jane_with_extra_dx(text: &str, icd: &str) -> Vec<CorpusDoc> {
    let mut corpus = load_jane();
    let last = corpus
        .iter_mut()
        .rev()
        .find(|d| d.kind == "门诊病历")
        .expect("有门诊");
    last.text.push_str(&format!("{text} [{icd}]\n"));
    let mut sidecar: serde_json::Value = serde_json::from_str(&last.sidecar).unwrap();
    sidecar["diagnoses"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({"text": text, "icd": icd}));
    last.sidecar = sidecar.to_string();
    corpus
}

#[test]
fn sle_package_does_not_apply_to_jane_even_if_enabled() {
    let corpus = load_jane();
    let docs = corpus_docs(&corpus);
    let pkg = common::full_pkg();
    let view = profile::materialize_generic(
        &docs,
        &[],
        &enable_sle(),
        std::slice::from_ref(&pkg),
        today(),
    );
    assert!(package_ids(&view).is_empty(), "{:?}", package_ids(&view));
    assert_eq!(view.packages.len(), 1);
    assert_eq!(view.packages[0].id, "sle");
    assert_eq!(view.packages[0].family, "immune");
    assert!(!view.packages[0].applies);
}

#[test]
fn sle_package_applies_by_icd_prefix() {
    let corpus = jane_with_extra_dx("Lupus nephritis", "M32.14");
    let docs = corpus_docs(&corpus);
    let pkg = common::full_pkg();
    let view = profile::materialize_generic(&docs, &[], &[], std::slice::from_ref(&pkg), today());
    assert!(package_ids(&view).iter().any(|p| p == "sle"));
    assert!(view.packages[0].applies);
    // 通用段在前、包段在后;包段里有状态段。
    let kinds: Vec<(&str, &str)> = view
        .sections
        .iter()
        .map(|s| {
            (
                s.package_id.as_deref().unwrap_or("general"),
                s.kind.as_str(),
            )
        })
        .collect();
    assert_eq!(
        kinds[..4].iter().map(|(p, _)| *p).collect::<Vec<_>>(),
        ["general"; 4]
    );
    assert!(kinds[4..].iter().all(|(p, _)| *p == "sle"));
}

#[test]
fn icd_prefix_match_is_case_and_dot_insensitive() {
    // Epic 无点写法 `M3214` 归一后仍命中 M32。
    let corpus = jane_with_extra_dx("Lupus nephritis", "m3214");
    let docs = corpus_docs(&corpus);
    let pkg = common::full_pkg();
    let view = profile::materialize_generic(&docs, &[], &[], std::slice::from_ref(&pkg), today());
    assert!(view.packages[0].applies);
}

#[test]
fn sle_package_applies_by_diagnosis_pattern_without_icd() {
    // 李静:中文「系统性红斑狼疮」,无码、无侧文件。
    let corpus = load_lijing();
    let docs = corpus_docs(&corpus);
    let pkg = common::full_pkg();
    let view = profile::materialize_generic(&docs, &[], &[], std::slice::from_ref(&pkg), today());
    assert!(view.packages[0].applies);
    assert!(package_ids(&view).iter().any(|p| p == "sle"));
}

#[test]
fn package_applies_is_pure_and_ignores_events() {
    let corpus = load_jane();
    let docs = corpus_docs(&corpus);
    let clinical = parser::aggregate(&docs);
    let pkg = common::full_pkg();
    assert!(!profile::package_applies(&pkg, &clinical.conditions));
    let corpus = load_lijing();
    let docs = corpus_docs(&corpus);
    let clinical = parser::aggregate(&docs);
    assert!(profile::package_applies(&pkg, &clinical.conditions));
}

#[test]
fn single_package_view_has_no_packages_key() {
    // 单包路径(查看器/分享)的 JSON 形状逐字节不变:没有 `packages` 键。
    let corpus = load_lijing();
    let docs = corpus_docs(&corpus);
    let pkg = common::full_pkg();
    let view = profile::materialize(&docs, &enable_sle(), &pkg, today());
    let json = serde_json::to_value(&view).unwrap();
    assert!(json.get("packages").is_none());
}

#[test]
fn ascii_trigger_words_match_whole_words_only() {
    // 审查 C1:「SLE」不能命中 "Obstructive sleep apnea" / "Measles";中文触发词仍按子串。
    let corpus = jane_with_extra_dx("Obstructive sleep apnea", "G47.33");
    let docs = corpus_docs(&corpus);
    let pkg = common::full_pkg();
    let view = profile::materialize_generic(&docs, &[], &[], std::slice::from_ref(&pkg), today());
    assert!(!view.packages[0].applies, "sleep 不是 SLE");
    let corpus = jane_with_extra_dx("Measles", "B05.9");
    let docs = corpus_docs(&corpus);
    let view = profile::materialize_generic(&docs, &[], &[], std::slice::from_ref(&pkg), today());
    assert!(!view.packages[0].applies, "Measles 不是 SLE");
    let corpus = jane_with_extra_dx("SLE, in remission", "Z86.59");
    let docs = corpus_docs(&corpus);
    let view = profile::materialize_generic(&docs, &[], &[], std::slice::from_ref(&pkg), today());
    assert!(view.packages[0].applies, "整词 SLE 命中");
}

#[test]
fn single_package_view_gates_on_diagnosis_not_on_events() {
    let pkg = common::full_pkg();
    let corpus = load_jane();
    let docs = corpus_docs(&corpus);
    let off = profile::materialize_applied(&docs, &enable_sle(), &pkg, today());
    assert!(!off.enabled && off.sections.is_empty());
    let corpus = load_lijing();
    let docs = corpus_docs(&corpus);
    let on = profile::materialize_applied(&docs, &[], &pkg, today());
    assert!(on.enabled && !on.sections.is_empty());
    assert!(serde_json::to_value(&on).unwrap().get("packages").is_none());
}
