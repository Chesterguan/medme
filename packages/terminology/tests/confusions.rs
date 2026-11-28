//! **解析混淆闸(spec A5)。** 一份已知易混对清单:每一行给「报告上印的项目名 +
//! 印刷单位」,断言 `resolve` 落在哪个规范键上(或必须 miss)。
//!
//! 为什么不挂在 MedRepBench 上:那份语料要 `MEDREP_ROOT`,CI 没有,挂上去等于没有闸。
//! 这份清单是**从评测里捞出来、钉进仓库**的常量,任何人改别名/改阈值/改模糊策略都
//! 当场知道有没有撞回已知的坑。新发现的混淆对往 `testdata/confusions.json` 里加一行,
//! 不改这个文件。
//!
//! 闸的判据(两条都要过):**混淆数为 0**,且任何一行都不许靠 0.4 的模糊命中过关——
//! 猜对了也是猜。

use std::path::Path;

#[derive(serde::Deserialize)]
struct Row {
    name: String,
    unit: String,
    expect: Option<String>,
    why: String,
}

fn rows() -> Vec<Row> {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/confusions.json");
    let raw = std::fs::read_to_string(&p).expect("confusions.json 必须在 testdata/ 下");
    serde_json::from_str(&raw).expect("confusions.json 必须是合法 JSON 数组")
}

#[test]
fn every_known_confusion_pair_resolves_to_the_right_concept() {
    let rows = rows();
    assert!(rows.len() >= 11, "清单被截短了?只剩 {} 行", rows.len());
    let mut bad: Vec<String> = Vec::new();
    for r in &rows {
        let got = terminology::resolve(&r.name, Some(&r.unit));
        match (&r.expect, &got) {
            (Some(want), Some(m)) if &m.key == want => {
                if m.confidence <= 0.4 {
                    bad.push(format!(
                        "{:?}({}) 配到 {} 但只是 0.4 的模糊猜 —— {}",
                        r.name, r.unit, m.key, r.why
                    ));
                }
            }
            (Some(want), Some(m)) => bad.push(format!(
                "{:?}({}) 应为 {want},实得 {}({}) —— {}",
                r.name, r.unit, m.key, m.confidence, r.why
            )),
            (Some(want), None) => bad.push(format!(
                "{:?}({}) 应为 {want},实得 miss —— {}",
                r.name, r.unit, r.why
            )),
            (None, Some(m)) => bad.push(format!(
                "{:?}({}) 必须 miss,却配到了 {} —— {}",
                r.name, r.unit, m.key, r.why
            )),
            (None, None) => {}
        }
    }
    assert!(
        bad.is_empty(),
        "混淆数必须为 0,实得 {}:\n{}",
        bad.len(),
        bad.join("\n")
    );
    eprintln!("confusion gate: {} 行全过", rows.len());
}
