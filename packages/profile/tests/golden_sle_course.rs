//! 合成 SLE 病程的 golden ProfileView。
//!
//! 语料文本本身是**写出来的**(模拟医院打印件,这一层没法用生产代码产出),但
//! 从文本往后的每一步都走生产路径:`parser::aggregate` → `profile::materialize`。
//! golden 文件由 `UPDATE_GOLDEN=1` 重新生成,**任何一次重生成都必须人工看 diff**:
//! 这份文件的作用就是让规则的改动无处可藏。
//!
//! 语料由 `examples/demo-dataset/generate_sle.sh` 写出、`extract_fixtures.py` 抽进
//! `testdata/corpus/`(与张建国那套同一条生产路径,只是另一个病人、另一个目录)。
//! **不要手改 `testdata/corpus/*.txt`** —— 改脚本,重跑那两条命令。
//!
//! 独占一个测试二进制:`terminology::set_overlay` 是进程级全局状态(尿红细胞/尿白细胞
//! 按高倍视野计数这两条只在包里,内置词典没有),同一个二进制里再加用例要跟着上串行锁。
use chrono::NaiveDate;
use std::path::{Path, PathBuf};

mod common;

fn testdata() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

/// 语料文件名形如 `2024-03-02_出院记录_协和.txt`,日期与类型都在名字里。
fn load_corpus() -> Vec<(String, NaiveDate, String)> {
    let mut out = Vec::new();
    for f in std::fs::read_dir(testdata().join("corpus"))
        .unwrap()
        .flatten()
    {
        let p = f.path();
        let stem = p.file_stem().unwrap().to_string_lossy().to_string();
        let mut parts = stem.splitn(3, '_');
        let date: NaiveDate = parts.next().unwrap().parse().unwrap();
        let kind = parts.next().unwrap().to_string();
        out.push((kind, date, std::fs::read_to_string(&p).unwrap()));
    }
    out.sort_by_key(|(_, d, _)| *d);
    out
}

fn doc_type_for(kind: &str) -> &'static str {
    match kind {
        "检验报告" => "lab_report",
        "处方" => "prescription",
        "出院记录" => "discharge_summary",
        "门诊病历" => "outpatient",
        "病理报告" => "pathology",
        "眼科报告" | "输液记录" => "clinical_note",
        _ => "other",
    }
}

#[test]
fn the_synthetic_sle_course_renders_the_pinned_profile_view() {
    let corpus = load_corpus();
    assert!(
        corpus.len() >= 12,
        "3 年 4 家医院的病程至少该有十几份文档,实际 {}",
        corpus.len()
    );

    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, (kind, date, text))| parser::SourceDoc {
            index: i,
            date: Some(*date),
            text,
            doc_type: Some(doc_type_for(kind).into()),
            title: None,
            extraction_json: None,
        })
        .collect();

    let events = vec![
        parser::ProfileEvent {
            kind: "enable".into(),
            package: "t".into(),
            at: "2024-03-15".into(),
            payload: serde_json::json!({}),
        },
        parser::ProfileEvent {
            kind: "weight".into(),
            package: "t".into(),
            at: "2026-09-01".into(),
            payload: serde_json::json!({"kg": 56.0}),
        },
    ];

    // 用**测试夹具包**,不是 skills/ 里那份 —— 那份要到 Task 18 才存在,而这条测试
    // 测的是规则引擎。两份内容一致由 Task 18 的
    // `the_shipped_sle_package_matches_the_test_fixture` 钉住。
    let pkg = common::full_pkg();
    // 尿红细胞/尿白细胞按**高倍视野**计数的那两条只在包里(内置词典只有按体积
    // 计数的 `urine_rbc_count`,两者没有确定换算)。真机上这一步由 Task 20 的 FFI
    // 在装包时做;测试里手动做一次,不然这两项在 golden 里永远是「未知」。
    terminology::set_overlay(common::overlay_entries(&pkg));
    let view = profile::materialize(&docs, &events, &pkg, "2026-09-16".parse().unwrap());
    let got = serde_json::to_value(&view).unwrap();
    terminology::set_overlay(vec![]);

    let golden_path = testdata().join("golden_profile_view.json");
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::write(
            &golden_path,
            serde_json::to_string_pretty(&got).unwrap() + "\n",
        )
        .unwrap();
        panic!("golden 已重写 —— 人工 review 这次 diff 之后再跑一遍(不带 UPDATE_GOLDEN)");
    }
    let want: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&golden_path).unwrap()).unwrap();
    assert_eq!(got, want, "ProfileView 与 golden 不一致");
}

#[test]
fn the_golden_view_never_claims_remission_or_a_sledai_total() {
    let s = std::fs::read_to_string(testdata().join("golden_profile_view.json")).unwrap();
    for banned in [
        "SLEDAI 总分",
        "已缓解",
        "判断缓解",
        "达到缓解",
        "计算 SLEDAI",
    ] {
        assert!(!s.contains(banned), "golden 里出现了禁用措辞:{banned}");
    }
}

#[test]
fn every_number_in_the_golden_view_traces_to_a_declared_source_id() {
    let v: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(testdata().join("golden_profile_view.json")).unwrap(),
    )
    .unwrap();
    let declared: Vec<String> = v["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap().to_string())
        .collect();
    fn walk(v: &serde_json::Value, declared: &[String]) {
        match v {
            serde_json::Value::Object(m) => {
                if let Some(s) = m.get("source").and_then(|x| x.as_str()) {
                    assert!(
                        declared.contains(&s.to_string()),
                        "出处 id {s} 没在 sources 里声明"
                    );
                }
                for x in m.values() {
                    walk(x, declared);
                }
            }
            serde_json::Value::Array(a) => {
                for x in a {
                    walk(x, declared)
                }
            }
            _ => {}
        }
    }
    walk(&v, &declared);
}
