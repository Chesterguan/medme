//! Deterministic diagnosis extraction (stage B).
//!
//! Pulls diagnosis terms out of labeled sections of a clinical note and keeps
//! them as honest raw strings. Pure string work: no network, no LLM. There is
//! **no** condition/diagnosis category in the terminology dictionary, so — unlike
//! labs and meds — the term itself is not normalized to a code. A trailing ICD
//! code that the note prints alongside the term IS captured verbatim into
//! [`ConditionMention::icd_code`] (additive FHIR-coding groundwork) but never
//! trusted for display: `raw_text` still has it stripped, and we don't validate
//! the code or invent one when the note omits it. It's the note's own claim,
//! carried through unchanged for a future FHIR export to use or ignore.
//!
//! ## Row shapes handled
//! Section label (optionally after a list number) + `:`/`：`, then either:
//! ```text
//! 出院诊断:2型糖尿病；高血压病3级          <- inline, split on ；;，,、 and numbers
//! 出院诊断:1. 急性脑梗死 2. 高血压3级 3. 2型糖尿病  <- inline w/ in-line numbering
//! 出院诊断:                                <- label then a numbered block:
//!   1. 2型糖尿病(E11.9)                    <- numbering stripped, ICD code → icd_code
//!   2. 高血压病3级
//! 处方日期:2026-06-20    临床诊断:2 型糖尿病、高尿酸血症  <- label mid-line
//! ```
//! Recognized labels: 诊断 初步诊断 入院诊断 出院诊断 主要诊断 其他诊断 临床诊断.
//! A numbered block is consumed until a blank line or a non-numbered line.
//!
//! The label does **not** have to start the line. A prescription prints the
//! diagnosis next to the date on one row, and OCR routinely folds a two-column
//! report into a single line, so requiring line-start silently dropped whole
//! diagnosis rows. What is required instead is a **boundary** before the label —
//! line start, whitespace, or a closing bracket — so the label can never be the
//! tail of a longer word. Text before the label is discarded, and a line may
//! carry several labels (each owns the text up to the next one).
//!
//! ## 病理诊断 is deliberately NOT a diagnosis label here
//! 病理 reports write a *narrative* impression (`(胃窦)慢性活动性胃炎,伴轻度肠上皮
//! 化生,Hp 阳性(++)。未见异型增生及恶性证据。`) that must never be comma-split into
//! fake "diagnoses" — it is surfaced as a pathology **conclusion** by the summary
//! layer (docs/030, quality dim 6), not as problems. Line-start anchoring used to
//! exclude it for free; now the boundary rule does it (a Han character is not a
//! boundary), plus [`NOT_A_PROBLEM_LIST_PREFIX`] for the OCR-spaced `病理 诊断:`.
//! Same for 鉴别诊断 (differential — diseases being ruled *out*), 影像诊断 and
//! 心电图诊断 (findings of one study, not the patient's problem list).
//!
//! ## Deliberately NOT handled (kept lean)
//! - Diagnoses in free prose with no section label.
//! - Negation / history qualifiers (`否认…`, `既往…`) — the term is kept verbatim.
//! - Splitting one term into disease + stage/laterality (`高血压病3级` stays whole).
//! - Any normalization / de-duplication across synonyms — only exact
//!   (raw_text, section) duplicates are collapsed.
//! - Inline diagnoses separated by **spaces alone** (`诊断:2型糖尿病 糖尿病肾病(早期)`)
//!   stay one term: a space is not a separator here, because the corpus writes
//!   `高血压 3 级(很高危)` and `2 型糖尿病` with spaces *inside* the disease name.
//! - A label glued to the preceding token with no boundary (`…2025-12-03诊断:`) or
//!   to the preceding label (`诊断:诊断:`) — no boundary character is left to see.

use regex::Regex;
use std::collections::HashSet;
use std::sync::OnceLock;

/// One diagnosis term as written, tagged with the section label it came under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConditionMention {
    pub raw_text: String,
    pub section: Option<String>,
    /// A trailing ICD-style code the note printed next to the term (`E11.9` from
    /// `2型糖尿病(E11.9)`), captured verbatim, `None` when the note prints none.
    /// Never derived — stripped out of `raw_text`, kept here for FHIR groundwork.
    pub icd_code: Option<String>,
}

/// A diagnosis-section label **anywhere on a line**: a boundary, an optional list
/// marker, a known label, a colon. The inline remainder is not captured here —
/// it is sliced off in [`extract_conditions`], which needs to know where the
/// *next* label starts. Longer labels precede `诊断` so a specific section name
/// wins over the generic one.
///
/// The leading `(?:^|[…])` is the whole point. Line start is still one of the
/// alternatives, so every row the old `^`-anchored pattern matched still matches
/// — the change is strictly additive. What may precede the label otherwise is
/// kept narrow on purpose: whitespace (`\s` is Unicode here, so the U+3000 gap
/// OCR emits for a column break counts) or a closing bracket. A Han character is
/// **not** a boundary, which is what keeps `病理诊断:`, `鉴别诊断:`, `影像诊断:`
/// and `心电图诊断:` out — they are different kinds of heading, not problem lists.
fn section_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(?:^|[\s)）\]】》」』])\s*(?:\d+\s*[.、)）]|[\u{2460}-\u{2473}]|[-•*·])?\s*(出院诊断|入院诊断|初步诊断|主要诊断|其他诊断|临床诊断|诊断)\s*[:：]",
        )
        .expect("section re")
    })
}

/// Words that turn a bare `诊断` into the tail of a compound heading which is
/// *not* a problem list. Written without a gap they are already rejected (a Han
/// character is not a boundary); this list exists only for the OCR-spaced form —
/// `病理 诊断:` — which the boundary rule on its own would happily accept and then
/// comma-split a pathology narrative into fake diagnoses.
const NOT_A_PROBLEM_LIST_PREFIX: &[&str] = &["病理", "鉴别", "影像", "超声", "心电图", "细胞学"];

/// Every diagnosis label on one line, as `(label, inline_start, match_start)`:
/// byte offsets into `line` for where this label's own text begins and where the
/// match itself begins (so the previous label's text can stop there).
fn section_hits(line: &str) -> Vec<(&str, usize, usize)> {
    section_re()
        .captures_iter(line)
        .filter_map(|c| {
            let whole = c.get(0).expect("whole match");
            let label = c.get(1).expect("label group");
            // Only the bare `诊断` can be the tail of a compound heading — there is
            // no such word as 病理临床诊断 — so a qualified label is never blocked by
            // the word in front of it. `检查项目:腹部超声  临床诊断:…` stays a
            // diagnosis; `病理 诊断:…` does not.
            if label.as_str() == "诊断" {
                let before = line[..label.start()].trim_end();
                if NOT_A_PROBLEM_LIST_PREFIX.iter().any(|p| before.ends_with(p)) {
                    return None;
                }
            }
            Some((label.as_str(), whole.end(), whole.start()))
        })
        .collect()
}

/// A numbered list item: `1. xxx` / `2、xxx` / `①xxx`. Captures the content after
/// the marker. A delimiter after the digits is required, so a bare `2型糖尿病`
/// (no delimiter) is NOT mistaken for a numbered item.
fn numbered_item_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"^\s*(?:\d+\s*[.、)）]|[\u{2460}-\u{2473}])\s*(.+)$").expect("numbered item re")
    })
}

/// Trailing ICD-style code in (), （）, [], 【】: `(E11.9)`, `[I10]`. Inner content
/// (capture group 1) must start with a letter+digit — the ICD-10 shape — so a
/// genuine parenthetical like `高血压(3级)` is left intact. Group 1 is the bare
/// code for [`ConditionMention::icd_code`]; the whole match is stripped from the
/// display name.
fn icd_paren_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"\s*[(（\[【]\s*([A-Za-z]\d[0-9A-Za-z.\-]*)\s*[)）\]】]\s*$").expect("icd re")
    })
}

/// An **in-line** numbered marker: whitespace (or line start) then `N.`/`N、`/`N)`.
/// The delimiter after the digit is required, so `高血压 3 级` / `2 型糖尿病` (a digit
/// glued to the disease name, no delimiter) is NOT treated as a marker.
///
/// 真 corpus 把多诊断写在一行:`出院诊断:1. 急性脑梗死 2. 高血压3级 3. 2型糖尿病`。
/// 这些 ` 2.` ` 3.` 既不是标点分隔符也不是「独立成行」的编号块,过去整行塌成一条
/// term。先按它切开,行内多诊断才拆得开(quality dim 1)。
fn inline_number_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // Whitespace (or end) MUST follow the delimiter, so a decimal measurement inside
    // a diagnosis (`甲状腺结节 1.2cm`) is not split at the `.` — the corpus always
    // writes list markers as `1. ` / `2. ` with a trailing space.
    R.get_or_init(|| Regex::new(r"(?:^|\s)\d+\s*[.、)）](?:\s+|$)").expect("inline number re"))
}

/// Split an inline diagnosis string, clean each part, keep order. Two passes:
/// first on in-line numbered markers (` 2.` ` 3.`), then on `；;，,、`. Each kept
/// part is `(display_name, optional_icd_code)`.
fn split_inline(s: &str) -> Vec<(String, Option<String>)> {
    inline_number_re()
        .split(s)
        .flat_map(|seg| seg.split(['；', ';', '，', ',', '、']))
        .filter_map(clean_dx)
        .collect()
}

/// Normalize one diagnosis term: strip any leading list numbering, capture then
/// strip a trailing ICD code, trim punctuation/space. Returns `(display_name,
/// icd_code)` — `icd_code` is `Some` only when the term printed one. `None` for
/// empties (an ICD code alone, with no disease text left, is not a diagnosis).
fn clean_dx(raw: &str) -> Option<(String, Option<String>)> {
    let mut s = numbered_item_re()
        .captures(raw)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .unwrap_or_else(|| raw.to_string());
    // Capture the bare code (group 1) before stripping the whole `(…)` match.
    let icd = icd_paren_re()
        .captures(&s)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()));
    s = icd_paren_re().replace(&s, "").to_string();
    let s = s
        .trim()
        .trim_matches(|c: char| {
            c.is_whitespace()
                || matches!(c, '.' | '。' | '、' | '，' | ',' | ';' | '；' | ':' | '：')
        })
        .to_string();
    if s.is_empty() {
        None
    } else {
        Some((s, icd))
    }
}

/// Extract diagnosis mentions from labeled sections. De-dups identical
/// (raw_text, section) pairs; keeps raw strings (no terminology normalization).
pub fn extract_conditions(text: &str) -> Vec<ConditionMention> {
    let lines: Vec<&str> = text.lines().collect();
    let mut out = Vec::new();
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut push =
        |dx: String, section: &str, icd: Option<String>, out: &mut Vec<ConditionMention>| {
            if seen.insert((dx.clone(), section.to_string())) {
                out.push(ConditionMention {
                    raw_text: dx,
                    section: Some(section.to_string()),
                    icd_code: icd,
                });
            }
        };

    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let hits = section_hits(line);
        if hits.is_empty() {
            i += 1;
            continue;
        }

        // Each label owns the text from its colon up to where the next label's
        // match starts; anything before the first label (`处方日期:2026-06-20`) is
        // not part of any diagnosis section and is dropped.
        for (k, (section, inline_start, _)) in hits.iter().enumerate() {
            let inline_end = hits.get(k + 1).map_or(line.len(), |next| next.2);
            for (dx, icd) in split_inline(line[*inline_start..inline_end].trim()) {
                push(dx, section, icd, &mut out);
            }
        }

        // A following numbered block belongs to the **last** label on the line —
        // the one whose text the block continues. Stop at a blank or non-numbered
        // line.
        let section = hits.last().expect("hits is non-empty").0;
        let mut j = i + 1;
        while j < lines.len() {
            if lines[j].trim().is_empty() || !numbered_item_re().is_match(lines[j]) {
                break;
            }
            if let Some((dx, icd)) = clean_dx(lines[j]) {
                push(dx, section, icd, &mut out);
            }
            j += 1;
        }
        i = j.max(i + 1);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_split_and_section_captured() {
        let obs = extract_conditions("出院诊断:2型糖尿病；高血压病3级");
        assert_eq!(obs.len(), 2);
        assert_eq!(obs[0].raw_text, "2型糖尿病");
        assert_eq!(obs[0].section.as_deref(), Some("出院诊断"));
        assert_eq!(obs[1].raw_text, "高血压病3级");
        assert_eq!(obs[1].section.as_deref(), Some("出院诊断"));
    }

    #[test]
    fn inline_numbered_multi_diagnosis_splits() {
        // 真 corpus 出院诊断:一行内用 `1. .. 2. .. 3. ..` 串三个诊断,须拆成三条,
        // 且 term 里不含行内编号标记(`2.`/`3.`),病名内的空格保留(逐字)。
        let obs =
            extract_conditions("出院诊断:1. 急性脑梗死  2. 高血压 3 级(很高危)  3. 2 型糖尿病");
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["急性脑梗死", "高血压 3 级(很高危)", "2 型糖尿病"]);
        assert!(obs.iter().all(|o| !o.raw_text.contains(" 2.")
            && !o.raw_text.contains(" 3.")
            && !o.raw_text.contains('。')));
    }

    #[test]
    fn decimal_measurement_in_diagnosis_is_not_split() {
        // 病名带尺寸的小数(`1.2cm`)不得被行内编号切分成 `["甲状腺结节","2cm"]`。
        let obs = extract_conditions("诊断:甲状腺结节 1.2cm");
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["甲状腺结节 1.2cm"]);
    }

    #[test]
    fn numbered_block_and_icd_code_stripped() {
        let text = "\
出院诊断:
1. 2型糖尿病(E11.9)
2. 高血压病3级

医师签名:王五
";
        let obs = extract_conditions(text);
        assert_eq!(obs.len(), 2);
        // ICD code stripped from the name (disease-leading digit 2型 preserved) but
        // now captured into icd_code; a term with no code carries None.
        assert_eq!(obs[0].raw_text, "2型糖尿病");
        assert_eq!(obs[0].icd_code.as_deref(), Some("E11.9"));
        assert_eq!(obs[0].section.as_deref(), Some("出院诊断"));
        assert_eq!(obs[1].raw_text, "高血压病3级");
        assert_eq!(obs[1].icd_code, None);
    }

    #[test]
    fn label_variants_and_dedup() {
        // A different label is captured; duplicates within a section collapse.
        let text = "\
初步诊断：冠心病、冠心病
其他诊断:高尿酸血症
";
        let obs = extract_conditions(text);
        assert_eq!(obs.len(), 2);
        assert_eq!(obs[0].raw_text, "冠心病");
        assert_eq!(obs[0].section.as_deref(), Some("初步诊断"));
        assert_eq!(obs[1].raw_text, "高尿酸血症");
        assert_eq!(obs[1].section.as_deref(), Some("其他诊断"));
    }

    /// 真 corpus 的处方笺把日期和诊断排在同一行(20 份里 4 份都这样)。`^` 锚定时
    /// 整行抓不到,一张处方上的诊断全部消失——高尿酸血症因此拿不到泳道。
    /// 标签前的 `处方日期:2026-06-20` 不属于任何诊断段,必须丢掉。
    #[test]
    fn label_mid_line_after_the_prescription_date() {
        let obs = extract_conditions(
            "处方日期:2026-06-20    临床诊断:2 型糖尿病、糖尿病肾病(早期)、高尿酸血症",
        );
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["2 型糖尿病", "糖尿病肾病(早期)", "高尿酸血症"]);
        assert!(obs.iter().all(|o| o.section.as_deref() == Some("临床诊断")));
        // The date is not a diagnosis and must not ride along in the first term.
        assert!(!terms[0].contains("2026"));
    }

    /// OCR 把双栏报表压成一行时,诊断标签会落在一段化验文字后面。空白就是边界,
    /// 前面那段化验文字整段丢弃。
    #[test]
    fn ocr_column_collapse_leaves_the_label_mid_line() {
        let obs = extract_conditions("血红蛋白 140 g/L 130-175   其他诊断:高尿酸血症");
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["高尿酸血症"]);
        assert_eq!(obs[0].section.as_deref(), Some("其他诊断"));
    }

    /// A closing bracket ends the previous token as cleanly as a space does, and
    /// scanned notes print `既往(2019年)诊断:…` with no gap.
    #[test]
    fn closing_bracket_counts_as_a_boundary() {
        let obs = extract_conditions("既往(2019年)诊断:痛风");
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["痛风"]);
        assert_eq!(obs[0].section.as_deref(), Some("诊断"));
    }

    /// 病理诊断 is a narrative impression, not a problem list (see the module doc).
    /// The `^` anchor used to exclude it as a side effect; now the boundary rule
    /// must do it — for the glued form (a Han character is not a boundary), for the
    /// OCR-spaced form, and mid-prose. Comma-splitting that paragraph would invent
    /// 「伴轻度肠上皮化生」 and 「未见异型增生及恶性证据」 as diagnoses.
    #[test]
    fn pathology_impression_is_never_a_problem_list() {
        for text in [
            "病理诊断:\n(胃窦)慢性活动性胃炎,伴轻度肠上皮化生,Hp 阳性(++)。",
            "病理 诊断:(胃窦)慢性活动性胃炎,伴轻度肠上皮化生",
            "浙江大学医学院附属第一医院 病理科 病理诊断报告 (pathology)",
            "建议:结合病理诊断:慢性活动性胃炎,择期复查。",
        ] {
            assert!(
                extract_conditions(text).is_empty(),
                "pathology narrative leaked into the problem list: {text}"
            );
        }
    }

    /// Other compound headings that end in 诊断 but do not name the patient's
    /// problems: 鉴别诊断 lists what is being ruled *out* (recording it as a
    /// diagnosis hands the doctor diseases the note explicitly did not diagnose),
    /// and 影像诊断 / 超声诊断 / 心电图诊断 are the findings of one study —
    /// `窦性心律` is not a problem. `诊断意见:` has no colon straight after the
    /// label so it never matched and still doesn't. Every one of these was already
    /// excluded by the anchor; the boundary rule keeps them excluded.
    #[test]
    fn compound_headings_are_not_diagnosis_labels() {
        for text in [
            "鉴别诊断:1. 急性胰腺炎  2. 消化性溃疡穿孔",
            "鉴别 诊断:急性胰腺炎",
            "影像诊断:双肺纹理增粗",
            "心电图诊断:\n1.窦性心律\n2.心率72次/分",
            "超声诊断:脂肪肝(中度)",
            "诊断意见:\n1. 左侧基底节区陈旧性脑梗死软化灶。",
        ] {
            assert!(
                extract_conditions(text).is_empty(),
                "`{text}` is not a problem list but produced diagnoses"
            );
        }
    }

    /// The compound-heading guard must not spill onto a *qualified* label. An
    /// imaging request form prints 检查项目 and 临床诊断 on one row, and 腹部超声
    /// lands right in front of the label — but 超声临床诊断 is not a word, so the
    /// diagnosis is real and must survive.
    #[test]
    fn compound_guard_does_not_block_a_qualified_label() {
        let obs = extract_conditions("检查项目:腹部超声  临床诊断:脂肪肝、2型糖尿病");
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["脂肪肝", "2型糖尿病"]);
        assert!(obs.iter().all(|o| o.section.as_deref() == Some("临床诊断")));
    }

    /// A collapsed line can carry two labels. Each owns the text up to where the
    /// next label starts — otherwise the first diagnosis swallows the rest of the
    /// line (`急性脑梗死    出院诊断:高血压3级`) and both sections are lost.
    #[test]
    fn several_labels_on_one_line_each_own_their_text() {
        let obs = extract_conditions("入院诊断:急性脑梗死    出院诊断:高血压3级、2型糖尿病");
        let got: Vec<(&str, &str)> = obs
            .iter()
            .map(|o| (o.section.as_deref().unwrap_or(""), o.raw_text.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("入院诊断", "急性脑梗死"),
                ("出院诊断", "高血压3级"),
                ("出院诊断", "2型糖尿病"),
            ]
        );
    }

    /// With several labels on the line, a numbered block underneath continues the
    /// **last** one — that is the label whose text was left open.
    #[test]
    fn numbered_block_belongs_to_the_last_label_on_the_line() {
        let text = "\
入院诊断:急性脑梗死    出院诊断:
1. 高血压病3级
2. 2型糖尿病
";
        let obs = extract_conditions(text);
        let got: Vec<(&str, &str)> = obs
            .iter()
            .map(|o| (o.section.as_deref().unwrap_or(""), o.raw_text.as_str()))
            .collect();
        assert_eq!(
            got,
            [
                ("入院诊断", "急性脑梗死"),
                ("出院诊断", "高血压病3级"),
                ("出院诊断", "2型糖尿病"),
            ]
        );
    }

    /// Known and deliberate: a scanned prescription that separates its diagnoses
    /// with **spaces only** stays one term. Splitting on spaces is not available —
    /// the same corpus writes `高血压 3 级(很高危)` and `2 型糖尿病` with spaces
    /// inside the disease name, so it would shatter far more than it joins. The
    /// mention is still emitted (it merges onto the diabetes lane downstream and
    /// loses the display slot to the shorter `2 型糖尿病`), so nothing regresses —
    /// but the row is not three diagnoses, and this test says so out loud.
    #[test]
    fn space_separated_inline_diagnoses_stay_one_term() {
        let obs =
            extract_conditions("处方日期:2025-12-03 诊断:2型糖尿病 糖尿病肾病(早期) 高血压3级");
        let terms: Vec<&str> = obs.iter().map(|o| o.raw_text.as_str()).collect();
        assert_eq!(terms, ["2型糖尿病 糖尿病肾病(早期) 高血压3级"]);
    }

    /// The boundary must be a real character. A label glued straight onto the
    /// previous token has none, so it is not picked up — an accepted gap, not an
    /// oversight: allowing digits or `:` as boundaries would let `诊断` attach to
    /// the tail of anything.
    #[test]
    fn label_glued_to_the_previous_token_is_not_picked_up() {
        assert!(extract_conditions("处方日期:2025-12-03诊断:2型糖尿病").is_empty());
    }

    #[test]
    fn bracket_icd_and_non_diagnosis_lines_ignored() {
        let text = "\
主诉:多饮多尿1年
临床诊断:2型糖尿病[E11.9]
血压:130/80
";
        let obs = extract_conditions(text);
        assert_eq!(obs.len(), 1);
        assert_eq!(obs[0].raw_text, "2型糖尿病");
        // Bracket form [E11.9] is captured the same as the paren form.
        assert_eq!(obs[0].icd_code.as_deref(), Some("E11.9"));
        assert_eq!(obs[0].section.as_deref(), Some("临床诊断"));
    }
}
