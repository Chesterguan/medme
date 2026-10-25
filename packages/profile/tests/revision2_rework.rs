//! 修订 2 返工(2026-10-25):过敏原按物质合并、诊断写法清洗、侧文件起始日、摘要文档不开剂量链。
mod common;

use common::mk_docs;

const TODAY: &str = "2026-10-25";

fn meds_json(docs: &[parser::SourceDoc<'_>]) -> serde_json::Value {
    serde_json::to_value(profile::materialize_meds(docs, &[], TODAY.parse().unwrap())).unwrap()
}

#[test]
fn allergies_merge_by_allergen_across_spellings_and_annotations() {
    let docs = [
        (
            "2026-01-02",
            "Allergies\nAllergen   Reactions\n • Penicillins [PENICILLIN G] (See Comments)   Rash\n\n"
                .to_string(),
        ),
        (
            "2026-02-02",
            "Allergies\nAllergen   Reactions\n • PENICILLINS   Hives\n\n".to_string(),
        ),
        ("2026-03-02", "Allergies: penicillins\n".to_string()),
    ];
    let v = meds_json(&mk_docs(&docs));
    let al = v["allergies"].as_array().unwrap();
    assert_eq!(al.len(), 1, "三种写法一个过敏原:{al:?}");
    assert!(al[0]["substance"]
        .as_str()
        .unwrap()
        .to_lowercase()
        .contains("penicillin"));
    assert_eq!(al[0]["reaction"], "皮疹、荨麻疹");
    assert_eq!(al[0]["evidence"].as_array().unwrap().len(), 3);
    assert_eq!(al[0]["aliases"].as_array().unwrap().len(), 3);
    assert_eq!(
        profile::allergen_display("Penicillins [PENICILLIN G] (See Comments)"),
        "Penicillins"
    );
}

#[test]
fn diagnosis_variants_are_cleaned_and_deduped() {
    assert_eq!(
        profile::clean_dx_text("Atrial fibrillation (CMS-HCC: 108)"),
        "Atrial fibrillation"
    );
    assert_eq!(
        profile::clean_dx_text("Heart failure (HCC)"),
        "Heart failure"
    );
    assert_eq!(
        profile::clean_dx_text("Preop Dx: Aortic stenosis"),
        "Aortic stenosis"
    );
    assert_eq!(
        profile::clean_dx_text("Preoperative Diagnosis: Aortic stenosis"),
        "Aortic stenosis"
    );
}

#[test]
fn sidecar_start_date_sets_since_and_summary_docs_do_not_open_a_run() {
    let summary = r#"{"doc_type":"other","meds":[{"name":"Warfarin","dose":"5mg","freq":"qd","start":"2024-03-01"}],"labs":[],"diagnoses":[]}"#;
    let visit = r#"{"doc_type":"clinical_note","meds":[{"name":"Warfarin","dose":"5mg","freq":"qd"}],"labs":[],"diagnoses":[]}"#;
    let docs = vec![
        parser::SourceDoc {
            index: 0,
            date: "2026-10-20".parse().ok(),
            text: "Current Medications\nWarfarin 5mg qd\n",
            doc_type: Some("other".into()),
            title: Some("Patient Summary".into()),
            extraction_json: Some(summary),
        },
        parser::SourceDoc {
            index: 1,
            date: "2026-09-01".parse().ok(),
            text: "Warfarin 5mg qd\n",
            doc_type: Some("clinical_note".into()),
            title: Some("Visit".into()),
            extraction_json: Some(visit),
        },
    ];
    let v = meds_json(&docs);
    let w = v["recent"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == "华法林")
        .expect("华法林最近有记录");
    assert_eq!(w["since"], "2024-03-01", "侧文件起始日优先:{w}");
    assert_eq!(w["last_seen"], "2026-10-20", "摘要文档仍算最近有记录");
    assert_eq!(w["mention_count"], 2);
    let nodes = w["nodes"].as_array().unwrap();
    assert!(
        nodes.iter().all(|n| n["at"] != "2026-10-20"),
        "摘要文档不开剂量链:{nodes:?}"
    );
    assert!(w["atc"].is_string() || w["atc"].is_null());
}

/// checkpoint 1 F12:过敏按词根归并,显示中文 + 最短写法,反应译成中文,写法数单算。
#[test]
fn allergens_merge_by_root_word_and_bracket_ingredient() {
    let docs = [
        (
            "2026-01-02",
            "Allergies\nAllergen   Reactions\n • Shellfish Allergy   Itching\n • Seasonal Ic [Octacosanol]   Other\n\n".to_string(),
        ),
        (
            "2026-02-02",
            "Allergies\nAllergen   Reactions\n • Shellfish-Derived Products   Itching\n • SEASONAL IC [OCTACOSANOL]   Other\n\n".to_string(),
        ),
        (
            "2026-03-02",
            "Allergies\nAllergen   Reactions\n • SHELLFISH PROTEIN-CONTAINING DRUG PRODUCTS   Itching\n\n".to_string(),
        ),
    ];
    let v = meds_json(&mk_docs(&docs));
    let al = v["allergies"].as_array().unwrap();
    assert_eq!(al.len(), 2, "贝类三种写法 + 二十八烷醇两种写法:{al:?}");
    let shell = al
        .iter()
        .find(|a| a["substance"].as_str().unwrap().contains("贝类"))
        .expect("贝类");
    assert_eq!(shell["substance"], "贝类(Shellfish Allergy)");
    assert_eq!(shell["reaction"], "瘙痒");
    assert_eq!(shell["spellings"], 3);
    assert_eq!(shell["evidence"].as_array().unwrap().len(), 3);
    let oct = al
        .iter()
        .find(|a| a["substance"].as_str().unwrap().contains("二十八烷醇"))
        .expect("二十八烷醇");
    assert_eq!(oct["reaction"], "其他");
    assert_eq!(oct["spellings"], 1, "只差大小写算同一种写法");
    assert_eq!(
        profile::allergen_key("Bactrim Ds [Sulfamethoxazole-Trimethoprim]"),
        "sulfamethoxazole"
    );
    assert_eq!(profile::allergen_key("Penicillins"), "penicillin");
}

/// checkpoint 1 F11:护理医嘱不算用药。
#[test]
fn nursing_orders_are_not_meds() {
    assert!(profile::is_nursing_order("CHG Treatment"));
    assert!(profile::is_nursing_order("Chlorhexidine bath"));
    assert!(!profile::is_nursing_order("Warfarin"));
    assert!(!profile::is_nursing_order("melatonin"));
}
