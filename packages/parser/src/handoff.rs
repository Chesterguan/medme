//! Doctor-summary assembly (stage B, slice ④).
//!
//! Turns a share's source documents into the `summary` object the hosted viewer
//! renders (disease swimlanes + trends, docs/030 §3). Deterministic: no network,
//! no LLM. Builds on [`crate::aggregate`] (the derived clinical layer) and a
//! curated **problem → analyte/drug map** ([`problem_map.json`], 10 chronic
//! diseases): labs are grouped under a problem by LOINC, meds by ATC prefix.
//!
//! ## What this does NOT do (kept honest)
//! - **No disease inference.** A problem exists only because a diagnosis line
//!   named it; we merely attach the analytes/meds the guideline map associates
//!   with that disease. Unmapped conditions still become problems (empty labs).
//! - **No fuzzy disease matching.** [`match_disease`] is a plain bidirectional
//!   substring test against the 10 mapped names — no synonym table, no ICD lookup.
//! - **Imaging is grouped, not interpreted.** [`imaging_impression`] copies the
//!   report's own 所见/结论 section verbatim (no radiology reasoning); an unknown
//!   modality is *not* guessed — the study still lists under the title/影像检查.
//!   Pathology impressions and the viewer's `care_facility` field stay out of
//!   scope. Only problems / labs / meds / allergies / notable_changes / imaging.

use crate::aggregate::{
    aggregate, AggregatedCondition, AnalyteSeries, LabPoint, MedSpan, SourceDoc,
};
use chrono::NaiveDate;
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

/// One lab row in the problem map (only the LOINC is load-bearing here).
#[derive(Deserialize)]
struct MapLab {
    loinc: String,
}

/// One drug class in the problem map (only the ATC prefix is load-bearing).
#[derive(Deserialize)]
struct MapDrug {
    atc: String,
}

/// One mapped chronic disease: its name plus the labs/drugs it groups.
#[derive(Deserialize)]
struct MapEntry {
    disease: String,
    labs: Vec<MapLab>,
    drugs: Vec<MapDrug>,
}

/// Parse the curated problem map once. Serde ignores fields we don't model
/// (icd10, lab name, drug class, source citations).
fn problem_map() -> &'static [MapEntry] {
    static M: OnceLock<Vec<MapEntry>> = OnceLock::new();
    M.get_or_init(|| {
        serde_json::from_str(include_str!("../data/problem_map.json"))
            .expect("problem_map.json is valid")
    })
}

/// Return the mapped disease name if `condition_raw` matches one of the 10
/// mapped chronic diseases, else `None` (the condition still becomes a problem,
/// just without grouped labs/meds).
///
/// Matching rule (deliberately simple + honest): **both sides are normalized
/// through [`terminology::normalize_term`]** (full-width → half-width, all
/// whitespace dropped, lowercased), then a disease matches when its name is a
/// substring of the condition text OR the condition text is a substring of the
/// name. That covers the common shortenings — `"糖尿病"` / `"2型糖尿病"` →
/// `"2型糖尿病"`, `"高血压病3级"` / `"高血压"` → `"高血压"` — without a synonym
/// table. First match in map order wins.
///
/// The normalization is not decoration. Chinese reports typeset diagnoses with
/// spaces (`2 型糖尿病`, `高血压 3 级`), and comparing raw strings silently
/// dropped every lab and drug off the diabetes lane in the doctor's viewer.
/// Never compare a term against the table without normalizing first.
/// Diagnoses that *contain* a mapped disease's alias but are a different disease.
/// Substring matching cannot tell them apart, and inheriting the wrong lane hands
/// a doctor the wrong analytes and the wrong drug classes. Kept to cases that are
/// genuinely distinct entities, not to stage/severity variants.
const NOT_THESE: &[&str] = &[
    // 焦磷酸钙沉积病 — contains 痛风, unrelated to urate.
    "假性痛风",
];

/// Unambiguous negations. `否认冠心病史` and `无痛风病史` are the *absence* of a
/// disease, and substring matching reads them as the disease — handing a doctor
/// a lane of urate labs for a patient the note says does not have gout. Only
/// forms with no second reading are listed: bare `无` is excluded on purpose,
/// because `无症状性高尿酸血症` is a real diagnosis. General negation handling is
/// out of scope (see `conditions.rs`), this only closes the clearest holes.
const NEGATIONS: &[&str] = &["否认", "未见", "既往无", "无既往"];

/// Does the text negate the disease rather than assert it?
fn is_negated(normalized: &str) -> bool {
    NEGATIONS
        .iter()
        .any(|n| normalized.contains(&terminology::normalize_term(n)))
        // `无…病史` / `无…史` — the trailing 史 is what disambiguates it from
        // 无症状性… and friends.
        || (normalized.starts_with('无') && normalized.ends_with('史'))
}

/// The **strict** identity test: does the note name this mapped disease itself,
/// without going through the alias expansion? Used where a match means "these
/// two mentions are the same problem", which merging makes lossy.
fn match_disease_exact(condition_raw: &str) -> Option<&'static str> {
    let c = terminology::normalize_term(condition_raw);
    if c.is_empty() || is_negated(&c) {
        return None;
    }
    problem_map().iter().map(|e| e.disease.as_str()).find(|d| {
        let dn = terminology::normalize_term(d);
        c.contains(&dn) || dn.contains(&c)
    })
}

pub fn match_disease(condition_raw: &str) -> Option<&'static str> {
    let c = terminology::normalize_term(condition_raw);
    if c.is_empty() || is_negated(&c) {
        return None;
    }
    if NOT_THESE
        .iter()
        .any(|x| c.contains(&terminology::normalize_term(x)))
    {
        return None;
    }
    for e in problem_map() {
        let d = e.disease.as_str();
        if disease_aliases(d)
            .iter()
            .any(|dn| c.contains(dn.as_str()) || dn.contains(&c))
        {
            return Some(d);
        }
    }
    None
}

fn entry_for(disease: &str) -> Option<&'static MapEntry> {
    problem_map().iter().find(|e| e.disease == disease)
}

/// The normalized forms a mapped disease may be written as, longest first.
///
/// The map's `disease` field doubles as a display label, so four of the ten
/// entries carry editorial furniture a report never prints: an abbreviation in
/// brackets (`慢性肾脏病(CKD)`, `高脂血症(血脂异常)`), an inline parenthetical
/// (`代谢相关(非酒精性)脂肪性肝病`), or a slash meaning "or" (`痛风/高尿酸血症`).
/// Matching required the note to contain that string verbatim, so the most
/// ordinary Chinese spellings missed entirely — `慢性肾脏病3期` (CKD is always
/// staged), `痛风性关节炎`, `混合性高脂血症` all returned `None`, taking their
/// whole lane's labs and drugs with them. Same failure as the diabetes lane,
/// living in the data instead of the code.
///
/// Expansion is mechanical and conservative: split on the slash, drop bracketed
/// runs, keep the original. Verified against the current table to introduce no
/// alias that is a substring of another entry's alias, i.e. no new cross-disease
/// false positive. It does **not** invent synonyms — `脂肪肝` still misses
/// `代谢相关脂肪性肝病`, because deciding those are the same disease is curation
/// with a citation attached, not string surgery.
fn disease_aliases(disease: &str) -> &'static [String] {
    static A: OnceLock<BTreeMap<String, Vec<String>>> = OnceLock::new();
    let map = A.get_or_init(|| {
        problem_map()
            .iter()
            .map(|e| {
                let mut set: BTreeSet<String> = BTreeSet::new();
                for part in e.disease.split(['/', '／']) {
                    let part = part.trim();
                    if part.is_empty() {
                        continue;
                    }
                    set.insert(terminology::normalize_term(part));
                    // Same part with any bracketed run removed.
                    let mut stripped = String::new();
                    let mut depth = 0usize;
                    for ch in part.chars() {
                        match ch {
                            '(' | '（' | '[' | '【' => depth += 1,
                            ')' | '）' | ']' | '】' => depth = depth.saturating_sub(1),
                            _ if depth == 0 => stripped.push(ch),
                            _ => {}
                        }
                    }
                    let stripped = terminology::normalize_term(&stripped);
                    if !stripped.is_empty() {
                        set.insert(stripped);
                    }
                }
                // Longest first: a note naming the fuller form should match on it.
                let mut v: Vec<String> = set.into_iter().collect();
                v.sort_by(|a, b| {
                    b.chars()
                        .count()
                        .cmp(&a.chars().count())
                        .then_with(|| a.cmp(b))
                });
                (e.disease.clone(), v)
            })
            .collect()
    });
    map.get(disease).map_or(&[], Vec::as_slice)
}

/// Curated disease **stems** for merging clinical variants the mapped-disease table
/// (problem_map) doesn't cover. A stem folds acute/stage/laterality variants to one
/// lane: `急性脑梗死` / `急性脑梗死(左侧基底节区)` / `脑梗死恢复期` / `陈旧性脑梗死` all
/// share `脑梗死` → one problem (quality dim 2). Kept tiny and explicit — only
/// well-known chronic problems whose variant spellings obviously mean one disease.
const DISEASE_STEMS: &[&str] = &["脑梗死", "脑梗塞", "脑出血", "脑卒中"];

/// A condition's **normalization key** — the identity that same-problem variants
/// merge on. A mapped chronic disease collapses to its mapped name (`高血压 3 级
/// (很高危)` / `高血压` → `高血压`); otherwise a known stem; otherwise the cleaned
/// raw text (distinct problems stay distinct). Deterministic, no fuzzy matching.
fn condition_key(raw: &str) -> String {
    // Deliberately the **narrow** matcher, not [`match_disease`]. Merging is
    // lossy: `merge_conditions` displays the shortest mention in a group, so
    // folding two diagnoses together deletes the longer one from the problem
    // list. With alias expansion in the key, `慢性肾脏病3期` (2023) and
    // `慢性肾脏病5期(尿毒症期)` (2026) collapsed into one lane labelled
    // `慢性肾脏病3期` — a patient's progression to dialysis simply gone. Same
    // for `高脂血症` + `高脂血症性胰腺炎`.
    //
    // Aliases are for deciding **which labs and drugs to attach**, where being
    // generous costs nothing. Identity is a different question and needs the
    // stricter test: the note has to name the mapped disease itself.
    if let Some(d) = match_disease_exact(raw) {
        return d.to_string();
    }
    // Same rule as match_disease: normalize before comparing, so a typeset
    // `急性 脑梗死` still folds onto the `脑梗死` stem.
    let n = terminology::normalize_term(raw);
    for stem in DISEASE_STEMS {
        if n.contains(&terminology::normalize_term(stem)) {
            return (*stem).to_string();
        }
    }
    // The fallback is a merge key too, so it needs the same normalization —
    // otherwise `糖尿病肾病(早期)` / `糖尿病肾病 (早期)` / `糖尿病肾病（早期）`
    // become three separate lanes for one diagnosis, which is the very failure
    // the mapped path was just fixed for. Only the KEY is normalized; the lane's
    // display term still comes from the shortest verbatim mention.
    n
}

/// One clinical problem after merging variant mentions across documents.
struct MergedProblem {
    /// Clean, verbatim display term (a real mention, never a mashed line).
    term: String,
    onset: Option<NaiveDate>,
    sources: Vec<usize>,
}

/// Fold `conditions` (already exact-deduped by [`crate::aggregate`]) into clinical
/// problems: mentions with the same [`condition_key`] collapse into one lane with
/// the earliest onset and merged evidence (quality dim 2). The display `term` is
/// the **shortest** raw mention in the group — the shortest is the cleanest and
/// avoids a mashed multi-diagnosis line (`2型糖尿病 糖尿病肾病(早期) 高血压3级`)
/// winning over a plain `2型糖尿病`. Output is sorted by (onset, term) so the
/// summary stays deterministic.
fn merge_conditions(conditions: &[AggregatedCondition]) -> Vec<MergedProblem> {
    // key → (candidate display terms, earliest onset, merged sources)
    type Group = (Vec<String>, Option<NaiveDate>, BTreeSet<usize>);
    let mut groups: BTreeMap<String, Group> = BTreeMap::new();
    for c in conditions {
        let key = condition_key(&c.raw_text);
        let g = groups.entry(key).or_default();
        g.0.push(c.raw_text.clone());
        g.1 = match (g.1, c.onset) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) => Some(a),
            (None, b) => b,
        };
        g.2.extend(c.sources.iter().copied());
    }
    let mut out: Vec<MergedProblem> = groups
        .into_values()
        .map(|(mut terms, onset, sources)| {
            // Shortest mention wins; tie-break lexicographically for determinism.
            terms.sort_by(|a, b| {
                a.chars()
                    .count()
                    .cmp(&b.chars().count())
                    .then_with(|| a.cmp(b))
            });
            MergedProblem {
                term: terms.into_iter().next().unwrap_or_default(),
                onset,
                sources: sources.into_iter().collect(),
            }
        })
        .collect();
    out.sort_by(|a, b| match (a.onset, b.onset) {
        (Some(x), Some(y)) => x.cmp(&y).then_with(|| a.term.cmp(&b.term)),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => a.term.cmp(&b.term),
    });
    out
}

/// Format a value without a trailing `.0` for whole numbers (`88.0` → `"88"`,
/// `7.9` → `"7.9"`), for the human-readable `notable_changes` strings.
fn fmt_num(v: f64) -> String {
    format!("{v}")
}

/// The first and last **dated** points of a series (falling back to the first/last
/// raw point when none carry a date). `None` only for an empty series.
fn first_last_point(s: &AnalyteSeries) -> Option<(&LabPoint, &LabPoint)> {
    let first = s
        .points
        .iter()
        .find(|p| p.date.is_some())
        .or_else(|| s.points.first())?;
    let last = s
        .points
        .iter()
        .rev()
        .find(|p| p.date.is_some())
        .or_else(|| s.points.last())?;
    Some((first, last))
}

/// Rank key for `notable_changes`: `(crosses_threshold, |fractional change|)`.
/// A normal↔abnormal crossing between the first and last point is the clinically
/// notable event (a value entering or leaving its reference band); magnitude is the
/// tiebreak. Both are computed only from grounded values/flags — no invented trend.
fn change_significance(s: &AnalyteSeries) -> (bool, f64) {
    let Some((first, last)) = first_last_point(s) else {
        return (false, 0.0);
    };
    let is_abn = |f: &Option<String>| matches!(f.as_deref(), Some("H") | Some("L"));
    let crosses = is_abn(&first.flag) != is_abn(&last.flag);
    let frac = if first.value != 0.0 {
        (last.value - first.value).abs() / first.value.abs()
    } else {
        (last.value - first.value).abs()
    };
    (crosses, frac)
}

/// `[["YYYY-MM", value], …]` for the dated points, chronological. Undated points
/// are skipped (the viewer's x-axis is monthly and can't place them).
fn points_json(s: &AnalyteSeries) -> Vec<Value> {
    s.points
        .iter()
        .filter_map(|p| {
            p.date
                .map(|d| json!([d.format("%Y-%m").to_string(), p.value]))
        })
        .collect()
}

/// Can a consumer actually show this series? Every renderer (hosted viewer,
/// Flutter, desktop) builds a row out of `pts` — the trend line, the latest
/// value, the date chip and the evidence link all come from it. A series whose
/// points are all undated therefore renders as **nothing**, and emitting it
/// produces a bare `相关化验` heading over empty space on a lane that may already
/// be badged 需关注: the doctor is told there are labs to look at and then shown
/// blank. That is worse than the empty box this change set set out to remove.
///
/// So an unrenderable series is not put in the summary at all. The observation
/// is not lost — it stays in the record's own text, reachable through
/// 「查看全部原件」. What is dropped is only the claim that there is a trend.
fn is_renderable(s: &AnalyteSeries) -> bool {
    s.points.iter().any(|p| p.date.is_some())
}

/// Distinct source record indices for a series, ascending (for evidence-jump).
fn series_evidence(s: &AnalyteSeries) -> Vec<usize> {
    let set: BTreeSet<usize> = s.points.iter().map(|p| p.source).collect();
    set.into_iter().collect()
}

/// One `labs[]` entry in the viewer schema.
fn series_to_json(s: &AnalyteSeries) -> Value {
    let mut m = Map::new();
    m.insert("name".into(), json!(s.group_name));
    if let Some(u) = s.points.last().and_then(|p| p.unit.clone()) {
        m.insert("unit".into(), json!(u));
    }
    if let Some(h) = s.ref_high {
        m.insert("refHigh".into(), json!(h));
    }
    if let Some(l) = s.ref_low {
        m.insert("refLow".into(), json!(l));
    }
    m.insert("pts".into(), json!(points_json(s)));
    m.insert("evidence".into(), json!(series_evidence(s)));
    Value::Object(m)
}

/// `"自 YYYY-MM"`, optionally `" → YYYY-MM"` when the latest mention is a
/// different month than the earliest. `None` if no mention carried a date.
fn med_span_str(start: Option<NaiveDate>, end: Option<NaiveDate>) -> Option<String> {
    match (start, end) {
        (Some(s), Some(e)) if e != s => {
            Some(format!("自 {} → {}", s.format("%Y-%m"), e.format("%Y-%m")))
        }
        (Some(s), _) => Some(format!("自 {}", s.format("%Y-%m"))),
        (None, Some(e)) => Some(format!("自 {}", e.format("%Y-%m"))),
        (None, None) => None,
    }
}

/// One `meds[]` entry in the viewer schema.
fn med_to_json(m: &MedSpan) -> Value {
    let mut map = Map::new();
    map.insert("name".into(), json!(m.name));
    if let Some(d) = &m.latest_dose {
        map.insert("dose".into(), json!(d));
    }
    map.insert("on".into(), json!(m.status == "active"));
    if let Some(sp) = med_span_str(m.start, m.end) {
        map.insert("span".into(), json!(sp));
    }
    map.insert("evidence".into(), json!(m.sources));
    Value::Object(map)
}

/// Scan `text` for an allergy label (`过敏史` / `过敏`), then split the remainder
/// on `；;，,、` into items of the form `substance(reaction)`; the reaction, if
/// any, is the trailing parenthesized fragment. Negations (`无…`/`否认…`) and
/// empty remainders are skipped. Returns `(substance, reaction)` pairs.
fn extract_allergies_pairs(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        // Prefer the longer label so `过敏史:` isn't split at `过敏`.
        let rest = ["过敏史", "过敏"].iter().find_map(|lbl| {
            line.find(lbl).map(|p| {
                line[p + lbl.len()..]
                    .trim_start_matches(|c: char| c.is_whitespace() || matches!(c, ':' | '：'))
            })
        });
        let Some(rest) = rest else { continue };
        for item in rest.split(['；', ';', '，', ',', '、']) {
            if let Some(pair) = parse_allergy_item(item) {
                out.push(pair);
            }
        }
    }
    out
}

/// Parse one allergy item like `青霉素(皮疹)` → `("青霉素", "皮疹")`, or bare
/// `磺胺` → `("磺胺", "")`. Returns `None` for empty / negation items.
fn parse_allergy_item(item: &str) -> Option<(String, String)> {
    let item = item
        .trim()
        .trim_matches(|c: char| c.is_whitespace() || matches!(c, '。' | '.' | ';' | '；'));
    if item.is_empty() || item.starts_with('无') || item.starts_with("否认") {
        return None;
    }
    if let Some(op) = item.find(['(', '（']) {
        let substance = item[..op].trim().to_string();
        if substance.is_empty() {
            return None;
        }
        let reaction = item[op..]
            .trim_matches(|c: char| matches!(c, '(' | '（' | ')' | '）'))
            .trim()
            .to_string();
        return Some((substance, reaction));
    }
    Some((item.to_string(), String::new()))
}

/// An imaging report's section-label line: optional list marker, one of the
/// recognized 所见/结论 labels, a colon, then the (possibly empty) inline
/// remainder. Labels start with distinct characters, so alternation order is not
/// load-bearing; longest variants are listed first regardless.
fn imaging_label_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"^\s*(?:\d+\s*[.、)）]|[\u{2460}-\u{2473}]|[-•*·])?\s*(影像所见|检查所见|超声所见|诊断意见|影像诊断|超声提示|影像提示|检查提示|心电图诊断|印象|结论|意见|所见)\s*[:：]\s*(.*)$",
        )
        .expect("imaging label re")
    })
}

/// A pathology report's section-label line. `病理诊断` is the impression/conclusion
/// (preferred); 镜下所见/肉眼所见 are raw findings (fallback). Pathology impressions
/// are surfaced as a conclusion, never split into problems (quality dim 6).
fn pathology_label_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"^\s*(?:\d+\s*[.、)）]|[\u{2460}-\u{2473}]|[-•*·])?\s*(病理诊断|病理所见|免疫组化|镜下所见|肉眼所见)\s*[:：]\s*(.*)$",
        )
        .expect("pathology label re")
    })
}

/// Whether an imaging label names an *impression/conclusion* (preferred) vs a raw
/// 所见 finding (fallback). Both are copied verbatim — neither is interpreted.
fn is_impression_label(label: &str) -> bool {
    matches!(
        label,
        "诊断意见"
            | "影像诊断"
            | "超声提示"
            | "影像提示"
            | "检查提示"
            | "心电图诊断"
            | "印象"
            | "结论"
            | "意见"
    )
}

/// Whether a pathology label names the conclusion (`病理诊断`) vs a raw finding.
fn is_pathology_impression_label(label: &str) -> bool {
    label == "病理诊断"
}

/// Lines that end an impression/findings block even without a blank separator:
/// the follow-up 建议 and the report's signature footer. Kept small and explicit
/// so an impression never bleeds into the 建议/签名 tail.
fn is_impression_terminator(line: &str) -> bool {
    const TERMS: &[&str] = &[
        "建议",
        "报告医师",
        "审核医师",
        "检查医师",
        "记录医师",
        "诊断医师",
        "医师签名",
        "签名",
        "医师:",
        "医师：",
    ];
    TERMS.iter().any(|k| line.starts_with(k))
}

/// Pull the impression/findings paragraph out of an imaging report's OCR text.
///
/// Recognizes the labeled sections in [`imaging_label_re`] (line starts, optional
/// list number, then `:`/`：`); the block is the inline remainder plus following
/// non-empty lines up to a blank line or the next labeled section. An
/// impression/结论/诊断意见 label wins over a raw 所见 when both are present.
/// Returns the trimmed text, or `None` if no labeled section carried content.
///
/// NOT handled (kept honest): unlabeled prose findings; non-imaging section
/// headers between labels are not treated as boundaries (a stray `检查方法:` line
/// after 所见 would be swallowed) — reports put 结论 last, so this is rare.
fn imaging_impression(text: &str) -> Option<String> {
    labeled_impression(text, imaging_label_re(), is_impression_label)
}

/// Pull a pathology report's **conclusion** (`病理诊断` narrative, else 镜下/肉眼所见).
/// Same block-scan as imaging; the narrative stays a single verbatim conclusion and
/// is NEVER comma-split into problems (quality dim 6).
fn pathology_impression(text: &str) -> Option<String> {
    labeled_impression(text, pathology_label_re(), is_pathology_impression_label)
}

/// Shared labeled-block extractor for imaging/pathology conclusions. Scans for
/// `label_re` line starts; a block is the inline remainder plus following non-empty
/// lines up to a blank line or the next labeled section (an `is_impression` label
/// wins over a raw 所见 fallback). Returns the trimmed text, or `None`.
fn labeled_impression(
    text: &str,
    label_re: &Regex,
    is_impression: impl Fn(&str) -> bool,
) -> Option<String> {
    let lines: Vec<&str> = text.lines().collect();
    let mut impression: Option<String> = None;
    let mut findings: Option<String> = None;
    let mut i = 0;
    while i < lines.len() {
        let Some(caps) = label_re.captures(lines[i]) else {
            i += 1;
            continue;
        };
        let label = caps.get(1).expect("label group").as_str();
        let inline = caps.get(2).map(|m| m.as_str()).unwrap_or("").trim();

        let mut parts: Vec<String> = Vec::new();
        if !inline.is_empty() {
            parts.push(inline.to_string());
        }
        let mut j = i + 1;
        while j < lines.len() {
            let t = lines[j].trim();
            if t.is_empty() {
                // pdf-extract 常在每行之间插入空行(见 normalize_cjk_radicals 同源
                // 的排版失真),空行不作段落边界,否则「诊断意见:」下一行是空行就
                // 会把整段结论漏掉。
                j += 1;
                continue;
            }
            if label_re.is_match(lines[j]) || is_impression_terminator(t) {
                break;
            }
            parts.push(t.to_string());
            j += 1;
        }
        let block = parts.join("\n").trim().to_string();
        if !block.is_empty() {
            if is_impression(label) {
                impression.get_or_insert(block);
            } else {
                findings.get_or_insert(block);
            }
        }
        i = j.max(i + 1);
    }
    impression.or(findings)
}

/// Detect the imaging **modality** from a title/text fragment, returning a stable
/// canonical label. `None` if no known keyword is present. Latin tokens are
/// matched case-insensitively; more specific modalities are tested first so
/// `PET-CT` reads as PET and `磁共振/MR` collapse to MRI.
fn detect_modality(s: &str) -> Option<&'static str> {
    let up = s.to_uppercase();
    if s.contains("磁共振") || up.contains("MRI") || up.contains("MR") {
        Some("MRI")
    } else if s.contains("超声") || s.contains("彩超") || s.contains("B超") || up.contains("US")
    {
        Some("超声")
    } else if s.contains("钼靶") {
        Some("钼靶")
    } else if up.contains("PET") {
        Some("PET")
    } else if s.contains("造影") {
        Some("造影")
    } else if s.contains("胃镜") || s.contains("肠镜") || s.contains("内镜") {
        Some("内镜")
    } else if s.contains("X线")
        || s.contains("胸片")
        || s.contains("平片")
        || up.contains("DR")
        || up.contains("CR")
    {
        Some("X线")
    } else if up.contains("CT") {
        Some("CT")
    } else {
        None
    }
}

/// Detect the imaging **body part** from a title/text fragment. `None` if no
/// known keyword is present. Compound/specific parts are tested before broad
/// stems (e.g. 甲状腺/颈部 before the spine group, 心脏 before 胸).
fn detect_body_part(s: &str) -> Option<&'static str> {
    if s.contains("头颅") || s.contains("颅脑") || s.contains("脑") {
        Some("头颅")
    } else if s.contains("甲状腺") || s.contains("颈部") {
        Some("颈部")
    } else if s.contains("脊柱") || s.contains("腰椎") || s.contains("颈椎") {
        Some("脊柱")
    } else if s.contains("乳腺") {
        Some("乳腺")
    } else if s.contains("心脏") {
        Some("心脏")
    } else if s.contains("盆腔") {
        Some("盆腔")
    } else if s.contains("泌尿") || s.contains("肾") || s.contains("膀胱") {
        Some("泌尿")
    } else if s.contains("胸") || s.contains("肺") {
        Some("胸部")
    } else if s.contains("腹")
        || s.contains("肝")
        || s.contains("胆")
        || s.contains("胰")
        || s.contains("脾")
    {
        Some("腹部")
    } else {
        None
    }
}

/// Derive a stable "部位+类型" group label (e.g. `"胸部CT"`, `"腹部超声"`).
/// Detection prefers `title`, falling back to `text`. If the modality is unknown
/// the title is used as-is; if both are unknown, `"影像检查"`.
fn imaging_group(title: Option<&str>, text: &str) -> String {
    let modality = title
        .and_then(detect_modality)
        .or_else(|| detect_modality(text));
    let body = title
        .and_then(detect_body_part)
        .or_else(|| detect_body_part(text));
    if let Some(m) = modality {
        return match body {
            Some(b) => format!("{b}{m}"),
            None => m.to_string(),
        };
    }
    match title.map(str::trim).filter(|t| !t.is_empty()) {
        Some(t) => t.to_string(),
        None => "影像检查".to_string(),
    }
}

/// Assemble the deterministic doctor-summary `Value` the viewer consumes.
/// See the module header for scope. `docs[i].index` must equal the record's
/// index in the viewer's `records[]` so evidence chips jump to the right doc.
pub fn assemble_summary(docs: &[SourceDoc<'_>]) -> Value {
    let mut agg = aggregate(docs);
    // MANUAL-ENTRY-DESIGN.md §5.1, decision: 选项 B。自测数据(家测血压/血糖/
    // 体重/体温/心率)不进医生二维码分享 / hosted-viewer —— 那条链的受众是医生,
    // 而"这条线是不是诊室测的"这件事目前只在手机端(趋势页/就诊单)标注了
    // "(家测)",viewer 侧还没有对应的展示逻辑(那是下一刀,需要单独批准触碰
    // `web/hosted-viewer/**`)。在那之前,宁可不出现,不能让医生把家测血压误当
    // 诊室血压看。`view_trends()`/`view_visit_summary()` 走的是不过滤的
    // `aggregate()` 直接输出,自测数据在手机端本机始终可见——这里的过滤只影响
    // 这一条(经 `assemble_summary` 的)分享链路。
    agg.labs.retain(|s| !s.self_measured);

    // Track which analyte series / med spans got placed under ANY problem, so
    // the leftovers fall into the synthetic「其他」bucket instead of vanishing.
    let mut placed_labs = vec![false; agg.labs.len()];
    let mut placed_meds = vec![false; agg.meds.len()];
    // Indices (into agg.labs) of grouped-and-abnormal series with ≥2 points; a
    // BTreeSet dedups a series that maps to several problems (quality dim 5).
    let mut changed: BTreeSet<usize> = BTreeSet::new();

    let mut problems: Vec<Value> = Vec::new();
    // Merge same-problem variants first (quality dim 2), then attach labs/meds by
    // the mapped disease of the (clean) display term.
    for c in merge_conditions(&agg.conditions) {
        let mut labs_json = Vec::new();
        let mut meds_json = Vec::new();
        let mut warn = false;

        if let Some(disease) = match_disease(&c.term) {
            let entry = entry_for(disease).expect("matched disease is in the map");
            let loincs: BTreeSet<&str> = entry.labs.iter().map(|l| l.loinc.as_str()).collect();
            let prefixes: Vec<&str> = entry
                .drugs
                .iter()
                .map(|d| d.atc.trim_end_matches('*'))
                .collect();

            for (i, s) in agg.labs.iter().enumerate() {
                if s.loinc.as_deref().is_some_and(|l| loincs.contains(l)) {
                    // Belongs to this disease either way, so it must not also
                    // fall through to the 其他 bucket.
                    placed_labs[i] = true;
                    // But if it cannot be drawn, claim NOTHING about it: no
                    // trend headline, no 需关注 badge. Otherwise the summary
                    // announces `肌酐 132→165` above a lane that says it found
                    // no indicators for this disease — the same contradiction,
                    // inverted.
                    if !is_renderable(s) {
                        continue;
                    }
                    warn |= s.any_abnormal;
                    if s.any_abnormal && s.points.len() >= 2 {
                        changed.insert(i);
                    }
                    labs_json.push(series_to_json(s));
                }
            }
            for (i, m) in agg.meds.iter().enumerate() {
                if m.atc
                    .as_deref()
                    .is_some_and(|a| prefixes.iter().any(|p| !p.is_empty() && a.starts_with(p)))
                {
                    placed_meds[i] = true;
                    meds_json.push(med_to_json(m));
                }
            }
        }

        let mut prob = Map::new();
        prob.insert("term".into(), json!(c.term));
        if let Some(onset) = c.onset {
            prob.insert("onset".into(), json!(onset.format("%Y-%m").to_string()));
        }
        prob.insert("status".into(), json!(if warn { "需关注" } else { "在管" }));
        prob.insert("warn".into(), json!(warn));
        prob.insert("acute".into(), json!(false));
        prob.insert("evidence".into(), json!(c.sources));
        prob.insert("labs".into(), json!(labs_json));
        prob.insert("meds".into(), json!(meds_json));
        problems.push(Value::Object(prob));
    }

    // ── 其他 bucket: analytes/meds that resolved but map to no problem ──
    let mut other_labs = Vec::new();
    let mut other_warn = false;
    for (i, s) in agg.labs.iter().enumerate() {
        if !placed_labs[i] {
            // Same rule as the mapped lanes: an undrawable series earns no badge.
            if !is_renderable(s) {
                continue;
            }
            other_warn |= s.any_abnormal;
            other_labs.push(series_to_json(s));
        }
    }
    let other_meds: Vec<Value> = agg
        .meds
        .iter()
        .enumerate()
        .filter(|(i, _)| !placed_meds[*i])
        .map(|(_, m)| med_to_json(m))
        .collect();
    if !other_labs.is_empty() || !other_meds.is_empty() {
        problems.push(json!({
            "term": "其他",
            "status": "其他",
            "acute": false,
            "warn": other_warn,
            "labs": other_labs,
            "meds": other_meds,
        }));
    }

    // ── notable_changes: short "指标 first→last unit" for the abnormal trends that
    // matter most. Deduped by series (changed is a set) and ranked by clinical
    // significance — a normal↔abnormal threshold crossing first (LDL 他汀达标↓,
    // 肌酐↑, 尿酸达标↓), then by fractional change magnitude — so the real story
    // surfaces instead of the smallest wiggle. Cap at 4 (quality dim 5).
    let mut ranked: Vec<&AnalyteSeries> = changed.iter().map(|&i| &agg.labs[i]).collect();
    ranked.sort_by(|a, b| {
        let (ca, fa) = change_significance(a);
        let (cb, fb) = change_significance(b);
        cb.cmp(&ca)
            .then(fb.total_cmp(&fa))
            .then(a.group_name.cmp(&b.group_name))
    });
    let notable_changes: Vec<String> = ranked
        .iter()
        .take(4)
        .filter_map(|s| {
            let (first, last) = first_last_point(s)?;
            let unit = last.unit.clone().unwrap_or_default();
            Some(format!(
                "{} {}→{}{}",
                s.group_name,
                fmt_num(first.value),
                fmt_num(last.value),
                unit
            ))
        })
        .collect();

    // ── allergies: scan every doc, dedup on (substance, reaction) ──
    let mut allergies = Vec::new();
    let mut seen: BTreeSet<(String, String)> = BTreeSet::new();
    for doc in docs {
        for (substance, reaction) in extract_allergies_pairs(doc.text) {
            if seen.insert((substance.clone(), reaction.clone())) {
                allergies.push(json!({ "substance": substance, "reaction": reaction }));
            }
        }
    }

    // ── imaging: group studies by 部位+类型, sorted by date within each group ──
    // Qualify ONLY on doc_type == imaging_report (the classifier's job). Sniffing
    // a modality out of arbitrary text is far too greedy — a lab report's "Cr"
    // (肌酐/creatinine) reads as "CR"→X线, "肾"→泌尿 — so a whole lab panel would
    // masquerade as imaging. Group label detection (below) may still consult the
    // report's own text, but only genuine imaging reports ever reach it.
    let mut imaging_groups: BTreeMap<String, Vec<(Option<NaiveDate>, Value)>> = BTreeMap::new();
    for doc in docs {
        let ty_imaging = doc
            .doc_type
            .as_deref()
            .is_some_and(|t| t.contains("imaging"));
        if !ty_imaging {
            continue;
        }
        let group = imaging_group(doc.title.as_deref(), doc.text);
        let study = json!({
            "date": doc.date.map(|d| d.format("%Y-%m").to_string()),
            "finding": imaging_impression(doc.text),
            "evidence": [doc.index],
        });
        imaging_groups
            .entry(group)
            .or_default()
            .push((doc.date, study));
    }
    // BTreeMap keys give group order; within a group, sort by date (None last).
    let imaging: Vec<Value> = imaging_groups
        .into_iter()
        .map(|(group, mut studies)| {
            studies.sort_by(|a, b| match (a.0, b.0) {
                (Some(x), Some(y)) => x.cmp(&y),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            });
            json!({
                "group": group,
                "studies": studies.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
            })
        })
        .collect();

    // ── pathology: each 病理 report's verbatim conclusion, never split into
    // problems (quality dim 6). Qualify ONLY on doc_type == pathology (same
    // discipline as imaging); the narrative is copied, not interpreted.
    let mut pathology: Vec<(Option<NaiveDate>, Value)> = Vec::new();
    for doc in docs {
        let is_path = doc
            .doc_type
            .as_deref()
            .is_some_and(|t| t.contains("pathology"));
        if !is_path {
            continue;
        }
        let Some(conclusion) = pathology_impression(doc.text) else {
            continue;
        };
        pathology.push((
            doc.date,
            json!({
                "date": doc.date.map(|d| d.format("%Y-%m").to_string()),
                "conclusion": conclusion,
                "evidence": [doc.index],
            }),
        ));
    }
    pathology.sort_by(|a, b| match (a.0, b.0) {
        (Some(x), Some(y)) => x.cmp(&y),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    let pathology: Vec<Value> = pathology.into_iter().map(|(_, v)| v).collect();

    let mut summary = json!({
        "problems": problems,
        "allergies": allergies,
        "notable_changes": notable_changes,
    });
    // Attach imaging/pathology only when present (老分享/无 keeps the key absent).
    if !imaging.is_empty() {
        summary["imaging"] = json!(imaging);
    }
    if !pathology.is_empty() {
        summary["pathology"] = json!(pathology);
    }
    summary
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, day: u32) -> Option<NaiveDate> {
        NaiveDate::from_ymd_opt(y, m, day)
    }

    #[test]
    fn match_disease_handles_shortenings_and_nonmatch() {
        assert_eq!(match_disease("糖尿病"), Some("2型糖尿病"));
        assert_eq!(match_disease("2型糖尿病"), Some("2型糖尿病"));
        assert_eq!(match_disease("  2型糖尿病  "), Some("2型糖尿病"));
        assert_eq!(match_disease("高血压"), Some("高血压"));
        assert_eq!(match_disease("高血压病3级"), Some("高血压"));
        assert_eq!(match_disease("社区获得性肺炎"), None);
        assert_eq!(match_disease(""), None);
    }

    /// Diagnoses **as real documents print them**, not as our table spells them.
    ///
    /// The first two are verbatim from `examples/demo-dataset/generate.sh`
    /// (`出院诊断:1. 急性脑梗死  2. 高血压 3 级(很高危)  3. 2 型糖尿病`); the rest
    /// are constructed OCR/typesetting variants and are labelled as such — an
    /// earlier draft of this test claimed all of them were corpus-verbatim, which
    /// was false, and one of them returned a different answer once the real full
    /// line was used. A test file whose thesis is "fixtures must be someone
    /// else's text" has no business misdescribing where its strings came from.
    ///
    /// The old matcher compared raw text and returned `None` for every spaced
    /// form, which emptied the diabetes lane in the doctor's viewer — while the
    /// test above stayed green, because it fed the table's own spelling back to
    /// itself.
    #[test]
    fn match_disease_survives_typeset_spacing_and_fullwidth() {
        // Verbatim from the corpus: Chinese typesetting spaces the numeral.
        assert_eq!(match_disease("2 型糖尿病"), Some("2型糖尿病"));
        assert_eq!(match_disease("高血压 3 级(很高危)"), Some("高血压"));
        // Constructed: full-width digits, as OCR of a scanned form emits them.
        assert_eq!(match_disease("２型糖尿病"), Some("2型糖尿病"));
        // Constructed: OCR splitting CJK (`肌 酐` is the canonical example).
        assert_eq!(match_disease("高 血 压"), Some("高血压"));
        // Still no false positives.
        assert_eq!(match_disease("社区获得性肺炎"), None);
    }

    /// The map's `disease` field carries editorial furniture no report prints —
    /// bracketed abbreviations, an inline parenthetical, a slash meaning "or".
    /// Requiring the note to contain that verbatim made the most ordinary Chinese
    /// spellings miss, silently emptying those lanes.
    #[test]
    fn map_disease_names_match_through_their_editorial_furniture() {
        // 慢性肾脏病(CKD) — Chinese notes always stage it.
        assert_eq!(match_disease("慢性肾脏病3期"), Some("慢性肾脏病(CKD)"));
        assert_eq!(match_disease("慢性肾脏病5期"), Some("慢性肾脏病(CKD)"));
        // 痛风/高尿酸血症 — the slash means either name alone should hit.
        assert_eq!(match_disease("痛风性关节炎"), Some("痛风/高尿酸血症"));
        assert_eq!(match_disease("高尿酸血症"), Some("痛风/高尿酸血症"));
        // 高脂血症(血脂异常)
        assert_eq!(match_disease("混合性高脂血症"), Some("高脂血症(血脂异常)"));
        // 代谢相关(非酒精性)脂肪性肝病 — the inline parenthetical comes out…
        assert_eq!(
            match_disease("代谢相关脂肪性肝病"),
            Some("代谢相关(非酒精性)脂肪性肝病")
        );
        // …but `脂肪肝` is a *synonym*, not a spelling of this string, and this
        // expansion deliberately does not invent synonyms. Asserted so the gap is
        // visible rather than assumed fixed; deciding these name one disease is
        // curation with a citation, and belongs in the map's data.
        assert_eq!(match_disease("脂肪肝"), None);
        assert_eq!(match_disease("非酒精性脂肪性肝病"), None);
        // No new cross-disease false positive from the shorter aliases.
        assert_eq!(match_disease("社区获得性肺炎"), None);
        assert_eq!(match_disease("肺炎"), None);
        // 假性痛风 is 焦磷酸钙沉积病 — a different disease that merely contains
        // the 2-character alias. Inheriting the gout lane would hand a doctor
        // urate labs and urate-lowering drug classes for a condition neither
        // applies to.
        assert_eq!(match_disease("假性痛风"), None);
        assert_eq!(match_disease("焦磷酸钙沉积病(假性痛风)"), None);
        // Negations assert the absence of the disease. Reading them as the
        // disease hands a doctor that lane's labs and drug classes for a
        // patient the note says does not have it.
        assert_eq!(match_disease("无痛风病史"), None);
        assert_eq!(match_disease("既往无痛风"), None);
        assert_eq!(match_disease("否认高脂血症"), None);
        // …but a real diagnosis that merely begins with 无 must survive.
        assert_eq!(match_disease("无症状性高尿酸血症"), Some("痛风/高尿酸血症"));
    }

    /// Merging is lossy — `merge_conditions` shows the **shortest** mention in a
    /// group — so lane identity must be stricter than lab attachment. When the
    /// alias expansion was used as the merge key, a patient's CKD stage 3 (2023)
    /// and stage 5 (2026) collapsed into one lane labelled `慢性肾脏病3期`, and
    /// the progression to dialysis vanished from the problem list.
    #[test]
    fn disease_stages_stay_separate_lanes() {
        let texts = ["出院诊断:慢性肾脏病3期", "出院诊断:慢性肾脏病5期(尿毒症期)"];
        let docs: Vec<SourceDoc<'_>> = texts
            .iter()
            .enumerate()
            .map(|(i, t)| SourceDoc {
                index: i,
                date: None,
                text: t,
                doc_type: Some("discharge_summary".into()),
                title: None,
            })
            .collect();
        let sm = assemble_summary(&docs);
        let terms: Vec<&str> = sm["problems"]
            .as_array()
            .expect("problems")
            .iter()
            .filter_map(|p| p["term"].as_str())
            .collect();
        assert!(
            terms.iter().any(|t| t.contains("5期")),
            "the later, worse diagnosis was swallowed by the earlier one: {terms:?}"
        );
        // …while a pure typesetting variant of ONE diagnosis still merges.
        let same = ["出院诊断:2 型糖尿病", "出院诊断:2型糖尿病"];
        let docs2: Vec<SourceDoc<'_>> = same
            .iter()
            .enumerate()
            .map(|(i, t)| SourceDoc {
                index: i,
                date: None,
                text: t,
                doc_type: Some("discharge_summary".into()),
                title: None,
            })
            .collect();
        let sm2 = assemble_summary(&docs2);
        let n = sm2["problems"]
            .as_array()
            .expect("problems")
            .iter()
            .filter(|p| p["term"].as_str().unwrap_or("").contains("糖尿病"))
            .count();
        assert_eq!(n, 1, "one diagnosis, two typesettings, should be one lane");
    }

    /// The furniture filter must not take real results with it. Every line here
    /// is a genuine lab row that an earlier punctuation-based rule discarded;
    /// `白球比值(A:G)` resolves to a dictionary entry, and the dictionary also
    /// curates `皮质醇(8:00)` — colons inside analyte names are normal here.
    #[test]
    fn furniture_filter_keeps_panel_prefixed_and_colon_bearing_analytes() {
        for line in [
            "生化:钾 4.2 mmol/L 3.5-5.3",
            "白球比值(A:G) 1.52 1.20-2.40",
            "甲功三项:TSH 2.35 mIU/L 0.27-4.20",
            "PT:INR 1.05 0.80-1.20",
        ] {
            assert_eq!(
                crate::extract_labs(line).len(),
                1,
                "dropped a real result: {line}"
            );
        }
        // …while the letterhead still goes.
        assert!(
            crate::extract_labs("姓名:张建国    性别:男    年龄:58岁    门诊号:20230615-1046")
                .is_empty()
        );
    }

    /// One diagnosis, several typesettings, one lane. The mapped path was fixed
    /// first; the unmapped fallback is a merge key too and had the same defect.
    #[test]
    fn unmapped_diagnosis_variants_merge_into_one_lane() {
        let texts = [
            "出院诊断:糖尿病肾病(早期)",
            "出院诊断:糖尿病肾病 (早期)",
            "出院诊断:糖尿病肾病(早期)",
        ];
        let docs: Vec<SourceDoc<'_>> = texts
            .iter()
            .enumerate()
            .map(|(i, t)| SourceDoc {
                index: i,
                date: None,
                text: t,
                doc_type: Some("discharge_summary".into()),
                title: None,
            })
            .collect();
        let sm = assemble_summary(&docs);
        let terms: Vec<&str> = sm["problems"]
            .as_array()
            .expect("problems")
            .iter()
            .filter_map(|p| p["term"].as_str())
            .filter(|t| t.contains("糖尿病肾病"))
            .collect();
        assert_eq!(terms.len(), 1, "one diagnosis split into lanes: {terms:?}");
    }

    /// A series that cannot be drawn must not headline `notable_changes` either.
    /// Gating only the `labs[]` push produced the mirror-image falsehood: the
    /// summary announced `肌酐 132→165` above a lane reporting that it found no
    /// indicators for that disease.
    #[test]
    fn notable_changes_never_cites_a_series_no_lane_shows() {
        let texts = [
            "检验报告\n临床诊断:慢性肾脏病(CKD)3期\n肌酐 132 umol/L 57-97 ↑\n",
            "检验报告\n临床诊断:慢性肾脏病(CKD)3期\n肌酐 165 umol/L 57-97 ↑\n",
        ];
        let docs: Vec<SourceDoc<'_>> = texts
            .iter()
            .enumerate()
            .map(|(i, t)| SourceDoc {
                index: i,
                date: None, // undated → nothing is drawable
                text: t,
                doc_type: Some("lab_report".into()),
                title: None,
            })
            .collect();
        let sm = assemble_summary(&docs);
        let shown: usize = sm["problems"]
            .as_array()
            .expect("problems")
            .iter()
            .map(|p| p["labs"].as_array().map_or(0, Vec::len))
            .sum();
        let changes = sm["notable_changes"].as_array().expect("changes");
        assert!(
            changes.is_empty() || shown > 0,
            "notable_changes {changes:?} cites series no lane renders"
        );
    }

    /// A series the viewer cannot draw must never reach the summary.
    ///
    /// Constructed directly rather than through the demo corpus on purpose: the
    /// corpus happens to date every report, so a corpus-driven assertion passes
    /// whether or not the guard exists (verified by mutation — flipping
    /// `is_renderable` to always-true left the corpus test green). The failure
    /// mode is real input, though: a report whose clinical date OCR can't
    /// recover gives every point `date: None`, and the lane then renders a bare
    /// `相关化验` heading over empty space while badged 需关注.
    #[test]
    fn undated_series_is_not_emitted_as_a_lab_row() {
        let text = "临床诊断:2型糖尿病\n糖化血红蛋白 7.5 % 参考值 4.0-6.0 ↑";
        let docs = vec![SourceDoc {
            index: 0,
            date: None, // no clinical date anywhere → every point is undated
            text,
            doc_type: Some("lab_report".into()),
            title: None,
        }];
        let sm = assemble_summary(&docs);
        let problems = sm["problems"].as_array().expect("problems array");
        for p in problems {
            for l in p["labs"].as_array().into_iter().flatten() {
                let pts = l["pts"].as_array().map_or(0, Vec::len);
                assert!(
                    pts > 0,
                    "series `{}` under `{}` has no drawable point yet was emitted",
                    l["name"].as_str().unwrap_or("?"),
                    p["term"].as_str().unwrap_or("?")
                );
            }
        }
    }

    #[test]
    fn assemble_summary_groups_labs_meds_and_buckets_the_rest() {
        // doc0/doc1: two HbA1c lab reports (both high) + an unmapped analyte.
        // doc2: a diagnosis note (dates the problem) + a prescription + allergy.
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: None,
                title: None,
                date: d(2024, 6, 1),
                text: "生化检验报告单\n糖化血红蛋白 7.9 % 4-6.5\n神秘指标XYZ 12.3 mg/L 0-5",
            },
            SourceDoc {
                index: 1,
                doc_type: None,
                title: None,
                date: d(2026, 6, 1),
                text: "生化检验报告单\n糖化血红蛋白 7.2 % 4-6.5",
            },
            SourceDoc {
                index: 2,
                doc_type: None,
                title: None,
                date: d(2021, 5, 1),
                text: "门诊病历\n诊断:2型糖尿病\n二甲双胍 0.5g bid\n过敏史:青霉素(皮疹)",
            },
        ];
        let sm = assemble_summary(&docs);

        let problems = sm["problems"].as_array().expect("problems array");
        let dm = problems
            .iter()
            .find(|p| p["term"] == "2型糖尿病")
            .expect("2型糖尿病 problem present");
        assert_eq!(dm["onset"], "2021-05");
        assert_eq!(dm["evidence"], json!([2]));

        // Grouped HbA1c lab: refHigh present, two chronological points.
        let labs = dm["labs"].as_array().expect("labs");
        let hba1c = labs
            .iter()
            .find(|l| l["name"] == "糖化血红蛋白")
            .expect("HbA1c grouped under diabetes");
        assert_eq!(hba1c["refHigh"], json!(6.5));
        let pts = hba1c["pts"].as_array().expect("pts");
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0], json!(["2024-06", 7.9]));
        assert_eq!(pts[1], json!(["2026-06", 7.2]));

        // Grouped metformin med, currently on.
        let meds = dm["meds"].as_array().expect("meds");
        let met = meds
            .iter()
            .find(|m| m["name"] == "二甲双胍")
            .expect("metformin grouped under diabetes");
        assert_eq!(met["on"], json!(true));

        // Unmapped analyte falls into the 其他 bucket.
        let other = problems
            .iter()
            .find(|p| p["term"] == "其他")
            .expect("其他 bucket present");
        assert!(other["labs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l["name"] == "神秘指标XYZ"));

        // notable_changes summarizes the abnormal HbA1c trend.
        let changes = sm["notable_changes"].as_array().expect("notable_changes");
        assert!(!changes.is_empty());
        assert!(changes[0].as_str().unwrap().contains("糖化血红蛋白"));

        // Allergy parsed with its reaction.
        let allergies = sm["allergies"].as_array().expect("allergies");
        assert_eq!(allergies.len(), 1);
        assert_eq!(allergies[0]["substance"], "青霉素");
        assert_eq!(allergies[0]["reaction"], "皮疹");
    }

    #[test]
    fn unmapped_condition_still_becomes_a_problem_without_groups() {
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: None,
            title: None,
            date: d(2022, 12, 1),
            text: "出院诊断:社区获得性肺炎",
        }];
        let sm = assemble_summary(&docs);
        let problems = sm["problems"].as_array().unwrap();
        let p = problems
            .iter()
            .find(|p| p["term"] == "社区获得性肺炎")
            .expect("unmapped condition is still a problem");
        assert_eq!(p["labs"], json!([]));
        assert_eq!(p["meds"], json!([]));
        assert_eq!(p["warn"], json!(false));
        assert_eq!(p["status"], "在管");
    }

    #[test]
    fn allergy_negation_and_bare_substance() {
        // Negations are skipped; a bare substance has an empty reaction.
        assert!(extract_allergies_pairs("过敏史:无").is_empty());
        assert!(extract_allergies_pairs("否认药物过敏史").is_empty());
        let pairs = extract_allergies_pairs("过敏史:磺胺、头孢(荨麻疹)");
        assert_eq!(pairs.len(), 2);
        assert_eq!(pairs[0], ("磺胺".to_string(), String::new()));
        assert_eq!(pairs[1], ("头孢".to_string(), "荨麻疹".to_string()));
    }

    #[test]
    fn imaging_impression_prefers_conclusion_over_raw_findings() {
        let text = "\
胸部CT平扫\n\
检查方法:胸部CT平扫\n\
影像所见:\n\
两肺纹理增多,右肺上叶见小结节影。\n\
纵隔内未见肿大淋巴结。\n\
\n\
结论:右肺上叶小结节,建议随访。\n\
\n\
医师:李四\n";
        let imp = imaging_impression(text).expect("impression found");
        // 结论 (impression) wins over the raw 影像所见 block.
        assert_eq!(imp, "右肺上叶小结节,建议随访。");

        // With only a 所见 section, the findings block is returned (both lines).
        let only_findings = "超声所见:肝内未见明显占位。\n胆囊壁毛糙。\n";
        let f = imaging_impression(only_findings).expect("findings found");
        assert_eq!(f, "肝内未见明显占位。\n胆囊壁毛糙。");

        // No labeled section → None.
        assert!(imaging_impression("普通门诊记录,无影像。").is_none());
    }

    #[test]
    fn imaging_impression_real_report_blank_lines_and_advice_terminator() {
        // 张建国真实头颅MRI报告(pdf-extract 逐行插空行的真实排版):结论段与标签
        // 之间、各条之间均有空行,且以「建议:」「报告医师:」收尾。impression 必须
        // 跨空行抓到完整「诊断意见」两条,且不吞入「建议」与签名。
        let mri = "\
放射科 头颅 MRI 检查报告\n\
\n\
影像所见:\n\
\n\
左侧基底节区见小片状 T1WI 低信号、T2WI/FLAIR 高信号影,DWI 未见明显弥散受限。\n\
\n\
诊断意见:\n\
\n\
1. 左侧基底节区陈旧性脑梗死软化灶,病灶稳定,未见新发梗死。\n\
\n\
2. 脑白质轻度缺血性改变(Fazekas 1 级)。\n\
\n\
建议:继续规律控制血压血糖血脂,神经内科定期随访。\n\
\n\
报告医师:张敏    审核医师:陈刚\n";
        let imp = imaging_impression(mri).expect("impression found");
        assert_eq!(
            imp,
            "1. 左侧基底节区陈旧性脑梗死软化灶,病灶稳定,未见新发梗死。\n2. 脑白质轻度缺血性改变(Fazekas 1 级)。"
        );

        // 腹部超声用「超声提示:」作结论标签(同样跨空行、以「建议」收尾)。
        let us = "超声所见:\n\n肝内回声增强,提示脂肪浸润。\n\n超声提示:\n\n1. 脂肪肝(中度)。\n\n2. 胆囊未见明显异常。\n\n建议:控制体重及血脂。\n";
        assert_eq!(
            imaging_impression(us).expect("us impression"),
            "1. 脂肪肝(中度)。\n2. 胆囊未见明显异常。"
        );
    }

    #[test]
    fn imaging_group_from_title_and_text() {
        assert_eq!(imaging_group(Some("胸部CT"), ""), "胸部CT");
        // Detection falls back to text when the title lacks keywords.
        assert_eq!(
            imaging_group(Some("检查报告"), "胸部CT平扫,两肺纹理增多"),
            "胸部CT"
        );
        assert_eq!(imaging_group(Some("腹部彩超"), ""), "腹部超声");
        // Modality unknown → title as-is; both unknown → 影像检查.
        assert_eq!(imaging_group(Some("某项检查"), "无关键词"), "某项检查");
        assert_eq!(imaging_group(None, "无关键词"), "影像检查");
    }

    #[test]
    fn assemble_summary_groups_imaging_by_part_over_time() {
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: Some("imaging_report".into()),
                title: Some("胸部CT".into()),
                date: d(2024, 3, 1),
                text: "结论:两肺未见明显异常。",
            },
            SourceDoc {
                index: 1,
                doc_type: Some("imaging_report".into()),
                title: Some("胸部CT".into()),
                date: d(2025, 1, 1),
                text: "结论:右肺上叶小结节,较前稳定。",
            },
            // A non-imaging doc contributes nothing to imaging.
            SourceDoc {
                index: 2,
                doc_type: Some("clinical_note".into()),
                title: Some("门诊病历".into()),
                date: d(2024, 6, 1),
                text: "诊断:2型糖尿病",
            },
        ];
        let sm = assemble_summary(&docs);
        let imaging = sm["imaging"].as_array().expect("imaging present");
        assert_eq!(imaging.len(), 1, "one 胸部CT group");
        let g = &imaging[0];
        assert_eq!(g["group"], "胸部CT");
        let studies = g["studies"].as_array().expect("studies");
        assert_eq!(studies.len(), 2);
        // Sorted by date ascending.
        assert_eq!(studies[0]["date"], "2024-03");
        assert_eq!(studies[0]["finding"], "两肺未见明显异常。");
        assert_eq!(studies[0]["evidence"], json!([0]));
        assert_eq!(studies[1]["date"], "2025-01");
        assert_eq!(studies[1]["finding"], "右肺上叶小结节,较前稳定。");
        assert_eq!(studies[1]["evidence"], json!([1]));
    }

    #[test]
    fn assemble_summary_surfaces_pathology_conclusion_not_as_problems() {
        // 真 corpus doc11 的病理叙事:过去被逗号拆成 3 条假「诊断」。现在整段作为一条
        // pathology 结论浮出,且绝不进 problems(quality dim 6)。
        let docs = vec![SourceDoc {
            index: 11,
            doc_type: Some("pathology".into()),
            title: Some("胃镜活检病理".into()),
            date: d(2024, 9, 1),
            text: "病理诊断:(胃窦)慢性活动性胃炎,伴轻度肠上皮化生,Hp阳性(++)。未见异型增生及恶性证据。",
        }];
        let sm = assemble_summary(&docs);
        assert!(
            sm["problems"].as_array().expect("problems").is_empty(),
            "病理叙事绝不进 problems"
        );
        let path = sm["pathology"].as_array().expect("pathology present");
        assert_eq!(path.len(), 1);
        assert_eq!(path[0]["date"], "2024-09");
        assert_eq!(
            path[0]["conclusion"],
            "(胃窦)慢性活动性胃炎,伴轻度肠上皮化生,Hp阳性(++)。未见异型增生及恶性证据。"
        );
        assert_eq!(path[0]["evidence"], json!([11]));
    }

    #[test]
    fn assemble_summary_omits_pathology_when_none() {
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("lab_report".into()),
            title: Some("血常规".into()),
            date: d(2024, 1, 1),
            text: "白细胞 10.5",
        }];
        assert!(
            assemble_summary(&docs).get("pathology").is_none(),
            "no pathology key when empty"
        );
    }

    #[test]
    fn assemble_summary_omits_imaging_when_none() {
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("lab_report".into()),
            title: Some("血常规".into()),
            date: d(2024, 1, 1),
            text: "白细胞 10.5",
        }];
        let sm = assemble_summary(&docs);
        assert!(sm.get("imaging").is_none(), "no imaging key when empty");
    }

    /// MANUAL-ENTRY-DESIGN.md §5.1 决定(选项 B):自测数据永远不出现在
    /// `assemble_summary` 的输出里 —— 这是医生二维码分享 / hosted-viewer 的数据
    /// 源。不只是不出现在"其他"桶,连本该按 LOINC 挂进「高血压」泳道(与
    /// `problem_map.json` 里 8480-6/8462-4 完全匹配)的自测血压也必须被挡在外面,
    /// 否则医生扫码看到的会是一条没有"这是家测"标注的裸血压值,可能被误当诊室值。
    #[test]
    fn assemble_summary_never_includes_self_measured_series_even_under_a_matched_disease() {
        let self_text = crate::render_self_measurement_text(
            &["血压 150/95 mmHg".to_string()],
            &[
                crate::SelfMeasuredValue {
                    analyte_key: "bp_systolic".into(),
                    value: 150.0,
                    unit: "mmHg".into(),
                },
                crate::SelfMeasuredValue {
                    analyte_key: "bp_diastolic".into(),
                    value: 95.0,
                    unit: "mmHg".into(),
                },
            ],
        );
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: Some("discharge_summary".into()),
                title: None,
                date: d(2024, 1, 1),
                text: "出院诊断:高血压",
            },
            SourceDoc {
                index: 1,
                doc_type: Some("self_measurement".into()),
                title: None,
                date: d(2024, 2, 1),
                text: &self_text,
            },
        ];
        let sm = assemble_summary(&docs);
        let all_lab_names: Vec<String> = sm["problems"]
            .as_array()
            .expect("problems")
            .iter()
            .flat_map(|p| p["labs"].as_array().into_iter().flatten())
            .filter_map(|l| l["name"].as_str().map(str::to_string))
            .collect();
        assert!(
            !all_lab_names.iter().any(|n| n.contains('压')),
            "自测血压不该出现在任何泳道里,实际出现: {all_lab_names:?}"
        );
        // 但同一份数据喂给不过滤的 `aggregate()` 时,自测序列确实在(手机端趋势页/
        // 就诊单走的是这条,不受本函数内部过滤影响)——这一断言确认过滤发生在
        // `assemble_summary` 内部,不是数据从一开始就没被抽出来。
        let agg = aggregate(&docs);
        assert!(
            agg.labs.iter().any(|s| s.self_measured),
            "sanity: aggregate() 本身仍然产出自测序列,过滤只发生在 assemble_summary"
        );
    }
}
