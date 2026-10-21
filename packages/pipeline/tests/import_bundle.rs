//! `pipeline::import_bundle`:吃 myEHR Epic 适配器包。全部合成数据(Doe, Jane),
//! PDF 由 lopdf 现造。设计见 `docs/superpowers/specs/2026-10-21-structured-import-design.md`。
use core_model::{DocType, Vault};
use std::io::Write;
use std::path::Path;

/// 单页、带 Helvetica 文本层的小 PDF(长度远超 `ocr::MIN_TEXT_LAYER_LEN`,不触发 OCR)。
fn text_pdf(text: &str) -> Vec<u8> {
    use lopdf::content::{Content, Operation};
    use lopdf::{dictionary, Document, Object, Stream};
    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica",
    });
    let resources_id = doc.add_object(dictionary! { "Font" => dictionary! { "F1" => font_id } });
    let content = Content {
        operations: vec![
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 12.into()]),
            Operation::new("Td", vec![20.into(), 700.into()]),
            Operation::new("Tj", vec![Object::string_literal(text)]),
            Operation::new("ET", vec![]),
        ],
    };
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

const DS: &str = "docs/2024-03-01_discharge_summary_hospital-stay.pdf";
const LAB: &str = "docs/2024-03-02_lab_report_cbc.pdf";
const NOTE: &str = "docs/2024-05-06_clinical_note_office-visit.pdf";

/// 三份文档:一份住院出院小结(带起止日)、一份窗口内的化验、一份两个月后的门诊。
/// 返回 (相对路径, 字节) 列表 + manifest JSON;sha256 真算。
fn synth_bundle() -> (Vec<(String, Vec<u8>)>, String) {
    let ds_pdf = text_pdf("Doe, Jane MRN 00000000 Discharge Summary Note. Hemoglobin 12.1 g/dL (12.0-16.0). Some Odd Name 1.1 mg/dL.");
    let lab_pdf = text_pdf(
        "Doe, Jane MRN 00000000 Lab in UF LAB. WBC 6.2 10*3/uL (4.0-10.0) collected 03/02/2024.",
    );
    let note_pdf = text_pdf("Doe, Jane MRN 00000000 Office Visit in Family Medicine. Diagnosis: Hypertension I10. Plan: continue.");
    let ds_side = r#"{"doc_type":"discharge_summary","doc_date":"2024-03-01","labs":[
        {"name":"Hemoglobin","value":"12.1","unit":"g/dL","ref_low":"12.0","ref_high":"16.0","flag":"","loinc":"718-7"},
        {"name":"Some Odd Name","value":"1.1","unit":"mg/dL","ref_low":"","ref_high":"","flag":"","loinc":"14682-9"}
      ],"meds":[],"diagnoses":[]}"#;
    let lab_side = r#"{"doc_type":"lab_report","doc_date":"2024-03-02","labs":[
        {"name":"WBC","value":"6.2","unit":"10*3/uL","ref_low":"4.0","ref_high":"10.0","flag":"","loinc":"6690-2"}
      ],"meds":[],"diagnoses":[]}"#;
    let note_side = r#"{"doc_type":"clinical_note","doc_date":"2024-05-06","labs":[],"meds":[],"diagnoses":[{"text":"Hypertension","icd":"I10"}]}"#;
    let sha = |b: &[u8]| core_model::cas::sha256_hex(b);
    let manifest = format!(
        r#"{{"source":{{"path":"synthetic.pdf","sha256":"x","pages":3}},"encounters":[],"coverage":{{}},"docs":[
          {{"file":"{DS}","sha256":"{}","doc_type":"discharge_summary","title":"Discharge Summary Note","doc_date":"2024-03-01","doc_date_end":"2024-03-04","pages":[[1,1]],"encounter_title":"Hosp","dropped":0}},
          {{"file":"{LAB}","sha256":"{}","doc_type":"lab_report","title":"CBC","doc_date":"2024-03-02","doc_date_end":null,"pages":[[2,2]],"encounter_title":"Hosp","dropped":0}},
          {{"file":"{NOTE}","sha256":"{}","doc_type":"clinical_note","title":"Office Visit","doc_date":"2024-05-06","doc_date_end":null,"pages":[[3,3]],"encounter_title":"Office","dropped":0}}
        ]}}"#,
        sha(&ds_pdf),
        sha(&lab_pdf),
        sha(&note_pdf)
    );
    let side = |p: &str| p.replace(".pdf", ".extraction.json");
    let files = vec![
        (DS.to_string(), ds_pdf),
        (side(DS), ds_side.as_bytes().to_vec()),
        (LAB.to_string(), lab_pdf),
        (side(LAB), lab_side.as_bytes().to_vec()),
        (NOTE.to_string(), note_pdf),
        (side(NOTE), note_side.as_bytes().to_vec()),
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

fn event_lines(vault_root: &Path) -> usize {
    std::fs::read_dir(vault_root.join("log"))
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|x| x == "jsonl"))
        .map(|e| std::fs::read_to_string(e.path()).unwrap().lines().count())
        .sum()
}

fn import(vault: &Vault, path: &Path) -> pipeline::BundleReport {
    let mut ticks = Vec::new();
    let r = pipeline::import_bundle(vault, path, &mut |d, t| ticks.push((d, t))).unwrap();
    assert_eq!(ticks.len(), r.total, "每份一次进度");
    if let Some(&(d, t)) = ticks.last() {
        assert_eq!((d, t), (r.total, r.total));
    }
    r
}

#[test]
fn imports_by_manifest_not_classifier_and_groups_encounters() {
    let tmp = tempfile::tempdir().unwrap();
    let bundle = tmp.path().join("bundle");
    let (files, manifest) = synth_bundle();
    write_dir(&bundle, &files, &manifest);
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();

    let r = import(&vault, &bundle);
    assert_eq!(
        (r.total, r.imported, r.deduped, r.no_text),
        (3, 3, 0, 0),
        "{r:?}"
    );
    assert!(r.failed.is_empty(), "{:?}", r.failed);

    let mut docs = vault.timeline().unwrap();
    docs.sort_by_key(|d| d.doc_date);
    assert_eq!(docs.len(), 3);
    assert_eq!(docs[0].doc_type, DocType::DischargeSummary);
    assert_eq!(docs[0].title.as_deref(), Some("Discharge Summary Note"));
    assert_eq!(
        docs[0].doc_date.unwrap().format("%Y-%m-%d").to_string(),
        "2024-03-01"
    );
    assert_eq!(
        docs[0].doc_date_end.unwrap().format("%Y-%m-%d").to_string(),
        "2024-03-04"
    );
    assert_eq!(
        docs[1].doc_type,
        DocType::LabReport,
        "manifest 说是化验,不是 classify 猜的"
    );
    assert_eq!(docs[2].doc_type, DocType::ClinicalNote);
    assert_eq!(docs[2].title.as_deref(), Some("Office Visit"));

    // 就诊分组:出院小结的起止日定义住院窗口,窗口内的化验归进去;门诊单独一天。
    let encs = vault.encounters_with_docs().unwrap();
    assert_eq!(encs.len(), 2, "{encs:?}");
    let inpatient = encs
        .iter()
        .find(|(_, ds)| ds.len() == 2)
        .expect("住院组含两份");
    assert!(inpatient.1.iter().any(|d| d.doc_type == DocType::LabReport));
    assert!(inpatient
        .1
        .iter()
        .any(|d| d.doc_type == DocType::DischargeSummary));

    // sidecar 原样进 CAS:loinc 还在;labs_from_json 读得到,名字认不出的那条按 LOINC 反查。
    let ds_doc = &inpatient
        .1
        .iter()
        .find(|d| d.doc_type == DocType::DischargeSummary)
        .unwrap();
    let json = vault
        .extraction_json(ds_doc.id)
        .unwrap()
        .expect("extraction 已挂");
    assert!(
        json.contains(r#""loinc": "14682-9""#) || json.contains(r#""loinc":"14682-9""#),
        "{json}"
    );
    let labs = parser::extraction::labs_from_json(&json).unwrap().labs;
    assert_eq!(labs.len(), 2);
    let odd = labs.iter().find(|l| l.raw_name == "Some Odd Name").unwrap();
    assert_eq!(odd.analyte_key.as_deref(), Some("creatinine"));

    // 页文本照常入库(FTS / 聚合 / 分享正文都靠它)。
    assert!(vault.ocr_text(ds_doc.id).unwrap().contains("Hemoglobin"));
    assert!(
        !vault.search("Hemoglobin", 10).unwrap().is_empty(),
        "FTS 搜得到 PDF 里的词"
    );
}

#[test]
fn rerun_is_idempotent() {
    let tmp = tempfile::tempdir().unwrap();
    let bundle = tmp.path().join("bundle");
    let (files, manifest) = synth_bundle();
    write_dir(&bundle, &files, &manifest);
    let vault_root = tmp.path().join("vault");
    let vault = Vault::open(&vault_root).unwrap();
    import(&vault, &bundle);
    let before = event_lines(&vault_root);
    let r = import(&vault, &bundle);
    assert_eq!((r.imported, r.deduped), (0, 3), "{r:?}");
    assert_eq!(event_lines(&vault_root), before, "重导不追加任何事件");
    assert_eq!(vault.timeline().unwrap().len(), 3);
}

#[test]
fn bad_entries_fail_one_at_a_time() {
    let tmp = tempfile::tempdir().unwrap();
    let bundle = tmp.path().join("bundle");
    let (files, manifest) = synth_bundle();
    // 坏 sha(第 1 份)、文件不存在(第 2 份)、未知类型(第 3 份)、坏日期(第 4 份,复用第 3 份 PDF 的 sha)。
    let m: serde_json::Value = serde_json::from_str(&manifest).unwrap();
    let mut docs = m["docs"].as_array().unwrap().clone();
    docs[0]["sha256"] = serde_json::Value::String("00".repeat(32));
    docs[1]["file"] = serde_json::Value::String("docs/missing.pdf".into());
    let mut fourth = docs[2].clone();
    docs[2]["doc_type"] = serde_json::Value::String("prescription_xyz".into());
    fourth["doc_date"] = serde_json::Value::String("2024-13-40".into());
    docs.push(fourth);
    let manifest = serde_json::json!({"docs": docs}).to_string();
    write_dir(&bundle, &files, &manifest);
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();

    let r = import(&vault, &bundle);
    assert_eq!((r.total, r.imported), (4, 0), "{r:?}");
    assert_eq!(r.failed.len(), 4, "{:?}", r.failed);
    assert!(r.failed[0].1.contains("sha256"), "{:?}", r.failed[0]);
    assert!(
        r.failed[1].1.contains("missing.pdf") || r.failed[1].1.contains("读不到"),
        "{:?}",
        r.failed[1]
    );
    assert!(r.failed[2].1.contains("doc_type"), "{:?}", r.failed[2]);
    assert!(r.failed[3].1.contains("日期"), "{:?}", r.failed[3]);
    assert!(
        vault.timeline().unwrap().is_empty(),
        "坏条目不建档,也不落 unknown 类型"
    );
}

#[test]
fn missing_manifest_is_a_hard_error() {
    let tmp = tempfile::tempdir().unwrap();
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();
    let empty = tmp.path().join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    assert!(pipeline::import_bundle(&vault, &empty, &mut |_, _| {}).is_err());
    assert!(pipeline::import_bundle(&vault, &tmp.path().join("nope.txt"), &mut |_, _| {}).is_err());
}

#[test]
fn zip_with_top_folder_and_macosx_matches_dir() {
    let tmp = tempfile::tempdir().unwrap();
    let (files, manifest) = synth_bundle();
    let zip_path = tmp.path().join("bundle.zip");
    {
        let f = std::fs::File::create(&zip_path).unwrap();
        let mut z = zip::ZipWriter::new(f);
        let opts = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        // macOS「压缩」的样子:顶级文件夹 + __MACOSX 资源叉。
        z.start_file("__MACOSX/bundle/._manifest.json", opts)
            .unwrap();
        z.write_all(b"\x00\x05\x16\x07 not json").unwrap();
        z.start_file("bundle/manifest.json", opts).unwrap();
        z.write_all(manifest.as_bytes()).unwrap();
        for (rel, bytes) in &files {
            z.start_file(format!("bundle/{rel}"), opts).unwrap();
            z.write_all(bytes).unwrap();
        }
        z.finish().unwrap();
    }
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();
    let r = import(&vault, &zip_path);
    assert_eq!((r.total, r.imported), (3, 3), "{r:?}");
    assert!(r.failed.is_empty(), "{:?}", r.failed);
    assert_eq!(vault.encounters_with_docs().unwrap().len(), 2);
    assert!(!tmp.path().join("bundle").exists(), "zip 不解压到磁盘");
}

#[test]
fn rerun_attaches_sidecar_that_was_missing_the_first_time() {
    let tmp = tempfile::tempdir().unwrap();
    let bundle = tmp.path().join("bundle");
    let (files, manifest) = synth_bundle();
    write_dir(&bundle, &files, &manifest);
    let side = bundle.join(LAB.replace(".pdf", ".extraction.json"));
    let side_bytes = std::fs::read(&side).unwrap();
    std::fs::remove_file(&side).unwrap();
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();

    let r = import(&vault, &bundle);
    assert_eq!((r.imported, r.failed.len()), (2, 1), "{r:?}");
    assert!(r.failed[0].1.contains("sidecar"), "{:?}", r.failed[0]);
    assert_eq!(
        vault.timeline().unwrap().len(),
        3,
        "文档本身建了,只是没挂 extraction"
    );

    std::fs::write(&side, side_bytes).unwrap();
    let r = import(&vault, &bundle);
    assert_eq!(
        (r.imported, r.deduped, r.failed.len()),
        (1, 2, 0),
        "补挂那一份算 imported:{r:?}"
    );
    let lab = vault
        .timeline()
        .unwrap()
        .into_iter()
        .find(|d| d.doc_type == DocType::LabReport)
        .unwrap();
    assert!(vault.extraction_json(lab.document_id).unwrap().is_some());
}

#[test]
fn rejects_bad_spans_and_paths_before_touching_the_vault() {
    let tmp = tempfile::tempdir().unwrap();
    let bundle = tmp.path().join("bundle");
    let (files, manifest) = synth_bundle();
    let m: serde_json::Value = serde_json::from_str(&manifest).unwrap();
    let mut docs = m["docs"].as_array().unwrap().clone();
    docs[0]["doc_date_end"] = serde_json::Value::String("2024-02-28".into()); // 早于 doc_date
    docs[1]["doc_date"] = serde_json::Value::Null; // 只有结束没有开始
    docs[1]["doc_date_end"] = serde_json::Value::String("2024-03-02".into());
    docs[2]["file"] = serde_json::Value::String("../outside.pdf".into());
    write_dir(
        &bundle,
        &files,
        &serde_json::json!({"docs": docs}).to_string(),
    );
    std::fs::write(tmp.path().join("outside.pdf"), b"%PDF-1.4 not really").unwrap();
    let vault = Vault::open(&tmp.path().join("vault")).unwrap();

    let r = import(&vault, &bundle);
    assert_eq!(r.failed.len(), 3, "{r:?}");
    assert!(r.failed[0].1.contains("早于"), "{:?}", r.failed[0]);
    assert!(r.failed[1].1.contains("doc_date"), "{:?}", r.failed[1]);
    assert!(r.failed[2].1.contains("路径"), "{:?}", r.failed[2]);
    assert!(vault.timeline().unwrap().is_empty());
}
