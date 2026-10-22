//! 通用病程档案层(2026-10-22 spec)的 golden 与断言:合成病人 Doe, Jane
//! (瓣膜置换 + 曲霉菌),语料由 `examples/demo-dataset/generate_jane.sh` 直接写进
//! `testdata/corpus-jane/`(文本 + Epic 适配器样式 sidecar)。**不要手改夹具**。
//!
//! 独占一个测试二进制:包叠加用例要 `terminology::set_overlay`(进程级全局)。
use chrono::NaiveDate;
use std::path::{Path, PathBuf};

mod common;

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/corpus-jane")
}

pub struct Doc {
    pub stem: String,
    pub kind: String,
    pub date: NaiveDate,
    pub text: String,
    pub sidecar: String,
}

/// 文件名形如 `2025-06-14_出院记录_UF.txt`;同 stem 的 `.json` 是 sidecar。按日期升序,
/// 同日按文件名。
pub fn load_corpus() -> Vec<Doc> {
    let mut out = Vec::new();
    for f in std::fs::read_dir(corpus_dir()).unwrap().flatten() {
        let p = f.path();
        if p.extension().is_none_or(|e| e != "txt") {
            continue;
        }
        let stem = p.file_stem().unwrap().to_string_lossy().to_string();
        let mut parts = stem.splitn(3, '_');
        let date: NaiveDate = parts.next().unwrap().parse().unwrap();
        let kind = parts.next().unwrap().to_string();
        let sidecar = std::fs::read_to_string(p.with_extension("json"))
            .unwrap_or_else(|e| panic!("{stem}.json 缺:{e}"));
        out.push(Doc {
            stem: stem.clone(),
            kind,
            date,
            text: std::fs::read_to_string(&p).unwrap(),
            sidecar,
        });
    }
    out.sort_by(|a, b| a.date.cmp(&b.date).then(a.stem.cmp(&b.stem)));
    out
}

pub fn doc_type_for(kind: &str) -> &'static str {
    match kind {
        "检验报告" => "lab_report",
        "出院记录" => "discharge_summary",
        "门诊病历" | "急诊记录" => "clinical_note",
        "手术记录" => "surgery",
        "影像报告" => "imaging_report",
        "病理报告" => "pathology",
        _ => "other",
    }
}

#[test]
fn corpus_is_complete_and_sidecars_are_verbatim_subsets_of_their_text() {
    let corpus = load_corpus();
    assert!(corpus.len() >= 15, "实际 {}", corpus.len());
    for d in &corpus {
        let parsed = deid::parse_extraction(&d.sidecar).expect("sidecar 是合法 JSON");
        let n = parsed.labs.len() + parsed.meds.len() + parsed.diagnoses.len();
        let v = deid::verify(parsed, &d.text, deid::Mode::Text);
        assert_eq!(
            v.rejected, 0,
            "{}:sidecar 里有 {} 条在文本里找不到(共 {n} 条)",
            d.stem, v.rejected
        );
    }
    let stems: Vec<&str> = corpus.iter().map(|d| d.stem.as_str()).collect();
    assert!(stems.contains(&"2025-11-17_门诊病历_UF"));
    assert_eq!(corpus.iter().filter(|d| d.kind == "门诊病历").count(), 9);
}

pub const TODAY: &str = "2026-10-22";

/// 两次住院 + 一次急诊(spec §8.2);`doc_indices` 按 stem 对回 `load_corpus` 的下标。
pub fn encounters(corpus: &[Doc]) -> Vec<profile::EncounterRef> {
    let idx = |stems: &[&str]| -> Vec<usize> {
        stems
            .iter()
            .map(|s| {
                corpus
                    .iter()
                    .position(|d| d.stem == *s)
                    .unwrap_or_else(|| panic!("{s}"))
            })
            .collect()
    };
    let d = |s: &str| s.parse::<NaiveDate>().ok();
    vec![
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2024-03-01"),
            end: d("2024-03-10"),
            provider: Some("UF Health Shands".into()),
            title: Some("Discharge Summary".into()),
            doc_indices: idx(&["2024-03-03_手术记录_UF", "2024-03-10_出院记录_UF"]),
        },
        profile::EncounterRef {
            kind: "emergency".into(),
            start: d("2025-06-02"),
            end: d("2025-06-02"),
            provider: Some("UF Health Shands".into()),
            title: Some("ED Visit".into()),
            doc_indices: idx(&["2025-06-02_急诊记录_UF"]),
        },
        profile::EncounterRef {
            kind: "inpatient".into(),
            start: d("2025-06-02"),
            end: d("2025-06-14"),
            provider: Some("UF Health Shands".into()),
            title: Some("Discharge Summary".into()),
            doc_indices: idx(&[
                "2025-06-03_影像报告_UF",
                "2025-06-05_病理报告_UF",
                "2025-06-14_出院记录_UF",
            ]),
        },
    ]
}

/// 同一份语料跑通用层;`pkgs` 是装着的包(开没开由 `events` 决定)。
pub fn render(
    today: &str,
    events: &[parser::ProfileEvent],
    pkgs: &[profile::Package],
) -> serde_json::Value {
    let corpus = load_corpus();
    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, d)| parser::SourceDoc {
            index: i,
            date: Some(d.date),
            text: &d.text,
            doc_type: Some(doc_type_for(&d.kind).into()),
            title: Some(d.stem.clone()),
            extraction_json: Some(&d.sidecar),
        })
        .collect();
    let encs = encounters(&corpus);
    let view = profile::materialize_generic(&docs, &encs, events, pkgs, today.parse().unwrap());
    serde_json::to_value(&view).unwrap()
}

pub fn section<'a>(view: &'a serde_json::Value, kind: &str) -> &'a serde_json::Value {
    view["sections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["kind"] == kind && s["package_id"] == "general")
        .unwrap_or_else(|| panic!("没有通用段 {kind}"))
}

fn family<'a>(fams: &'a serde_json::Value, key: &str) -> &'a serde_json::Value {
    fams.as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == key)
        .unwrap_or_else(|| panic!("没有族 {key}"))
}

fn codes(fam: &serde_json::Value) -> Vec<String> {
    fam["diagnoses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["code"].as_str().unwrap_or("").to_string())
        .collect()
}

fn lab_keys(fam: &serde_json::Value) -> Vec<String> {
    fam["labs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["key"].as_str().unwrap().to_string())
        .collect()
}

/// 验收 1:族卡 —— 覆盖表生效、同码合并、无码落 uncoded、一条诊断只在一个主族。
#[test]
fn family_cards_group_diagnoses_by_icd() {
    let view = render(TODAY, &[], &[]);
    let s = section(&view, "family_cards");
    assert_eq!(s["id"], "general_families");
    let fams = &s["body"]["families"];
    let cardio = family(fams, "cardio");
    assert!(
        codes(cardio).contains(&"I35.0".into()),
        "{:?}",
        codes(cardio)
    );
    assert!(codes(cardio).contains(&"Z95.2".into()));
    assert!(
        codes(cardio).contains(&"Z79.01".into()),
        "Z79.01 长期抗凝 → 心血管"
    );
    let z95 = cardio["diagnoses"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["code"] == "Z95.2")
        .unwrap();
    let texts = z95["texts"].as_array().unwrap();
    assert_eq!(texts.len(), 3, "三种写法同码合并成一条:{texts:?}");
    assert_eq!(z95["doc_count"], 10, "两份出院小结 + 8 次门诊");
    assert_eq!(z95["first_seen"], "2024-03-10");
    assert_eq!(z95["last_seen"], "2026-09-14");
    assert!(!z95["evidence"].as_array().unwrap().is_empty());
    let inf = family(fams, "infection");
    assert_eq!(codes(inf), vec!["B44.1"]);
    assert_eq!(inf["diagnoses"][0]["secondary"], "respiratory");
    let unc = family(fams, "uncoded");
    assert_eq!(unc["diagnoses"][0]["texts"][0], "Hypertension");
    assert_eq!(unc["diagnoses"][0]["code"], serde_json::Value::Null);
    // 一条诊断只归一个主族。
    let mut all: Vec<String> = Vec::new();
    for f in fams.as_array().unwrap() {
        for c in codes(f) {
            if !c.is_empty() {
                assert!(!all.contains(&c), "{c} 出现在两个族");
                all.push(c);
            }
        }
    }
    // 排序:最近出现日倒序;other 倒数第二、uncoded 最后。
    let keys: Vec<&str> = fams
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["key"].as_str().unwrap())
        .collect();
    assert_eq!(keys.last().copied(), Some("uncoded"));
    assert_eq!(keys[0], "cardio", "{keys:?}");
    assert_eq!(cardio["count"], 3);
    assert_eq!(cardio["last_seen"], "2026-09-14");
}

/// 验收 5:化验小表 —— 值与单位来自同一个 LabPoint;认不出的 key 不出现、不报错。
#[test]
fn family_cards_attach_lab_tables() {
    let view = render(TODAY, &[], &[]);
    let fams = &section(&view, "family_cards")["body"]["families"];
    let cardio = family(fams, "cardio");
    let keys = lab_keys(cardio);
    for k in ["inr", "bnp", "creatinine"] {
        assert!(keys.contains(&k.into()), "{keys:?}");
    }
    assert!(
        !keys.contains(&"digoxin_level".into()),
        "没有数据的 key 不出行"
    );
    let inr = cardio["labs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "inr")
        .unwrap();
    assert_eq!(inr["value"], "2.4");
    assert_eq!(inr["date"], "2026-09-14");
    assert_eq!(inr["ref"], "2-3", "区间是解析后的数,与状态行同一个 fmt_num");
    assert!(
        inr["unit"].is_null() || inr["unit"] == "1",
        "{:?}",
        inr["unit"]
    );
    let crea = cardio["labs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "creatinine")
        .unwrap();
    assert_eq!(crea["unit"], "mg/dL", "印刷单位配印刷值");
    assert_eq!(crea["value"], "1.1");
    let inf = family(fams, "infection");
    let ik = lab_keys(inf);
    assert!(ik.contains(&"galactomannan".into()), "{ik:?}");
    assert!(ik.contains(&"crp".into()));
    assert!(
        ik.contains(&"voriconazole_level".into()),
        "名字命中 2025-08-18 那条:{ik:?}"
    );
    let gm = inf["labs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["key"] == "galactomannan")
        .unwrap();
    assert_eq!(gm["value"], "0.2");
    assert_eq!(gm["unit"], "index");
    let common: Vec<&str> = section(&view, "family_cards")["body"]["common_labs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["key"].as_str().unwrap())
        .collect();
    assert!(common.contains(&"wbc"), "{common:?}");
    // 每个 ev: 都在依据段里。
    let ev = section(&view, "evidence");
    let ids: Vec<&str> = ev["body"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].as_str().unwrap())
        .collect();
    for f in fams.as_array().unwrap() {
        for d in f["diagnoses"].as_array().unwrap() {
            for e in d["evidence"].as_array().unwrap() {
                assert!(ids.contains(&e.as_str().unwrap()), "{e} 不在依据段");
            }
        }
        for l in f["labs"].as_array().unwrap() {
            assert!(ids.contains(&l["evidence"].as_str().unwrap()));
        }
    }
}
