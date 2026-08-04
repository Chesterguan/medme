//! End-to-end guard on the **doctor-facing** summary, driven by real documents.
//!
//! Why this file exists
//! --------------------
//! Every layer of the pipeline had unit tests and every one of them was green
//! while the doctor's viewer showed an empty lane for 「2 型糖尿病」: the diabetes
//! swim-lane rendered a blank box, and HbA1c / metformin / dapagliflozin sat in
//! the catch-all 「其他」 bucket instead. The reason no test caught it is that the
//! unit tests fed `match_disease` the *table's own* spelling (`2型糖尿病`), while
//! real reports typeset it with a space (`2 型糖尿病`). Tests written from the
//! same vocabulary as the code can prove "the code matches my idea"; they can
//! never prove "my idea matches reality".
//!
//! So the fixtures under `tests/fixtures/corpus/` are **not authored here**. They
//! are extracted verbatim from `examples/demo-dataset/generate.sh`, the realistic
//! longitudinal corpus for patient 张建国. Regenerate them with the extractor in
//! that directory if the corpus changes; never hand-edit them to make a test pass.
//!
//! What this file asserts is not "the parser is correct" — it is the narrower,
//! checkable property the viewer depends on: **a disease that the problem map
//! claims to track must actually come out with its labs attached**, and the
//! catch-all bucket must not contain page furniture masquerading as an analyte.

use parser::{assemble_summary, SourceDoc};
use serde_json::Value;
use std::path::Path;

/// Load every fixture, deriving date and type exactly the way production does
/// (`parser::classify` + `parser::guess_date` over the document text), so the
/// summary under test is assembled from the same inputs a real import produces.
fn corpus() -> Vec<(String, String)> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/corpus");
    let mut docs: Vec<(String, String)> = std::fs::read_dir(&dir)
        .expect("corpus fixtures are checked in next to this test")
        .filter_map(|e| {
            let p = e.ok()?.path();
            if p.extension()? != "txt" {
                return None;
            }
            let name = p.file_stem()?.to_str()?.to_string();
            Some((name, std::fs::read_to_string(&p).ok()?))
        })
        .collect();
    docs.sort_by(|a, b| a.0.cmp(&b.0));
    assert!(
        docs.len() >= 15,
        "expected the full demo corpus, found {} files — did the extractor run?",
        docs.len()
    );
    docs
}

fn summary() -> Value {
    let raw = corpus();
    let docs: Vec<SourceDoc<'_>> = raw
        .iter()
        .enumerate()
        .map(|(i, (name, text))| SourceDoc {
            index: i,
            date: parser::guess_date(text).map(|d| d.date_naive()),
            text: text.as_str(),
            doc_type: Some(format!("{:?}", parser::classify(text)).to_lowercase()),
            title: Some(name.clone()),
        })
        .collect();
    assemble_summary(&docs)
}

fn problems(sm: &Value) -> Vec<&Value> {
    sm.get("problems")
        .and_then(Value::as_array)
        .map(|a| a.iter().collect())
        .unwrap_or_default()
}

fn term_of(p: &Value) -> &str {
    p.get("term").and_then(Value::as_str).unwrap_or("")
}

fn count(p: &Value, field: &str) -> usize {
    p.get(field).and_then(Value::as_array).map_or(0, Vec::len)
}

/// The regression that started all this: 张建国 is a diagnosed type-2 diabetic
/// whose corpus contains HbA1c, fasting glucose, LDL, metformin and
/// dapagliflozin — every one of them listed in the problem map's diabetes entry.
/// A doctor clicking that lane must see them.
#[test]
fn diabetes_lane_is_not_empty() {
    let sm = summary();
    let probs = problems(&sm);
    let dm = probs
        .iter()
        .find(|p| term_of(p).contains("糖尿病") && !term_of(p).contains("肾病"))
        .unwrap_or_else(|| {
            panic!(
                "no diabetes problem at all; lanes were: {:?}",
                probs.iter().map(|p| term_of(p)).collect::<Vec<_>>()
            )
        });

    assert!(
        count(dm, "labs") > 0,
        "「{}」 has zero labs — the doctor sees a blank box. HbA1c and LDL are in \
         the corpus and in the problem map, so they must attach here rather than \
         fall through to the 其他 bucket.",
        term_of(dm)
    );
    assert!(
        count(dm, "meds") > 0,
        "「{}」 has zero meds — metformin and dapagliflozin are prescribed in the \
         corpus and their ATC codes are covered by the map entry.",
        term_of(dm)
    );
}

/// What the documents name, the doctor must be served — with the reading of the
/// documents done by a person, not by the code under test.
///
/// Two wrong versions of this test shipped before this one, both green, both
/// useless:
///
/// 1. `problems.filter(|p| match_disease(p.term).is_some())` — asks the matcher
///    which lanes should have matched, so a matcher that fires on nothing empties
///    the test's own scope and the assertion passes on an empty set.
/// 2. Gating on `corpus_line.contains(raw_map_name)` — the map's `disease` field
///    carries editorial furniture (`慢性肾脏病(CKD)`, `痛风/高尿酸血症`) that no
///    report prints, so the gate reproduced, inside the test, the exact defect
///    `disease_aliases` exists to remove. It put 2 of 10 diseases in scope and
///    stayed green when the alias expansion was reverted.
///
/// Both failed the same way: the gate consulted logic that the bug had broken.
/// So the gate is now **data** — a list written by reading the 20 fixtures, each
/// entry citing the file and line it came from. It cannot be emptied by a
/// regression in the code it guards.
///
/// Known gaps are listed too, and asserted **as gaps**. A gap that is silently
/// filtered out is indistinguishable from a gap that has been fixed; asserting
/// it means this test also tells us the day it starts working.
#[test]
fn diseases_named_in_the_documents_get_a_lane_with_content() {
    // (disease named in a document, where it is written)
    const NAMED_AND_SERVED: &[(&str, &str)] = &[
        (
            "2型糖尿病",
            "2023-04-24_出院记录_脑梗死.txt — `出院诊断:… 3. 2 型糖尿病`",
        ),
        (
            "高血压",
            "2023-04-24_出院记录_脑梗死.txt — `出院诊断:… 2. 高血压 3 级(很高危)`",
        ),
    ];

    // Named by a document, still not served. Each needs a fix elsewhere; until
    // then the assertion below pins the *current* behaviour so the day it changes
    // is visible.
    const NAMED_BUT_MISSING: &[(&str, &str)] = &[
        (
            "高尿酸血症",
            "2026-06-20_处方_内分泌科.txt:4 — the line reads \
             `处方日期:2026-06-20    临床诊断:2 型糖尿病、糖尿病肾病(早期)、高尿酸血症`. \
             conditions.rs `section_re` is `^`-anchored, so a 诊断 label sitting \
             mid-line takes the whole line's diagnoses down with it.",
        ),
        (
            "脂肪肝",
            "2024-03-22_腹部超声_脂肪肝.txt:13 — `1. 脂肪肝(中度)。` under 提示, \
             which is not a diagnosis-section label; and 脂肪肝 is a synonym of \
             代谢相关(非酒精性)脂肪性肝病 rather than a spelling of it, which the \
             mechanical alias expansion deliberately does not invent.",
        ),
    ];

    let sm = summary();
    let lanes: Vec<(&str, usize, usize)> = problems(&sm)
        .into_iter()
        .map(|p| (term_of(p), count(p, "labs"), count(p, "meds")))
        .collect();
    let lane_for = |disease: &str| {
        lanes
            .iter()
            .find(|(term, _, _)| parser::match_disease(term) == Some(disease))
            .copied()
    };

    let mut failures = Vec::new();
    for (disease, whence) in NAMED_AND_SERVED {
        match lane_for(disease) {
            None => failures.push(format!("`{disease}` has no lane — named in {whence}")),
            Some((term, 0, 0)) => {
                failures.push(format!("lane `{term}` is empty — `{disease}` named in {whence}"))
            }
            Some(_) => {}
        }
    }
    assert!(
        failures.is_empty(),
        "diseases the documents name but the viewer fails to serve:\n  {}\n\
         (lanes assembled: {lanes:?})",
        failures.join("\n  ")
    );

    for (disease, why) in NAMED_BUT_MISSING {
        assert!(
            lane_for(disease).is_none(),
            "`{disease}` now gets a lane — good news, but this test still lists it \
             as a known gap. Move it to NAMED_AND_SERVED. Context: {why}"
        );
    }
}

/// A lab series the viewer cannot draw must not be announced. Every renderer
/// builds a row out of `pts` (trend line, latest value, date chip, evidence
/// link), so a series whose points are all undated shows nothing — and shipping
/// it produces a bare 相关化验 heading over empty space, on a lane that may
/// already be badged 需关注. Worse than the blank box we set out to remove.
///
/// Reachable from real input: a report whose clinical date OCR can't recover
/// gives every point `date: None`.
#[test]
fn no_lab_series_is_announced_without_a_drawable_point() {
    let sm = summary();
    let mut bad = Vec::new();
    for p in problems(&sm) {
        for l in p.get("labs").and_then(Value::as_array).into_iter().flatten() {
            let pts = l.get("pts").and_then(Value::as_array).map_or(0, Vec::len);
            if pts == 0 {
                bad.push(format!(
                    "{} → {}",
                    term_of(p),
                    l.get("name").and_then(Value::as_str).unwrap_or("?")
                ));
            }
        }
    }
    assert!(
        bad.is_empty(),
        "these series would render as an empty row under a 相关化验 heading: {bad:#?}"
    );
}

/// Document furniture — the demographics header, the report timestamp, the
/// specimen line — is not an analyte. When it leaks into the summary it does not
/// merely add noise: the viewer draws it a sparkline and flags it red, so the
/// doctor sees a fabricated trend sitting next to a real creatinine curve.
#[test]
fn no_page_furniture_is_reported_as_an_analyte() {
    let sm = summary();
    // Substrings that can only come from a header line, never from an analyte name.
    const FURNITURE: &[&str] = &["姓名", "性别", "门诊号", "报告时间", "样本类型", "采集时间"];

    let mut bad: Vec<String> = Vec::new();
    for p in problems(&sm) {
        for l in p.get("labs").and_then(Value::as_array).into_iter().flatten() {
            let name = l.get("name").and_then(Value::as_str).unwrap_or("");
            if FURNITURE.iter().any(|f| name.contains(f)) {
                bad.push(format!("{} → {}", term_of(p), name));
            }
        }
    }

    assert!(
        bad.is_empty(),
        "header text is being charted as a lab series: {bad:#?}"
    );
}
