//! Deterministic lab-value extraction (stage B).
//!
//! Turns a lab report's OCR text into structured, normalized [`LabObservation`]
//! rows. Pure string work: no network, no LLM. Normalization/coding is delegated
//! to the `terminology` crate — this module only locates rows, parses numbers,
//! and asks terminology what each analyte is.
//!
//! ## Row shapes handled
//! Chinese lab reports are table-ish; columns are separated by 2+ spaces or tabs:
//! ```text
//! 项目            结果    单位        参考范围     [↑/↓]
//! 肌酐            88      μmol/L      59-104
//! 谷丙转氨酶(ALT) 45      U/L         0-40         ↑
//! 低密度脂蛋白胆固醇 3.6   mmol/L      <3.4         ↑
//! ```
//! Plus the labeled inline form: `肌酐: 88 μmol/L (参考 59-104)`.
//!
//! A line is treated as a lab row when it has a name token (contains a letter or
//! CJK char) + a numeric result AND at least one piece of lab evidence (a unit, a
//! reference range, an explicit H/L marker, or a successful terminology match).
//! That evidence gate is what skips demographics like `年龄:60` without a
//! blocklist — honest, deterministic, and it still keeps genuine-but-unknown
//! analytes (they carry a unit/range).
//!
//! ## Name↔value glue (OCR drops the separator)
//! OCR sometimes runs the name straight into the result with no space at all
//! (`含量*26.3`, real corpus). Naive non-greedy name matching can't stop there
//! (no separator to anchor on), so it keeps growing "name" past the glued
//! digits until it finds the NEXT real separator+number — which is usually
//! the reference range's low bound — and wrongly reports THAT as the result
//! (`27` instead of `26.3`, a fabricated near-miss, not just a dropped row).
//! `fix_name_value_glue` detects this and inserts the missing space, but only
//! when unambiguous: exactly one glue point, and the glued digits aren't
//! themselves glued to yet another number. Anything less clear-cut drops the
//! whole row rather than guess — see that function's doc for why.
//!
//! ## Deliberately NOT handled (kept lean)
//! - Ratio-style results printed as one token (`血压 120/80`) — the `/80` is
//!   mistaken for a unit; blood pressure is a vital, out of scope here.
//! - Multi-line wrapped rows (name on one line, value on the next).
//! - Reference ranges are parsed/stored in the RAW reporting unit only; the
//!   struct has no canonical-ref fields, so refs are compared against the raw
//!   value (same unit) for flagging and left un-converted.

use regex::Regex;
use std::sync::OnceLock;
use terminology::{dictionary_entries, normalize_unit, resolve};

/// One normalized lab result row. Mapping is additive: the raw name/value is
/// always kept even when terminology can't resolve it (upper layer decides).
#[derive(Debug, Clone)]
pub struct LabObservation {
    pub raw_name: String,
    pub analyte_key: Option<String>,
    pub canonical_name: Option<String>,
    pub loinc: Option<String>,
    pub value_num: f64,
    pub value_canonical: Option<f64>,
    pub unit_raw: Option<String>,
    pub unit_canonical: Option<String>,
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    /// "H" | "L" | "N": explicit ↑/↓/H/L marker if present, else value-vs-ref.
    pub flag: Option<String>,
    /// 0.0 if unmatched; else the terminology `Match.confidence`.
    pub confidence: f32,
}

/// A lab-report line whose result couldn't be read with confidence — kept and
/// surfaced (never guessed, never silently dropped) so a person can check it
/// against the original document during per-document review. Never mixed into
/// `Vec<LabObservation>`; see `extract_labs_with_unreadable`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreadableRow {
    /// The original OCR text line, verbatim — for cross-checking the source.
    pub raw_line: String,
    /// Why it couldn't be read, phrased for the person reviewing it (a
    /// patient/doctor), not a developer — plain Chinese, not an error code.
    pub reason: String,
}

/// `name  value  rest`. Name is non-greedy so `value` is the FIRST number after
/// the first separator run (space/tab/colon) — i.e. the result column.
/// `sep2` (the gap between value and rest) is captured, not just skipped, so
/// callers can tell a genuine separator from a zero-width one — see
/// `value_glued_to_next_number`.
fn row_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"^\s*(?P<name>.*?)[\s:：]+(?P<value>-?\d+(?:\.\d+)?)(?P<sep2>\s*)(?P<rest>.*)$")
            .expect("row re")
    })
}

// Reference-range regexes match ANYWHERE in the trailing columns (not anchored),
// and tolerate spaces around the comparator/dash. 真 corpus 把参考写成带空格的
// `< 5.20`、`> 90`、`3.9 - 6.1` —— 逐 token 分类会把 `<` 和 `5.20` 拆成两个各自作废
// 的 token,单边参考(LDL/TC/eGFR)与带空格的双边参考就全丢了(quality dim 4/5)。
fn range_two_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d+(?:\.\d+)?)\s*[-~]\s*(\d+(?:\.\d+)?)").expect("range re"))
}
fn range_high_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[<≤]=?\s*(\d+(?:\.\d+)?)").expect("high re"))
}
fn range_low_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[>≥]=?\s*(\d+(?:\.\d+)?)").expect("low re"))
}
/// A dash-separated `YYYY-MM-DD` date. Only the dash form matters: the range regex
/// keys on `[-~]`, so slash/dot dates never look like a range in the first place.
/// A real reference range has a single dash (`3.9-6.1`); a date has two — so this
/// blanks a trailing 采样/报告日期 (`… 2024-01-05`) without ever eating a range,
/// stopping it from being misread as `2024-1` and fabricating a flag. Quality dim 4/5.
fn date_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"\d{2,4}-\d{1,2}-\d{1,2}").expect("date re"))
}

/// Matches a `YYYY-MM-DD` date sitting right at the start of the "value column"
/// (i.e. immediately after the name + separator, allowing only whitespace/colons
/// in between). Used to reject whole rows like `采集时间：2026-07-11 05:22:25`:
/// `row_re` doesn't know `采集时间` isn't an analyte name, so it happily reads
/// `2026` as the result and hands `-07-11…` to `parse_rest`, which misreads it as
/// a reference range (`07-1105` → refLow 7 / refHigh 1105 — pure fabrication).
/// A genuine lab result is always a bare number, never a date stamp, so this
/// shape is unambiguous: whole row out, not just the range. Deliberately keys
/// only on the date's own digits (not the label text `时间`/`日期`), so it
/// catches 采集/送检/报告/检验 time rows alike, however OCR spells the label,
/// without turning into a word blocklist.
fn date_value_column_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^[\s:：]*\d{4}-\d{1,2}-\d{1,2}").expect("date column re"))
}

/// OCR frequently glues the CBC `×10⁹/L` / `×10¹²/L` unit straight onto the
/// number right before it, with no separating space (`0.12~1.2010~9/L` — should
/// read as range `0.12~1.20` + unit `10~9/L`). Without a boundary there, the
/// greedy decimal-number regex swallows the unit's leading "10" as more fraction
/// digits (refHigh becomes `1.201` instead of `1.20`), and what's left of the
/// unit token loses its "10" prefix (`~9/L` instead of `10~9/L`). The
/// `10`(`^`|`~`)?(`9`|`12`)`/` shape is a fixed, well-known clinical unit
/// notation — it is never a plausible continuation of a decimal number — so
/// wherever it's found glued to a preceding digit, split it off with a space
/// before any number parsing runs. Captures the preceding digit (group 1) since
/// the `regex` crate has no lookbehind.
fn glued_cbc_unit_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d)(10[\^~]?(?:9|12)/)").expect("glued cbc unit re"))
}

/// A CJK ideograph or the OCR "省内互认项目" star, directly (zero separator)
/// followed by a decimal number — the shape of a glued analyte name + result
/// (`含量*26.3`). Group 1 captures the digit run so its start position is the
/// exact spot to insert the missing space. Restricted to CJK/`*` specifically
/// (not any name char) so it can never fire on an ordinary ASCII analyte code
/// like `CA125` or a serial-number prefix (`12红细胞` — digit-then-CJK, the
/// other direction, never matches this pattern).
fn glued_name_value_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"[\u{4e00}-\u{9fa5}*](\d+(?:\.\d+)?)").expect("glued name-value re")
    })
}

/// User-facing reason (Chinese, for the person reviewing the row — not a
/// developer) for the two ambiguous-glue shapes below. Shared by both the
/// name↔value glue check (`fix_name_value_glue`) and the post-parse value↔range
/// glue check (`value_glued_to_next_number`), since they're the same
/// underlying phenomenon caught at two different points in the pipeline.
/// Labels that only ever appear in a report's letterhead / specimen block, never
/// in an analyte name. A row whose "name" contains one of these is page
/// furniture that happened to end in a number (`… 年龄：58岁 门诊号：20230615-1046`
/// → value 58, reference range 20230615–1046), and charting it puts a fabricated
/// trend line next to a real one in the doctor's view.
///
/// Deliberately a *name* list, not a punctuation heuristic — see the call site.
/// Keep it to words that cannot be part of a measured quantity; `血压` and
/// `体温` are vitals, not furniture, and must never appear here.
const PAGE_FURNITURE: &[&str] = &[
    "姓名",
    "性别",
    "年龄",
    "门诊号",
    "住院号",
    "病案号",
    "床号",
    "科室",
    "样本类型",
    "标本类型",
    "采集时间",
    "送检时间",
    "报告时间",
    "审核时间",
    "检验者",
    "审核者",
    "送检医生",
    "申请医生",
];

const REASON_VALUE_GLUED_TO_RANGE: &str = "数值和参考范围粘在一起,读不准,请核对原件";
const REASON_MULTIPLE_GLUE_POINTS: &str =
    "这一行有多处数字和名称粘在一起,分不清对应关系,读不准,请核对原件";

/// Result of scanning a raw line for the name↔value glue.
enum GlueFix {
    /// No glue point found — line is used as-is.
    Clean,
    /// Exactly one glue point, cleanly bounded (not itself glued to another
    /// number) — corrected line, ready to feed through `row_re`.
    Fixed(String),
    /// Glue found but not safely resolvable — 2+ candidate glue points (can't
    /// tell which is the real name/value boundary), or the glued number is
    /// itself glued to yet another number. Row is kept as an `UnreadableRow`
    /// (see module doc), not guessed — the carried string is the user-facing
    /// reason.
    Ambiguous(&'static str),
}

/// True when the text right after `pos` starts with a decimal number glued
/// with zero separator — i.e. `pos` sits between two back-to-back numbers.
/// Shared by both glue checks: a name glued to a value (here) and a value
/// glued to a reference range's low bound (`value_glued_to_next_number`).
fn starts_with_glued_number(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_digit() => true,
        Some('.') => chars.next().is_some_and(|c2| c2.is_ascii_digit()),
        _ => false,
    }
}

/// Scan `line` for an unresolved name↔value glue (see module doc) and, when
/// it's unambiguous, return a corrected line with the missing space inserted.
///
/// "Unambiguous" means: exactly one glue candidate in the line (2+ candidates
/// means we can't tell which is the true name/value boundary), and the glued
/// digits are not themselves immediately followed by more digits (that would
/// mean the "value" is glued to a second number too — e.g. a reference
/// range's low bound — which has no reliable split point; see
/// `value_glued_to_next_number`). Real corpus never trips the multi-candidate
/// branch; it exists as a safety net, not a case observed in practice.
fn fix_name_value_glue(line: &str) -> GlueFix {
    let mut caps_iter = glued_name_value_re().captures_iter(line);
    let Some(caps) = caps_iter.next() else {
        return GlueFix::Clean;
    };
    if caps_iter.next().is_some() {
        return GlueFix::Ambiguous(REASON_MULTIPLE_GLUE_POINTS);
    }
    let whole = caps.get(0).expect("group 0 always present");
    let digits = caps.get(1).expect("digit group always present");
    if starts_with_glued_number(&line[whole.end()..]) {
        return GlueFix::Ambiguous(REASON_VALUE_GLUED_TO_RANGE);
    }
    let insert_at = digits.start();
    let mut corrected = String::with_capacity(line.len() + 1);
    corrected.push_str(&line[..insert_at]);
    corrected.push(' ');
    corrected.push_str(&line[insert_at..]);
    GlueFix::Fixed(corrected)
}

/// True when `value` is glued directly (zero separator, `sep2_is_empty`) to
/// what looks like the start of another number in `rest` — e.g. OCR's
/// `2.353.5~5.5` where the true value `2.35` and the reference range's low
/// bound `3.5` were printed with no space between them.
///
/// Two decimal numbers run together like this have no reliable split point:
/// `2.35|3.5`, `2.3|53.5`, and `2|.353.5` are all syntactically valid
/// numbers — nothing in the text says which one is right. Before this check,
/// `row_re`'s greedy value match picked ONE of those splits anyway (usually
/// the wrong one) and additionally corrupted the reference range with
/// whatever digits were left over. Per the "宁可漏,不能编" rule, this row is
/// dropped rather than reporting a value we can't actually justify.
fn value_glued_to_next_number(sep2_is_empty: bool, rest: &str) -> bool {
    sep2_is_empty && starts_with_glued_number(rest)
}

/// Fold the full-width comparison/range punctuation a report might use into the
/// half-width forms the range regexes expect. Pure notation, not semantics.
fn fold_range_punct(tok: &str) -> String {
    tok.chars()
        .map(|c| match c {
            '～' => '~',
            '－' | '—' | '−' => '-',
            '＜' => '<',
            '＞' => '>',
            _ => c,
        })
        .collect()
}

/// A located reference range: `(low, high, byte_span_in_folded)`.
type RangeMatch = (Option<f64>, Option<f64>, (usize, usize));

/// Locate the reference range anywhere in the trailing columns. Returns
/// `(low, high, byte_span_in_folded)`: `59-104`/`3.9 - 6.1` → both bounds;
/// `< 5.20`/`≤6.5` → high only; `> 90`/`≥130` → low only. Two-sided wins over
/// single-sided. `None` when no range is present. `folded` must already be
/// punctuation-folded so `＜`/`～`/`－` read as `<`/`~`/`-`.
fn find_range(folded: &str) -> Option<RangeMatch> {
    if let Some(c) = range_two_re().captures(folded) {
        let lo = c.get(1)?.as_str().parse().ok();
        let hi = c.get(2)?.as_str().parse().ok();
        let m = c.get(0)?;
        return Some((lo, hi, (m.start(), m.end())));
    }
    if let Some(c) = range_high_re().captures(folded) {
        let hi = c.get(1)?.as_str().parse().ok();
        let m = c.get(0)?;
        return Some((None, hi, (m.start(), m.end())));
    }
    if let Some(c) = range_low_re().captures(folded) {
        let lo = c.get(1)?.as_str().parse().ok();
        let m = c.get(0)?;
        return Some((lo, None, (m.start(), m.end())));
    }
    None
}

/// Parse the trailing `单位 参考范围 [↑/↓]` columns. The reference range is matched
/// on the whole (punctuation-folded) string first — so a spaced `< 5.20` or
/// `3.9 - 6.1` parses as one range — then blanked out; unit and flag are read from
/// what remains, order-independently.
fn parse_rest(rest: &str) -> (Option<String>, Option<f64>, Option<f64>, Option<String>) {
    let folded = fold_range_punct(rest);
    // Split a CBC ×10⁹/L or ×10¹²/L unit that OCR glued onto the number before it
    // (see glued_cbc_unit_re doc) before any numeric parsing, so the range regex
    // can't read the unit's leading "10" as extra fraction digits.
    let folded = glued_cbc_unit_re()
        .replace_all(&folded, "$1 $2")
        .into_owned();
    // Blank any embedded date so the unanchored range scan can't read it as a range.
    let folded = date_re().replace_all(&folded, " ").into_owned();
    let (mut low, mut high) = (None, None);
    let mut scan = folded.clone();
    if let Some((lo, hi, (s, e))) = find_range(&folded) {
        low = lo;
        high = hi;
        // Blank the range so its digits can't be re-read as a unit token.
        scan.replace_range(s..e, " ");
    }

    let (mut unit, mut flag) = (None, None);
    for raw in scan.split_whitespace() {
        let tok =
            raw.trim_matches(|c| matches!(c, '(' | ')' | '（' | '）' | '[' | ']' | '【' | '】'));
        if tok.is_empty() {
            continue;
        }
        // Explicit flag markers (arrows may be glued to another token).
        if raw.contains('↑') || tok == "H" || tok == "高" || tok == "偏高" {
            flag = Some("H".to_string());
            continue;
        }
        if raw.contains('↓') || tok == "L" || tok == "低" || tok == "偏低" {
            flag = Some("L".to_string());
            continue;
        }
        // Label noise inside inline `(参考 …)` / `正常范围` etc.
        if tok.contains("参考") || tok.contains("范围") || tok.contains("正常") {
            continue;
        }
        // First unit-looking token wins (has a letter, %, / or degree sign).
        if unit.is_none()
            && tok
                .chars()
                .any(|c| c.is_ascii_alphabetic() || c == '%' || c == '/' || c == '°')
        {
            unit = Some(tok.to_string());
        }
    }
    (unit, low, high, flag)
}

/// Extract normalized lab observations from a report's text. Unknown analytes
/// are kept (analyte_key = None, confidence 0.0), never dropped.
///
/// This is the stable, existing signature (`aggregate.rs` depends on it) — it
/// silently discards lines that can't be read at all. To also see those lines
/// (surfaced for human review instead of thrown away), use
/// `extract_labs_with_unreadable`.
pub fn extract_labs(text: &str) -> Vec<LabObservation> {
    extract_labs_with_unreadable(text).0
}

/// Same extraction as `extract_labs`, plus the lines that couldn't be read
/// with confidence (ambiguous number gluing — see module doc "Name↔value
/// glue"), returned as `UnreadableRow`s instead of being thrown away. Per
/// "宁可漏,不能编": these rows are never guessed into a `LabObservation`, only
/// kept verbatim for a human to check against the original document.
pub fn extract_labs_with_unreadable(text: &str) -> (Vec<LabObservation>, Vec<UnreadableRow>) {
    let mut out = Vec::new();
    let mut unreadable = Vec::new();
    for raw_line in text.lines() {
        // Un-glue a name directly fused to its value (`含量*26.3`) before
        // row_re ever sees the line — see fix_name_value_glue doc. An
        // ambiguous glue (can't tell where name ends) surfaces the row as
        // unreadable rather than guessing.
        let owned_line;
        let line: &str = match fix_name_value_glue(raw_line) {
            GlueFix::Clean => raw_line,
            GlueFix::Fixed(s) => {
                owned_line = s;
                &owned_line
            }
            GlueFix::Ambiguous(reason) => {
                unreadable.push(UnreadableRow {
                    raw_line: raw_line.to_string(),
                    reason: reason.to_string(),
                });
                continue;
            }
        };
        let Some(caps) = row_re().captures(line) else {
            continue;
        };
        let name_group = caps.name("name").expect("name group");
        let raw_name = name_group.as_str().trim();
        // Need a real name token — rejects date/number-only lines.
        if raw_name.is_empty() || !raw_name.chars().any(|c| c.is_alphabetic()) {
            continue;
        }
        // The "value column" (everything from right after the name) is itself a
        // YYYY-MM-DD date — this is a 采集/送检/报告 timestamp row, not a result.
        // See date_value_column_re doc.
        if date_value_column_re().is_match(&line[name_group.end()..]) {
            continue;
        }
        // A real analyte name has no *sentence* punctuation. This rejects narrative
        // fragments that a mis-routed prose/imaging line would otherwise smuggle in
        // as a "lab" (`右肺上叶尖段磨玻璃结节(GGN),大小约` value 8 …) — quality dim 3.
        if raw_name
            .chars()
            .any(|c| matches!(c, '，' | ',' | '。' | '；' | ';' | '、'))
        {
            continue;
        }
        // Demographics / specimen headers (`姓名：张建国  性别：男  年龄：58岁
        // 门诊号：20230615-1046`) parse as a lab row because the trailing field is
        // numeric: name = `姓名：张建国  性别：男  年龄`, value = 58, and the 门诊号
        // digits get read as a reference range. The viewer then charts that as a
        // trend line and flags it red, next to a real creatinine curve.
        //
        // Identified by NAMING the furniture, not by guessing from punctuation.
        // The obvious punctuation rule — "a colon inside the name means it is
        // really several `label：value` fields" — reads well and is wrong: it
        // discards `生化:钾 4.2 mmol/L 3.5-5.3`, `甲功三项:TSH …`, `PT:INR …` and
        // `白球比值(A:G) 1.52 1.20-2.40` (which resolves to a real dictionary
        // entry). The dictionary itself curates `皮质醇(8:00)` and friends, so a
        // colon in an analyte name is expressly normal in this domain.
        if PAGE_FURNITURE.iter().any(|w| raw_name.contains(w)) {
            continue;
        }
        let Ok(value_num) = caps
            .name("value")
            .expect("value group")
            .as_str()
            .parse::<f64>()
        else {
            continue;
        };
        let rest = caps.name("rest").expect("rest group").as_str();
        // Value glued with zero separator straight into another number (its
        // own reference range's low bound, typically) — no reliable split
        // point exists (see value_glued_to_next_number doc). Surface it as
        // unreadable rather than report a value we can't actually justify.
        let sep2_is_empty = caps.name("sep2").expect("sep2 group").as_str().is_empty();
        if value_glued_to_next_number(sep2_is_empty, rest) {
            unreadable.push(UnreadableRow {
                raw_line: raw_line.to_string(),
                reason: REASON_VALUE_GLUED_TO_RANGE.to_string(),
            });
            continue;
        }
        let (unit_raw, ref_low, ref_high, explicit_flag) = parse_rest(rest);

        let m = resolve(raw_name, unit_raw.as_deref());
        // Lab-row gate: some evidence beyond "a name and a number" must exist,
        // else it's demographics/metadata (年龄:60) — skip it.
        let has_evidence = unit_raw.is_some()
            || ref_low.is_some()
            || ref_high.is_some()
            || explicit_flag.is_some()
            || m.is_some();
        if !has_evidence {
            continue;
        }

        // Canonical conversion (only when matched AND the entry knows this unit).
        let mut value_canonical = None;
        let mut unit_canonical = None;
        if let (Some(m), Some(u)) = (&m, &unit_raw) {
            if let Some(entry) = dictionary_entries().iter().find(|e| e.key == m.key) {
                let nu = normalize_unit(u);
                if let Some(conv) = entry.units.iter().find(|c| normalize_unit(&c.unit) == nu) {
                    value_canonical = Some(conv.slope * value_num + conv.intercept);
                    unit_canonical = entry.canonical_unit.clone();
                }
            }
        }

        // Flag: explicit marker wins; else compare raw value against raw refs.
        let flag = explicit_flag.or_else(|| {
            if ref_high.is_some_and(|h| value_num > h) {
                Some("H".to_string())
            } else if ref_low.is_some_and(|l| value_num < l) {
                Some("L".to_string())
            } else if ref_low.is_some() || ref_high.is_some() {
                Some("N".to_string())
            } else {
                None
            }
        });

        out.push(LabObservation {
            raw_name: raw_name.to_string(),
            analyte_key: m.as_ref().map(|m| m.key.clone()),
            canonical_name: m.as_ref().map(|m| m.canonical_name.clone()),
            loinc: m.as_ref().and_then(|m| m.codes.loinc.clone()),
            value_num,
            value_canonical,
            unit_raw,
            unit_canonical,
            ref_low,
            ref_high,
            flag,
            confidence: m.as_ref().map_or(0.0, |m| m.confidence),
        });
    }
    (out, unreadable)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find<'a>(obs: &'a [LabObservation], key: &str) -> &'a LabObservation {
        obs.iter()
            .find(|o| o.analyte_key.as_deref() == Some(key))
            .unwrap_or_else(|| panic!("no observation for {key}"))
    }

    #[test]
    fn renal_panel_extracts_creatinine() {
        let text = "\
生化检验报告单
项目            结果    单位        参考范围
肌酐            88      μmol/L      59-104
尿素            5.2     mmol/L      2.9-8.2
尿酸            380     μmol/L      150-420
";
        let obs = extract_labs(text);
        let cr = find(&obs, "creatinine");
        assert_eq!(cr.value_num, 88.0);
        assert_eq!(cr.raw_name, "肌酐");
        assert!(cr.loinc.is_some(), "creatinine must carry a LOINC");
        assert_eq!(cr.unit_canonical.as_deref(), Some("umol/L"));
        assert_eq!(cr.value_canonical, Some(88.0)); // identity conversion
        assert_eq!(cr.flag.as_deref(), Some("N")); // 88 within 59-104
        assert_eq!(cr.confidence, 1.0);
    }

    #[test]
    fn lipids_ldl_flag_high() {
        let text = "\
血脂四项
低密度脂蛋白胆固醇  3.6  mmol/L  <3.4  ↑
";
        let obs = extract_labs(text);
        let ldl = find(&obs, "ldl");
        assert_eq!(ldl.value_num, 3.6);
        assert_eq!(ldl.ref_high, Some(3.4));
        assert_eq!(ldl.ref_low, None);
        assert_eq!(ldl.flag.as_deref(), Some("H"));
    }

    #[test]
    fn spaced_single_sided_and_two_sided_refs_parse() {
        // 真 corpus 的写法:单边参考带空格 `< 5.20` / `> 90`,双边参考带空格 `3.9 - 6.1`。
        // 过去逐 token 分类把它们拆碎全丢;现在都要解析出 refLow/refHigh。
        let text = "\
TC         总胆固醇 Cholesterol   6.05     mmol/L      < 5.20          ↑
eGFR       估算肾小球滤过率      72       ml/min/1.73m2   > 90         ↓
GLU        空腹血糖 Glucose       7.1      mmol/L      3.9 - 6.1       ↑
";
        let obs = extract_labs(text);
        let tc = find(&obs, "cholesterol");
        assert_eq!(tc.ref_high, Some(5.20));
        assert_eq!(tc.ref_low, None);
        assert_eq!(tc.unit_raw.as_deref(), Some("mmol/L"));
        assert_eq!(tc.flag.as_deref(), Some("H"));
        let egfr = find(&obs, "egfr");
        assert_eq!(egfr.ref_low, Some(90.0));
        assert_eq!(egfr.ref_high, None);
        assert_eq!(egfr.flag.as_deref(), Some("L"));
        let glu = find(&obs, "glucose");
        assert_eq!(glu.ref_low, Some(3.9));
        assert_eq!(glu.ref_high, Some(6.1));
    }

    #[test]
    fn trailing_report_date_is_not_read_as_a_reference_range() {
        // 行尾的采样/报告日期(`2024-01-05`)不得被无锚点的范围扫描当成参考范围
        // `2024-1`,否则会伪造 refLow/refHigh 并派生出假异常 flag。
        let obs = extract_labs("葡萄糖 Glucose 5.0 mmol/L 2024-01-05");
        let glu = find(&obs, "glucose");
        assert_eq!(glu.ref_low, None);
        assert_eq!(glu.ref_high, None);
        assert_eq!(glu.flag, None);
        // 真参考范围与行尾日期并存时,仍解析出参考范围,且不被日期污染。
        let obs2 = extract_labs("葡萄糖 Glucose 7.1 mmol/L 3.9 - 6.1 ↑ 2024-01-05");
        let glu2 = find(&obs2, "glucose");
        assert_eq!(glu2.ref_low, Some(3.9));
        assert_eq!(glu2.ref_high, Some(6.1));
    }

    #[test]
    fn cbc_hemoglobin_flag_low() {
        let text = "\
血常规
血红蛋白    109     g/L       130-175   ↓
";
        let obs = extract_labs(text);
        let hb = find(&obs, "hgb");
        assert_eq!(hb.value_num, 109.0);
        assert_eq!(hb.unit_canonical.as_deref(), Some("g/L"));
        assert_eq!(hb.value_canonical, Some(109.0));
        assert_eq!(hb.flag.as_deref(), Some("L"));
    }

    #[test]
    fn mgdl_value_converts_to_canonical() {
        // Inline labeled form + mg/dL that must convert: 1.2 mg/dL * 88.42 ≈ 106.1 µmol/L.
        let text = "肌酐: 1.2 mg/dL (参考 0.6-1.3)";
        let obs = extract_labs(text);
        let cr = find(&obs, "creatinine");
        assert_eq!(cr.unit_raw.as_deref(), Some("mg/dL"));
        assert_eq!(cr.unit_canonical.as_deref(), Some("umol/L"));
        let vc = cr.value_canonical.expect("mg/dL must convert");
        assert!((vc - 106.104).abs() < 0.01, "got {vc}");
    }

    #[test]
    fn unmatched_analyte_row_is_kept() {
        let text = "神秘指标XYZ   12.3   mg/L   0-5";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 1);
        let o = &obs[0];
        assert_eq!(o.analyte_key, None);
        assert_eq!(o.canonical_name, None);
        assert_eq!(o.loinc, None);
        assert_eq!(o.confidence, 0.0);
        assert_eq!(o.value_num, 12.3);
        assert_eq!(o.unit_raw.as_deref(), Some("mg/L"));
        assert_eq!(o.flag.as_deref(), Some("H")); // 12.3 > 5, computed from ref
    }

    #[test]
    fn timestamp_rows_are_not_read_as_lab_results() {
        // Real repro (涟水县中医院血常规 OCR): OCR glues the date and time together
        // with no space. Before the fix, row_re read 采集时间/送检时间 as name +
        // value=2026, and the leftover `-07-1105:22:25` was misread as a reference
        // range (refLow 7 / refHigh 1105) — fabricated data reaching the summary.
        let text = "\
采集时间：2026-07-1105:22:25备注：
送检时间：2026-07-1107:57:51报告时间：2026-07-1108:26:25
";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 0, "got {:?}", obs);
    }

    #[test]
    fn date_only_metadata_row_without_a_time_is_also_skipped() {
        // Same bug class without a clock time glued on (`报告日期：2026-07-11`) —
        // must be rejected too, not just the timestamp variant.
        let obs = extract_labs("报告日期：2026-07-11");
        assert_eq!(obs.len(), 0, "got {:?}", obs);
    }

    #[test]
    fn year_like_value_is_not_mistaken_for_a_date_row() {
        // Counter-example: a legitimate result that happens to look like a year
        // (2020) must still be extracted — only a genuine YYYY-MM-DD shape right
        // after the name should reject the row.
        let obs = extract_labs("血糖 2020 mmol/L 3.9-6.1");
        let glu = find(&obs, "glucose");
        assert_eq!(glu.value_num, 2020.0);
        assert_eq!(glu.ref_low, Some(3.9));
        assert_eq!(glu.ref_high, Some(6.1));
    }

    #[test]
    fn glued_cbc_unit_does_not_inflate_ref_high_or_truncate_unit() {
        // Real repro: OCR ran the reference range and the ×10⁹/L unit together
        // with no space (`0.12~1.2010~9/L`). Before the fix, the greedy decimal
        // regex read the unit's leading "10" as extra fraction digits (refHigh
        // 1.201 instead of 1.20) and the unit lost its "10" prefix (`~9/L`).
        let text = "4   单核细胞数            0.10↓  0.12~1.2010~9/L    15  红细胞平均体积*       86.5   80~100    fL\n";
        let obs = extract_labs(text);
        let mono = find(&obs, "mono_count");
        assert_eq!(mono.value_num, 0.10);
        assert_eq!(mono.ref_low, Some(0.12));
        assert_eq!(mono.ref_high, Some(1.20));
        assert_eq!(mono.unit_raw.as_deref(), Some("10~9/L"));
        assert_eq!(mono.flag.as_deref(), Some("L"));
    }

    #[test]
    fn already_spaced_cbc_unit_is_unaffected() {
        // Counter-example / idempotency: the common case where OCR keeps a space
        // before the ×10⁹/L unit must parse exactly as before the fix.
        let text = "白细胞*             4.50   4.0~10.0 10~9/L\n";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        let wbc = &obs[0];
        assert_eq!(wbc.value_num, 4.5);
        assert_eq!(wbc.ref_low, Some(4.0));
        assert_eq!(wbc.ref_high, Some(10.0));
        assert_eq!(wbc.unit_raw.as_deref(), Some("10~9/L"));
    }

    #[test]
    fn name_glued_directly_to_value_is_split_correctly() {
        // Real repro (涟水县中医院血常规 OCR, PP-OCR + column split): the analyte
        // name and its result have NO separator at all — `含量*26.3`. Before the
        // fix, row_re's non-greedy name couldn't stop there (no separator to
        // anchor on), so it kept growing past the glued `26.3` and picked the
        // reference range's low bound (`27`) as the "value" instead — 26.3 is
        // actually LOW (flag ↓) but 27.0 reads as within-range, silently
        // inverting the abnormal flag the patient would see.
        let text = "16                                                红细胞平均血红蛋白含量*26.3↓      27~34    pg\n";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        let mch = &obs[0];
        assert_eq!(
            mch.value_num, 26.3,
            "must read the glued value, not the ref low bound"
        );
        assert_eq!(mch.ref_low, Some(27.0));
        assert_eq!(mch.ref_high, Some(34.0));
        assert_eq!(mch.unit_raw.as_deref(), Some("pg"));
        assert_eq!(mch.flag.as_deref(), Some("L"));
    }

    #[test]
    fn name_glued_to_value_without_a_flag_marker_still_splits() {
        // Same glue shape (`浓度*305.0`) but nothing between the glued value and
        // the reference range's `↓` this time comes right after the value with
        // no space either, and the range itself uses a full-width `～`. Real
        // repro from the same report — this row didn't extract AT ALL before
        // the fix (every number on the line was glued to something with no
        // separator, so row_re never found a valid split anywhere).
        let text = "17                                                红细胞平均血红蛋白浓度*305.0↓320～360       g/L\n";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        let mchc = &obs[0];
        assert_eq!(mchc.value_num, 305.0);
        assert_eq!(mchc.ref_low, Some(320.0));
        assert_eq!(mchc.ref_high, Some(360.0));
        assert_eq!(mchc.flag.as_deref(), Some("L"));
    }

    #[test]
    fn value_glued_directly_to_reference_range_is_marked_unreadable_not_guessed() {
        // Real repro, same report: the result and the reference range's low
        // bound are glued together with no separator at all — `2.353.5~5.5` is
        // literally `2.35` (result) + `3.5~5.5` (range) printed back to back.
        // Unlike the name/value glue above, this has NO reliable split point:
        // `2.35|3.5`, `2.3|53.5`, and `2|.353.5` are all syntactically valid
        // numbers. Before the fix this silently produced value_num=2.353 and
        // ref_low=5.0 (nonsense, and 2.35 vs the true range 3.5~5.5 is LOW,
        // not the "L" the old code happened to compute from bad numbers by
        // coincidence). Per "宁可漏,不能编" this row must never be guessed —
        // but per the later UX call ("mark, don't discard"), it must also not
        // vanish silently: it's surfaced as an UnreadableRow for the user to
        // check against the original document.
        let text = "12红细胞*                                                            2.353.5~5.5      10^12/L\n";
        // Old, stable signature: still never yields a (possibly wrong) observation.
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 0, "must not guess a value, got {:?}", obs);
        // New signature: the row is kept, verbatim, with a plain-language reason.
        let (obs2, unreadable) = extract_labs_with_unreadable(text);
        assert_eq!(obs2.len(), 0);
        assert_eq!(unreadable.len(), 1, "got {:?}", unreadable);
        assert_eq!(unreadable[0].raw_line, text.trim_end_matches('\n'));
        assert_eq!(
            unreadable[0].reason,
            "数值和参考范围粘在一起,读不准,请核对原件"
        );
    }

    #[test]
    fn value_glued_to_range_without_a_flag_marker_is_also_marked_unreadable() {
        // Same ambiguous-glue shape, no arrow this time: `0.2910.108~0.282` is
        // `0.291` (result) + `0.108~0.282` (range) with zero separator. Before
        // the fix this produced ref_low=108.0 (a plain reference-range digit
        // run misread as 108, off by 3 orders of magnitude) — now surfaced as
        // unreadable instead of guessed or silently dropped.
        let text = "21                                                血小板压积           0.2910.108~0.282\n";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 0, "must not guess a value, got {:?}", obs);
        let (obs2, unreadable) = extract_labs_with_unreadable(text);
        assert_eq!(obs2.len(), 0);
        assert_eq!(unreadable.len(), 1, "got {:?}", unreadable);
        assert_eq!(unreadable[0].raw_line, text.trim_end_matches('\n'));
        assert_eq!(
            unreadable[0].reason,
            "数值和参考范围粘在一起,读不准,请核对原件"
        );
    }

    #[test]
    fn multiple_glue_candidates_on_one_line_are_marked_unreadable_not_picked() {
        // Two independent name/value glue points on the same line — no basis to
        // prefer one boundary over the other, so the row is surfaced as
        // unreadable rather than arbitrarily picking the first (or last) match.
        let text = "指标甲*12.3  单位乙*45.6  mg/L";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 0, "got {:?}", obs);
        let (obs2, unreadable) = extract_labs_with_unreadable(text);
        assert_eq!(obs2.len(), 0);
        assert_eq!(unreadable.len(), 1, "got {:?}", unreadable);
        assert_eq!(unreadable[0].raw_line, text);
        assert_eq!(
            unreadable[0].reason,
            "这一行有多处数字和名称粘在一起,分不清对应关系,读不准,请核对原件"
        );
    }

    #[test]
    fn normal_rows_never_end_up_in_unreadable() {
        // Counter-example: ordinary, unambiguous rows must produce zero
        // unreadable entries — the new tracking must not over-fire on clean data.
        let text = "\
肌酐            88      μmol/L      59-104
低密度脂蛋白胆固醇  3.6  mmol/L  <3.4  ↑
";
        let (obs, unreadable) = extract_labs_with_unreadable(text);
        assert_eq!(obs.len(), 2, "got {:?}", obs);
        assert!(
            unreadable.is_empty(),
            "clean rows must not be marked unreadable, got {:?}",
            unreadable
        );
    }

    #[test]
    fn extract_labs_signature_and_behavior_are_unchanged() {
        // aggregate.rs depends on this exact signature/behavior — the new
        // tracking must be purely additive, never surfacing unreadable rows
        // through the old function.
        let text = "\
肌酐            88      μmol/L      59-104
12红细胞*                                                            2.353.5~5.5      10^12/L
";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        assert_eq!(obs[0].raw_name, "肌酐");
    }

    #[test]
    fn glued_cjk_digit_without_lab_evidence_is_still_skipped() {
        // Counter-example: a CJK-char-immediately-followed-by-digit shape that
        // ISN'T a lab row at all (no unit, no range, no flag, no terminology
        // match) must still be rejected by the existing evidence gate — the
        // glue fix only changes where the name/value boundary is drawn, never
        // bypasses the "is this actually a lab row" gate.
        let obs = extract_labs("结节3处未见明显异常灶");
        assert_eq!(obs.len(), 0, "got {:?}", obs);
    }

    #[test]
    fn already_separated_rows_are_unaffected_by_the_glue_fix() {
        // Counter-example: ordinary, already-well-separated rows (name, real
        // whitespace, value, unit, range) must parse exactly as before — the
        // glue-detection regex requires a CJK char or `*` directly touching a
        // digit, which none of these have.
        let text = "\
肌酐            88      μmol/L      59-104
低密度脂蛋白胆固醇  3.6  mmol/L  <3.4  ↑
";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 2, "got {:?}", obs);
        let cr = find(&obs, "creatinine");
        assert_eq!(cr.value_num, 88.0);
        assert_eq!(cr.ref_low, Some(59.0));
        assert_eq!(cr.ref_high, Some(104.0));
        let ldl = find(&obs, "ldl");
        assert_eq!(ldl.value_num, 3.6);
        assert_eq!(ldl.ref_high, Some(3.4));
        assert_eq!(ldl.flag.as_deref(), Some("H"));
    }

    #[test]
    fn header_and_section_lines_are_skipped() {
        let text = "\
生化检验报告单
姓名:张三  性别:男  年龄:60
项目            结果    单位        参考范围
谷丙转氨酶(ALT)  45     U/L         0-40    ↑
空腹血糖        6.9     mmol/L      3.9-6.1
";
        let obs = extract_labs(text);
        // Only the two real data rows survive; header/section/demographics gone.
        assert_eq!(obs.len(), 2, "got {:?}", obs);
        assert!(obs.iter().all(|o| o.raw_name != "项目"));
        assert!(obs.iter().all(|o| o.raw_name != "年龄"));
        let alt = find(&obs, "alt");
        assert_eq!(alt.value_num, 45.0);
        assert_eq!(alt.flag.as_deref(), Some("H")); // explicit ↑
        let glu = find(&obs, "glucose");
        assert_eq!(glu.value_num, 6.9);
        assert_eq!(glu.flag.as_deref(), Some("H")); // 6.9 > 6.1, computed
    }
}
