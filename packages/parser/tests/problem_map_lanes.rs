//! Guard on **which lane a drug lands in**, for the ATC prefixes the problem map
//! claims to cover.
//!
//! Why this file exists
//! --------------------
//! `problem_map.json` grew seven ATC prefixes (`C03BA`, `C09B`, `C09DA`, `C09DB`,
//! `A10BD`, `C10B`) plus the whole code `C10BX03`, and the suite stayed green
//! before and after — because it had **zero coverage of any of them**. None of the
//! 20 corpus fixtures prescribes indapamide or any of the fixed-dose combinations;
//! the drug names appear nowhere in the repo except `dictionary.json` and
//! `problem_map.json` themselves. Delete one of those lines tomorrow and every
//! test still passes, while a hypertensive patient's lane silently loses its only
//! antihypertensive.
//!
//! The defect being guarded is not "the parser is wrong" — it is a **table entry
//! going missing**, which is invisible to every test that does not name the drug.
//! So the expectations here are written as data: an ATC code, the lanes it must
//! appear under, and why. Removing a row from the map empties a lane and turns
//! this file red.
//!
//! Two layers, deliberately:
//!
//! 1. [`indapamide_and_amlodipine_atorvastatin_reach_their_lanes`] drives the
//!    **real pipeline** (`assemble_summary`) over a synthetic prescription, so it
//!    also proves the dictionary → ATC → lane chain is intact end to end. It is
//!    the load-bearing one.
//! 2. [`atc_codes_land_in_the_expected_lanes`] applies the map's prefix rule to a
//!    table of codes, covering every prefix the branch added plus the near-misses
//!    that must *not* match. It reimplements one line of `assemble_summary`
//!    (`atc.starts_with(prefix)`) against the shipped JSON; layer 1 is what pins
//!    that line to production behaviour.

use parser::{assemble_summary, SourceDoc};
use serde_json::Value;
use std::collections::BTreeSet;

// ─────────────────────────── layer 1: end to end ───────────────────────────

/// A prescription naming all five cardiometabolic diseases in the map, so every
/// lane a combination product *could* reach actually exists in the summary and
/// "absent from lane X" is a real assertion rather than "lane X wasn't there".
///
/// Written in the layout of `tests/fixtures/corpus/*_处方_*.txt`, but authored
/// here on purpose: the corpus is a fixed real-patient dataset that happens to
/// contain none of these drugs, and editing it to insert them would corrupt a
/// fixture whose value is that nobody wrote it to make a test pass.
const PRESCRIPTION: &str = "\
北京协和医院 门诊处方笺

姓名:张某某    性别:男    年龄:64岁    科室:心内科
处方日期:2026-07-15
临床诊断:高血压、高脂血症、冠心病、2 型糖尿病、慢性肾脏病 3 期

Rp.
1. 吲达帕胺片 Indapamide  2.5mg × 30 片
   用法:口服,一次 1 片,一日 1 次(晨服)
2. 氨氯地平阿托伐他汀钙片 Amlodipine/Atorvastatin  5mg/20mg × 28 片
   用法:口服,一次 1 片,一日 1 次(睡前)

医师:李某    药师(审核/调配):王某
";

/// `(lane term, med names on that lane)` for the synthetic prescription above.
fn lanes() -> Vec<(String, Vec<String>)> {
    let doc = SourceDoc {
        index: 0,
        date: parser::guess_date(PRESCRIPTION).map(|d| d.date_naive()),
        text: PRESCRIPTION,
        doc_type: Some(format!("{:?}", parser::classify(PRESCRIPTION)).to_lowercase()),
        title: Some("2026-07-15_处方_心内科".to_string()),
    };
    assemble_summary(&[doc])
        .get("problems")
        .and_then(Value::as_array)
        .map(|ps| {
            ps.iter()
                .map(|p| {
                    let term = p
                        .get("term")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let meds = p
                        .get("meds")
                        .and_then(Value::as_array)
                        .map(|ms| {
                            ms.iter()
                                .filter_map(|m| m.get("name").and_then(Value::as_str))
                                .map(str::to_string)
                                .collect()
                        })
                        .unwrap_or_default();
                    (term, meds)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Lane terms (as printed in the document) whose med list mentions `drug`.
fn lanes_carrying(lanes: &[(String, Vec<String>)], drug: &str) -> BTreeSet<String> {
    lanes
        .iter()
        .filter(|(_, meds)| meds.iter().any(|m| m.contains(drug)))
        .map(|(term, _)| term.clone())
        .collect()
}

/// The two drugs this branch exists for, through the pipeline a real import runs.
///
/// Indapamide is a thiazide-like diuretic — one of the five first-line
/// antihypertensive classes in 《中国高血压防治指南（2024年修订版）》 — and its ATC
/// `C03BA11` is matched by no prefix the hypertension lane held before `C03BA`
/// was added. Amlodipine/atorvastatin `C10BX03` contains amlodipine, so a patient
/// on nothing else must not see a hypertension lane with zero antihypertensives.
#[test]
fn indapamide_and_amlodipine_atorvastatin_reach_their_lanes() {
    let lanes = lanes();
    let terms: Vec<&str> = lanes.iter().map(|(t, _)| t.as_str()).collect();

    // Sanity: the diagnoses must have produced lanes at all, otherwise the
    // membership assertions below would pass vacuously on an empty summary.
    for named in ["高血压", "高脂血症", "冠心病"] {
        assert!(
            lanes
                .iter()
                .any(|(t, _)| parser::match_disease(t).is_some() && t.contains(named)),
            "the prescription names 「{named}」 but no lane came out for it; lanes: {terms:?}"
        );
    }

    // C03BA11 — hypertension (C03BA, added here) and CKD (the pre-existing broad
    // C03 diuretics prefix; a thiazide-like diuretic genuinely belongs there).
    let indapamide = lanes_carrying(&lanes, "吲达帕胺");
    assert!(
        indapamide.iter().any(|t| t.contains("高血压")),
        "吲达帕胺 (C03BA11) is missing from the hypertension lane — the patient's \
         only antihypertensive is invisible there. Lanes carrying it: {indapamide:?}; \
         all lanes: {terms:?}"
    );
    assert!(
        !indapamide.iter().any(|t| t == "其他"),
        "吲达帕胺 fell through to the 其他 bucket, i.e. it matched no lane at all"
    );

    // C10BX03 — hyperlipidaemia + CAD (via the C10B prefix, for the atorvastatin)
    // and hypertension (via the whole code, for the amlodipine).
    let combo = lanes_carrying(&lanes, "氨氯地平阿托伐他汀");
    for (needle, why) in [
        (
            "高血压",
            "it contains amlodipine (C08CA01); the whole code C10BX03 is in the \
             hypertension entry precisely so this patient's lane is not empty",
        ),
        (
            "高脂血症",
            "it contains atorvastatin; matched by the C10B prefix",
        ),
        (
            "冠心病",
            "ASCVD secondary prevention must show the lipid-lowering exposure; \
             matched by the C10B prefix",
        ),
    ] {
        assert!(
            combo.iter().any(|t| t.contains(needle)),
            "氨氯地平阿托伐他汀 (C10BX03) is missing from the 「{needle}」 lane — {why}. \
             Lanes carrying it: {combo:?}; all lanes: {terms:?}"
        );
    }
    assert!(
        !combo.iter().any(|t| t == "其他"),
        "氨氯地平阿托伐他汀 fell through to the 其他 bucket"
    );
}

// ────────────────────── layer 2: the table, code by code ──────────────────────

/// The shipped map, as `(disease, [atc prefix])`. Read from the same file the
/// parser compiles in, so a row deleted there is a row missing here.
fn map_prefixes() -> Vec<(String, Vec<String>)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("data/problem_map.json");
    let raw = std::fs::read_to_string(&path).expect("problem_map.json ships next to the parser");
    let v: Value = serde_json::from_str(&raw).expect("problem_map.json is valid JSON");
    v.as_array()
        .expect("problem_map.json is an array of disease entries")
        .iter()
        .map(|e| {
            let disease = e["disease"].as_str().unwrap_or_default().to_string();
            let prefixes = e["drugs"]
                .as_array()
                .map(|ds| {
                    ds.iter()
                        .filter_map(|d| d["atc"].as_str())
                        .map(|a| a.trim_end_matches('*').to_string())
                        .filter(|a| !a.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            (disease, prefixes)
        })
        .collect()
}

/// Which lanes a fully-specified ATC code lands on. Mirrors the one line of
/// `assemble_summary` that does the placement (`atc.starts_with(prefix)`); the
/// end-to-end test above is what keeps that mirror honest.
fn lanes_for_atc(map: &[(String, Vec<String>)], atc: &str) -> BTreeSet<String> {
    map.iter()
        .filter(|(_, prefixes)| prefixes.iter().any(|p| atc.starts_with(p.as_str())))
        .map(|(disease, _)| disease.clone())
        .collect()
}

/// Every prefix this branch added, exercised through a real drug's full ATC code,
/// together with the near-misses that must **not** match.
///
/// The negative rows are the point of the table. `C10BA10` (bempedoic acid +
/// ezetimibe) is why the hypertension entry carries the whole code `C10BX03`
/// rather than the `C10B` prefix: `C10BA` is "Combinations of various lipid
/// modifying agents", contains no antihypertensive, and a prefix there would
/// hang a lipid drug off a blood-pressure lane. The rows expecting an empty or
/// partial lane set encode the gaps documented under 「已知缺口（待临床裁定）」
/// in `problem_map.methodology.md` — asserted as gaps, so the day one is filled
/// this test says so instead of quietly agreeing.
#[test]
fn atc_codes_land_in_the_expected_lanes() {
    const DM: &str = "2型糖尿病";
    const HTN: &str = "高血压";
    const LIPID: &str = "高脂血症(血脂异常)";
    const CAD: &str = "冠心病";
    const CKD: &str = "慢性肾脏病(CKD)";

    // (ATC code, drug, expected lanes, why)
    #[allow(clippy::type_complexity)]
    let cases: &[(&str, &str, &[&str], &str)] = &[
        // ── prefixes added by this branch ──
        (
            "C03BA11",
            "吲达帕胺",
            &[HTN, CKD],
            "噻嗪样利尿剂, 指南一线降压药 (C03BA); 亦是利尿剂, 落 CKD 的 C03",
        ),
        ("C03BA04", "氯噻酮", &[HTN, CKD], "同 C03BA, 噻嗪样利尿剂"),
        (
            "C09BA04",
            "培哚普利吲达帕胺",
            &[HTN, CAD, CKD],
            "ACEI+利尿剂固定复方 (C09B); CAD/CKD 用的是宽前缀 C09",
        ),
        (
            "C09DA01",
            "氯沙坦钾氢氯噻嗪",
            &[HTN, CAD, CKD],
            "ARB+利尿剂固定复方 (C09DA)",
        ),
        (
            "C09DB01",
            "缬沙坦氨氯地平",
            &[HTN, CAD, CKD],
            "ARB+CCB 固定复方 (C09DB)",
        ),
        (
            "A10BD07",
            "西格列汀二甲双胍",
            &[DM],
            "口服降糖药固定复方 (A10BD), 成员按 ATC 定义必为降糖药",
        ),
        (
            "C10BA02",
            "辛伐他汀依折麦布",
            &[LIPID, CAD],
            "调脂药固定复方 (C10B); 不入高血压——无降压成分",
        ),
        // ── the whole code added on top of the prefixes ──
        (
            "C10BX03",
            "氨氯地平阿托伐他汀",
            &[HTN, LIPID, CAD],
            "含氨氯地平, 故整码入高血压; 含阿托伐他汀, 故经 C10B 入血脂/冠心病",
        ),
        // ── negative controls: the reason it is a whole code, not a prefix ──
        (
            "C10BA10",
            "贝派地酸依折麦布",
            &[LIPID, CAD],
            "C10BA 按 WHOCC 定义是调脂药相互组合, 不含降压成分——若高血压挂了 \
             C10B 前缀, 这一行会错挂到高血压泳道",
        ),
        // ── documented gaps, asserted as gaps ──
        (
            "C02CA06",
            "乌拉地尔",
            &[],
            "已知缺口 1: 高血压泳道对整个 C02 ANTIHYPERTENSIVES 零覆盖, 暂缓待人工核",
        ),
        (
            "C09DX04",
            "沙库巴曲缬沙坦",
            &[CAD, CKD],
            "已知缺口 2: 未入高血压 (主适应证 HFrEF, 表内无心衰条目); \
             落 CAD/CKD 是那两条既有的宽前缀 C09 所致",
        ),
        (
            "C08DB01",
            "地尔硫䓬",
            &[],
            "已知缺口 3: 未入高血压 (无法从 ATC 区分用药意图), 该尺子与既有 C07A 不自洽",
        ),
    ];

    let map = map_prefixes();
    let known: BTreeSet<&str> = map.iter().map(|(d, _)| d.as_str()).collect();

    let mut failures: Vec<String> = Vec::new();
    for (atc, drug, expected, why) in cases {
        for d in *expected {
            assert!(
                known.contains(d),
                "test names a disease `{d}` that is not in problem_map.json; \
                 the map's entries are {known:?}"
            );
        }
        let want: BTreeSet<String> = expected.iter().map(|d| (*d).to_string()).collect();
        let got = lanes_for_atc(&map, atc);
        if got != want {
            let missing: Vec<&String> = want.difference(&got).collect();
            let extra: Vec<&String> = got.difference(&want).collect();
            failures.push(format!(
                "{atc} ({drug}): expected {want:?}, got {got:?}\n      missing: {missing:?}  \
                 unexpected: {extra:?}\n      rationale: {why}"
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "problem_map.json places these ATC codes on the wrong lanes:\n  - {}",
        failures.join("\n  - ")
    );
}

/// The counts printed in `problem_map.methodology.md` are shown to doctors as a
/// claim about coverage — the bibliography that section belongs to is rendered in
/// the app. They went stale once already (still 37 drug rows after the table
/// reached 44), which is how a bibliography starts lying. Pin them to the table.
///
/// Only the methodology doc is checked here: it ships inside this package, next
/// to the JSON. `docs/030_Clinical_Handoff.md` carries the same numbers and was
/// updated alongside, but it lives outside the crate and a test that reaches up
/// past `CARGO_MANIFEST_DIR` breaks the moment the package is vendored.
#[test]
fn documented_row_counts_match_the_table() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("data/problem_map.json");
    let v: Value = serde_json::from_str(&std::fs::read_to_string(&path).expect("map is readable"))
        .expect("map is valid JSON");
    let entries = v.as_array().expect("map is an array");

    let diseases = entries.len();
    let labs: usize = entries
        .iter()
        .map(|e| e["labs"].as_array().map_or(0, Vec::len))
        .sum();
    let drugs: usize = entries
        .iter()
        .map(|e| e["drugs"].as_array().map_or(0, Vec::len))
        .sum();

    let methodology = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("data/problem_map.methodology.md"),
    )
    .expect("methodology doc ships with the map");
    let claim = format!("{labs} 条实验室映射、{drugs} 条药物映射");
    assert!(
        methodology.contains(&claim),
        "problem_map.methodology.md no longer states the table's real size. \
         The table now holds {diseases} diseases, {labs} lab rows and {drugs} drug rows, \
         so the 覆盖情况 section must read 「{claim}」."
    );
    assert!(
        methodology.contains(&format!("共覆盖 {diseases} 个疾病条目")),
        "problem_map.methodology.md no longer states the table's real disease count ({diseases})"
    );
}
