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
//! ## Wrapped rows (name on one line, its result on the next)
//! Clean text layers keep a row on one line, and for years that made strict
//! line-by-line parsing the right call. Photographs don't: PP-OCR emits one
//! detection box per column block, so a report can come out with the whole
//! 项目 column on one line and the 结果/单位/参考范围 columns on the next
//! (real corpus, 北京协和 biochemistry sheet — 8 analytes, zero extracted,
//! with not a single character mis-read).
//!
//! Joining lines is the most dangerous thing in this module: a wrong join
//! invents a lab value that appears nowhere in the document. So the join is
//! gated on *both* lines having an unmistakable shape and on the result being
//! corroborated — see `merged_wrap_row` for the full list of conditions and,
//! more importantly, for when we deliberately refuse to join.
//!
//! ## Row number glued to the name (`12红细胞计数`)
//! The printed row number from a Chinese lab sheet's leftmost column is
//! sometimes fused onto the analyte name by OCR. The name itself is spelled
//! correctly — only the exact-match lookup fails — so `strip_serial_prefix`
//! peels the leading digits off and retries as a fallback (never a rewrite:
//! `raw_name` always stays verbatim, and a name that resolves as printed is
//! never touched — see that function's doc).
//!
//! This fallback is trusted for **bare `name value` lines only** — nothing
//! else on the line for OCR to have bled in from a neighbouring column. Real
//! corpus (扫描版, 苏州独墅湖 血常规 photos) shows why: on a two-column sheet,
//! the "rest" after the value is exactly where a stray unit or reference-range
//! fragment from the RIGHT-hand column shows up glued onto a LEFT-hand
//! column's row. One photo's `13血红蛋白` line carries no value of its own on
//! that line at all — HGB's real result (122) is one line down — but the line
//! still parses as `name value rest` because a neighbouring column's stray
//! unit token (`1012/`) landed in the "rest" slot; without this restriction,
//! stripping the row number resolves the name to `hgb` and charts a
//! **fabricated `hgb ≈ 4`** (the row's incidental numeral, not the LOINC-coded
//! measurement) right next to the real trend line. Sampling every serial-prefix
//! candidate across the real photo corpus: every bare-pair case checked out
//! correct; every case with an attached unit/range was inconsistent with the
//! resolved analyte at least once. Per "宁可漏,不能编", the fallback is
//! restricted to the shape it can actually vouch for, at the cost of a few
//! recoveries (`9单核细胞百分比 12.70 3.50~10.00%`, correct on this document)
//! that a name+value+rest line cannot be told apart from the fabricating one.
//!
//! ## A row with no result of its own (`13血红蛋白  4.00~5.50`)
//! The result column is found by POSITION — first number after the name — and
//! a reference range's low bound sits in exactly that position when the result
//! cell is empty or its text landed on another line. Splitting the range token
//! in half then reports the bound as the measurement, and because a bound is
//! by construction a sensible number for that analyte, the fabricated point is
//! invisible on a chart. `value_is_range_low_bound` catches it (a range
//! operator directly abutting the value) and the row is refused, not guessed.
//!
//! ## Deliberately NOT handled (kept lean)
//! - Ratio-style results printed as one token (`血压 120/80`) — the `/80` is
//!   mistaken for a unit; blood pressure is a vital, out of scope here.
//! - Wrapped rows whose analyte is NOT in the dictionary: the join needs
//!   corroboration and an unknown name provides none, so those stay dropped.
//! - Wraps spanning 3+ lines, and value-above-name wraps — neither is observed
//!   in the corpus, and each extra degree of freedom multiplies the ways a join
//!   can fabricate a row.
//! - A row-number-glued name is only recovered when the line is otherwise
//!   bare — see "Row number glued to the name" above.
//!
//! ## 参考区间也换算(2026-08-05,推翻本模块此前一条既定决定)
//!
//! **旧决定(此处逐字保留,不是删掉):**「Reference ranges are parsed/stored in
//! the RAW reporting unit only; the struct has no canonical-ref fields, so refs
//! are compared against the raw value (same unit) for flagging and left
//! un-converted.」
//!
//! 旧决定在本模块内部是自洽的(flag 用印刷值比印刷区间,同单位,永远对),但它
//! 把一个**半截状态**交给了下游:`value_canonical` 换过、`ref_low`/`ref_high`
//! 没换。凡是「拿值和区间比」的下游都会算错 —— 实测 `肌酐: 1.2 mg/dL (参考
//! 0.6-1.3)`,`value_canonical = 106.104 umol/L` 配 `ref = [0.6, 1.3] mg/dL`,
//! 托管查看器(`web/hosted-viewer/index.html` 的 `sumFlag`)据此算出「高出上限
//! 80 倍」,而同一份载荷里 `warn: false`,自相矛盾。
//!
//! **新契约:值和区间必须成对、同单位,一共两套,各自内部自洽,永不交叉。**
//!
//! | 套 | 值 | 单位 | 区间 |
//! |---|---|---|---|
//! | 印刷(paper) | `value_num` | `unit_raw` | `ref_low` / `ref_high` |
//! | 规范(canonical,锚) | `value_canonical` | `unit_canonical` | `ref_low_canonical` / `ref_high_canonical` |
//!
//! 两套用**同一个**仿射映射 `y = slope * x + intercept` 生成(值和两个界值走同一
//! 行 `UnitConversion`),所以要么两套都有、要么规范那套整体为 `None`,不存在
//! 「值换了区间没换」。词典里全部 `slope > 0`(见
//! `dictionary_slopes_are_all_positive` 测试),仿射严格单调递增 ⇒ low/high 不需
//! 互换,且 `flag` 在两套单位下**可证明相同**(见
//! `flag_is_identical_under_canonical_conversion`)。`slope <= 0` 时本模块拒绝换
//! 算(规范那套整体留空),而不是产出一个上下颠倒的区间。
//!
//! 「哪一层显示哪一套」不由本模块决定 —— 本模块只保证两套都在、都自洽。选哪一套
//! 显示是 `aggregate.rs` 的职责(见那里的「哪一层用哪一套单位」表)。

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
    /// 参考区间,**印刷单位**(`unit_raw`)—— 报告上逐字印的那一对。
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    /// 参考区间,**规范单位**(`unit_canonical`)。与 `value_canonical` 用同一行
    /// `UnitConversion`、同一个仿射映射生成,故三者恒同单位;换算不可用时三者
    /// 一起为 `None`。见模块头「参考区间也换算」一节。
    pub ref_low_canonical: Option<f64>,
    pub ref_high_canonical: Option<f64>,
    /// "H" | "L" | "N": explicit ↑/↓/H/L marker if present, else value-vs-ref.
    ///
    /// 用**印刷值比印刷区间**算(同单位)。因换算是严格单调递增的仿射映射,拿
    /// `value_canonical` 比 `ref_*_canonical` 得到的结论完全相同 —— 两套单位下
    /// flag 唯一,不需要也不该有第二个 flag 字段。
    pub flag: Option<String>,
    /// 0.0 if unmatched; else the terminology `Match.confidence`.
    pub confidence: f32,
    /// Always `false` here — this extractor only ever reads OCR'd report text.
    /// `true` is set exclusively by `aggregate()`'s self-measurement branch
    /// (`self_entry::parse_self_measurement_payload`), which builds
    /// `LabObservation`s directly rather than through this function. Carried on
    /// the struct (not a separate parallel type) so `aggregate()`'s per-document
    /// dispatch can treat both sources uniformly — see `aggregate.rs`'s
    /// `GroupKey::SelfMeasured` for why this field, not `analyte_key`, decides
    /// grouping.
    pub self_measured: bool,
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
///
/// The value sub-pattern accepts EITHER `.` or `,` as the decimal separator,
/// exactly like the reference-range patterns below, and is parsed through the
/// same [`parse_decimal_token`]. It used to be dot-only while the ranges were
/// not, and that asymmetry is a value-fabricating bug, not a cosmetic gap: on
/// `肌钙蛋白I 0,08 ng/mL 0-0.04` the dot-only group could not consume the `,`,
/// so it stopped at the leading `0` and reported **troponin I = 0, flag N** for
/// a result that is twice its own cutoff. The truncated head is always a
/// physiologically plausible number, so nothing downstream can notice it — the
/// same silent-failure shape the range patterns were fixed for one commit
/// earlier. See [`parse_decimal_token`] for why a `,` between digits is a
/// misread period rather than a thousands grouping.
fn row_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"^\s*(?P<name>.*?)[\s:：]+(?P<value>-?\d+(?:[.,]\d+)?)(?P<sep2>\s*)(?P<rest>.*)$",
        )
        .expect("row re")
    })
}

// Reference-range regexes match ANYWHERE in the trailing columns (not anchored),
// and tolerate spaces around the comparator/dash. 真 corpus 把参考写成带空格的
// `< 5.20`、`> 90`、`3.9 - 6.1` —— 逐 token 分类会把 `<` 和 `5.20` 拆成两个各自作废
// 的 token,单边参考(LDL/TC/eGFR)与带空格的双边参考就全丢了(quality dim 4/5)。
//
// The number sub-pattern `\d+(?:[.,]\d+)?` accepts EITHER `.` or `,` as the
// decimal separator — see `parse_decimal_token` for why `,` is folded to a
// decimal point unconditionally rather than treated as a thousands grouping.
// Being unanchored, an earlier version of this pattern (dot-only) had no
// notion of where a numeral starts or ends, so on a malformed token it would
// silently match the TAIL of a number instead of the whole thing: with the
// old dot-only pattern, `12,5~20` (comma is OCR's misread decimal point) had
// no way to consume the `,`, so the match started only at `5` — reading the
// range as `5~20` and dropping the `12,` prefix entirely, with no error and
// no implausible result to notice. Two independent fixes close this:
// (1) the number pattern now consumes a single comma-decimal group itself,
// so `12,5` is read whole in the first place; (2) `range_is_bounded` rejects
// any match that still sits directly against a digit or `.` outside the
// match (a genuinely malformed/glued numeral this pattern can't make sense
// of), so a same-shaped failure in some other punctuation combination fails
// loud (row dropped) rather than fabricating a plausible-looking half value.
//
// The separator itself is `[-~]+` — ONE OR MORE dash/tilde chars, not exactly
// one. Real corpus (`9.4--12.5`, `21--37`, `0--252`, MedRepBench ground truth,
// sampled 618 occurrences of the exact `<num>--<num>` shape across the corpus'
// source annotations) prints a doubled hyphen where a single en/em dash was
// meant — every single one of those 618 has `low <= high` under the plain
// "doubled separator" reading, zero under-support the alternative reading
// "second number's own leading `-` is a minus sign" (which would make the
// bound negative for exactly the same physiologically non-negative analytes —
// PT/APTT seconds, bilirubin, D-dimer, TSH — that never legitimately go
// negative). A single `-` still matches (the `+` is satisfied by one
// repetition), so this only WIDENS what's accepted; it never changes how an
// already-matching single-dash range reads.
fn range_two_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(\d+(?:[.,]\d+)?)\s*[-~]+\s*(\d+(?:[.,]\d+)?)").expect("range re")
    })
}
fn range_high_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[<≤]=?\s*(\d+(?:[.,]\d+)?)").expect("high re"))
}
fn range_low_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[>≥]=?\s*(\d+(?:[.,]\d+)?)").expect("low re"))
}
/// The TAIL of a two-sided range — the operator plus the high bound — anchored
/// at the start of whatever follows the result. Same number sub-pattern as the
/// range regexes above, and the same `+` on the separator as `range_two_re`
/// (a value bound into a doubled-dash range, e.g. `13血红蛋白  4.00--5.50`, is
/// the same shape one dash shorter). Used by `value_is_range_low_bound`.
fn range_tail_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^[-~]+\s*(\d+(?:[.,]\d+)?)").expect("range tail re"))
}

/// True when neither the char immediately before `start` nor the char
/// immediately after `end` in `s` is a digit or `.` — i.e. the match at
/// `[start, end)` is not the truncated head/tail of a longer numeral the
/// pattern didn't fully consume. `,` is deliberately NOT in this forbidden
/// set: it's already folded into the number by the regex itself (see
/// `range_two_re` doc), so a `,` can only appear at a match boundary when
/// it's a SECOND, un-consumed comma group (e.g. a genuine `1,234,567`
/// thousands chain) — real corpus (11/11 digit-comma-digit occurrences
/// sampled from actual OCR'd reports, `labaudit/ocr-dump/*.txt`) never does
/// that, so there's nothing to defend against there.
fn range_is_bounded(s: &str, start: usize, end: usize) -> bool {
    let breaks_numeral = |c: char| c.is_ascii_digit() || c == '.';
    let before_ok = !s[..start].chars().next_back().is_some_and(breaks_numeral);
    let after_ok = !s[end..].chars().next().is_some_and(breaks_numeral);
    before_ok && after_ok
}

/// Parse a captured number token (`5.20` or a comma-decimal `5,20`) into an
/// `f64`. Used for BOTH the result column (`row_re`'s `value` group) and the
/// reference-range bounds, so the two cannot drift apart again: the rule below
/// is a property of the document, not of one column, and applying it to only
/// one of them is what let `0,08` be read as `0`.
///
/// Chinese lab reports print decimals with `.` only; a `,`
/// between digits is PP-OCR misreading a period, never a thousands
/// separator — the domain's values are already SI-scaled (platelet counts
/// read e.g. `171`, not `150,000`), and a sample of every digit-comma-digit
/// token across the project's real OCR corpus
/// (`labaudit/ocr-dump/*.txt`, 11 occurrences across 6 independent reports)
/// found 1–2 digits after the comma in every case, zero instances of the
/// 3-digit shape a thousands grouping would need — so there is no live
/// ambiguity to hedge against. This mirrors `normalize_ocr_decimal_comma` in
/// the `ocr` crate exactly (same rule, unconditional comma→period), which
/// text-layer/`.txt` input never passes through — this parser has no
/// dependency on `ocr`, so it has to make the same call itself here rather
/// than rely on that normalization having already happened upstream.
fn parse_decimal_token(raw: &str) -> Option<f64> {
    if raw.contains(',') {
        raw.replace(',', ".").parse().ok()
    } else {
        raw.parse().ok()
    }
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
/// other direction, handled separately by `strip_serial_prefix`).
fn glued_name_value_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"[\u{4e00}-\u{9fa5}*](\d+(?:\.\d+)?)").expect("glued name-value re")
    })
}

/// The OTHER glue direction: the printed row number from the leftmost column of
/// a Chinese lab sheet, fused onto the analyte name (`12红细胞计数`,
/// `1白细胞计数`). Anchored at the start, 1–2 digits (sheets number rows 1..99),
/// and the digits must be followed by a CJK ideograph — which is what separates
/// a row number from a name that legitimately *begins* with digits
/// (`25羟基维生素D`, `13C尿素呼气试验`, `24小时尿蛋白定量`: the char after the
/// digits is Latin, or the whole name is a dictionary alias that resolves before
/// this is ever consulted).
///
/// Only the glued form needs this. When the sheet prints a space
/// (`2  中性粒细胞计数`), `terminology::term_candidates` already splits on
/// whitespace and the name resolves on its own.
fn serial_prefix_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^\d{1,2}(?P<name>[\u{4e00}-\u{9fa5}].*)$").expect("serial re"))
}

/// A whitespace-delimited token that is nothing but a number — the shape of a
/// bare result cell. Used by the wrapped-row detector to tell a line that
/// carries its own value from one that doesn't.
fn bare_number_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^-?\d+(?:\.\d+)?$").expect("bare number re"))
}

/// Drop a leading printed row number from an analyte name — see
/// `serial_prefix_re`. `None` when there is no row-number prefix, or when
/// removing it would leave too little to identify (a single character resolves
/// far too eagerly against the dictionary's short aliases).
///
/// Callers must try the UNSTRIPPED name first: this is a fallback, never a
/// rewrite, so a name that already resolves can never be changed by it. And
/// per the module doc ("Row number glued to the name"), callers must only
/// trust the fallback match for a bare `name value` line — see `parse_line`.
fn strip_serial_prefix(raw_name: &str) -> Option<&str> {
    let name = serial_prefix_re()
        .captures(raw_name)?
        .name("name")?
        .as_str();
    (name.chars().count() >= 2).then_some(name)
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
    // Same letterhead family, seen in the photo corpus but not in the clean
    // PDFs the original list was built from.
    "打印时间",
    "接收时间",
    "检验时间",
    "登记时间",
];

/// The COLUMN LABELS of the result table itself (`检验项目 结果 参考范围 单位`),
/// plus the report's own title line. Different from `PAGE_FURNITURE` in origin,
/// identical in consequence: on a photograph the header band is split across
/// detection boxes and lands in the text stream next to a stray number from a
/// neighbouring column, so `row_re` reads e.g. `参考范围 单位 检验项目` as an
/// analyte with value 42, or the title line as an analyte with value 2016. The
/// viewer then draws that as a trend line beside a real one — the same
/// fabricated-chart failure `PAGE_FURNITURE` exists to prevent.
///
/// Substring-matched, and therefore restricted to words that cannot occur
/// inside a measured quantity's name. Column labels that are too short or too
/// generic to match as a substring safely (`结果`, `单位`) are deliberately
/// absent: every header line in the corpus already carries one of the words
/// below, so the extra reach buys nothing and only risks a real analyte.
const TABLE_HEADER: &[&str] = &[
    "检验项目",
    "检测项目",
    "项目名称",
    "项目缩写",
    "参考范围",
    "参考值",
    "报告单",
    "标本状态",
];

/// Header labels that must match a WHOLE whitespace-delimited token, never a
/// substring. `No`(=编号, as in `No:20160824XXS0025`) is the only one so far:
/// as a substring it would swallow anything containing those two letters, and
/// even as a token it is case-sensitive so the nitric-oxide abbreviation `NO`
/// stays untouched.
const HEADER_TOKENS: &[&str] = &["No"];

/// True when a parsed "analyte name" is really letterhead, specimen-block, or
/// result-table-header text. See `PAGE_FURNITURE` / `TABLE_HEADER`.
fn is_page_furniture(raw_name: &str) -> bool {
    PAGE_FURNITURE.iter().any(|w| raw_name.contains(w))
        || TABLE_HEADER.iter().any(|w| raw_name.contains(w))
        || raw_name
            .split_whitespace()
            .any(|t| HEADER_TOKENS.contains(&t))
}

const REASON_VALUE_GLUED_TO_RANGE: &str = "数值和参考范围粘在一起,读不准,请核对原件";
const REASON_MULTIPLE_GLUE_POINTS: &str =
    "这一行有多处数字和名称粘在一起,分不清对应关系,读不准,请核对原件";
/// See `value_is_range_low_bound`: the line has a name and a reference range but
/// no result of its own.
const REASON_NO_RESULT_ONLY_RANGE: &str = "这一行只有参考范围,没有结果值,请核对原件";

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

/// True when a range operator sits immediately after the value — i.e. the
/// number `row_re` picked as the RESULT is really the LOW BOUND of a printed
/// reference range, and this line carries no result of its own.
///
/// `row_re` identifies the result column by POSITION: first number after the
/// name. A reference range is two numbers joined by `-`/`~`, and its low bound
/// occupies exactly that position whenever the result cell is empty or its
/// text landed elsewhere — which is routine on a photographed two-column sheet.
/// Nothing in the parser said "a number bound into a range is not a result", so
/// it happily split the range token in half:
///
/// ```text
/// 13血红蛋白  4.00~5.50   → hgb = 4.0 g/L   (a lethal value, charted as a
///                            clean historical point next to the real trend)
/// 淋巴细胞计数 1.00~3.30   → lymph = 1.0
/// 钾 3.5-5.3              → potassium = 3.5
/// ```
///
/// The fabrication is undetectable by inspection because a reference range's
/// low bound is, by construction, always a physiologically sensible number for
/// that analyte. Per 宁可漏,不能编 the whole row goes out (surfaced as an
/// [`UnreadableRow`] when it otherwise looked like a real lab row, so a person
/// can check the original) rather than reporting the bound as a measurement.
///
/// Two conditions, both necessary:
///
/// 1. **A range operator directly abuts the value.** That is what shows the
///    value was bound INTO the range rather than standing on its own, and it is
///    what separates this from the ordinary row where a genuine result is
///    separated from its range (`血红蛋白 122  4.00~5.50` → `rest` starts with a
///    digit → a real reading, kept). `row_re`'s `sep2` has already absorbed the
///    whitespace, so `rest` begins at the first non-space character and the
///    spaced form `3.9 - 6.1` is caught the same way as the glued `4.00~5.50`.
///
/// 2. **The pair reads as a well-formed range** — `value <= high`. A genuine
///    reference range never inverts (the same invariant `parse_line` already
///    uses to discard a misread `low > high` pair), so if it does invert, the
///    operator is not binding the value into a range and the value stands.
///
/// Condition 2 is not a hedge, it is what keeps a real corpus row readable:
/// an analyte with no unit prints an empty unit cell as a `-` placeholder, so
/// `INR 国际标准化比值 1.05 - 0.8 - 1.2 正常` (华山医院 术前凝血, verbatim) puts
/// an operator right after a perfectly good result. Reading `1.05` as a low
/// bound would make the range `1.05–0.8`, which is impossible; the real range
/// `0.8 - 1.2` follows, and both are parsed correctly today. Condition 1 alone
/// threw this row away.
///
/// Known gap this leaves open: when OCR misreads a decimal point as a dash
/// (`38.3` → `38-3`, seen once in the corpus), the pair inverts, so the row is
/// kept and the value reads `38`. That is the pre-existing behaviour and it is
/// still wrong, but `-` between digits is a genuine range operator in this
/// domain — unlike `,`, there is no elimination argument that makes the misread
/// reading the only possible one, so it is not fixed here by guessing.
fn value_is_range_low_bound(value_num: f64, rest: &str) -> bool {
    let folded = fold_range_punct(rest);
    let Some(caps) = range_tail_re().captures(&folded) else {
        return false;
    };
    parse_decimal_token(caps.get(1).expect("high group").as_str())
        .is_some_and(|high| value_num <= high)
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
///
/// Each regex is scanned with `captures_iter`, not a single `captures` call,
/// skipping over any match `range_is_bounded` rejects rather than stopping at
/// the first (possibly truncated) one — see that function's doc. This does
/// NOT run into the "boundary consumes a char, so the next match's own
/// left-boundary check has nothing to consume" trap that a lookbehind
/// work-around by consuming a prefix character would: the boundary check
/// only PEEKS at the neighbouring char via string indexing, it never
/// consumes it, so two ranges sitting back-to-back on one line (a real shape
/// — see `glued_cbc_unit_does_not_inflate_ref_high_or_truncate_unit`, which
/// has a second row's range trailing in the same `rest`) are found
/// independently, in the same left-to-right order as before.
fn find_range(folded: &str) -> Option<RangeMatch> {
    for c in range_two_re().captures_iter(folded) {
        let m = c.get(0).expect("group 0 always present");
        if !range_is_bounded(folded, m.start(), m.end()) {
            continue;
        }
        let lo = parse_decimal_token(c.get(1)?.as_str());
        let hi = parse_decimal_token(c.get(2)?.as_str());
        return Some((lo, hi, (m.start(), m.end())));
    }
    for c in range_high_re().captures_iter(folded) {
        let m = c.get(0).expect("group 0 always present");
        if !range_is_bounded(folded, m.start(), m.end()) {
            continue;
        }
        let hi = parse_decimal_token(c.get(1)?.as_str());
        return Some((None, hi, (m.start(), m.end())));
    }
    for c in range_low_re().captures_iter(folded) {
        let m = c.get(0).expect("group 0 always present");
        if !range_is_bounded(folded, m.start(), m.end()) {
            continue;
        }
        let lo = parse_decimal_token(c.get(1)?.as_str());
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
        //
        // Normalized, so a full-width `Ｈ` or a lowercase `h` reads the same as
        // `H` — Chinese printouts use all three for the same column.
        //
        // The vocabulary stays limited to **flag-column** tokens on purpose.
        // `升高` / `降低` / `减低` were tried here, on the grounds that the JS and
        // Dart renderers accept them; measurement said otherwise. In reports
        // those words are prose, not a column, and an explicit marker overrides
        // the range-derived flag — so `白蛋白 42 g/L 40-55 无 降低` came out `L`
        // and `血红蛋白 140 g/L 130-175 未见 减低` came out `L`, i.e. the parser
        // asserting the opposite of what the report says, on values sitting
        // inside their own reference range. The renderers do have those words,
        // via substring regex, and therefore have the same false positive:
        // matching them here would have been copying a bug, not fixing a gap.
        // Case-SENSITIVE on purpose: the full-width `Ｈ`/`Ｌ` are the same column
        // as `H`/`L`, but the lowercase letters are not — `h` and `l` are unit
        // fragments. Folding case turned `血沉 15 mm / h 0-20` into a high flag
        // and `血钾 4.1 mmol / l 3.5-5.3` into a low one, both on values inside
        // their printed range, whenever OCR put spaces around the slash.
        if raw.contains('↑') || matches!(tok, "H" | "Ｈ" | "高" | "偏高") {
            flag = Some("H".to_string());
            continue;
        }
        if raw.contains('↓') || matches!(tok, "L" | "Ｌ" | "低" | "偏低") {
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
    let lines: Vec<&str> = text.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let outcome = parse_line(lines[i]);
        // A line that yielded nothing may be the NAME half of a row whose
        // result columns wrapped onto the next line. Only ever attempted here,
        // i.e. after the line has failed on its own, so joining can never take
        // away a row the strict line-by-line reading already produced.
        if matches!(outcome, LineOutcome::Nothing) && i + 1 < lines.len() {
            if let Some(row) = merged_wrap_row(lines[i], lines[i + 1]) {
                out.push(row);
                i += 2;
                continue;
            }
        }
        match outcome {
            LineOutcome::Row(mut o) => {
                // The row parsed cleanly but with NO reference range at all —
                // try completing it from a range that wrapped onto the next
                // line (see `complete_wrapped_range`). Only attempted when
                // `parse_rest` found neither bound, so this can only ADD a
                // range, never override one already read with confidence.
                if o.ref_low.is_none()
                    && o.ref_high.is_none()
                    && complete_wrapped_range(&mut o, lines[i], lines.get(i + 1).copied())
                {
                    out.push(o);
                    i += 2;
                    continue;
                }
                out.push(o);
            }
            LineOutcome::Unreadable(u) => unreadable.push(u),
            LineOutcome::Nothing => {}
        }
        i += 1;
    }
    (out, unreadable)
}

/// A reference range's low bound trails a line with a dangling separator
/// (`0.85-`) and nothing after it — evidence the layout reconstruction wrapped
/// the line before the high bound could print, not that the range is simply
/// absent. Read straight off the RAW line (not `rest`): `rest` is just its
/// trailing substring, so the text at the very end is identical either way.
fn dangling_range_low_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d+(?:[.,]\d+)?)\s*[-~]+\s*$").expect("dangling range re"))
}

fn dangling_range_low(line: &str) -> Option<f64> {
    let folded = fold_range_punct(line.trim_end());
    let caps = dangling_range_low_re().captures(&folded)?;
    parse_decimal_token(caps.get(1)?.as_str())
}

/// Complete a reference range whose high bound wrapped onto the next physical
/// line — the reference-range twin of "Wrapped rows" (module doc): PP-OCR's
/// line reconstruction breaks a too-wide row wherever it likes, not at a
/// column boundary, and a long `单位 参考范围` tail is exactly wide enough to
/// get cut. Mutates `row` in place and returns whether it consumed
/// `next_line`; `row` is left untouched on `false`.
///
/// Two conditions, both necessary — same discipline as `merged_wrap_row` and
/// for the same reason (a wrong join fabricates a reference range that
/// appears nowhere in the document, worse than leaving the row un-ranged):
///
/// 1. **The current line ends in a dangling low bound** (`dangling_range_low`)
///    — proof this line's range was cut off mid-print, not just absent.
/// 2. **The next line, trimmed, is nothing but a bare number** — after
///    stripping any LEADING `-`/`~` run first, since the doubled-separator
///    typo this module already folds elsewhere (`range_two_re`'s `[-~]+` —
///    see that function's doc, 618 corpus occurrences of `<num>--<num>`,
///    zero genuinely negative) is exactly as likely to land split across the
///    line break as it is to land whole on one line: `0.45-` \n `-1.81` is
///    the same `0.45--1.81` as `0.45--1.81` on one line, just broken between
///    the two dashes. Requiring the WHOLE trimmed line (not just its first
///    token, unlike `is_wrapped_value_line`) to be that one number is what
///    keeps this safe: real corpus shows the unsafe shapes this shape
///    rejects — a stray `H`/`N` flag letter before the number (`H` \n
///    `0.28`), a wrapped analyte-name fragment (`C)` \n `-1.94`), and an
///    unrelated row's own name sitting where the high bound would be
///    (`部分凝血活酶时间` \n `15.90`, a different analyte's row entirely) —
///    joining any of those either invents a bound from noise or steals a
///    different row's line. Left un-ranged (same outcome as today) rather
///    than guessed, per 宁可漏,不能编 — a known, documented gap, not an
///    oversight.
///
/// `low <= high` is required for the same reason `parse_line`'s own
/// low>high check exists: a genuine reference range never inverts, so a pair
/// that doesn't form one isn't a matching pair and the row is left alone.
fn complete_wrapped_range(row: &mut LabObservation, line: &str, next_line: Option<&str>) -> bool {
    let Some(low) = dangling_range_low(line) else {
        return false;
    };
    let Some(next) = next_line else {
        return false;
    };
    let candidate = next.trim().trim_start_matches(['-', '~']);
    if !bare_number_re().is_match(candidate) {
        return false;
    }
    let Some(high) = parse_decimal_token(candidate) else {
        return false;
    };
    if low > high {
        return false;
    }
    row.ref_low = Some(low);
    row.ref_high = Some(high);
    true
}

/// What one line of the report turned into.
///
/// `Row` 明显比另外两个变体大(`LabObservation` 有十几个字段),clippy 的
/// `large_enum_variant` 因此建议 `Box` 起来。这里**不 Box**:这个枚举的生命周期
/// 只有「产出 → 立刻 match 掉」这么长(见 `extract_labs_with_unreadable` 的循环),
/// 从不进集合、不跨线程、不长期持有;为它每行做一次堆分配,是拿真实开销换一个
/// 这里不存在的问题。
#[allow(clippy::large_enum_variant)]
enum LineOutcome {
    /// A readable lab row.
    Row(LabObservation),
    /// Lab-row-shaped but not readable with confidence (see [`UnreadableRow`]).
    Unreadable(UnreadableRow),
    /// Not a lab row (header, prose, blank, demographics …).
    Nothing,
}

/// Join a wrapped row's two halves and parse them as one — or refuse.
///
/// Returns a row only when ALL of the following hold, because a wrong join
/// fabricates a lab value that appears nowhere in the document (strictly worse
/// than dropping the row — see the module's 宁可漏,不能编 rule):
///
/// 1. `name_line` looks like a bare analyte-name cell: it has name characters,
///    carries NO bare number token of its own, and no reference range. A line
///    that already holds a number is a row in its own right, not a dangling
///    name, and pulling the next line's number onto it would attach a result to
///    the wrong analyte.
/// 2. `value_line` looks like a bare result cell: it STARTS with a number and
///    every one of its tokens is result-column material (number, unit, range,
///    flag) — no analyte name anywhere in it.
/// 3. `value_line` carries real lab evidence besides that number (a unit, a
///    range, or a flag). This is the guard that matters most: a lone number on
///    the following line is exactly what a two-COLUMN layout produces when the
///    OCR reading order interleaves columns, and the number then belongs to a
///    different analyte entirely.
/// 4. The joined row RESOLVES to a dictionary analyte. The join is an inference
///    about page layout; a terminology hit is independent corroboration that
///    the text above really was this number's name. Unknown analytes therefore
///    stay dropped when they wrap — the deliberate cost of not guessing.
fn merged_wrap_row(name_line: &str, value_line: &str) -> Option<LabObservation> {
    if !is_wrapped_name_line(name_line) || !is_wrapped_value_line(value_line) {
        return None;
    }
    let joined = format!("{}  {}", name_line.trim_end(), value_line.trim_start());
    match parse_line(&joined) {
        LineOutcome::Row(o) if o.analyte_key.is_some() => Some(o),
        _ => None,
    }
}

/// Condition 1 of [`merged_wrap_row`]: a line holding only an analyte name.
fn is_wrapped_name_line(line: &str) -> bool {
    let t = line.trim();
    if t.is_empty() || !t.chars().any(char::is_alphabetic) {
        return false;
    }
    if t.split_whitespace()
        .any(|tok| bare_number_re().is_match(tok))
    {
        return false;
    }
    if find_range(&fold_range_punct(t)).is_some() {
        return false;
    }
    !is_page_furniture(t)
}

/// Conditions 2+3 of [`merged_wrap_row`]: a line holding only result columns.
fn is_wrapped_value_line(line: &str) -> bool {
    let t = line.trim();
    let mut toks = t.split_whitespace();
    if !toks
        .next()
        .is_some_and(|first| bare_number_re().is_match(first))
    {
        return false;
    }
    let mut has_evidence = false;
    for tok in toks {
        if !is_result_column_token(tok) {
            return false;
        }
        has_evidence = has_evidence || is_lab_evidence_token(tok);
    }
    has_evidence
}

/// A token that can appear in the 结果/单位/参考范围/提示 columns and nowhere
/// else: numbers, units, ranges, comparators, arrows, and the handful of CJK
/// words that are flag-column vocabulary (`parse_rest` already reads exactly
/// these). Anything else — notably any other CJK text — means the line still
/// contains an analyte name and is not a bare result cell.
fn is_result_column_token(tok: &str) -> bool {
    let t = tok.trim_matches(|c| matches!(c, '(' | ')' | '（' | '）' | '[' | ']' | '【' | '】'));
    if t.is_empty() || matches!(t, "高" | "低" | "偏高" | "偏低" | "正常") {
        return true;
    }
    t.chars()
        .all(|c| c.is_ascii_alphanumeric() || RESULT_COLUMN_PUNCT.contains(c))
}

/// Every non-alphanumeric character that legitimately shows up in a result,
/// unit, reference range or flag cell: decimal points and thousands commas,
/// range dashes/tildes (half- and full-width), exponent and multiplication
/// marks, unit slashes and micro signs, comparators, plus/minus, the ↑↓ arrows,
/// and the `|` PP-OCR emits for a printed column rule. Anything outside this
/// set means the token is not result-column material.
const RESULT_COLUMN_PUNCT: &str = ".,-~^*/%<>=°μµ±＜＞≤≥～－—−↑↓|";

/// Condition 3's evidence test: this token is a unit, a range/comparator, or an
/// abnormal-flag marker — i.e. proof the line really is a result row's tail and
/// not a stray number from another column.
fn is_lab_evidence_token(tok: &str) -> bool {
    let t = tok.trim_matches(|c| matches!(c, '(' | ')' | '（' | '）' | '[' | ']' | '【' | '】'));
    if t.contains('↑') || t.contains('↓') || matches!(t, "H" | "Ｈ" | "L" | "Ｌ") {
        return true;
    }
    if matches!(t, "高" | "低" | "偏高" | "偏低") {
        return true;
    }
    if find_range(&fold_range_punct(t)).is_some() {
        return true;
    }
    t.chars()
        .any(|c| c.is_ascii_alphabetic() || c == '%' || c == '/' || c == '°')
}

/// Parse ONE line into at most one lab row. Split out of
/// [`extract_labs_with_unreadable`] so a wrapped pair can be re-parsed as a
/// single joined line through exactly the same rules.
fn parse_line(raw_line: &str) -> LineOutcome {
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
            return LineOutcome::Unreadable(UnreadableRow {
                raw_line: raw_line.to_string(),
                reason: reason.to_string(),
            });
        }
    };
    let Some(caps) = row_re().captures(line) else {
        return LineOutcome::Nothing;
    };
    let name_group = caps.name("name").expect("name group");
    let raw_name = name_group.as_str().trim();
    // Need a real name token — rejects date/number-only lines.
    if raw_name.is_empty() || !raw_name.chars().any(|c| c.is_alphabetic()) {
        return LineOutcome::Nothing;
    }
    // The "value column" (everything from right after the name) is itself a
    // YYYY-MM-DD date — this is a 采集/送检/报告 timestamp row, not a result.
    // See date_value_column_re doc.
    if date_value_column_re().is_match(&line[name_group.end()..]) {
        return LineOutcome::Nothing;
    }
    // A real analyte name has no *sentence* punctuation. This rejects narrative
    // fragments that a mis-routed prose/imaging line would otherwise smuggle in
    // as a "lab" (`右肺上叶尖段磨玻璃结节(GGN),大小约` value 8 …) — quality dim 3.
    if raw_name
        .chars()
        .any(|c| matches!(c, '，' | ',' | '。' | '；' | ';' | '、'))
    {
        return LineOutcome::Nothing;
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
    //
    // The result table's own COLUMN LABELS fail the same way once a photo
    // splits the header band across detection boxes — see `TABLE_HEADER`.
    if is_page_furniture(raw_name) {
        return LineOutcome::Nothing;
    }
    // Same number parser as the reference-range bounds — a comma-decimal
    // result (`0,08`) is read whole instead of truncated to its leading digit.
    // See `parse_decimal_token` / `row_re`.
    let Some(value_num) = parse_decimal_token(caps.name("value").expect("value group").as_str())
    else {
        return LineOutcome::Nothing;
    };
    let rest = caps.name("rest").expect("rest group").as_str();
    // Value glued with zero separator straight into another number (its
    // own reference range's low bound, typically) — no reliable split
    // point exists (see value_glued_to_next_number doc). Surface it as
    // unreadable rather than report a value we can't actually justify.
    let sep2_is_empty = caps.name("sep2").expect("sep2 group").as_str().is_empty();
    if value_glued_to_next_number(sep2_is_empty, rest) {
        return LineOutcome::Unreadable(UnreadableRow {
            raw_line: raw_line.to_string(),
            reason: REASON_VALUE_GLUED_TO_RANGE.to_string(),
        });
    }
    let (unit_raw, ref_low, ref_high, explicit_flag) = parse_rest(rest);
    // Invariant fallback, NOT the fix itself: a genuine reference range
    // never inverts, so low>high can only mean the range was misread
    // somewhere upstream (range_is_bounded / parse_decimal_token above
    // are the actual fix for the known misread shapes — this is a net
    // for whatever shape isn't covered yet). Discard the whole pair
    // rather than pick one bound to trust; the row otherwise still
    // extracts (value/unit/flag), just without a reference range.
    let (ref_low, ref_high) = match (ref_low, ref_high) {
        (Some(lo), Some(hi)) if lo > hi => (None, None),
        other => other,
    };

    // Terminology lookup, then — only if that missed AND the line is a bare
    // `name value` pair — the same lookup with the sheet's printed row number
    // peeled off the front (`12红细胞计数`). Fallback order matters: a name
    // that resolves as printed is never rewritten, so this can add a mapping
    // but never change or remove one.
    //
    // The bare-pair restriction is the module doc's "Row number glued to the
    // name" section: real corpus shows a line that ALSO carries a unit, range
    // or flag cannot be trusted to have that content actually belong to this
    // name — on a two-column sheet it is exactly where a neighbouring
    // column's stray token shows up. Trusting it there turned an (unmapped,
    // harmless) row into a charted one with a fabricated value.
    let is_bare_pair =
        unit_raw.is_none() && ref_low.is_none() && ref_high.is_none() && explicit_flag.is_none();
    let m = resolve(raw_name, unit_raw.as_deref()).or_else(|| {
        is_bare_pair
            .then(|| strip_serial_prefix(raw_name))
            .flatten()
            .and_then(|n| resolve(n, unit_raw.as_deref()))
    });
    // Lab-row gate: some evidence beyond "a name and a number" must exist,
    // else it's demographics/metadata (年龄:60) — skip it.
    let has_evidence = unit_raw.is_some()
        || ref_low.is_some()
        || ref_high.is_some()
        || explicit_flag.is_some()
        || m.is_some();
    if !has_evidence {
        return LineOutcome::Nothing;
    }
    // The number taken as the result is bound into a reference range — this
    // line has a name and a range but no result of its own (see
    // `value_is_range_low_bound`). Checked AFTER the evidence gate on purpose:
    // ordinary prose with a numeric span in it (`随访 3-6 个月复查`) has the
    // same shape and is already thrown away as a non-row, and promoting those
    // to reviewable rows would bury the real ones in noise.
    if value_is_range_low_bound(value_num, rest) {
        return LineOutcome::Unreadable(UnreadableRow {
            raw_line: raw_line.to_string(),
            reason: REASON_NO_RESULT_ONLY_RANGE.to_string(),
        });
    }

    // Canonical conversion (only when matched AND the entry knows this unit).
    // 值和参考区间的两个界值走**同一行** `UnitConversion`、**同一个**仿射映射:
    // 规范那一套要么整体产出、要么整体留空,不存在「值换了区间没换」——
    // 见模块头「参考区间也换算」。
    let mut value_canonical = None;
    let mut unit_canonical = None;
    let mut ref_low_canonical = None;
    let mut ref_high_canonical = None;
    if let (Some(m), Some(u)) = (&m, &unit_raw) {
        if let Some(entry) = dictionary_entries().iter().find(|e| e.key == m.key) {
            let nu = normalize_unit(u);
            if let Some(conv) = entry.units.iter().find(|c| normalize_unit(&c.unit) == nu) {
                // `slope <= 0` 会让映射单调递减,low/high 的含义互换。词典里目前
                // 一条都没有(`dictionary_slopes_are_all_positive` 守着),真出现
                // 时**拒绝换算**(规范那套整体留空)而不是产出一个上下颠倒的
                // 区间 —— 一个颠倒的区间比没有区间危险得多。
                if conv.slope > 0.0 {
                    let to_canonical = |x: f64| conv.slope * x + conv.intercept;
                    value_canonical = Some(to_canonical(value_num));
                    ref_low_canonical = ref_low.map(to_canonical);
                    ref_high_canonical = ref_high.map(to_canonical);
                    unit_canonical = entry.canonical_unit.clone();
                }
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

    LineOutcome::Row(LabObservation {
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
        ref_low_canonical,
        ref_high_canonical,
        flag,
        confidence: m.as_ref().map_or(0.0, |m| m.confidence),
        self_measured: false,
    })
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

    /// The abnormal marker vocabulary has to be complete, not merely plausible.
    /// `flag` feeds `any_abnormal`, which feeds a lane's `warn`, which is the red
    /// 需关注 badge a doctor scans the timeline for — so a marker we cannot read
    /// does not degrade to "unknown", it degrades to "稳定". The JS and Dart
    /// renderers accepted 升高/降低/减低 while this parser did not, meaning the
    /// same report could read stable in the app and abnormal in the viewer.
    #[test]
    fn abnormal_markers_cover_the_forms_reports_actually_print() {
        let flag_of = |marker: &str| {
            extract_labs(&format!("肌酐 112 umol/L {marker}"))
                .first()
                .and_then(|o| o.flag.clone())
        };
        for m in ["↑", "H", "Ｈ", "高", "偏高"] {
            assert_eq!(flag_of(m).as_deref(), Some("H"), "missed high marker {m:?}");
        }
        for m in ["↓", "L", "Ｌ", "低", "偏低"] {
            assert_eq!(flag_of(m).as_deref(), Some("L"), "missed low marker {m:?}");
        }
        // A normal row must stay unflagged — the list must not be greedy.
        assert_eq!(flag_of("正常"), None);
        // Lowercase `h`/`l` are unit fragments, not flag letters. Folding case
        // made `血沉 15 mm / h 0-20` read as high on an in-range value.
        assert_eq!(flag_of("h"), None);
        assert_eq!(flag_of("l"), None);
        assert_eq!(
            extract_labs("血沉 15 mm / h 0-20")
                .first()
                .and_then(|o| o.flag.clone())
                .as_deref(),
            Some("N"),
            "a spaced unit turned into a flag"
        );
    }

    /// Comparative prose is not a flag column. An explicit marker overrides the
    /// range-derived flag, so accepting 升高/降低/减低 made the parser contradict
    /// the report on values sitting inside their own reference range — including
    /// the negated forms, where `未见减低` came out as "low". The JS and Dart
    /// renderers do match these words (by substring regex) and carry the same
    /// false positive; parity with them is not a reason to reproduce it.
    #[test]
    fn comparative_prose_does_not_flag_an_in_range_value() {
        for line in [
            "白蛋白 42 g/L 40 - 55 无 降低",
            "血红蛋白 140 g/L 130 - 175 未见 减低",
            "总胆固醇 4.5 mmol/L < 5.2 无 明显 升高",
            "血糖 5.6 mmol/L 3.9 - 6.1 较前 降低",
        ] {
            let obs = extract_labs(line);
            let flag = obs.first().and_then(|o| o.flag.clone());
            assert_ne!(flag.as_deref(), Some("L"), "prose flagged low: {line}");
            assert_ne!(flag.as_deref(), Some("H"), "prose flagged high: {line}");
        }
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

    /// 缺陷钉子(2026-08-05):值换算了、参考区间没换,下游拿到一对**单位不一致**
    /// 的数。实测 `肌酐: 1.2 mg/dL (参考 0.6-1.3)` 曾产出
    /// `value_canonical=106.104 umol/L` 配 `ref=[0.6,1.3] mg/dL`。
    #[test]
    fn mgdl_ref_range_converts_alongside_the_value() {
        let text = "肌酐: 1.2 mg/dL (参考 0.6-1.3)";
        let obs = extract_labs(text);
        let cr = find(&obs, "creatinine");
        // 印刷套:逐字保留,一个字都不动。
        assert_eq!(cr.value_num, 1.2);
        assert_eq!(cr.unit_raw.as_deref(), Some("mg/dL"));
        assert_eq!(cr.ref_low, Some(0.6));
        assert_eq!(cr.ref_high, Some(1.3));
        // 规范套:值和两个界值走同一个仿射映射(×88.42)。
        let lo = cr.ref_low_canonical.expect("ref_low must convert too");
        let hi = cr.ref_high_canonical.expect("ref_high must convert too");
        assert!((lo - 53.052).abs() < 0.01, "ref_low_canonical = {lo}");
        assert!((hi - 114.946).abs() < 0.01, "ref_high_canonical = {hi}");
        // 硬不变量:规范套三者同在同缺 —— 不许出现「值换了区间没换」。
        assert_eq!(
            cr.value_canonical.is_some(),
            cr.ref_low_canonical.is_some(),
            "value/ref canonical must appear together"
        );
        // 换算后 106.104 仍落在 [53.05, 114.95] 内 —— 与印刷套同一个结论。
        assert_eq!(cr.flag.as_deref(), Some("N"));
    }

    /// 换算是仿射的;`slope > 0` 时严格单调递增,low/high 不需互换,且 flag 在两套
    /// 单位下**可证明相同**。这条不变量是整套「印刷套/规范套」设计的地基,词典一旦
    /// 加进一条负斜率(理论上不存在,但没人拦着)就必须先来这里改设计。
    #[test]
    fn dictionary_slopes_are_all_positive() {
        let bad: Vec<_> = dictionary_entries()
            .iter()
            .flat_map(|e| e.units.iter().map(move |u| (&e.key, u)))
            .filter(|(_, u)| u.slope <= 0.0)
            .map(|(k, u)| format!("{k}/{} slope={}", u.unit, u.slope))
            .collect();
        assert!(bad.is_empty(), "non-positive slopes: {bad:?}");
    }

    /// 词典里**每一条**非恒等换算都验一遍:印刷值比印刷区间、规范值比规范区间,
    /// 两者得出的 H/L/N 恒等。这是「flag 只存一份」这个决定的凭据。
    #[test]
    fn flag_is_identical_under_canonical_conversion() {
        let cmp = |v: f64, lo: f64, hi: f64| {
            if v > hi {
                "H"
            } else if v < lo {
                "L"
            } else {
                "N"
            }
        };
        let mut checked = 0usize;
        for e in dictionary_entries() {
            for c in &e.units {
                let map = |x: f64| c.slope * x + c.intercept;
                // 区间 [10, 20],取带内/带外/正好压线四类探针。
                let (lo, hi) = (10.0_f64, 20.0_f64);
                for v in [-5.0, 0.0, 9.999, 10.0, 15.0, 20.0, 20.001, 100.0] {
                    assert_eq!(
                        cmp(v, lo, hi),
                        cmp(map(v), map(lo), map(hi)),
                        "{}/{}: flag flipped for v={v} (slope={}, intercept={})",
                        e.key,
                        c.unit,
                        c.slope,
                        c.intercept
                    );
                    checked += 1;
                }
            }
        }
        assert!(checked > 1000, "expected a real sweep, checked {checked}");
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

    // --- range_two_re boundary fix (comma-misread-as-decimal-point) ---
    //
    // Root cause: the old dot-only number pattern `\d+(?:\.\d+)?` had no way
    // to consume a `,`, so on a token where PP-OCR misread a `.` as `,` it
    // matched only the TAIL of the numeral after the comma — silently, with
    // no implausible-looking result to raise suspicion. `low > high` cases
    // (e.g. `3,50~10.00` → old code read `50~10.00`) at least "say something
    // is wrong"; these two don't: the truncated result looks like a
    // perfectly ordinary range.

    #[test]
    fn comma_misread_decimal_at_low_bound_is_read_whole_not_truncated() {
        // Real quiet failure: `12,5~20` (comma is OCR's misread `.`). Old
        // code silently returned low=5/high=20 — a plausible-looking range
        // with the `12` prefix simply gone, nothing to raise suspicion.
        let obs = extract_labs("血糖 15.0 mmol/L 12,5~20");
        let glu = find(&obs, "glucose");
        assert_eq!(glu.ref_low, Some(12.5), "must read 12,5 as 12.5, not 5");
        assert_eq!(glu.ref_high, Some(20.0));
        assert_eq!(glu.flag.as_deref(), Some("N")); // 15.0 sits inside 12.5-20
    }

    #[test]
    fn comma_misread_decimal_at_high_bound_is_read_whole_not_truncated() {
        // Same shape as the ticket's `3.50~10,00` example, but with `10,25`
        // instead of `10,00`: `10` and `10.00` are the same f64 value, so
        // that literal example can't distinguish correct from truncated via
        // a numeric assertion (the underlying regex bug — dropping
        // everything before the last matched digit run — is identical
        // either way). `10,25` makes the truncation numerically visible:
        // old code silently returned high=10 (`,25` dropped entirely).
        let obs = extract_labs("血糖 8.0 mmol/L 3.50~10,25");
        let glu = find(&obs, "glucose");
        assert_eq!(glu.ref_low, Some(3.50));
        assert_eq!(
            glu.ref_high,
            Some(10.25),
            "must read 10,25 as 10.25, not 25"
        );
    }

    #[test]
    fn comma_misread_decimal_also_fixed_in_single_sided_ranges() {
        // Same shape, single-sided comparator form — `range_high_re` /
        // `range_low_re` share the same number pattern and boundary check.
        let hi = extract_labs("总胆固醇 4.0 mmol/L < 5,20")
            .first()
            .and_then(|o| o.ref_high);
        assert_eq!(hi, Some(5.20), "must read 5,20 as 5.20, not 5");
        let lo = extract_labs("eGFR 95 ml/min/1.73m2 ≥ 3,50")
            .first()
            .and_then(|o| o.ref_low);
        assert_eq!(lo, Some(3.50), "must read 3,50 as 3.50, not 3");
    }

    #[test]
    fn three_digit_comma_shape_is_still_read_as_a_decimal_misread() {
        // `1,200` is the one shape where a comma COULD in principle be a
        // thousands separator instead of a misread decimal point (exactly 3
        // digits after it). Decided by real data, not by guessing: a sample
        // of every digit-comma-digit token across this project's actual OCR
        // corpus (`labaudit/ocr-dump/*.txt`, 11 occurrences across 6
        // independently-scanned reports) found 1-2 digits after the comma in
        // every single case and zero 3-digit occurrences — this domain's lab
        // values are already SI-scaled (e.g. platelets read `171`, never
        // `150,000`), so there is no real ambiguity to hedge against here.
        // Matches `normalize_ocr_decimal_comma` in the `ocr` crate, which
        // makes the same unconditional call.
        let obs = extract_labs("血糖 1.5 mmol/L 1,200~2,000");
        let glu = find(&obs, "glucose");
        assert_eq!(glu.ref_low, Some(1.200));
        assert_eq!(glu.ref_high, Some(2.000));
    }

    /// The comma-decimal defence has to cover the RESULT column, not just the
    /// reference range. While it did not, a troponin I of 0.08 ng/mL — twice
    /// its own 0.04 cutoff, i.e. a myocardial-infarction marker — was read as
    /// `0` and flagged **N**: the parser asserting "normal" about the single
    /// number on the sheet that says the opposite. The truncated head of a
    /// comma-decimal is always a plausible-looking value, so there is nothing
    /// downstream (no inverted range, no implausible magnitude) that could
    /// catch it. Both columns now go through `parse_decimal_token`.
    #[test]
    fn comma_decimal_in_the_result_column_is_read_whole() {
        let obs = extract_labs("肌钙蛋白I 0,08 ng/mL 0-0.04");
        let tni = find(&obs, "troponin_i");
        assert_eq!(tni.value_num, 0.08, "result column truncated at the comma");
        assert_eq!(
            tni.flag.as_deref(),
            Some("H"),
            "a value at twice its cutoff must not read as normal"
        );

        // Same shape where the flag happens to come out right anyway — the
        // VALUE is still wrong, and it is the value that gets charted.
        let obs = extract_labs("糖化血红蛋白 7,2 % 4.0-6.0");
        assert_eq!(find(&obs, "hba1c").value_num, 7.2);

        // Real corpus, verbatim (血常规报告3.jpg PP-OCRv5 layout rebuild):
        // RBC `4,35` was being reported as `4`.
        let obs = extract_labs("2红细胞计数          4,35   4.00~5.50 1012/");
        assert_eq!(obs.first().map(|o| o.value_num), Some(4.35));

        // Counter-examples: the dot form and plain integers are untouched.
        assert_eq!(
            extract_labs("肌钙蛋白I 0.08 ng/mL 0-0.04")
                .first()
                .map(|o| o.value_num),
            Some(0.08)
        );
        assert_eq!(
            extract_labs("肌酐 88 μmol/L 59-104")
                .first()
                .map(|o| o.value_num),
            Some(88.0)
        );
    }

    /// A line that prints a name and a reference range but no result of its own
    /// must not have the range's low bound reported as the measurement. This is
    /// the worst shape in the module: the fabricated number is a reference
    /// bound, so it is *by construction* physiologically sensible for that
    /// analyte and cannot be spotted on a chart. `hgb 4.0 g/L` is a lethal
    /// value and it used to land on the trend line as a clean historical point.
    #[test]
    fn a_row_whose_value_is_its_reference_ranges_low_bound_is_refused() {
        for line in [
            // Real corpus shape (血常规报告1.jpg): row number glued to the name,
            // no result cell on this line at all.
            "13血红蛋白  4.00~5.50",
            "13血红蛋白                     4.00~5.50  1012/",
            "淋巴细胞计数  1.00~3.30",
            // Plain half-width dash, and the spaced form (`sep2` swallows the
            // space, so `rest` still begins at the operator).
            "钾 3.5-5.3",
            "葡萄糖 3.9 - 6.1",
            // Full-width range punctuation must be caught the same way.
            "钾 3.5～5.3",
        ] {
            let (obs, unreadable) = extract_labs_with_unreadable(line);
            assert!(
                obs.is_empty(),
                "fabricated a result from a reference bound: {line:?} -> {obs:?}"
            );
            assert_eq!(
                unreadable.len(),
                1,
                "the row must be surfaced for review, not silently dropped: {line:?}"
            );
            assert_eq!(unreadable[0].reason, REASON_NO_RESULT_ONLY_RANGE);
        }
    }

    /// Counter-examples for the check above: it must key on the range operator
    /// ABUTTING the value, so an ordinary row — where a genuine result is
    /// followed by its own reference range — is completely untouched.
    #[test]
    fn a_genuine_result_followed_by_its_range_is_untouched() {
        for (line, key, value) in [
            ("血红蛋白 122  4.00~5.50", "hgb", 122.0),
            (
                "肌酐            88      μmol/L      59-104",
                "creatinine",
                88.0,
            ),
            ("葡萄糖 7.1 mmol/L 3.9 - 6.1 ↑", "glucose", 7.1),
            ("钾 4.2 mmol/L 3.5-5.3", "potassium", 4.2),
            // Negative results still parse; the `-` here is the value's own sign.
            ("剩余碱 -2.5 mmol/L -3.0 - 3.0", "base_excess", -2.5),
            // Real corpus, verbatim (复旦华山 术前生化+凝血, 2024-08-08): INR has
            // no unit, so the empty unit cell prints as a `-` placeholder and a
            // range operator lands directly after a perfectly good result. The
            // inversion test is what keeps this row — `1.05–0.8` is impossible,
            // so `1.05` is a result, and the real range `0.8 - 1.2` follows.
            ("INR 国际标准化比值 1.05 - 0.8 - 1.2 正常", "inr", 1.05),
        ] {
            let obs = extract_labs(line);
            let o = obs
                .iter()
                .find(|o| o.analyte_key.as_deref() == Some(key))
                .unwrap_or_else(|| panic!("{key} disappeared from {line:?}: {obs:?}"));
            assert_eq!(o.value_num, value, "{line:?}");
        }
        // Prose with a numeric span reads the same way but carries no lab
        // evidence — it must stay a non-row, NOT become review noise.
        let (obs, unreadable) = extract_labs_with_unreadable("随访 3-6 个月复查");
        assert!(
            obs.is_empty() && unreadable.is_empty(),
            "{obs:?} {unreadable:?}"
        );
    }

    #[test]
    fn low_greater_than_high_is_discarded_as_a_safety_net() {
        // Not the primary fix (that's range_is_bounded / parse_decimal_token
        // above) — a defensive invariant check for whatever range-misread
        // shape isn't covered by those. A genuine reference range never
        // inverts, so if low > high still slips through, drop the whole pair
        // rather than trust either bound. The row itself is NOT dropped —
        // value/unit still extract, just without a reference range or a
        // range-derived flag.
        let obs = extract_labs("血糖 5.0 mmol/L 70~40");
        let glu = find(&obs, "glucose");
        assert_eq!(glu.ref_low, None);
        assert_eq!(glu.ref_high, None);
        assert_eq!(glu.flag, None);
        assert_eq!(glu.value_num, 5.0); // value itself is untouched
    }

    #[test]
    fn invalid_leading_range_candidate_does_not_hide_a_later_valid_one() {
        // Guards the specific implementation risk called out when this fix
        // was written: `find_range` now walks ALL `range_two_re` matches
        // (`captures_iter`, not a single `captures`) and skips ones
        // `range_is_bounded` rejects, so it must not stop scanning after the
        // first rejection and miss a later, genuinely valid range on the
        // same line. `2.35.6~7.8` has a stray extra `.` (a malformed/glued
        // numeral — exactly what `range_is_bounded` exists to reject: the
        // match it finds, `35.6~7.8`, sits directly against the leading
        // `.`), so it must be skipped over in favor of the real range that
        // follows it, `3.9-6.1`.
        let obs = extract_labs("血糖 5.0 mmol/L 2.35.6~7.8 参考 3.9-6.1");
        let glu = find(&obs, "glucose");
        assert_eq!(
            glu.ref_low,
            Some(3.9),
            "later valid range must still be found"
        );
        assert_eq!(glu.ref_high, Some(6.1));
    }

    #[test]
    fn ticket_example_inputs_are_locked_down_unchanged() {
        // Explicit regression lock for every "must not regress" example the
        // fix ticket called out by name.
        let cases: &[(&str, Option<f64>, Option<f64>)] = &[
            ("血糖 5.0 mmol/L 3.50~10.00", Some(3.50), Some(10.00)),
            ("血糖 5.0 mmol/L 4.0-10.0", Some(4.0), Some(10.0)),
            ("血糖 5.0 mmol/L 0.00~5.00", Some(0.00), Some(5.00)),
            ("血糖 5.0 mmol/L 120~160", Some(120.0), Some(160.0)),
        ];
        for (text, lo, hi) in cases {
            let obs = extract_labs(text);
            let glu = find(&obs, "glucose");
            assert_eq!(glu.ref_low, *lo, "ref_low regressed for {text:?}");
            assert_eq!(glu.ref_high, *hi, "ref_high regressed for {text:?}");
        }
        let below = extract_labs("血糖 5.0 mmol/L < 5.20");
        assert_eq!(find(&below, "glucose").ref_high, Some(5.20));
        assert_eq!(find(&below, "glucose").ref_low, None);
        let above = extract_labs("血糖 5.0 mmol/L ≥ 90");
        assert_eq!(find(&above, "glucose").ref_low, Some(90.0));
        assert_eq!(find(&above, "glucose").ref_high, None);
    }

    // ---------------------------------------------------------------- 折行
    // (wrapped rows: name on one line, result columns on the next)

    #[test]
    fn wrapped_row_joins_the_name_line_to_its_result_line() {
        // Real repro, verbatim PP-OCRv5 output of 北京协和医院 生化+血糖检验报告单
        // (photo, no text layer; also reproduced live via the actual OCR engine
        // against `labaudit/extra-photos/化验单照片.jpg` during validation of this
        // change — 8/8 rows extracted, every value/unit/ref/flag correct). Not a
        // single character is mis-read — the row is simply split across two
        // detection boxes, 项目 column above, 结果/单位/参考范围/提示 columns below.
        // Strict line-by-line parsing got 0 of these 8 analytes; the only thing it
        // did produce was one junk row (`7.1 … mmol/L` read as the NAME, 3.9 — the
        // range's low bound — read as the value), which the join replaces with the
        // real 空腹血糖 7.1.
        let text = "\
项目缩写            项目名称
结果                                                     单位            参考范围           提示
TC              总胆固醇 Cholesterol
6.05                                                   mmol/L                <5.20   ↑
HDL-C           高密度脂蛋白胆固醇
0.98                                                    mmol/L               >1.04   ↓
GLU             空腹血糖 Glucose
7.1                                                    mmol/L               3.9 -6.1  ↑
HbA1c           糖化血红蛋白
6.9                                                    %                   4.0 -6.0  ↑
Cr              肌酐 Creatinine
95                                                     umol/L               57-97   正常
";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 5, "got {:?}", obs);
        let tc = find(&obs, "cholesterol");
        assert_eq!(tc.value_num, 6.05);
        assert_eq!(tc.unit_raw.as_deref(), Some("mmol/L"));
        assert_eq!(tc.ref_high, Some(5.20));
        assert_eq!(tc.flag.as_deref(), Some("H"));
        let hdl = find(&obs, "hdl");
        assert_eq!(hdl.value_num, 0.98);
        assert_eq!(hdl.ref_low, Some(1.04));
        assert_eq!(hdl.flag.as_deref(), Some("L"));
        let glu = find(&obs, "glucose");
        assert_eq!(
            glu.value_num, 7.1,
            "must be the result, not the range's low"
        );
        assert_eq!(glu.ref_low, Some(3.9));
        assert_eq!(glu.ref_high, Some(6.1));
        let cr = find(&obs, "creatinine");
        assert_eq!(cr.value_num, 95.0);
        assert_eq!(cr.flag.as_deref(), Some("N"));
        // The table's own header band sits directly above the first data row and
        // must never be joined into one.
        assert!(obs.iter().all(|o| !o.raw_name.contains("项目缩写")));
    }

    #[test]
    fn a_lone_number_on_the_next_line_is_never_joined_even_though_it_sometimes_would_be_right() {
        // The guard that matters most (`merged_wrap_row` condition 3). A value
        // line with no unit, no range and no flag is indistinguishable from a
        // number belonging to a DIFFERENT column, and a two-column sheet read in
        // OCR order produces exactly that.
        let obs = extract_labs("4 单核细胞计数\n28.0.\n27.9-33.0\n");
        assert!(
            obs.iter()
                .all(|o| o.analyte_key.as_deref() != Some("mono_count")),
            "fabricated a 单核细胞计数 from a neighbouring column: {:?}",
            obs
        );
        // Same guard, isolated: a bare name over a bare number, nothing else.
        // This one WOULD have been correct — refusing it is the price of the
        // rule, paid on purpose (宁可漏,不能编).
        assert_eq!(extract_labs("单核细胞计数\n0.49\n").len(), 0);
        // …and it is genuinely the missing unit/range that decides, not the
        // analyte: the same pair with its result columns attached does join.
        let joined = extract_labs("单核细胞计数\n0.49   10^9/L   0.20~1.00\n");
        assert_eq!(joined.len(), 1, "got {:?}", joined);
        assert_eq!(joined[0].analyte_key.as_deref(), Some("mono_count"));
        assert_eq!(joined[0].value_num, 0.49);
    }

    #[test]
    fn a_wrapped_row_is_only_joined_when_the_joined_name_is_a_known_analyte() {
        // `merged_wrap_row` condition 4: joining is an inference about page
        // layout, and a dictionary hit is the only independent corroboration
        // available that the text above really names this number. An unknown
        // analyte offers none, so it stays dropped — even though the value line
        // is perfectly well-formed.
        assert_eq!(extract_labs("神秘指标XYZ\n12.3   mg/L   0-5\n").len(), 0);
        // Counter-example: identical shape, name the dictionary knows.
        let obs = extract_labs("肌酐 Creatinine\n88   umol/L   59-104\n");
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        assert_eq!(obs[0].analyte_key.as_deref(), Some("creatinine"));
        assert_eq!(obs[0].value_num, 88.0);
    }

    #[test]
    fn a_name_line_carrying_its_own_number_is_never_used_as_a_wrap_head() {
        // `merged_wrap_row` condition 1. `2 中性粒细胞计数` produces nothing on
        // its own (row_re finds no number AFTER a separator), so it does reach
        // the wrap path — and the bare `2` is the sheet's printed row number.
        // Without this condition the line below it, which on these two-column
        // 血常规 sheets belongs to the RIGHT-hand column (血小板压积 0.20,
        // 0.11~0.28 L/L), would be attributed to 中性粒细胞计数: a fabricated
        // value with somebody else's reference range attached.
        let obs = extract_labs("2 中性粒细胞计数\n0.20      0.11~0.28  L/L\n");
        assert_eq!(obs.len(), 0, "joined across a row number: {:?}", obs);
    }

    #[test]
    fn a_line_that_already_parsed_never_absorbs_the_next_lines_number() {
        // `merged_wrap_row` is only reached after a line has failed to parse on
        // its own, and a name line carrying its own bare number is rejected
        // besides. Both together mean the join can never re-attribute a result
        // that the strict line-by-line reading already got right.
        let obs = extract_labs("甘油三酯 TG 2.35\n1.70   mmol/L   0.5-1.7\n");
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        assert_eq!(obs[0].analyte_key.as_deref(), Some("triglycerides"));
        assert_eq!(obs[0].value_num, 2.35, "swallowed the next line's number");
    }

    #[test]
    fn single_line_rows_are_completely_unaffected_by_wrapping() {
        // Idempotency counter-example: a clean report where every row is whole
        // must parse exactly as it did before wrapping existed — same count,
        // same values — including when consecutive rows could superficially
        // look like a name line followed by a value line.
        let text = "\
肌酐            88      μmol/L      59-104
尿素            5.2     mmol/L      2.9-8.2
低密度脂蛋白胆固醇  3.6  mmol/L  <3.4  ↑
";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 3, "got {:?}", obs);
        assert_eq!(find(&obs, "creatinine").value_num, 88.0);
        assert_eq!(find(&obs, "urea").value_num, 5.2);
        assert_eq!(find(&obs, "ldl").value_num, 3.6);
    }

    // ------------------------------------------------- 项目名粘上行序号

    #[test]
    fn a_bare_row_number_glued_name_value_pair_resolves_via_the_dictionary() {
        // Real repro (血常规报告1.jpg / 血常规报告5.jpg, PP-OCRv5, verified against
        // the live OCR engine during validation of this change): the leftmost
        // column of a Chinese lab sheet is the printed row number, and OCR fuses
        // it onto the analyte name. The name itself is spelled correctly — only
        // the exact-match lookup fails. When the line carries NOTHING else (no
        // unit, no range, no flag — a bare `name value` pair, exactly this
        // shape), there is nothing on the line OCR could have bled in from a
        // neighbouring column, so the fallback is trusted.
        let cases = [
            ("1白细胞计数               3.86", "wbc", 3.86),
            ("2中性粒细胞计数             1.68", "neut_count", 1.68),
            ("3淋巴细胞计数              1.48", "lymph_count", 1.48),
            ("12红细胞计数            4.35", "rbc", 4.35),
            ("13血红蛋白             122", "hgb", 122.0),
        ];
        for (line, key, value) in cases {
            let obs = extract_labs(line);
            assert_eq!(
                obs.first().and_then(|o| o.analyte_key.as_deref()),
                Some(key),
                "row number blocked the lookup: {line}"
            );
            assert_eq!(obs[0].value_num, value, "{line}");
            // The raw name stays verbatim — stripping is a lookup fallback, not
            // a rewrite of what the document says.
            assert!(obs[0].raw_name.starts_with(|c: char| c.is_ascii_digit()));
        }
    }

    #[test]
    fn a_row_number_glued_name_with_anything_else_on_the_line_stays_unmapped() {
        // The restriction that keeps `strip_serial_prefix` from repeating the
        // exact failure this branch was sent back for: promoting a name→value
        // pair to a charted analyte is safe only when there is nothing else on
        // the line for OCR to have bled in from a neighbouring column. The
        // moment a unit, range or flag is ALSO present, that attachment cannot
        // be trusted — real corpus (血常规报告1.jpg, verbatim PP-OCRv5 layout
        // reconstruction) has exactly this line: `13血红蛋白` carries no value of
        // its own here (HGB's real result, 122, is a full line further down —
        // see `wrapped_row_joins_the_name_line_to_its_result_line` for what a
        // GENUINE wrap looks like), but the line still parses as `name value
        // rest` because the right-hand column's stray reference-unit fragment
        // (`1012/`, itself garbled from a neighbouring row's `10^12/L`) landed
        // in the "rest" slot. Without this restriction, stripping the row
        // number resolves the name to `hgb` and charts a fabricated `hgb ≈ 4`
        // right next to the real trend line — strictly worse than the
        // (unmapped, harmless) row this line produces today.
        // Note the assertion has been TIGHTENED since this test was written:
        // it used to accept the line still producing an (unmapped) row with
        // `value_num == 4.0`, on the reasoning that an unmapped row is
        // harmless. It is not — `aggregate` groups unmapped rows by raw name
        // (`GroupKey::Raw`) and they render as their own trend line, so the
        // fabricated 4.0 was charted either way, just under the label
        // `13血红蛋白` instead of `血红蛋白`. The row has no result of its own
        // and is now refused outright; see
        // `a_row_whose_value_is_its_reference_ranges_low_bound_is_refused`.
        let (obs, unreadable) =
            extract_labs_with_unreadable("13血红蛋白                     4.00~5.50  1012/");
        assert!(
            obs.is_empty(),
            "a reference bound was reported as a result: {obs:?}"
        );
        assert_eq!(unreadable.len(), 1, "and it must be surfaced for review");

        // Same danger, a unit alone is enough to trip it.
        let obs = extract_labs("9单核细胞百分比          12.70     3.50~10.00%");
        assert_eq!(
            obs.first().and_then(|o| o.analyte_key.as_deref()),
            None,
            "a unit/range on the line must block the fallback too: {:?}",
            obs
        );

        // Counter-example: strip the trailing range/unit and the same name+value
        // pair (now bare) resolves fine — confirms the gate is the "anything
        // else on the line" shape, not the name or value themselves.
        let bare = extract_labs("9单核细胞百分比          12.70");
        assert_eq!(
            bare.first().and_then(|o| o.analyte_key.as_deref()),
            Some("mono_pct")
        );
    }

    #[test]
    fn analyte_names_that_legitimately_begin_with_digits_are_not_mangled() {
        // Counter-example. Plenty of real analytes start with digits, so the
        // strip must never run before the name has been tried as printed, must
        // stop at 2 digits (sheets number rows 1..99), and must require a CJK
        // char right after them (`13C…`, `25-OH…` are Latin-initial).
        for (line, key) in [
            (
                "25羟基维生素D        18.5    ng/mL    30-100",
                "vitamin_d_25oh",
            ),
            ("24小时尿蛋白定量      0.35    g/24h", "urine_protein_24h"),
            (
                "2小时餐后血糖         9.8     mmol/L   <7.8",
                "glucose_2h_pp",
            ),
        ] {
            assert_eq!(
                extract_labs(line)
                    .first()
                    .and_then(|o| o.analyte_key.as_deref()),
                Some(key),
                "digit-initial analyte name was broken: {line}"
            );
        }
        // A 3-digit prefix is not a sheet row number — no strip, so no match.
        let obs = extract_labs("123红细胞计数     4.35    4.00~5.50   10^12/L");
        assert_eq!(obs.len(), 1, "got {:?}", obs);
        assert_eq!(obs[0].analyte_key, None, "guessed past a 3-digit prefix");
    }

    // ------------------------------------------------------- 表头残余

    #[test]
    fn result_table_column_headers_are_not_charted_as_analytes() {
        // Real repro (verbatim PP-OCRv5 output, 苏州独墅湖 血常规 photos +
        // scanned PDFs). A photograph splits the header band across detection
        // boxes, so the column labels land in the text stream next to a stray
        // number from a neighbouring column and parse as `name + value`:
        // `参考范围 单位 检验项目` = 42, the title line = 2016, `No` = 20160824.
        // Each one becomes a fabricated trend line beside a real one.
        let text = "\
【血常规】  门诊          独墅湖科教创新区医院化验报告单                          No:20160824XXS0025
参考范围                                   单位    检验项目                     42.0~49.0L/L
独墅湖科教创新区医院化验报告单                                                               2016-08-Z4
结果                             参考范围       单位    14红细胞压积          39.2    82.0~95.0 f1
检验项目                 3.86      4.00~10.0010~9/L
项目缩写            项目名称
No:20160824XXS0025
打印时间2016-08-2411:08                                   审核者樊笋
";
        let obs = extract_labs(text);
        assert_eq!(obs.len(), 0, "header residue charted as labs: {:?}", obs);
    }

    #[test]
    fn header_words_never_take_out_a_real_analyte_row() {
        // Counter-example: the header list is substring-matched, so it must only
        // contain words that cannot occur inside a measured quantity's name.
        // `No` is the one that could — it is matched as a whole token and
        // case-sensitively, so the nitric-oxide abbreviation survives.
        let text = "\
肌酐            88      μmol/L      59-104
谷丙转氨酶(ALT)  45     U/L         0-40    ↑
白球比值(A:G)   1.52    1.20-2.40
NO             25      umol/L      10-40
";
        let obs = extract_labs(text);
        assert_eq!(
            obs.len(),
            4,
            "a real row was taken out as header: {:?}",
            obs
        );
        assert_eq!(find(&obs, "creatinine").value_num, 88.0);
        assert_eq!(find(&obs, "alt").value_num, 45.0);
    }

    #[test]
    fn doubled_dash_range_reads_as_one_positive_range_not_a_negative_bound() {
        // Real MedRepBench corpus (`item_range` field, verbatim): a doubled
        // hyphen where a single en/em dash was meant. Every one of 618 exact
        // `<num>--<num>` occurrences sampled across the dataset's source
        // annotations has low<=high under this "doubled separator" reading —
        // PT/APTT seconds, bilirubin, creatinine, TSH, D-dimer — none of which
        // is a quantity that legitimately goes negative. The OLD single-`-`
        // separator regex read the second number's leading `-` as ITS sign
        // instead, turning `9.4--12.5` into a negative low bound (`-12.5`) for
        // a coagulation time — physiologically impossible, and dangerous per
        // this module's whole point: a wrong reference range is worse than no
        // range at all.
        let obs = extract_labs("PT 凝血酶原时间 19.40 秒 9.4--12.5 ↑");
        let pt = find(&obs, "pt");
        assert_eq!(pt.ref_low, Some(9.4));
        assert_eq!(pt.ref_high, Some(12.5));

        // A single dash still reads exactly as before — the `+` only WIDENS
        // what's accepted, it never changes how an already-matching
        // single-dash range reads.
        let obs2 = extract_labs("肌酐 88 μmol/L 59-104");
        assert_eq!(find(&obs2, "creatinine").ref_low, Some(59.0));
        assert_eq!(find(&obs2, "creatinine").ref_high, Some(104.0));
    }

    #[test]
    fn doubled_dash_value_bound_into_range_is_still_refused() {
        // `value_is_range_low_bound`'s tail check (`range_tail_re`) must catch
        // the doubled-dash shape too, not just single-dash — otherwise a value
        // bound into a doubled-dash range slips past the guard and gets
        // reported as a fabricated result (this exact shape, `GLOB 37--53`,
        // is real MedRepBench corpus: 球蛋白/globulin has no result of its own
        // on that line, just its reference range, doubled-dash).
        let (obs, unreadable) = extract_labs_with_unreadable("GLOB 球蛋白 37--53");
        assert!(
            obs.is_empty(),
            "a doubled-dash range's low bound was reported as a result: {obs:?}"
        );
        assert_eq!(
            unreadable.len(),
            1,
            "must be surfaced for review, not dropped silently"
        );
        assert_eq!(unreadable[0].reason, REASON_NO_RESULT_ONLY_RANGE);
    }

    #[test]
    fn reference_range_wrapped_across_a_line_break_is_completed() {
        // Real MedRepBench corpus shape (multiple docs, e.g. 无机磷/磷/钠/钙/
        // 渗透压 rows): the row's name+value+unit print on one line, but the
        // line is wide enough that the layout reconstruction wraps BEFORE the
        // range's high bound — the low bound trails the line with a dangling
        // `-`/`~` and the high bound alone starts the next line.
        let text = "\
无机磷                       HR/☆Pi 1.01              mmol/L                    0.85-
1.51
";
        let obs = extract_labs(text);
        let p = find(&obs, "phosphate");
        assert_eq!(p.value_num, 1.01);
        assert_eq!(p.ref_low, Some(0.85));
        assert_eq!(p.ref_high, Some(1.51));

        // The doubled-dash separator (see `range_two_re`) can itself land
        // split across the wrap — the low bound's line ends in ONE dash, and
        // the continuation starts with the OTHER: `0.45-` \n `-1.81` is the
        // same `0.45--1.81` one line short of a doubled dash. The leading `-`
        // on the continuation is stripped as more separator, not read as a
        // sign — consistent with `range_two_re` never producing a negative
        // bound from this shape.
        let text2 = "\
总胆红素                              12.9            μmol/L                       5.1-
-28.0
";
        let obs2 = extract_labs(text2);
        let t = find(&obs2, "tbil");
        assert_eq!(t.ref_low, Some(5.1));
        assert_eq!(t.ref_high, Some(28.0));
    }

    #[test]
    fn reference_range_wrap_is_refused_when_the_next_line_is_not_a_bare_number() {
        // Counter-examples for the join above — real corpus shapes that must
        // NOT be joined, because the "next line" is not actually the missing
        // high bound:
        for (text, key) in [
            // A stray abnormal-flag letter before the number (`H`/`N` column) —
            // joining would silently absorb the flag digit-adjacent text as if
            // it were part of the range.
            (
                "22          血小板压积                0.33           ml/L                         0.11-\nH                                                                            0.28\n",
                "plateletcrit",
            ),
            // A wrapped ANALYTE-NAME fragment, not a value at all.
            (
                "高密度脂蛋白胆固醇(HDL-                                 1.48         mmol/L            0.95-\nC)                                                                            -1.94\n",
                "hdl",
            ),
            // An unrelated row's own name sitting where the high bound would
            // be — joining would steal a different analyte's line entirely.
            (
                "国际标准化比值                                     0.83                                0.8-\n部分凝血活酶时间                                    15.90\n",
                "inr",
            ),
        ] {
            let obs = extract_labs(text);
            let o = obs.iter().find(|o| o.analyte_key.as_deref() == Some(key));
            if let Some(o) = o {
                assert_eq!(
                    (o.ref_low, o.ref_high),
                    (None, None),
                    "a wrap join fabricated a range from an unsafe next line: {text:?} -> {o:?}"
                );
            }
        }
    }
}
