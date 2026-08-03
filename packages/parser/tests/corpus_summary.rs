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

/// Generalization of the above. Getting this one right matters more than it
/// looks, because the obvious phrasing is **vacuous**:
///
/// ```ignore
/// problems.filter(|p| match_disease(p.term).is_some())   // ← WRONG
///         .assert(|p| !p.labs.is_empty())
/// ```
///
/// That filter asks the matcher which lanes should have matched — so the exact
/// failure we are guarding against (the matcher not firing) removes the lane
/// from the test's own scope and the assertion passes on an empty set. Verified
/// by reverting the fix: this test stayed green while `diabetes_lane_is_not_empty`
/// went red. It is the same tautology that let the original bug ship.
///
/// So "should have matched" is decided from the **documents**, not the matcher:
/// if a curated disease name appears in the corpus text, a lane for it must
/// exist and must carry something. Diagnoses outside the curated map are exempt
/// — that is a coverage gap, tracked separately, not a silent failure.
#[test]
fn diseases_named_in_the_documents_get_a_lane_with_content() {
    let map: Value = serde_json::from_str(include_str!("../data/problem_map.json"))
        .expect("problem_map.json parses");
    let diseases: Vec<String> = map
        .as_array()
        .expect("problem_map is an array")
        .iter()
        .filter_map(|e| e.get("disease")?.as_str().map(str::to_string))
        .collect();
    assert!(!diseases.is_empty(), "problem map is empty — wrong shape?");

    // Normalize per line, not per document: `normalize_term` drops newlines too,
    // so a whole-file blob can "contain" a disease name glued together out of
    // two unrelated lines — the gate would then demand a lane for a disease no
    // document actually names.
    let raw = corpus();
    let corpus_lines: Vec<String> = raw
        .iter()
        .flat_map(|(_, t)| t.lines())
        .map(terminology::normalize_term)
        .collect();

    let sm = summary();
    let lanes: Vec<(&str, usize, usize)> = problems(&sm)
        .into_iter()
        .map(|p| (term_of(p), count(p, "labs"), count(p, "meds")))
        .collect();

    let mut missing = Vec::new();
    let mut hollow = Vec::new();
    for d in &diseases {
        // Does any document line actually say this disease? (Normalized, so
        // typeset spacing in the report doesn't decide the answer.)
        let dn = terminology::normalize_term(d);
        if !corpus_lines.iter().any(|l| l.contains(&dn)) {
            continue;
        }
        match lanes
            .iter()
            .find(|(term, _, _)| parser::match_disease(term) == Some(d.as_str()))
        {
            None => missing.push(d.clone()),
            Some((term, labs, meds)) if *labs == 0 && *meds == 0 => {
                hollow.push((*term).to_string())
            }
            Some(_) => {}
        }
    }

    assert!(
        missing.is_empty() && hollow.is_empty(),
        "diseases the documents name but the viewer fails to serve:\n  \
         no lane at all: {missing:?}\n  lane present but empty: {hollow:?}\n  \
         (lanes assembled: {lanes:?})"
    );
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
