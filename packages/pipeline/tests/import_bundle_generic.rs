//! Epic 包导入 → `Vault::encounters_with_docs()` → 通用病程档案(`profile::materialize_generic`):
//! 结构化导入那条路上 sidecar 的 ICD/RxNorm/LOINC 与住院窗口都要能被通用层读到
//! (2026-10-22 spec §8.2「同一包走 import_bundle 与纯文本两条路都要跑」)。全部合成数据。
use chrono::NaiveDate;
use core_model::Vault;
use std::path::Path;

/// 多行文本层的小 PDF(每行一个 Tj),长度远超 `ocr::MIN_TEXT_LAYER_LEN`,不触发 OCR。
fn text_pdf(text: &str) -> Vec<u8> {
    use lopdf::content::{Content, Operation};
    use lopdf::{dictionary, Document, Object, Stream};
    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica",
    });
    let resources_id = doc.add_object(dictionary! { "Font" => dictionary! { "F1" => font_id } });
    let mut ops = vec![
        Operation::new("BT", vec![]),
        Operation::new("Tf", vec!["F1".into(), 12.into()]),
        Operation::new("TL", vec![14.into()]),
        Operation::new("Td", vec![20.into(), 760.into()]),
    ];
    for line in text.lines() {
        ops.push(Operation::new("Tj", vec![Object::string_literal(line)]));
        ops.push(Operation::new("T*", vec![]));
    }
    ops.push(Operation::new("ET", vec![]));
    let content = Content { operations: ops };
    let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
    let page_id = doc.add_object(dictionary! {
        "Type" => "Page", "Parent" => pages_id, "Contents" => content_id, "Resources" => resources_id,
    });
    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages", "Kids" => vec![page_id.into()], "Count" => 1,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
        }),
    );
    let catalog_id = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    doc.trailer.set("Root", catalog_id);
    let mut bytes = Vec::new();
    doc.save_to(&mut bytes).unwrap();
    bytes
}

const DS: &str = "docs/2024-03-10_discharge_summary.pdf";
const OP: &str = "docs/2024-03-03_surgery.pdf";
const NOTE: &str = "docs/2025-01-14_clinical_note.pdf";
const LAB: &str = "docs/2025-04-14_lab_report.pdf";

fn synth_bundle() -> (Vec<(String, Vec<u8>)>, String) {
    let ds = text_pdf("Doe, Jane MRN 00000000 DISCHARGE SUMMARY\nAdmission Date: 2024-03-01 Discharge Date: 2024-03-10\nDischarge Diagnoses:\n1. Aortic stenosis (I35.0)\n2. Status post aortic valve replacement (Z95.2)\nDischarge Medications:\nWarfarin Sodium 5 MG tablet daily\nINR 2.1 (2.0-3.0)\nCreatinine 0.9 mg/dL (0.6-1.2)\n");
    let op = text_pdf("Doe, Jane MRN 00000000 OPERATIVE REPORT\nDate of Procedure: 2024-03-03\nProcedure: Surgical aortic valve replacement with 23 mm bioprosthetic valve\nPreoperative Diagnosis: Severe aortic stenosis (I35.0)\n");
    let note = text_pdf("Doe, Jane MRN 00000000 OFFICE VISIT Cardiology Clinic\nVisit Date: 2025-01-14\nAssessment:\n1. Presence of prosthetic heart valve (Z95.2)\nCurrent Medications:\nWarfarin Sodium 4 MG tablet daily\nLabs today:\nINR 2.2 (2.0-3.0)\n");
    let lab = text_pdf("Doe, Jane MRN 00000000 LABORATORY REPORT\nCollected: 2025-04-14\nINR 2.5 (2.0-3.0)\nBNP 150 pg/mL (0-100) H\n");
    let ds_side = r#"{"doc_type":"discharge_summary","doc_date":"2024-03-10",
      "labs":[{"name":"INR","value":"2.1","unit":"","ref_low":"2.0","ref_high":"3.0","flag":"","loinc":"6301-6"},
              {"name":"Creatinine","value":"0.9","unit":"mg/dL","ref_low":"0.6","ref_high":"1.2","flag":"","loinc":"2160-0"}],
      "meds":[{"name":"Warfarin Sodium 5 MG tablet","dose":"5 MG","freq":"daily","route":"","rxnorm":"11289"}],
      "diagnoses":[{"text":"Aortic stenosis","icd":"I35.0"},{"text":"Status post aortic valve replacement","icd":"Z95.2"}]}"#;
    let op_side = r#"{"doc_type":"surgery","doc_date":"2024-03-03","labs":[],"meds":[],"diagnoses":[{"text":"Severe aortic stenosis","icd":"I35.0"}]}"#;
    let note_side = r#"{"doc_type":"clinical_note","doc_date":"2025-01-14",
      "labs":[{"name":"INR","value":"2.2","unit":"","ref_low":"2.0","ref_high":"3.0","flag":"","loinc":"6301-6"}],
      "meds":[{"name":"Warfarin Sodium 4 MG tablet","dose":"4 MG","freq":"daily","route":"","rxnorm":"11289"}],
      "diagnoses":[{"text":"Presence of prosthetic heart valve","icd":"Z95.2"}]}"#;
    let lab_side = r#"{"doc_type":"lab_report","doc_date":"2025-04-14",
      "labs":[{"name":"INR","value":"2.5","unit":"","ref_low":"2.0","ref_high":"3.0","flag":"","loinc":"6301-6"},
              {"name":"BNP","value":"150","unit":"pg/mL","ref_low":"0","ref_high":"100","flag":"H","loinc":"30934-4"}],
      "meds":[],"diagnoses":[]}"#;
    let sha = |b: &[u8]| core_model::cas::sha256_hex(b);
    let manifest = format!(
        r#"{{"source":{{"path":"synthetic.pdf","sha256":"x","pages":4}},"encounters":[],"coverage":{{}},"docs":[
          {{"file":"{DS}","sha256":"{}","doc_type":"discharge_summary","title":"Discharge Summary","doc_date":"2024-03-01","doc_date_end":"2024-03-10","pages":[[1,1]],"encounter_title":"Hosp","dropped":0}},
          {{"file":"{OP}","sha256":"{}","doc_type":"surgery","title":"Operative Report","doc_date":"2024-03-03","doc_date_end":null,"pages":[[2,2]],"encounter_title":"Hosp","dropped":0}},
          {{"file":"{NOTE}","sha256":"{}","doc_type":"clinical_note","title":"Office Visit","doc_date":"2025-01-14","doc_date_end":null,"pages":[[3,3]],"encounter_title":"Office","dropped":0}},
          {{"file":"{LAB}","sha256":"{}","doc_type":"lab_report","title":"Lab","doc_date":"2025-04-14","doc_date_end":null,"pages":[[4,4]],"encounter_title":"Lab","dropped":0}}
        ]}}"#,
        sha(&ds),
        sha(&op),
        sha(&note),
        sha(&lab)
    );
    let side = |p: &str| p.replace(".pdf", ".extraction.json");
    let files = vec![
        (DS.to_string(), ds),
        (side(DS), ds_side.as_bytes().to_vec()),
        (OP.to_string(), op),
        (side(OP), op_side.as_bytes().to_vec()),
        (NOTE.to_string(), note),
        (side(NOTE), note_side.as_bytes().to_vec()),
        (LAB.to_string(), lab),
        (side(LAB), lab_side.as_bytes().to_vec()),
    ];
    (files, manifest)
}

fn write_dir(root: &Path, files: &[(String, Vec<u8>)], manifest: &str) {
    std::fs::create_dir_all(root.join("docs")).unwrap();
    std::fs::write(root.join("manifest.json"), manifest).unwrap();
    for (rel, bytes) in files {
        std::fs::write(root.join(rel), bytes).unwrap();
    }
}

#[test]
fn imported_bundle_feeds_the_generic_profile() {
    let tmp = tempfile::tempdir().unwrap();
    let bundle = tmp.path().join("bundle");
    let (files, manifest) = synth_bundle();
    write_dir(&bundle, &files, &manifest);
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();
    let r = pipeline::import_bundle(&vault, &bundle, &mut |_, _| {}).unwrap();
    assert_eq!((r.total, r.imported), (4, 4), "{r:?}");

    // 手机侧 gather_for_profile 同一手法:文档按临床日期升序编 index,encounter 的文档映射成 index。
    let mut docs = vault.timeline().unwrap();
    docs.sort_by_key(|d| (d.doc_date, d.document_id));
    let texts: Vec<String> = docs
        .iter()
        .map(|d| vault.ocr_text(d.document_id).unwrap())
        .collect();
    let extractions: Vec<Option<String>> = docs
        .iter()
        .map(|d| vault.extraction_json(d.document_id).unwrap())
        .collect();
    let source_docs: Vec<parser::SourceDoc> = docs
        .iter()
        .enumerate()
        .map(|(i, d)| parser::SourceDoc {
            index: i,
            date: d.doc_date.map(|x| x.date_naive()),
            text: &texts[i],
            doc_type: Some(d.doc_type.as_str().to_string()),
            title: d.title.clone(),
            extraction_json: extractions[i].as_deref(),
        })
        .collect();
    let index_of = |id: i64| docs.iter().position(|d| d.document_id == id).unwrap();
    let encounters: Vec<profile::EncounterRef> = vault
        .encounters_with_docs()
        .unwrap()
        .into_iter()
        .map(|(e, ds)| profile::EncounterRef {
            kind: e.kind.as_str().into(),
            start: e.start_date.map(|x| x.date_naive()),
            end: e.end_date.map(|x| x.date_naive()),
            provider: e.provider.clone(),
            title: e.title.clone(),
            doc_indices: ds.iter().map(|d| index_of(d.id)).collect(),
        })
        .collect();
    // 「今天」取在最后一份文档(2025-04-14)之后、Z95.2 最近出现(2025-01-14)的 12 个月之内:
    // Z95.2 在「现在」、I35.0(最近 2024-03-10)在「更早」(2026-10-23 spec §4.1)。
    let today: NaiveDate = "2025-10-01".parse().unwrap();
    let view = profile::materialize_generic(&source_docs, &encounters, &[], &[], today);
    let v = serde_json::to_value(&view).unwrap();
    let find = |kind: &str| {
        v["sections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["kind"] == kind)
            .unwrap()
            .clone()
    };

    let fams = find("family_cards")["body"]["families"].clone();
    let cardio = fams
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == "cardio")
        .expect("心血管族");
    let codes: Vec<&str> = cardio["diagnoses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["code"].as_str().unwrap())
        .collect();
    // I35.0 最近 2024-03,超过 12 个月 → 在 earlier_families 的心血管里(2026-10-23 spec §4.1)。
    assert!(
        codes.contains(&"Z95.2") && !codes.contains(&"I35.0"),
        "{codes:?}"
    );
    let earlier = find("family_cards")["body"]["earlier_families"].clone();
    let earlier_cardio = earlier
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == "cardio")
        .expect("更早的心血管");
    assert!(earlier_cardio["diagnoses"]
        .as_array()
        .unwrap()
        .iter()
        .any(|d| d["code"] == "I35.0"));
    let labs: Vec<&str> = cardio["labs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["key"].as_str().unwrap())
        .collect();
    assert!(labs.contains(&"inr") && labs.contains(&"bnp"), "{labs:?}");

    let rows = find("med_table")["body"]["rows"].clone();
    let w = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == "华法林")
        .expect("rxnorm 反查到 warfarin");
    assert_eq!(w["since"], "2025-01-14");
    assert_eq!(w["raw_name"], "Warfarin Sodium 4 MG tablet");

    let lanes = find("journey")["body"]["lanes"].clone();
    let inp = lanes
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "enc_inpatient")
        .expect("住院泳道");
    assert_eq!(inp["nodes"].as_array().unwrap().len(), 1);
    assert_eq!(inp["nodes"][0]["to"], "2024-03-01 → 2024-03-10 · 住院 9 天");
    assert!(lanes
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["key"] == "surgery"));
}
