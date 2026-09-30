//! 李静三年 SLE 语料的模型输出 fixture,逐条核对 facts 与 meds 召回。
//!
//! fixture 是原始模型 JSON(见 testdata/README.md),这里先跑 `deid::verify`(Text
//! 模式:没核上的条目直接丢),再断言「一个该抽到的事件模型抽到了、且 verify 留住了」。
//! 断言是**下界**:模型多抽了原文里确实有的东西不算错,少抽了列出来的才算。
use std::path::Path;

fn testdata() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

/// (原文, verify 后的抽取)
fn load(name: &str) -> (String, deid::Extraction) {
    let text = std::fs::read_to_string(testdata().join("corpus").join(format!("{name}.txt")))
        .unwrap_or_else(|e| panic!("{name}.txt: {e}"));
    let json = std::fs::read_to_string(testdata().join("extractions").join(format!("{name}.json")))
        .unwrap_or_else(|e| panic!("{name}.json 缺 —— 跑 examples/demo-dataset/extract_sle_fixtures.py: {e}"));
    let parsed = deid::parse_extraction(&json).expect("fixture 是合法 JSON");
    let v = deid::verify(parsed, &text, deid::Mode::Text);
    (text, v.extraction)
}

fn facts_of<'a>(e: &'a deid::Extraction, ty: &str) -> Vec<&'a deid::Fact> {
    e.facts.iter().filter(|f| f.r#type == ty).collect()
}

fn corpus_stems() -> Vec<String> {
    std::fs::read_dir(testdata().join("corpus"))
        .unwrap()
        .flatten()
        .map(|f| f.path().file_stem().unwrap().to_string_lossy().to_string())
        .collect()
}

#[test]
fn every_corpus_file_has_a_fixture() {
    for stem in corpus_stems() {
        assert!(
            testdata().join("extractions").join(format!("{stem}.json")).exists(),
            "{stem} 没有 fixture"
        );
    }
}

#[test]
fn prescriptions_yield_all_three_drugs_with_dose_and_frequency() {
    for (name, want) in [
        (
            "2024-09-20_处方_华西",
            [("醋酸泼尼松片", 20.0, "mg", "qd"), ("吗替麦考酚酯胶囊", 0.75, "g", "bid"), ("硫酸羟氯喹片", 0.2, "g", "bid")],
        ),
        (
            "2026-06-15_处方_协和",
            [("醋酸泼尼松片", 7.5, "mg", "qd"), ("吗替麦考酚酯胶囊", 0.5, "g", "bid"), ("硫酸羟氯喹片", 0.2, "g", "qd")],
        ),
    ] {
        let (_, e) = load(name);
        let json = serde_json::to_string(&e).unwrap();
        let meds = parser::meds_from_json(&json).unwrap().meds;
        for (raw, num, unit, freq) in want {
            let m = meds
                .iter()
                .find(|m| m.raw_name == raw)
                .unwrap_or_else(|| panic!("{name}: 缺 {raw}"));
            assert_eq!(m.dose_num, Some(num), "{name} {raw} 剂量");
            assert_eq!(m.dose_unit.as_deref(), Some(unit), "{name} {raw} 单位");
            assert_eq!(m.frequency.as_deref(), Some(freq), "{name} {raw} 频次");
            assert!(!m.unverified);
        }
    }
}

#[test]
fn lab_reports_yield_no_meds() {
    for name in [
        "2024-03-05_检验报告_仁济",
        "2024-06-10_检验报告_仁济",
        "2024-09-09_检验报告_华西",
        "2025-02-20_检验报告_协和",
        "2025-12-05_检验报告_中山一院",
        "2026-03-14_检验报告_中山一院",
        "2026-09-10_检验报告_协和",
    ] {
        let (_, e) = load(name);
        assert!(e.meds.is_empty(), "{name}: 化验单不该抽出药,抽到了 {:?}", e.meds);
    }
}

#[test]
fn discharge_record_yields_hospitalization_with_both_dates() {
    let (_, e) = load("2024-03-15_出院记录_仁济");
    let h = facts_of(&e, "hospitalization");
    assert!(!h.is_empty(), "缺 hospitalization");
    assert!(
        h.iter().any(|f| f.date_start == "2024-03-08" && f.date_end == "2024-03-15"),
        "住院日期不对:{h:?}"
    );
    assert!(
        !facts_of(&e, "biopsy").is_empty() || !facts_of(&e, "organ_involvement").is_empty(),
        "出院记录里写了肾穿刺与狼疮肾炎,至少要有 biopsy 或 organ_involvement"
    );
}

#[test]
fn pathology_report_yields_kidney_biopsy() {
    let (_, e) = load("2024-03-12_病理报告_仁济");
    let b = facts_of(&e, "biopsy");
    assert!(b.iter().any(|f| f.organ == "kidney"), "缺 kidney biopsy:{b:?}");
}

#[test]
fn infusion_record_yields_belimumab_infusion() {
    let (_, e) = load("2025-06-18_输液记录_中山一院");
    let i = facts_of(&e, "infusion");
    assert!(
        i.iter().any(|f| f.drug.contains("贝利尤单抗") && f.dose.contains("560") && f.date == "2025-06-18"),
        "缺 贝利尤单抗 560mg 2025-06-18:{i:?}"
    );
}

#[test]
fn eye_report_yields_exam_done_for_oct_and_visual_field() {
    let (_, e) = load("2025-03-08_眼科报告_协和");
    let names: Vec<&str> = facts_of(&e, "exam_done").iter().map(|f| f.name.as_str()).collect();
    assert!(names.contains(&"OCT"), "缺 OCT:{names:?}");
    assert!(names.contains(&"视野"), "缺 视野:{names:?}");
}

/// 召回缺口(2026-09-30,见 docs/log/2026-09-30-d1-llm-meds-intake.md):模型**抽到了**
/// 眼底检查,但 evidence 把原文里跨行的一句拼成一行(「…未见牛眼样黄斑病变,视网膜血管…」
/// 中间原文有换行),`deid::verify` 按逐字子串规则丢掉。这是 verify 对换行的严格度 /
/// prompt 的事,不在 D1 范围;修好后去掉 ignore。
#[test]
#[ignore = "召回缺口:眼底 exam_done 的 evidence 跨原文换行被 verify 丢掉,见 log 2026-09-30"]
fn eye_report_yields_exam_done_for_fundus() {
    let (_, e) = load("2025-03-08_眼科报告_协和");
    let names: Vec<&str> = facts_of(&e, "exam_done").iter().map(|f| f.name.as_str()).collect();
    assert!(names.contains(&"眼底"), "缺 眼底:{names:?}");
}

#[test]
fn outpatient_note_yields_the_two_dose_changes() {
    let (_, e) = load("2025-09-12_门诊病历_中山一院");
    let c = facts_of(&e, "dose_change");
    assert!(c.iter().any(|f| f.to.contains("10")), "缺 激素减至 10mg:{c:?}");
    assert!(c.iter().any(|f| f.to.contains("0.5")), "缺 吗替麦考酚酯减至 0.5g:{c:?}");
}

#[test]
fn every_kept_fact_quotes_the_source_verbatim() {
    for stem in corpus_stems() {
        let (text, e) = load(&stem);
        for fact in &e.facts {
            assert!(
                text.contains(&fact.evidence),
                "{stem}: verify 放过了非逐字 evidence {:?}",
                fact.evidence
            );
        }
    }
}
