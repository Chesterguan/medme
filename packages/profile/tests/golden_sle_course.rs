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
fn load_corpus() -> Vec<(String, String, NaiveDate, String)> {
    let mut out = Vec::new();
    for f in std::fs::read_dir(testdata().join("corpus"))
        .unwrap()
        .flatten()
    {
        let p = f.path();
        if p.extension().is_none_or(|e| e != "txt") {
            continue;
        }
        let stem = p.file_stem().unwrap().to_string_lossy().to_string();
        let mut parts = stem.splitn(3, '_');
        let date: NaiveDate = parts.next().unwrap().parse().unwrap();
        let kind = parts.next().unwrap().to_string();
        out.push((
            stem.clone(),
            kind,
            date,
            std::fs::read_to_string(&p).unwrap(),
        ));
    }
    out.sort_by_key(|(_, _, d, _)| *d);
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

/// 同一份语料的两条路:`with_llm=false` 只有正文(正则路径,facts 为空);
/// `with_llm=true` 把 `testdata/extractions/` 里的模型输出经 `deid::verify` 后当作
/// 已落库的云抽取结果喂进去 —— 这才是登录用户真实走的那条路,`state`/`journey`/
/// `evidence` 三段只有在这条路上才有 facts 可用。两份 golden 都要人工 review。
fn render(with_llm: bool) -> serde_json::Value {
    let corpus = load_corpus();
    assert!(
        corpus.len() >= 12,
        "3 年 4 家医院的病程至少该有十几份文档,实际 {}",
        corpus.len()
    );
    let extractions: Vec<Option<String>> = corpus
        .iter()
        .map(|(stem, _, _, text)| {
            if !with_llm {
                return None;
            }
            let raw = std::fs::read_to_string(
                testdata().join("extractions").join(format!("{stem}.json")),
            )
            .unwrap_or_else(|e| {
                panic!("{stem}.json 缺 —— 跑 examples/demo-dataset/extract_sle_fixtures.py: {e}")
            });
            let parsed = deid::parse_extraction(&raw).expect("fixture 是合法 JSON");
            let v = deid::verify(parsed, text, deid::Mode::Text);
            Some(serde_json::to_string(&v.extraction).unwrap())
        })
        .collect();

    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .zip(extractions.iter())
        .enumerate()
        .map(|(i, ((_, kind, date, text), ej))| parser::SourceDoc {
            index: i,
            date: Some(*date),
            text,
            doc_type: Some(doc_type_for(kind).into()),
            title: None,
            extraction_json: ej.as_deref(),
        })
        .collect();

    let events = vec![
        parser::ProfileEvent {
            kind: "enable".into(),
            package: "sle".into(),
            at: "2024-03-15".into(),
            payload: serde_json::json!({}),
        },
        parser::ProfileEvent {
            kind: "weight".into(),
            package: "sle".into(),
            at: "2026-09-01".into(),
            payload: serde_json::json!({"kg": 56.0}),
        },
    ];

    let pkg = common::full_pkg();
    terminology::set_overlay(common::overlay_entries(&pkg));
    let view = profile::materialize(&docs, &events, &pkg, "2026-09-16".parse().unwrap());
    let got = serde_json::to_value(&view).unwrap();
    terminology::set_overlay(vec![]);
    got
}

/// 返回 `true` = 这次是重写 golden(调用方在全部写完后再 panic 提醒 review)。
fn check_golden(got: serde_json::Value, file: &str) -> bool {
    let golden_path = testdata().join(file);
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::write(
            &golden_path,
            serde_json::to_string_pretty(&got).unwrap() + "\n",
        )
        .unwrap();
        return true;
    }
    let want: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&golden_path).expect("golden 文件在"))
            .expect("golden 是合法 JSON");
    assert_eq!(
        got, want,
        "ProfileView 变了;确认是有意的再 UPDATE_GOLDEN=1 重生成"
    );
    false
}

/// 两条路在**同一个**测试里顺序跑:`terminology::set_overlay` 是进程全局的,拆成两个
/// `#[test]` 会并行、互相清掉对方的覆盖层,golden 时红时绿。
#[test]
fn the_synthetic_sle_course_renders_both_pinned_profile_views() {
    let wrote = check_golden(render(false), "golden_profile_view.json")
        | check_golden(render(true), "golden_profile_view_llm.json");
    assert!(
        !wrote,
        "golden 已重写 —— 人工 review 这次 diff 之后再跑一遍(不带 UPDATE_GOLDEN)"
    );
}

#[test]
#[ignore = "被上面两条取代;保留旧函数体只为对照,下一次清理删掉"]
fn the_synthetic_sle_course_renders_the_pinned_profile_view_old() {
    let corpus = load_corpus();
    assert!(
        corpus.len() >= 12,
        "3 年 4 家医院的病程至少该有十几份文档,实际 {}",
        corpus.len()
    );

    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, (_, kind, date, text))| parser::SourceDoc {
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
            package: "sle".into(),
            at: "2024-03-15".into(),
            payload: serde_json::json!({}),
        },
        parser::ProfileEvent {
            kind: "weight".into(),
            package: "sle".into(),
            at: "2026-09-01".into(),
            payload: serde_json::json!({"kg": 56.0}),
        },
    ];

    // 用的就是**发布出去的那一份**(`common::FULL` = `skills/sle/2026.10.1.src.json`
    // 的原文逐字节),不是另一份长得差不多的夹具 —— 所以这份 golden 钉住的是用户
    // 真会装上的那个包。「签好的信封里也是这一份」由 `shipped_package.rs` 钉住。
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
