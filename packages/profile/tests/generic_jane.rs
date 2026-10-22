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
