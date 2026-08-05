//! Cross-document clinical aggregation (stage B, slice ③).
//!
//! Folds the per-document extractions ([`extract_labs`], [`extract_meds`],
//! [`extract_conditions`]) across MANY source documents into a small "derived
//! layer": analyte trends, medication spans, and a deduped condition list. This
//! is the structure a doctor-summary is later assembled from (slice ④, not this
//! module). Pure in-memory folding: no network, no LLM, no re-parsing of text
//! beyond calling the sibling extractors.
//!
//! ## What this layer does NOT do (kept lean, honest)
//! - **Dates are supplied by the caller**, one per document (e.g. from
//!   [`crate::guess_date`]). We never re-derive a document's clinical date here,
//!   and we never attribute a date to an individual row inside a document — every
//!   row inherits its document's date.
//! - **Medication start/stop/restart is NOT inferred.** `status` is always
//!   `"active"`; there is not enough signal in free-text mentions to detect
//!   discontinuation without inventing it. The proper start/stop/restart fold
//!   (docs/030 §4) is deferred to when the event log carries explicit stop
//!   actions — only then can "stopped" be asserted rather than guessed.
//! - **No cross-synonym merging of conditions.** The dictionary has no condition
//!   category, so conditions are deduped by exact (trimmed) raw text only; two
//!   spellings of the same disease stay separate rather than be laundered.
//! - Unmatched analytes/drugs are kept separate from matched ones (grouped by
//!   raw name) and never merged into a coded series — honest about what resolved.
//!
//! ## 单位:哪一层用哪一套(**这就是那个「铆」**,2026-08-05)
//!
//! 一份化验有两套自洽的数:**印刷套**(纸上逐字印的值+单位+参考区间)和**规范套**
//! (换算到词典 `canonical_unit` 的值+单位+参考区间)。两套各自内部同单位,由
//! `labs.rs` 用同一个仿射映射同时产出(见那里的模块头)。本模块负责**选**:
//!
//! | 层 | 用哪一套 | 为什么 |
//! |---|---|---|
//! | 数据层 · 归组 | 与单位无关 | 按 `analyte_key` 归组(`GroupKey`),压根不看数值 |
//! | 数据层 · flag | 印刷套 | 仿射严格单调递增 ⇒ 两套算出的 H/L/N **恒等**,取印刷套是因为它永远存在(未归一化的项目也有) |
//! | 数据层 · 锚 | 规范套 | `LabPoint::value_canonical` + `AnalyteSeries::ref_*_canonical` + `unit_canonical`,供跨院/跨单位比较,恒同单位 |
//! | 趋势图(轴/点/参考带) | **显示基准**(见下) | 带子必须和点同一个单位,否则参考带画在错的高度上 |
//! | 概览化验行 / 「看病带这个」 | 显示基准 | 患者要拿 app 上的数字去核对手里那张纸(`docs/007` §2.1「原件永远可达」) |
//! | 医生纯文本 / 二维码 / 托管查看器 | 显示基准 | 医生要能和患者递过来的纸对上;三者同源于 `AnalyteSeries`,不各算各的 |
//!
//! **显示基准(display basis)由本模块每条序列算一次,下游一律读
//! `LabPoint::value`/`unit` 与 `AnalyteSeries::ref_low`/`ref_high`,不自己判断:**
//!
//! 1. 这条序列全部点的印刷单位一致(忽略没印单位的点)⇒ 基准 = **印刷套**。
//!    这是绝大多数情况(一家医院一套单位),患者看到的就是纸上那个数。
//! 2. 印刷单位不一致(mg/dL 的报告和 umol/L 的报告混在一条线上)⇒ 一条线上没法
//!    同时画两种单位,基准 = **规范套**,前提是**每一个**点都换算得出来。
//!    `values_converted = true`,渲染层据此告诉用户「已统一换算」—— 显示一个纸上
//!    没有的数字必须说出来,否则用户核对不了。
//! 3. 印刷单位不一致**且**换不全(未归一化的项目按原始名归组、各报告单位又不同)
//!    ⇒ 没有任何一对区间对所有点都成立,**序列级参考区间整体留空**(`None`),
//!    点仍带各自的印刷值和印刷单位。宁可没有区间,也不给一个错单位的区间 ——
//!    这正是本次要修的那个缺陷的形状。
//!
//! 参考区间还有一道闸:即使基准是印刷套,那对区间**必须来自印刷单位与序列一致的
//! 那份报告**,否则也留空。区间和值同单位是硬不变量,不是「尽量」。

use crate::{
    extract_conditions, extract_labs, extract_meds, self_entry, LabObservation, MedObservation,
};
use chrono::NaiveDate;
use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::{BTreeSet, HashMap};

/// One source document to aggregate over. `date` is the document's clinical date
/// (caller supplies it, e.g. from [`crate::guess_date`]); `None` if unknown.
pub struct SourceDoc<'a> {
    /// Stable index back into the caller's record list (kept for evidence).
    pub index: usize,
    pub date: Option<NaiveDate>,
    pub text: &'a str,
    /// The record's `doc_type` as a lowercased string (e.g. `"imaging_report"`),
    /// used by the summary to route imaging docs; `None` when unknown. `aggregate`
    /// itself ignores this — it only feeds doctor-summary routing (slice ④).
    pub doc_type: Option<String>,
    /// The record's title (e.g. `"胸部CT"`); helps derive an imaging group label.
    /// `None` when unknown. Ignored by `aggregate`.
    pub title: Option<String>,
}

/// One measured value of an analyte, tagged with the document it came from.
#[derive(Debug, Clone)]
pub struct LabPoint {
    pub date: Option<NaiveDate>,
    /// **显示基准值** —— 见模块头「哪一层用哪一套」。同一条序列上所有点的
    /// `value` 保证同单位,且与该序列的 `ref_low`/`ref_high` 同单位。渲染层
    /// (趋势图、化验行、纯文本、二维码、托管查看器)读这个,不自己挑。
    pub value: f64,
    /// `value` 的单位。序列内恒定(基准=印刷套时是那份报告印的单位;基准=规范套
    /// 时是词典 `canonical_unit`)。序列连一个单位都没印时为 `None`。
    pub unit: Option<String>,
    /// **规范单位下的值(锚)**,单位见 [`AnalyteSeries::unit_canonical`]。
    /// `None` = 这个点换算不出来(项目没归一化,或词典不认这份报告的单位)。
    /// 跨院/跨单位比较只许用这个,不许用 `value`。
    pub value_canonical: Option<f64>,
    pub flag: Option<String>,
    /// The [`SourceDoc::index`] this point came from.
    pub source: usize,
}

/// A single analyte's trend across all documents.
#[derive(Debug, Clone)]
pub struct AnalyteSeries {
    /// `Some` for a resolved analyte; `None` when grouped by raw name (unmatched
    /// analytes are kept separate, never merged with matched ones).
    pub analyte_key: Option<String>,
    /// Display/grouping label: canonical name if resolved, else the raw name.
    pub group_name: String,
    pub loinc: Option<String>,
    /// Reference range, taken from the most recent observation in the group that
    /// carried one (fallback: any). The viewer draws the normal band from these.
    ///
    /// **单位保证与 [`LabPoint::value`] 一致**(显示基准),这是硬不变量:参考带
    /// 必须和点同一个单位。做不到保证时整体为 `None`,不给错单位的一对数 ——
    /// 见模块头「哪一层用哪一套」的第 3 条与最后那道闸。
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    /// 规范单位(词典 `canonical_unit`)。未归一化的序列为 `None`。
    pub unit_canonical: Option<String>,
    /// **规范单位下的参考区间(锚)**,与 [`LabPoint::value_canonical`] 同单位。
    /// 与 `ref_low`/`ref_high` 同源同一份报告、同一个仿射映射,只是换了单位。
    /// 那份报告换算不出来时为 `None`。
    pub ref_low_canonical: Option<f64>,
    pub ref_high_canonical: Option<f64>,
    /// 显示基准是不是**规范套**(即:这条线上混了不同印刷单位,已统一换算)。
    /// `true` 时渲染层必须说出来 —— 用户在纸上找不到这个数字,不说就等于改写原文。
    pub values_converted: bool,
    /// Chronological; `None`-dated points sort last, preserving input order.
    pub points: Vec<LabPoint>,
    /// True if any point is flagged "H" or "L".
    pub any_abnormal: bool,
    /// True for a series built from manually-entered self-measurements (blood
    /// pressure/glucose/weight/temperature/heart rate recorded via "记录", never
    /// from an OCR'd report). Homogeneous within the series by construction —
    /// see `GroupKey::SelfMeasured`, which keeps self-measured points out of any
    /// group that also holds hospital-sourced points for the same analyte.
    pub self_measured: bool,
}

/// A medication's span across all documents that mention it.
#[derive(Debug, Clone)]
pub struct MedSpan {
    /// `Some` for a resolved drug; `None` when grouped by raw name.
    pub drug_key: Option<String>,
    /// Canonical name if resolved, else the raw name.
    pub name: String,
    pub atc: Option<String>,
    /// e.g. "0.5g bid", taken from the most recent mention (fallback: any).
    pub latest_dose: Option<String>,
    /// Earliest dated mention (`None` if no mention carried a date).
    pub start: Option<NaiveDate>,
    /// Latest dated mention.
    pub end: Option<NaiveDate>,
    /// Always "active" — see the module header: discontinuation is not inferred.
    pub status: String,
    /// All [`SourceDoc::index`] that mention it, deduped, ascending.
    pub sources: Vec<usize>,
}

/// A deduped condition mention across documents.
#[derive(Debug, Clone)]
pub struct AggregatedCondition {
    pub raw_text: String,
    /// Earliest dated mention (`None` if no mention carried a date).
    pub onset: Option<NaiveDate>,
    /// ICD code the note printed alongside this diagnosis, if any (first
    /// non-empty across the merged mentions). Additive FHIR groundwork — not yet
    /// surfaced in the summary/share; carried here for a future export to use.
    pub icd_code: Option<String>,
    /// All [`SourceDoc::index`] that mention it, deduped, ascending.
    pub sources: Vec<usize>,
}

/// The derived clinical layer: analyte trends, med spans, and conditions.
#[derive(Debug, Clone)]
pub struct AggregatedClinical {
    pub labs: Vec<AnalyteSeries>,
    pub meds: Vec<MedSpan>,
    pub conditions: Vec<AggregatedCondition>,
}

/// Grouping key. `Matched`/`Raw`/`SelfMeasured` live in separate namespaces so a
/// resolved item never merges with an unmatched one that happens to share a
/// display string — and, per `MANUAL-ENTRY-DESIGN.md` §1/§3.4, a self-measured
/// analyte never merges with a hospital-sourced one that resolves to the same
/// `analyte_key`. A self-measured blood pressure reading and a diagnosed
/// diastolic/systolic reading from a report both resolve to `"bp_systolic"` /
/// `"bp_diastolic"`, but they were taken in different settings with different
/// reference ranges (home vs. clinic) and must never be drawn as one line.
#[derive(PartialEq, Eq, Hash, Clone)]
enum GroupKey {
    Matched(String),
    /// Same `analyte_key` namespace as `Matched`, but a structurally separate
    /// bucket — a self-measured `"bp_systolic"` and a hospital `"bp_systolic"`
    /// hash to different keys even though the string inside is identical.
    SelfMeasured(String),
    Raw(String),
}

/// Order two optional dates with `None` sorting *after* any `Some` (unknown
/// dates last). Used for both point ordering and output ordering.
fn cmp_date_none_last(a: &Option<NaiveDate>, b: &Option<NaiveDate>) -> Ordering {
    match (a, b) {
        (Some(x), Some(y)) => x.cmp(y),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn min_date(cur: Option<NaiveDate>, new: Option<NaiveDate>) -> Option<NaiveDate> {
    match (cur, new) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (Some(a), None) => Some(a),
        (None, b) => b,
    }
}

fn max_date(cur: Option<NaiveDate>, new: Option<NaiveDate>) -> Option<NaiveDate> {
    match (cur, new) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (Some(a), None) => Some(a),
        (None, b) => b,
    }
}

/// Whether this document should be mined for **labs**. Only lab reports —
/// running `extract_labs` over prescriptions/imaging/prose mis-reads drug doses
/// and sentence fragments as "labs" (`二甲双胍 0.5g` → analyte, CT text → analyte).
/// `None`/unknown stays permissive so callers that don't classify still work
/// (and to keep the low-level aggregate unit tests type-agnostic). Quality dim 3/4.
fn wants_labs(doc_type: Option<&str>) -> bool {
    doc_type.is_none_or(|t| t.contains("lab"))
}

/// Whether this document should be mined for **meds**. Only prescriptions —
/// running `extract_meds` over lab reports/prose mis-reads lab rows and prose as
/// "meds" (`肌酐 112 umol/L` → 112U, 病历散文 → 剂量). `None`/unknown stays
/// permissive (see [`wants_labs`]). Quality dim 3/4.
fn wants_meds(doc_type: Option<&str>) -> bool {
    doc_type.is_none_or(|t| t.contains("prescription"))
}

/// A clinical section kind, for section-scoped mining of **embedded** labs/meds.
#[derive(Clone, Copy, PartialEq, Eq)]
enum SecKind {
    Meds,
    Labs,
    Other,
}

/// Does `line` start with one of `heads`?
///
/// Prefix match **after [`terminology::normalize_term`]** on both sides. Comparing
/// the raw line only worked when the report typeset the header exactly the way
/// these lists spell it: `出院　医嘱:` (ideographic space U+3000, ordinary in
/// Chinese typesetting) and `出 院 医 嘱:` (OCR splitting CJK) both failed the
/// prefix test, the section went unrecognized, and every discharge medication in
/// the document silently disappeared from the summary. Same defect that emptied
/// the diabetes lane — one comparison of Chinese text against a curated literal
/// without normalizing first.
///
/// Two ways to be a header, and the split matters — both halves were learned the
/// hard way.
///
/// 1. The **raw** prefix, exactly as before. Real headers trail all sorts of
///    things: `出院医嘱如下:`, `出院带药(共2种):`, `带药如下`, `出院医嘱 1.`,
///    `用药医嘱 -`. An earlier attempt demanded a delimiter right after the
///    prefix and lost every one of them — worse than the bug it was fixing.
///
/// 2. The **normalized** prefix, but only when what follows is a delimiter or
///    the line ends. Normalization exists here for `出 院 医 嘱:` (OCR splits
///    CJK) and `ＲＰ:` (full-width) — but it also lowercases and deletes all
///    internal whitespace, so an unguarded prefix test on the normalized line
///    reads ordinary content as a header. `RPR 阴性` (routine syphilis screen)
///    matched the lowercased `Rp`; `用 药 后 患者症状缓解` matched `用药`. And a
///    false header is much worse than a missed one: `sections_text` treats
///    headers as boundaries, so it truncates the block and everything below it
///    vanishes — one RPR row deleted 肌酐 and 血钾 from a real summary.
///
/// Together: never less than the raw rule recognized, plus the despaced and
/// full-width spellings, and nothing that merely happens to start with a
/// header word.
fn starts_with_header(line: &str, heads: &[&str]) -> bool {
    let raw = line.trim_start();
    let folded = terminology::normalize_term(line);
    heads.iter().any(|h| {
        raw.starts_with(h)
            || folded
                .strip_prefix(terminology::normalize_term(h).as_str())
                .is_some_and(|rest| rest.is_empty() || rest.starts_with([':', '.', '、']))
    })
}

/// The section kind a header line starts, or `None` if it isn't a header. `Other`
/// headers (诊断/病史/…) aren't mined but still bound a section so a meds/labs
/// section ends where the next section begins.
fn header_kind(line: &str) -> Option<SecKind> {
    const MEDS: &[&str] = &[
        "出院医嘱",
        "出院带药",
        "带药",
        "用药医嘱",
        "用药",
        "医嘱",
        "Rp",
    ];
    const LABS: &[&str] = &["检验项目", "检验结果", "化验", "生化检验", "检验报告"];
    const OTHER: &[&str] = &[
        "出院诊断",
        "入院诊断",
        "初步诊断",
        "主要诊断",
        "临床诊断",
        "病理诊断",
        "诊断",
        "影像所见",
        "超声所见",
        "检查所见",
        "诊断意见",
        "印象",
        "结论",
        "主诉",
        "现病史",
        "既往史",
        "住院经过",
        "查体",
        "处理意见",
        "处方",
        "建议",
        "小结",
    ];
    let hit = |hs: &[&str]| starts_with_header(line, hs);
    if hit(MEDS) {
        Some(SecKind::Meds)
    } else if hit(LABS) {
        Some(SecKind::Labs)
    } else if hit(OTHER) {
        Some(SecKind::Other)
    } else {
        None
    }
}

/// Text of the sections in `text` whose header matches `want` (a section runs from
/// its header line to the next recognized header, or end). Mines **embedded**
/// labs/meds out of documents whose own `doc_type` isn't lab/rx — a discharge
/// summary's 出院医嘱 list, a note's 化验 block — that whole-doc `doc_type` gating
/// would otherwise drop (#148). Section-scoped, so `extract_labs`/`extract_meds`'s
/// own row-level guards still apply, and prose outside these sections is untouched.
fn sections_text(text: &str, want: SecKind) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur: Option<(SecKind, Vec<&str>)> = None;
    for line in text.lines() {
        if let Some(k) = header_kind(line) {
            if let Some((ck, lines)) = cur.take() {
                if ck == want {
                    out.push(lines.join("\n"));
                }
            }
            cur = Some((k, vec![line]));
        } else if let Some((_, lines)) = cur.as_mut() {
            lines.push(line);
        }
    }
    if let Some((ck, lines)) = cur {
        if ck == want {
            out.push(lines.join("\n"));
        }
    }
    out
}

/// Medication-block headers used to **mask** text out of whole-document lab
/// mining. Deliberately a strict subset of [`header_kind`]'s `MEDS`: the bare
/// `用药` / `医嘱` entries are left out on purpose, because as raw prefixes they
/// also match ordinary lab-report furniture — `医嘱号:12345` and `用药指导:…` are
/// printed fields on real Chinese 检验报告单. In `header_kind` a false positive
/// costs a truncated section; here it would DELETE lab rows from a genuine lab
/// report, so this list carries only spellings that cannot be anything but the
/// head of a drug list. Cost of the omission: a drug list introduced by a bare
/// `医嘱:` inside a lab-classified document still leaks (see the masking doc) —
/// under-masking is the safe direction.
const MEDS_BLOCK_HEADERS: &[&str] = &["出院医嘱", "出院带药", "带药", "用药医嘱", "Rp"];

/// Blank out the lines of every medication block in `text`, leaving every other
/// line byte-identical (line count included — `extract_labs` reads line by line
/// and ignores blanks, so nothing else about the parse shifts).
///
/// Why this is needed: [`wants_labs`] is a **whole-document** verdict, and when
/// it says yes the document's ENTIRE text goes to `extract_labs` — the 出院医嘱
/// list included. `二甲双胍 0.5g bid` then parses as a lab row (value `0.5`,
/// unit `g`) and the trend chart grows a curve for a drug.
///
/// Classification cannot be relied on to prevent that. Drop the `出院记录` title
/// from a discharge summary — routine when the source is a phone photo — and
/// `classify` falls through to `LabReport`, because the keyword chain then only
/// sees the 检验 section that is genuinely in the document. The document's own
/// section structure survives that OCR loss where the title does not, so the fix
/// keys on structure: with the mask, the titled and untitled copies of the same
/// discharge summary yield the same labs, and the drug stays a drug (the meds
/// path reads it from the very same block via [`sections_text`]).
///
/// A block runs from its header to the next header of ANY kind (or end of text).
/// The start boundary is conservative (see [`MEDS_BLOCK_HEADERS`]) and the end
/// boundary liberal, because ending a mask early only ever keeps more text: both
/// choices err toward mining too much rather than silently deleting a real row.
fn mask_meds_blocks(text: &str) -> Cow<'_, str> {
    if !text
        .lines()
        .any(|l| starts_with_header(l, MEDS_BLOCK_HEADERS))
    {
        return Cow::Borrowed(text);
    }
    let mut masking = false;
    let mut out: Vec<&str> = Vec::new();
    for line in text.lines() {
        if starts_with_header(line, MEDS_BLOCK_HEADERS) {
            masking = true;
        } else if masking && header_kind(line).is_some() {
            // Any other section header ends the drug list; keep that line.
            masking = false;
        }
        out.push(if masking { "" } else { line });
    }
    Cow::Owned(out.join("\n"))
}

/// Render a mention's dose + frequency, e.g. "0.5g bid". `None` if the mention
/// carries neither a dose nor a frequency.
fn dose_string(m: &MedObservation) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    match (m.dose_num, &m.dose_unit) {
        (Some(n), Some(u)) => parts.push(format!("{n}{u}")),
        (Some(n), None) => parts.push(format!("{n}")),
        _ => {}
    }
    if let Some(f) = &m.frequency {
        parts.push(f.clone());
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join(" "))
    }
}

/// 一个还没定下显示基准的观测点。显示基准是**序列级**决定(要看齐这条序列上所有
/// 点的印刷单位),所以两套数一直原样带到 finalize 才二选一 —— 见模块头。
struct PendingPoint {
    date: Option<NaiveDate>,
    value_printed: f64,
    unit_printed: Option<String>,
    value_canonical: Option<f64>,
    flag: Option<String>,
    source: usize,
}

struct LabBuilder {
    analyte_key: Option<String>,
    group_name: String,
    loinc: Option<String>,
    /// Whether `group_name`/`loinc` were taken from a matched observation yet.
    meta_from_match: bool,
    /// Reference range of the mention currently winning "most recent ref".
    /// 印刷套与规范套**成对**保留(同一份报告、同一个仿射映射),连同那份报告的
    /// 印刷单位 —— finalize 要用它验证「区间和点同单位」。
    ref_low: Option<f64>,
    ref_high: Option<f64>,
    ref_low_canonical: Option<f64>,
    ref_high_canonical: Option<f64>,
    ref_unit_printed: Option<String>,
    ref_date: Option<NaiveDate>,
    has_ref: bool,
    /// 词典规范单位。序列内恒定:`GroupKey::Matched`/`SelfMeasured` 按
    /// `analyte_key` 归组 ⇒ 同一个词典条目 ⇒ 同一个 `canonical_unit`;
    /// `GroupKey::Raw`(未归一化)则全程为 `None`。
    unit_canonical: Option<String>,
    points: Vec<PendingPoint>,
    any_abnormal: bool,
    /// Set once from the first observation's `self_measured` and never
    /// changed — `GroupKey::SelfMeasured` guarantees every observation folded
    /// into this builder agrees (see the struct-level doc on `AnalyteSeries`).
    self_measured: bool,
}

struct MedBuilder {
    drug_key: Option<String>,
    name: String,
    atc: Option<String>,
    meta_from_match: bool,
    start: Option<NaiveDate>,
    end: Option<NaiveDate>,
    sources: BTreeSet<usize>,
    /// Dose/date of the mention currently winning "most recent".
    best_dose: Option<String>,
    best_date: Option<NaiveDate>,
    has_best: bool,
}

struct CondBuilder {
    raw_text: String,
    onset: Option<NaiveDate>,
    icd_code: Option<String>,
    sources: BTreeSet<usize>,
}

/// Build a [`LabObservation`] from one structured self-measured value
/// (`MANUAL-ENTRY-DESIGN.md` §3.4). Unlike [`extract_labs`], this never touches
/// the document's printed text for the reference range — the synthetic text has
/// no printed range to read, and even if it did, the home/clinic distinction
/// means the report's own words would be the wrong range to trust. The range
/// (and whether there is one at all) comes exclusively from
/// [`self_entry::home_ref_range`], so an analyte with no defensible home range
/// (temperature/weight/glucose — see that function's doc) always gets `flag:
/// None` here, never a value-vs-clinic-range guess.
fn build_self_measured_observation(v: &self_entry::SelfMeasuredValue) -> LabObservation {
    let entry = terminology::dictionary_entries()
        .iter()
        .find(|e| e.key == v.analyte_key);
    let range = self_entry::home_ref_range(&v.analyte_key);
    let ref_low = range.as_ref().and_then(|r| r.low);
    let ref_high = range.as_ref().and_then(|r| r.high);
    let flag = range.as_ref().and_then(|r| {
        if r.high.is_some_and(|h| v.value > h) {
            Some("H".to_string())
        } else if r.low.is_some_and(|l| v.value < l) {
            Some("L".to_string())
        } else if r.low.is_some() || r.high.is_some() {
            Some("N".to_string())
        } else {
            None
        }
    });
    LabObservation {
        raw_name: entry
            .map(|e| e.canonical_name.clone())
            .unwrap_or_else(|| v.analyte_key.clone()),
        analyte_key: Some(v.analyte_key.clone()),
        canonical_name: entry.map(|e| e.canonical_name.clone()),
        loinc: entry.and_then(|e| e.codes.loinc.clone()),
        value_num: v.value,
        // 写入方(移动端 FFI)恒发规范单位(见 SelfMeasuredValue 的文档),此处
        // 不做换算 —— 与 value_num 相同,只是走了 value_canonical 这条通路,
        // 使下游(aggregate 的 point.value)与 extract_labs 的产物同构。
        value_canonical: Some(v.value),
        unit_raw: Some(v.unit.clone()),
        unit_canonical: Some(v.unit.clone()),
        ref_low,
        ref_high,
        // 同上:写入方恒发规范单位,印刷套与规范套在自测值上是同一对数(恒等
        // 换算)。照样两套都填满,好让 finalize 的基准选择不必为自测值开特例。
        ref_low_canonical: ref_low,
        ref_high_canonical: ref_high,
        flag,
        // 不是术语模糊匹配出来的置信度(那个字段的原意),而是"这是用户在封闭
        // 五选一里选的项,结构上精确无歧义" —— 满置信度是如实的,不是编的。
        confidence: 1.0,
        self_measured: true,
    }
}

/// 给一条序列定下**显示基准**,把「印刷套 / 规范套」两套数收敛成渲染层可以直接
/// 用的一对(点的 `value`/`unit` 与序列的 `ref_low`/`ref_high`,保证同单位)。
///
/// **这是那个「铆」——全项目唯一做这个决定的地方。** 规则、理由与边界情况见模块头
/// 的「哪一层用哪一套」。渲染层(趋势图、概览化验行、就诊摘要、医生纯文本、二维码、
/// 托管查看器)一律读结果,不许自己在 `value_num` / `value_canonical` 之间挑,
/// 也不许自己拿区间反推 —— 那正是本次缺陷的成因。
fn finalize_lab_series(b: LabBuilder) -> AnalyteSeries {
    use terminology::normalize_unit;

    // 这条线上印了几种单位?没印单位的点不参与表决 —— 它在纸上本来就没有单位,
    // 显示成一个光秃秃的数才是忠实的;但它也证明不了同质,所以只在「印了单位的
    // 点」之间比。
    let printed_units: BTreeSet<String> = b
        .points
        .iter()
        .filter_map(|p| p.unit_printed.as_deref().map(normalize_unit))
        .collect();
    let series_printed_unit = printed_units.iter().next().cloned();
    let printed_homogeneous = printed_units.len() <= 1;

    // 规范套**要么整条能用,要么整条不用**:`collect::<Option<Vec<_>>>()` 让
    // 「有一个点换不出来」直接塌成 `None`,结构上不可能只换一半。
    let canonical_values: Option<Vec<f64>> = b
        .points
        .iter()
        .map(|p| p.value_canonical)
        .collect::<Option<Vec<f64>>>()
        .filter(|_| b.unit_canonical.is_some());

    let (display_values, canonical_basis, ref_low, ref_high) = if printed_homogeneous {
        // ① 单位同质 ⇒ 显示纸上那个数。参考区间还要过一道闸:必须来自印刷单位与
        // 本序列一致的那份报告,否则宁可没有区间,也不给一个错单位的区间。
        let ref_ok = b.ref_unit_printed.as_deref().map(normalize_unit) == series_printed_unit;
        let (lo, hi) = if ref_ok {
            (b.ref_low, b.ref_high)
        } else {
            (None, None)
        };
        (
            b.points.iter().map(|p| p.value_printed).collect::<Vec<_>>(),
            false,
            lo,
            hi,
        )
    } else if let Some(vals) = canonical_values {
        // ② 混了单位但换得全 ⇒ 统一到规范单位才连得成一条线。区间同样取规范套
        // (与值同源同映射)。`values_converted` 让渲染层把「已换算」说出来。
        (vals, true, b.ref_low_canonical, b.ref_high_canonical)
    } else {
        // ③ 混了单位又换不全(未归一化的项目按原始名归组,各报告单位还不同)⇒
        // 没有任何一对区间对所有点都成立。点各自带自己的印刷值/印刷单位(自
        // 描述),**序列级区间整体留空**。
        (
            b.points.iter().map(|p| p.value_printed).collect::<Vec<_>>(),
            false,
            None,
            None,
        )
    };

    let points = b
        .points
        .into_iter()
        .zip(display_values)
        .map(|(p, value)| LabPoint {
            date: p.date,
            value,
            // 基准=规范套时用词典规范单位;否则**逐字**用这份报告印的单位 ——
            // 别的报告印了单位不代表这一份也印了,替它补一个就是改写原文。
            unit: if canonical_basis {
                b.unit_canonical.clone()
            } else {
                p.unit_printed
            },
            value_canonical: p.value_canonical,
            flag: p.flag,
            source: p.source,
        })
        .collect();

    AnalyteSeries {
        analyte_key: b.analyte_key,
        group_name: b.group_name,
        loinc: b.loinc,
        ref_low,
        ref_high,
        unit_canonical: b.unit_canonical,
        ref_low_canonical: b.ref_low_canonical,
        ref_high_canonical: b.ref_high_canonical,
        values_converted: canonical_basis,
        points,
        any_abnormal: b.any_abnormal,
        self_measured: b.self_measured,
    }
}

/// Aggregate per-document extractions across `docs` into the derived layer.
pub fn aggregate(docs: &[SourceDoc<'_>]) -> AggregatedClinical {
    let mut labs: HashMap<GroupKey, LabBuilder> = HashMap::new();
    let mut meds: HashMap<GroupKey, MedBuilder> = HashMap::new();
    let mut conds: HashMap<String, CondBuilder> = HashMap::new();

    for doc in docs {
        let dt = doc.doc_type.as_deref();
        // 手动录入(MANUAL-ENTRY-DESIGN.md §3.4/§3.6):`self_measurement`/`note`
        // 文档没有可信的诊断/用药信号 —— `self_measurement` 的合成文本本来就不会
        // 触发 meds/conditions 正则,`note` 是用户随手写的一句话("头晕,是不是又
        // 高血压了"),把它喂给 extract_conditions 有真实概率读出一条无凭无据的
        // 诊断。两类文档都显式跳过 meds/conditions —— 比"恰好没触发"更安全、更好
        // 审计,且对每一个调用方(手机端投影、`assemble_summary`/加密分享/二维码)
        // 统一生效,不依赖每个调用方自己记得先过滤。
        let is_manual_entry = matches!(dt, Some("self_measurement") | Some("note"));

        // --- labs: self_measurement 文档直接读回结构化载荷(不跑 extract_labs——
        // 那是给 OCR 报告用的模糊正则,我们自己写的、自己读的格式不需要模糊匹配);
        // 其余按原规则:whole-doc for lab reports,否则只从 embedded 化验 sections
        // 抽(section-scoped,so a discharge summary's prose 血压 stays out) —— #148。
        // whole-doc 那条路上先把 出院医嘱/带药 段屏蔽掉:一行药读起来就是一行化验,
        // 而 `wants_labs` 会对一份标题被 OCR 丢掉的出院小结点头 —— 见 mask_meds_blocks。 ---
        let doc_labs: Vec<LabObservation> = if dt == Some("self_measurement") {
            self_entry::parse_self_measurement_payload(doc.text)
                .unwrap_or_default()
                .iter()
                .map(build_self_measured_observation)
                .collect()
        } else if wants_labs(dt) {
            extract_labs(&mask_meds_blocks(doc.text))
        } else {
            sections_text(doc.text, SecKind::Labs)
                .iter()
                .flat_map(|s| extract_labs(s))
                .collect()
        };
        for obs in doc_labs {
            let matched = obs.analyte_key.is_some();
            // 自测值与医院值永不同组:即使 analyte_key 相同(如同是
            // "bp_systolic"),`self_measured` 把它们分进结构上不同的 GroupKey
            // 分支 —— 见 GroupKey 的文档。
            let key = match (&obs.analyte_key, obs.self_measured) {
                (Some(k), true) => GroupKey::SelfMeasured(k.clone()),
                (Some(k), false) => GroupKey::Matched(k.clone()),
                (None, _) => GroupKey::Raw(obs.raw_name.clone()),
            };
            // 两套数原样入库,基准留到 finalize 选 —— 见模块头「哪一层用哪一套」。
            let point = PendingPoint {
                date: doc.date,
                value_printed: obs.value_num,
                unit_printed: obs.unit_raw.clone(),
                value_canonical: obs.value_canonical,
                flag: obs.flag.clone(),
                source: doc.index,
            };
            let abnormal = matches!(obs.flag.as_deref(), Some("H") | Some("L"));
            let b = labs.entry(key).or_insert_with(|| LabBuilder {
                analyte_key: obs.analyte_key.clone(),
                group_name: obs.raw_name.clone(),
                loinc: None,
                meta_from_match: false,
                ref_low: None,
                ref_high: None,
                ref_low_canonical: None,
                ref_high_canonical: None,
                ref_unit_printed: None,
                ref_date: None,
                has_ref: false,
                unit_canonical: None,
                points: Vec::new(),
                any_abnormal: false,
                self_measured: obs.self_measured,
            });
            // 序列内恒定(见字段文档);第一个换算得出来的点供出即可。
            if b.unit_canonical.is_none() {
                b.unit_canonical = obs.unit_canonical.clone();
            }
            // First matched observation supplies the display name + LOINC.
            if !b.meta_from_match && matched {
                if let Some(name) = &obs.canonical_name {
                    b.group_name = name.clone();
                }
                b.loinc = obs.loinc.clone();
                b.meta_from_match = true;
            }
            // Keep the ref range of the most-recently-dated mention that carried
            // one; ties/undated keep the first seen (stable). Fallback: any.
            if obs.ref_low.is_some() || obs.ref_high.is_some() {
                let replace = if !b.has_ref {
                    true
                } else {
                    match (doc.date, b.ref_date) {
                        (Some(m), Some(cur)) => m > cur,
                        (Some(_), None) => true,
                        (None, _) => false,
                    }
                };
                if replace {
                    b.ref_low = obs.ref_low;
                    b.ref_high = obs.ref_high;
                    // 印刷套与规范套**同时**换掉,连同这份报告的印刷单位。三者
                    // 是一个整体:任何一个单独更新都会造出「值换了区间没换」。
                    b.ref_low_canonical = obs.ref_low_canonical;
                    b.ref_high_canonical = obs.ref_high_canonical;
                    b.ref_unit_printed = obs.unit_raw.clone();
                    b.ref_date = doc.date;
                    b.has_ref = true;
                }
            }
            b.any_abnormal |= abnormal;
            b.points.push(point);
        }

        // --- meds (only from prescriptions; see wants_meds) ---
        // --- meds: whole-doc for prescriptions; else only from embedded 用药/带药
        // sections (a discharge summary's 出院医嘱 list) —— #148. 手动录入文档
        // (self_measurement/note) 显式跳过,见本函数开头 is_manual_entry 的注释。
        let doc_meds = if is_manual_entry {
            Vec::new()
        } else if wants_meds(dt) {
            extract_meds(doc.text)
        } else {
            sections_text(doc.text, SecKind::Meds)
                .iter()
                .flat_map(|s| {
                    // 出院医嘱等常把多药写在**一行**、用「、;,。」分隔,且带用法动词
                    // (继续口服阿司匹林…)。extract_meds 按行抽、#141 整句标点 guard 会拒
                    // 整行。故:先按分隔符拆行,再剥去行首用法动词,让每个药各成干净一行
                    // (散文碎片如「低盐低脂饮食」无剂量,仍被 guard 正确拒掉)。
                    let normalized: String = s
                        .replace(['、', '；', ';', '，', ',', '。'], "\n")
                        .lines()
                        .map(|l| {
                            let t = l.trim_start();
                            for p in ["继续口服", "继续服用", "继续", "口服", "服用", "给予", "予"]
                            {
                                if let Some(rest) = t.strip_prefix(p) {
                                    return rest;
                                }
                            }
                            t
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    extract_meds(&normalized)
                })
                .collect()
        };
        for obs in doc_meds {
            let matched = obs.drug_key.is_some();
            let key = match &obs.drug_key {
                Some(k) => GroupKey::Matched(k.clone()),
                None => GroupKey::Raw(obs.raw_name.clone()),
            };
            let this_dose = dose_string(&obs);
            let b = meds.entry(key).or_insert_with(|| MedBuilder {
                drug_key: obs.drug_key.clone(),
                name: obs.raw_name.clone(),
                atc: None,
                meta_from_match: false,
                start: None,
                end: None,
                sources: BTreeSet::new(),
                best_dose: None,
                best_date: None,
                has_best: false,
            });
            if !b.meta_from_match && matched {
                if let Some(name) = &obs.canonical_name {
                    b.name = name.clone();
                }
                b.atc = obs.atc.clone();
                b.meta_from_match = true;
            }
            b.start = min_date(b.start, doc.date);
            b.end = max_date(b.end, doc.date);
            b.sources.insert(doc.index);
            // Keep the dose of the most-recently-dated mention; ties/undated keep
            // the first seen (stable). Fallback: any mention (the first one).
            let replace = if !b.has_best {
                true
            } else {
                match (doc.date, b.best_date) {
                    (Some(m), Some(cur)) => m > cur,
                    (Some(_), None) => true,
                    (None, _) => false,
                }
            };
            if replace {
                b.best_date = doc.date;
                b.best_dose = this_dose;
                b.has_best = true;
            }
        }

        // --- conditions --- 手动录入文档跳过(见 is_manual_entry 的注释):这里
        // 原本对每份文档无条件跑,没有 doc_type 门控,一条随手记的笔记("头晕,
        // 是不是又高血压了")会被读成一条无凭无据的诊断。
        if is_manual_entry {
            continue;
        }
        for c in extract_conditions(doc.text) {
            let raw = c.raw_text.trim().to_string();
            if raw.is_empty() {
                continue;
            }
            let b = conds.entry(raw.clone()).or_insert_with(|| CondBuilder {
                raw_text: raw,
                onset: None,
                icd_code: None,
                sources: BTreeSet::new(),
            });
            b.onset = min_date(b.onset, doc.date);
            // First document that printed a code for this diagnosis wins.
            if b.icd_code.is_none() {
                b.icd_code = c.icd_code;
            }
            b.sources.insert(doc.index);
        }
    }

    // --- finalize labs: chronological points, deterministic series order ---
    let mut lab_out: Vec<AnalyteSeries> = labs
        .into_values()
        .map(|mut b| {
            b.points
                .sort_by(|x, y| cmp_date_none_last(&x.date, &y.date));
            finalize_lab_series(b)
        })
        .collect();
    // (group_name, analyte_key) fully determinizes order despite HashMap.
    lab_out.sort_by(|a, b| {
        a.group_name
            .cmp(&b.group_name)
            .then_with(|| a.analyte_key.cmp(&b.analyte_key))
    });

    let mut med_out: Vec<MedSpan> = meds
        .into_values()
        .map(|b| MedSpan {
            drug_key: b.drug_key,
            name: b.name,
            atc: b.atc,
            latest_dose: b.best_dose,
            start: b.start,
            end: b.end,
            status: "active".to_string(),
            sources: b.sources.into_iter().collect(),
        })
        .collect();
    med_out.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.drug_key.cmp(&b.drug_key))
    });

    let mut cond_out: Vec<AggregatedCondition> = conds
        .into_values()
        .map(|b| AggregatedCondition {
            raw_text: b.raw_text,
            onset: b.onset,
            icd_code: b.icd_code,
            sources: b.sources.into_iter().collect(),
        })
        .collect();
    cond_out.sort_by(|a, b| {
        cmp_date_none_last(&a.onset, &b.onset).then_with(|| a.raw_text.cmp(&b.raw_text))
    });

    AggregatedClinical {
        labs: lab_out,
        meds: med_out,
        conditions: cond_out,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, day: u32) -> Option<NaiveDate> {
        NaiveDate::from_ymd_opt(y, m, day)
    }

    fn lab_doc(index: usize, date: Option<NaiveDate>, text: &str) -> SourceDoc<'_> {
        SourceDoc {
            index,
            doc_type: Some("lab_report".into()),
            title: Some("生化".into()),
            date,
            text,
        }
    }

    fn series<'a>(agg: &'a AggregatedClinical, key: &str) -> &'a AnalyteSeries {
        agg.labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some(key))
            .unwrap_or_else(|| panic!("no series for {key}"))
    }

    /// 「值和区间必须同单位」——这是本模块对每一个渲染层的硬承诺。任何一条序列
    /// 都要过这一关:序列级区间存在时,它必须和**每一个**点的 `value` 同单位。
    /// 单位字符串对不上就当场炸,而不是让托管查看器去替我们发现。
    fn assert_ref_and_points_share_a_unit(s: &AnalyteSeries) {
        if s.ref_low.is_none() && s.ref_high.is_none() {
            return;
        }
        let units: BTreeSet<Option<String>> = s
            .points
            .iter()
            .map(|p| p.unit.as_deref().map(terminology::normalize_unit))
            .collect();
        assert!(
            units.len() <= 1,
            "{}: 序列带着参考区间,点却有多种单位 {:?} —— 这正是缺陷的形状",
            s.group_name,
            units
        );
    }

    /// **缺陷钉子(2026-08-05)。** 一份完全正常的报告 `肌酐: 1.2 mg/dL (参考
    /// 0.6-1.3)`,曾让 `aggregate` 产出 `value=106.104 umol/L` 配 `ref=[0.6,1.3]`
    /// (mg/dL 的区间,没换算)。托管查看器 `sumFlag` 自己重算,得出「高出上限 80
    /// 倍」= 终末期肾衰,而同一份载荷里 `warn:false`,自相矛盾。
    ///
    /// 新契约(见模块头「哪一层用哪一套」①):单位同质的序列显示**印刷套** ——
    /// 患者手里那张纸印的就是 `1.2 mg/dL 参考 0.6-1.3`,app 上必须能对得上。
    #[test]
    fn homogeneous_series_ships_paper_values_with_paper_refs() {
        let text = "肌酐: 1.2 mg/dL (参考 0.6-1.3)";
        let docs = vec![lab_doc(0, d(2026, 8, 1), text)];
        let agg = aggregate(&docs);
        let s = series(&agg, "creatinine");

        assert_eq!(s.points.len(), 1);
        assert_eq!(s.points[0].value, 1.2, "患者要看到纸上那个数");
        assert_eq!(s.points[0].unit.as_deref(), Some("mg/dL"));
        assert_eq!((s.ref_low, s.ref_high), (Some(0.6), Some(1.3)));
        assert!(!s.values_converted, "没换算就不许说换算了");
        assert_ref_and_points_share_a_unit(s);

        // 锚仍在,且规范套自己也成对同单位 —— 跨院比较照样有得用。
        assert_eq!(s.unit_canonical.as_deref(), Some("umol/L"));
        let vc = s.points[0].value_canonical.expect("锚必须在");
        let (lo, hi) = (
            s.ref_low_canonical.expect("锚的区间必须在"),
            s.ref_high_canonical.expect("锚的区间必须在"),
        );
        assert!((vc - 106.104).abs() < 0.01, "{vc}");
        assert!(
            (lo - 53.052).abs() < 0.01 && (hi - 114.946).abs() < 0.01,
            "{lo} {hi}"
        );
        // 下游任何「值 vs 区间」的重算,两套都必须得出「正常」。
        assert!(
            s.points[0].value >= s.ref_low.unwrap() && s.points[0].value <= s.ref_high.unwrap()
        );
        assert!(vc >= lo && vc <= hi);
        assert_eq!(s.points[0].flag.as_deref(), Some("N"));
    }

    /// 模块头②:两家医院用了不同单位,一条线上没法同时画两种单位 ⇒ 轴、点、
    /// 参考带**一起**换到规范单位,并把「已换算」这件事说出来。
    #[test]
    fn mixed_unit_series_converts_values_and_refs_together() {
        let docs = vec![
            lab_doc(0, d(2026, 1, 1), "肌酐: 1.2 mg/dL (参考 0.6-1.3)"),
            lab_doc(1, d(2026, 6, 1), "肌酐: 96 umol/L (参考 59-104)"),
        ];
        let agg = aggregate(&docs);
        let s = series(&agg, "creatinine");

        assert!(s.values_converted, "混单位必须走规范套,而且必须说出来");
        assert_eq!(s.points.len(), 2);
        for p in &s.points {
            assert_eq!(p.unit.as_deref(), Some("umol/L"), "轴只能有一个单位");
        }
        assert!(
            (s.points[0].value - 106.104).abs() < 0.01,
            "{:?}",
            s.points[0].value
        );
        assert_eq!(s.points[1].value, 96.0);
        // 区间取的是最近一份报告(2026-06,umol/L),规范套 = 印刷套(恒等换算)。
        assert_eq!((s.ref_low, s.ref_high), (Some(59.0), Some(104.0)));
        assert_ref_and_points_share_a_unit(s);
    }

    /// 反过来:最近一份报告是 mg/dL,区间也必须跟着换到规范单位,不能把
    /// `[0.6, 1.3]` 配到 umol/L 的点上 —— 那就是原缺陷换了个方向再来一次。
    #[test]
    fn mixed_unit_series_converts_the_ref_of_the_newest_report_too() {
        let docs = vec![
            lab_doc(0, d(2026, 1, 1), "肌酐: 96 umol/L (参考 59-104)"),
            lab_doc(1, d(2026, 6, 1), "肌酐: 1.2 mg/dL (参考 0.6-1.3)"),
        ];
        let agg = aggregate(&docs);
        let s = series(&agg, "creatinine");
        assert!(s.values_converted);
        let (lo, hi) = (
            s.ref_low.expect("必须有区间"),
            s.ref_high.expect("必须有区间"),
        );
        assert!(
            (lo - 53.052).abs() < 0.01 && (hi - 114.946).abs() < 0.01,
            "参考区间没跟着换算:[{lo}, {hi}]"
        );
        assert_ref_and_points_share_a_unit(s);
    }

    /// 模块头③:未归一化的项目按原始名归组,两份报告单位还不同 ⇒ 换不出规范套,
    /// 也没有任何一对区间对所有点都成立。**宁可没有区间,也不给一个错单位的区间。**
    #[test]
    fn incoherent_series_ships_no_series_level_ref() {
        let docs = vec![
            lab_doc(0, d(2026, 1, 1), "神秘指标XYZ   12.3   mg/L   0-5"),
            lab_doc(1, d(2026, 6, 1), "神秘指标XYZ   0.8    g/L    0-0.005"),
        ];
        let agg = aggregate(&docs);
        let s = agg
            .labs
            .iter()
            .find(|s| s.group_name.contains("神秘指标XYZ"))
            .expect("未归一化的序列也要在");
        assert_eq!(s.points.len(), 2, "点一个都不能丢");
        assert_eq!(s.analyte_key, None);
        assert_eq!(
            (s.ref_low, s.ref_high),
            (None, None),
            "单位对不上就不许给序列级区间"
        );
        assert!(!s.values_converted, "换都换不出来,不许说换算了");
        // 点各自带自己印刷的单位,自描述,不被改写。
        assert_eq!(s.points[0].unit.as_deref(), Some("mg/L"));
        assert_eq!(s.points[1].unit.as_deref(), Some("g/L"));
        assert_ref_and_points_share_a_unit(s);
    }

    /// 参考区间的那道闸:区间来自一份**没印单位**的报告,而序列的点印着 mg/dL
    /// ⇒ 这对数字是几的量纲无从判断,留空。
    #[test]
    fn series_ref_is_dropped_when_its_report_printed_no_unit() {
        let docs = vec![
            lab_doc(0, d(2026, 6, 1), "肌酐: 1.2 mg/dL"),
            // 更晚的一份带区间但没有单位 —— 它会赢下「最近的区间」。
            lab_doc(1, d(2026, 7, 1), "肌酐: 1.1 (参考 0.6-1.3)"),
        ];
        let agg = aggregate(&docs);
        let s = series(&agg, "creatinine");
        assert_eq!(
            (s.ref_low, s.ref_high),
            (None, None),
            "量纲不明的区间不许发给渲染层"
        );
        assert_ref_and_points_share_a_unit(s);
    }

    /// 自测值(家测血压/血糖…)本来就恒发规范单位,两套是同一对数。改动不能把它
    /// 的参考区间弄丢 —— 那是 `self_entry::home_ref_range` 给的家测阈值。
    #[test]
    fn self_measured_series_keeps_its_home_ref_range() {
        let text = self_entry::render_self_measurement_text(
            &["收缩压 128 mmHg".to_string()],
            &[self_entry::SelfMeasuredValue {
                analyte_key: "bp_systolic".into(),
                value: 128.0,
                unit: "mmHg".into(),
            }],
        );
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("self_measurement".into()),
            title: None,
            date: d(2026, 6, 1),
            text: &text,
        }];
        let agg = aggregate(&docs);
        let s = series(&agg, "bp_systolic");
        assert!(s.self_measured);
        assert_eq!(s.points[0].value, 128.0);
        assert!(s.ref_high.is_some(), "家测阈值不能丢");
        assert_eq!(s.ref_high, s.ref_high_canonical, "恒等换算,两套必须一致");
        assert!(!s.values_converted);
        assert_ref_and_points_share_a_unit(s);
    }

    #[test]
    fn discharge_summary_embedded_meds_recovered_via_section() {
        // #148:出院小结 doc_type 不是 prescription,现状 doc_type 门控会丢它的「出院
        // 医嘱」带药。按段路由应从 用药段 抽出这 4 个药(逗号分隔在一行)。
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("discharge_summary".into()),
            title: None,
            date: d(2023, 5, 1),
            text: "出院诊断:急性脑梗死\n出院医嘱:低盐低脂饮食;继续口服阿司匹林 100mg qd、阿托伐他汀 20mg qn、氨氯地平 5mg qd、二甲双胍 0.5g bid;门诊随访。",
        }];
        let agg = aggregate(&docs);
        let keys: Vec<&str> = agg
            .meds
            .iter()
            .filter_map(|m| m.drug_key.as_deref())
            .collect();
        for want in ["aspirin", "atorvastatin", "amlodipine", "metformin"] {
            assert!(
                keys.contains(&want),
                "缺药 {want};实际 keys={keys:?} names={:?}",
                agg.meds.iter().map(|m| &m.name).collect::<Vec<_>>()
            );
        }
    }

    /// The section header decides whether a whole block of the document is read
    /// at all, so a header spelled with ordinary Chinese typesetting must still
    /// be recognized. `出院　医嘱` (ideographic space, common in printed forms)
    /// and `出 院 医 嘱` (OCR splitting CJK) used to fail the prefix test, and
    /// every discharge medication in the document vanished from the summary
    /// without a trace — no warning, no partial result.
    #[test]
    fn section_header_survives_typeset_spacing_and_fullwidth() {
        for header in [
            "出院医嘱:",
            "出院\u{3000}医嘱:", // ideographic space
            "出 院 医 嘱:",      // OCR split
            "ＲＰ:",             // full-width Rp
        ] {
            let text =
                format!("出院记录\n\n{header}\n1.二甲双胍 0.5g 每日两次\n2.阿托伐他汀 20mg 每晚");
            let docs = vec![SourceDoc {
                index: 0,
                doc_type: Some("discharge_summary".into()),
                title: None,
                date: d(2023, 5, 1),
                text: &text,
            }];
            let agg = aggregate(&docs);
            let keys: Vec<&str> = agg
                .meds
                .iter()
                .filter_map(|m| m.drug_key.as_deref())
                .collect();
            assert!(
                keys.contains(&"metformin") && keys.contains(&"atorvastatin"),
                "header {header:?} lost the whole medication block; got {keys:?}"
            );
        }
    }

    /// The mirror-image failure, and the more dangerous one: a line that is *not*
    /// a header must not become one. Headers bound sections, so a false positive
    /// truncates the block and silently deletes everything after it.
    ///
    /// Both cases below are real report content, not adversarial strings. `RPR`
    /// (梅毒快速血浆反应素) is a routine row on Chinese admission and pre-op
    /// panels and begins with the letters of the `Rp` prescription marker once
    /// case is folded; the prose line is what OCR produces when it splits CJK,
    /// which is the same phenomenon the sibling test above relies on.
    #[test]
    fn ordinary_content_does_not_become_a_section_header() {
        let base = "血红蛋白 96 g/L 130-175 ↓\n肌酐 145 umol/L 57-97 ↑\n血钾 4.1 mmol/L 3.5-5.3\n";
        for intruder in ["RPR 阴性", "用 药 后 患者症状缓解", "建 议 复查肝功能"]
        {
            let text = format!("出院记录\n\n检验结果:\n血红蛋白 96 g/L 130-175 ↓\n{intruder}\n肌酐 145 umol/L 57-97 ↑\n血钾 4.1 mmol/L 3.5-5.3\n");
            let mk = |t: &str| {
                let docs = vec![SourceDoc {
                    index: 0,
                    doc_type: Some("discharge_summary".into()),
                    title: None,
                    date: d(2026, 5, 1),
                    text: t,
                }];
                let agg = aggregate(&docs);
                let mut n: Vec<String> = agg.labs.iter().map(|s| s.group_name.clone()).collect();
                n.sort();
                n
            };
            let control = mk(&format!("出院记录\n\n检验结果:\n{base}"));
            assert_eq!(
                mk(&text),
                control,
                "line {intruder:?} was read as a section header and truncated the block"
            );
        }
    }

    /// …and the guard against false headers must not cost real ones. Requiring a
    /// delimiter right after the prefix looked tidy and silently dropped every
    /// one of these — each an ordinary way a Chinese discharge summary heads its
    /// medication block, and each recognized before the change.
    #[test]
    fn header_prefix_tolerates_the_usual_trailing_text() {
        for header in [
            "出院医嘱如下:",
            "出院带药(共2种):",
            "出院医嘱(2种)",
            "带药如下",
            "出院医嘱 1.",
            "用药医嘱 -",
        ] {
            let text =
                format!("出院记录\n\n{header}\n1.二甲双胍 0.5g 每日两次\n2.阿托伐他汀 20mg 每晚");
            let docs = vec![SourceDoc {
                index: 0,
                doc_type: Some("discharge_summary".into()),
                title: None,
                date: d(2023, 5, 1),
                text: &text,
            }];
            let agg = aggregate(&docs);
            let keys: Vec<&str> = agg
                .meds
                .iter()
                .filter_map(|m| m.drug_key.as_deref())
                .collect();
            assert!(
                keys.contains(&"metformin"),
                "header {header:?} lost the medication block; got {keys:?}"
            );
        }
    }

    /// Classify `text` the way the real callers do (`DocType::as_str()`
    /// lowercased), aggregate it as a single document, and report what came out.
    fn parse_as_classified(text: &str) -> (Vec<String>, Vec<String>) {
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some(crate::classify(text).as_str().to_lowercase()),
            title: None,
            date: d(2026, 5, 1),
            text,
        }];
        let agg = aggregate(&docs);
        (
            agg.labs.iter().map(|s| s.group_name.clone()).collect(),
            agg.meds.iter().map(|m| m.name.clone()).collect(),
        )
    }

    /// The reported defect, end to end through `classify` + `aggregate`.
    ///
    /// A discharge summary parses correctly only as long as OCR preserves its
    /// `出院记录` title: that keyword is what puts `classify` on the
    /// `DischargeSummary` branch, which makes `wants_labs` false, which routes
    /// lab mining through the 检验 section only. Lose the title — routine on a
    /// phone photo, where the measured extraction rate is about 55% — and the
    /// keyword chain sees only the 检验 section that really is there, answers
    /// `LabReport`, and `wants_labs` hands the WHOLE document to `extract_labs`.
    /// `二甲双胍 0.5g bid` then comes back as an analyte (value 0.5, unit g) and
    /// the trend chart draws a lab curve for a drug.
    ///
    /// The assertion is deliberately "both spellings agree" rather than a fixed
    /// expected `DocType`: what has to hold is that the extraction stops
    /// depending on a title surviving OCR. If `classify` is later improved, this
    /// test keeps passing for the right reason.
    #[test]
    fn losing_the_title_does_not_turn_a_discharge_drug_into_a_lab_curve() {
        const BODY: &str = "检验结果:\n血红蛋白 122 g/L 120-160\n出院医嘱:\n二甲双胍 0.5g bid\n";
        let (titled_labs, titled_meds) = parse_as_classified(&format!("出院记录\n{BODY}"));
        let (untitled_labs, untitled_meds) = parse_as_classified(BODY);

        assert_eq!(
            titled_labs,
            vec!["血红蛋白".to_string()],
            "titled discharge summary must yield exactly the one real analyte"
        );
        assert_eq!(
            untitled_labs, titled_labs,
            "dropping the 出院记录 title changed which analytes are charted — \
             二甲双胍 leaks in as a lab when classify falls through to LabReport"
        );
        // …and the drug is still a drug on both paths, not merely deleted.
        for meds in [&titled_meds, &untitled_meds] {
            assert!(
                meds.iter().any(|m| m.contains("二甲双胍")),
                "the masked 出院医嘱 block must still be mined for meds; got {meds:?}"
            );
        }
    }

    /// The mirror-image risk of the mask, and the one that would actually hurt a
    /// patient: masking must never eat rows out of a genuine lab report.
    ///
    /// Every line below is real 检验报告单 furniture that *starts with* a
    /// medication keyword. `医嘱号` / `医嘱医生` are printed fields on Chinese lab
    /// forms and begin with `医嘱`; `用药指导` begins with `用药`; `RPR`
    /// (梅毒快速血浆反应素) begins with the letters of the `Rp` marker once case is
    /// folded. If any of them opened a mask, every row after it would silently
    /// vanish from the chart — strictly worse than the leak being fixed.
    #[test]
    fn lab_report_furniture_never_masks_real_rows() {
        let rows = "血红蛋白 122 g/L 120-160\n肌酐 145 umol/L 57-97 ↑\n血钾 4.1 mmol/L 3.5-5.3";
        let control = parse_as_classified(&format!("检验报告单\n{rows}")).0;
        assert_eq!(control.len(), 3, "control must find all three analytes");
        for intruder in [
            "医嘱号:12345",
            "医嘱医生:王医生",
            "用药指导:空腹采血",
            "RPR 阴性",
            "用 药 后 患者症状缓解",
        ] {
            let got = parse_as_classified(&format!("检验报告单\n{intruder}\n{rows}")).0;
            assert_eq!(
                got, control,
                "line {intruder:?} was read as a drug block and deleted lab rows"
            );
        }
    }

    /// A masked drug block ends where the next section begins — the 检验 rows
    /// printed *after* an 出院医嘱 list are still charted. Getting this wrong
    /// (masking to end of document) would trade the leak for lost data.
    #[test]
    fn masking_stops_at_the_next_section_header() {
        let text = "检验结果:\n血红蛋白 122 g/L 120-160\n\
                    出院医嘱:\n二甲双胍 0.5g bid\n\
                    检验项目:\n肌酐 145 umol/L 57-97\n\
                    出院诊断:2型糖尿病\n";
        let (labs, _) = parse_as_classified(text);
        assert_eq!(labs, vec!["肌酐".to_string(), "血红蛋白".to_string()]);
    }

    /// Callers that don't classify at all (`doc_type: None`) take the same
    /// permissive whole-document path, so they used to hit the identical trap.
    /// The mask is on that path too, which is why `wants_labs`'s deliberate
    /// permissiveness for `None` could be left alone.
    #[test]
    fn untyped_documents_are_protected_too() {
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: None,
            title: None,
            date: d(2026, 5, 1),
            text: "血红蛋白 122 g/L 120-160\n出院带药:\n二甲双胍 0.5g bid\n",
        }];
        let agg = aggregate(&docs);
        let labs: Vec<&str> = agg.labs.iter().map(|s| s.group_name.as_str()).collect();
        assert_eq!(labs, vec!["血红蛋白"]);
    }

    /// A document with no drug block must come out of the mask untouched — the
    /// guard is not allowed to cost anything on the common case. `二甲双胍` here
    /// sits in bare prose with no 医嘱 header, so it is NOT in scope for this fix
    /// and is expected to be read exactly as before (see also
    /// `output_vectors_are_in_deterministic_order`).
    #[test]
    fn documents_without_a_drug_block_are_unchanged() {
        assert!(matches!(
            mask_meds_blocks("检验结果:\n血红蛋白 122 g/L 120-160\n二甲双胍 0.5g bid\n"),
            Cow::Borrowed(_)
        ));
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("lab_report".into()),
            title: None,
            date: d(2026, 5, 1),
            text: "检验报告单\n血红蛋白 122 g/L 120-160\n肌酐 145 umol/L 57-97",
        }];
        let agg = aggregate(&docs);
        let labs: Vec<&str> = agg.labs.iter().map(|s| s.group_name.as_str()).collect();
        assert_eq!(labs, vec!["肌酐", "血红蛋白"]);
    }

    /// The typeset/OCR spellings the sibling meds tests rely on must open a mask
    /// too — otherwise a `出院　医嘱` block leaks into the chart while the very
    /// same block is correctly mined for meds.
    #[test]
    fn mask_accepts_the_same_header_spellings_as_the_meds_path() {
        for header in [
            "出院医嘱:",
            "出院\u{3000}医嘱:", // ideographic space
            "出 院 医 嘱:",      // OCR split
            "出院医嘱如下:",
            "出院带药(共2种):",
            "带药如下",
            "ＲＰ:", // full-width Rp
        ] {
            let text = format!("检验结果:\n血红蛋白 122 g/L 120-160\n{header}\n二甲双胍 0.5g bid");
            let (labs, _) = parse_as_classified(&text);
            assert_eq!(
                labs,
                vec!["血红蛋白".to_string()],
                "header {header:?} did not mask its drug block; got {labs:?}"
            );
        }
    }

    #[test]
    fn same_analyte_across_docs_forms_one_sorted_series() {
        // 肌酐 (creatinine) in three docs, dates out of order; one abnormal (H).
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: None,
                title: None,
                date: d(2023, 6, 1),
                text: "肌酐 96 μmol/L 59-104",
            },
            SourceDoc {
                index: 1,
                doc_type: None,
                title: None,
                date: d(2022, 1, 1),
                text: "肌酐 88 μmol/L 59-104",
            },
            SourceDoc {
                index: 2,
                doc_type: None,
                title: None,
                date: d(2023, 1, 1),
                text: "肌酐 120 μmol/L 59-104", // > 104 -> H
            },
        ];
        let agg = aggregate(&docs);
        assert_eq!(agg.labs.len(), 1);
        let s = &agg.labs[0];
        assert_eq!(s.analyte_key.as_deref(), Some("creatinine"));
        assert!(s.loinc.is_some());
        assert_eq!(s.points.len(), 3);
        // Sorted ascending by date.
        assert_eq!(s.points[0].date, d(2022, 1, 1));
        assert_eq!(s.points[1].date, d(2023, 1, 1));
        assert_eq!(s.points[2].date, d(2023, 6, 1));
        assert_eq!(s.points[0].source, 1);
        assert!(s.any_abnormal, "the 120 point is flagged H");
    }

    #[test]
    fn matched_and_unmatched_analytes_do_not_merge() {
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: None,
                title: None,
                date: d(2024, 1, 1),
                text: "肌酐 88 μmol/L 59-104",
            },
            SourceDoc {
                index: 1,
                doc_type: None,
                title: None,
                date: d(2024, 2, 1),
                text: "神秘指标XYZ 12.3 mg/L 0-5",
            },
        ];
        let agg = aggregate(&docs);
        assert_eq!(agg.labs.len(), 2);
        let matched = agg
            .labs
            .iter()
            .find(|s| s.analyte_key.is_some())
            .expect("matched series");
        assert_eq!(matched.analyte_key.as_deref(), Some("creatinine"));
        let unmatched = agg
            .labs
            .iter()
            .find(|s| s.analyte_key.is_none())
            .expect("unmatched series");
        assert_eq!(unmatched.group_name, "神秘指标XYZ");
        assert!(unmatched.loinc.is_none());
        assert_eq!(unmatched.points.len(), 1);
    }

    #[test]
    fn same_drug_across_docs_forms_one_span() {
        let docs = vec![
            SourceDoc {
                index: 3,
                doc_type: None,
                title: None,
                date: d(2023, 1, 1),
                text: "二甲双胍 0.5g bid",
            },
            SourceDoc {
                index: 7,
                doc_type: None,
                title: None,
                date: d(2024, 3, 1),
                text: "二甲双胍 0.85g tid",
            },
        ];
        let agg = aggregate(&docs);
        assert_eq!(agg.meds.len(), 1);
        let m = &agg.meds[0];
        assert_eq!(m.drug_key.as_deref(), Some("metformin"));
        assert_eq!(m.start, d(2023, 1, 1));
        assert_eq!(m.end, d(2024, 3, 1));
        assert_eq!(m.sources, vec![3, 7]);
        assert_eq!(m.status, "active");
        // Dose from the later mention.
        assert_eq!(m.latest_dose.as_deref(), Some("0.85g tid"));
    }

    #[test]
    fn conditions_dedup_with_earliest_onset_and_merged_sources() {
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: None,
                title: None,
                date: d(2024, 5, 1),
                text: "出院诊断:2型糖尿病",
            },
            SourceDoc {
                index: 1,
                doc_type: None,
                title: None,
                date: d(2023, 2, 1),
                text: "入院诊断:2型糖尿病",
            },
        ];
        let agg = aggregate(&docs);
        assert_eq!(agg.conditions.len(), 1);
        let c = &agg.conditions[0];
        assert_eq!(c.raw_text, "2型糖尿病");
        assert_eq!(c.onset, d(2023, 2, 1)); // earliest
        assert_eq!(c.sources, vec![0, 1]);
    }

    #[test]
    fn none_dated_lab_point_sorts_last_but_is_kept() {
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: None,
                title: None,
                date: None,
                text: "肌酐 88 μmol/L 59-104",
            },
            SourceDoc {
                index: 1,
                doc_type: None,
                title: None,
                date: d(2024, 1, 1),
                text: "肌酐 90 μmol/L 59-104",
            },
        ];
        let agg = aggregate(&docs);
        assert_eq!(agg.labs.len(), 1);
        let s = &agg.labs[0];
        assert_eq!(s.points.len(), 2);
        assert_eq!(s.points[0].date, d(2024, 1, 1));
        assert_eq!(s.points[1].date, None); // undated point last, retained
        assert_eq!(s.points[1].source, 0);
    }

    #[test]
    fn output_vectors_are_in_deterministic_order() {
        // Labs ordered by group_name, meds by name, conditions by onset then text.
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: None,
            title: None,
            date: d(2024, 1, 1),
            text: "\
肌酐 88 μmol/L 59-104
血红蛋白 140 g/L 130-175
二甲双胍 0.5g bid
阿托伐他汀钙片 20mg qn
出院诊断:高血压病；2型糖尿病
",
        }];
        let agg = aggregate(&docs);

        let lab_names: Vec<&str> = agg.labs.iter().map(|s| s.group_name.as_str()).collect();
        let mut sorted_labs = lab_names.clone();
        sorted_labs.sort();
        assert_eq!(lab_names, sorted_labs, "labs must be sorted by group_name");

        let med_names: Vec<&str> = agg.meds.iter().map(|m| m.name.as_str()).collect();
        let mut sorted_meds = med_names.clone();
        sorted_meds.sort();
        assert_eq!(med_names, sorted_meds, "meds must be sorted by name");

        // Both conditions share the doc's onset, so they order by raw_text.
        let cond_texts: Vec<&str> = agg.conditions.iter().map(|c| c.raw_text.as_str()).collect();
        let mut sorted_conds = cond_texts.clone();
        sorted_conds.sort();
        assert_eq!(cond_texts, sorted_conds, "conditions must be sorted");
    }

    // ──────────────── MANUAL-ENTRY-DESIGN.md: self-measurement dispatch ────────────────

    fn self_entry_doc_text(values: &[crate::SelfMeasuredValue]) -> String {
        crate::render_self_measurement_text(&["(测试用合成文本)".to_string()], values)
    }

    #[test]
    fn self_measured_series_never_merges_with_a_same_analyte_hospital_series() {
        // 家测血压 128/82,同一天医院化验单也测了一次血压(140/90,诊室值)。两条
        // 序列共享同一个 analyte_key("bp_systolic"),但绝不能合成一条线 —— 这是
        // 本次改动最硬的一条不变量(MANUAL-ENTRY-DESIGN.md §1/§3.4/硬约束)。
        let self_text = self_entry_doc_text(&[crate::SelfMeasuredValue {
            analyte_key: "bp_systolic".into(),
            value: 128.0,
            unit: "mmHg".into(),
        }]);
        let docs = vec![
            SourceDoc {
                index: 0,
                doc_type: Some("self_measurement".into()),
                title: None,
                date: d(2026, 8, 1),
                text: &self_text,
            },
            SourceDoc {
                index: 1,
                doc_type: Some("lab_report".into()),
                title: None,
                date: d(2026, 8, 1),
                text: "收缩压 140 mmHg",
            },
        ];
        let agg = aggregate(&docs);
        let bp_series: Vec<&AnalyteSeries> = agg
            .labs
            .iter()
            .filter(|s| s.analyte_key.as_deref() == Some("bp_systolic"))
            .collect();
        assert_eq!(
            bp_series.len(),
            2,
            "自测血压与医院血压必须是两条独立序列,不能合并成一条: {:?}",
            bp_series
                .iter()
                .map(|s| (s.self_measured, s.points.len()))
                .collect::<Vec<_>>()
        );
        let self_series = bp_series
            .iter()
            .find(|s| s.self_measured)
            .expect("one series must be the self-measured one");
        let hospital_series = bp_series
            .iter()
            .find(|s| !s.self_measured)
            .expect("one series must be the hospital one");
        assert_eq!(self_series.points.len(), 1);
        assert_eq!(self_series.points[0].value, 128.0);
        assert_eq!(hospital_series.points.len(), 1);
        assert_eq!(hospital_series.points[0].value, 140.0);
    }

    #[test]
    fn self_measured_bp_uses_home_range_not_clinic_range() {
        // 128 mmHg 低于家测阈值 135,但若被误套诊室区间(140)也会判"正常"——
        // 这条测试要的是"用的是家测那套区间",不是碰巧两套区间给出同一个结论,
        // 所以取一个能在两套区间下给出不同 flag 的值:138。
        // 家测(<=135 正常)→ H;诊室(<=140 正常)→ 若误用会是 N。
        let text = self_entry_doc_text(&[crate::SelfMeasuredValue {
            analyte_key: "bp_systolic".into(),
            value: 138.0,
            unit: "mmHg".into(),
        }]);
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("self_measurement".into()),
            title: None,
            date: d(2026, 8, 1),
            text: &text,
        }];
        let agg = aggregate(&docs);
        let s = agg
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("bp_systolic"))
            .expect("bp series present");
        assert_eq!(
            s.ref_high,
            Some(135.0),
            "must be the home threshold, not 140"
        );
        assert_eq!(s.points[0].flag.as_deref(), Some("H"));
    }

    #[test]
    fn self_measured_bp_is_one_document_two_series() {
        // §5.3:血压两个值共享同一份文档/同一个 measured_at,但在 AnalyteSeries
        // 层面仍拆成两条独立序列(与医院化验从不把两个不同 LOINC 的值画在同一条
        // 线上是一个道理)。
        let text = self_entry_doc_text(&[
            crate::SelfMeasuredValue {
                analyte_key: "bp_systolic".into(),
                value: 128.0,
                unit: "mmHg".into(),
            },
            crate::SelfMeasuredValue {
                analyte_key: "bp_diastolic".into(),
                value: 82.0,
                unit: "mmHg".into(),
            },
        ]);
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("self_measurement".into()),
            title: None,
            date: d(2026, 8, 1),
            text: &text,
        }];
        let agg = aggregate(&docs);
        assert_eq!(agg.labs.len(), 2);
        let sys = agg
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("bp_systolic"))
            .unwrap();
        let dia = agg
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("bp_diastolic"))
            .unwrap();
        // 两条序列的唯一一个点都来自同一份文档(index 0)。
        assert_eq!(sys.points[0].source, 0);
        assert_eq!(dia.points[0].source, 0);
    }

    #[test]
    fn analytes_with_no_home_range_get_no_flag() {
        // 体温/体重/血糖(§5.2/§3.3):没有出处就不给区间、不出 flag —— 裸值显示。
        for (key, value, unit) in [
            ("body_temperature", 39.0, "Cel"), // 明显"发烧"级别的高值,也不该出 flag
            ("body_weight", 65.0, "kg"),
            ("glucose", 20.0, "mmol/L"), // 明显异常的高血糖,也不该出 flag
        ] {
            let text = self_entry_doc_text(&[crate::SelfMeasuredValue {
                analyte_key: key.into(),
                value,
                unit: unit.into(),
            }]);
            let docs = vec![SourceDoc {
                index: 0,
                doc_type: Some("self_measurement".into()),
                title: None,
                date: d(2026, 8, 1),
                text: &text,
            }];
            let agg = aggregate(&docs);
            let s = agg
                .labs
                .iter()
                .find(|s| s.analyte_key.as_deref() == Some(key))
                .unwrap_or_else(|| panic!("series for {key} present"));
            assert_eq!(s.ref_low, None, "{key} must have no ref_low");
            assert_eq!(s.ref_high, None, "{key} must have no ref_high");
            assert_eq!(
                s.points[0].flag, None,
                "{key} must never carry a flag with no defensible home range"
            );
        }
    }

    #[test]
    fn self_measured_heart_rate_series_marked_self_measured() {
        let text = self_entry_doc_text(&[crate::SelfMeasuredValue {
            analyte_key: "heart_rate".into(),
            value: 72.0,
            unit: "/min".into(),
        }]);
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("self_measurement".into()),
            title: None,
            date: d(2026, 8, 1),
            text: &text,
        }];
        let agg = aggregate(&docs);
        let s = &agg.labs[0];
        assert!(s.self_measured);
        assert_eq!(s.loinc.as_deref(), Some("8867-4"));
        assert_eq!(s.group_name, "心率");
    }

    #[test]
    fn self_measurement_document_contributes_no_meds_or_conditions() {
        // 显式跳过,即使合成文本理论上"恰好没触发"正则也不该依赖那份运气。
        let text = self_entry_doc_text(&[crate::SelfMeasuredValue {
            analyte_key: "heart_rate".into(),
            value: 72.0,
            unit: "/min".into(),
        }]);
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("self_measurement".into()),
            title: None,
            date: d(2026, 8, 1),
            text: &text,
        }];
        let agg = aggregate(&docs);
        assert!(agg.meds.is_empty());
        assert!(agg.conditions.is_empty());
    }

    #[test]
    fn note_document_contributes_no_conditions_meds_or_labs() {
        // 笔记文档("头晕,是不是又高血压了")绝不能被读成一条诊断 —— 这是本次
        // 改动特别要堵的那类假线(MANUAL-ENTRY-DESIGN.md §3.4)。
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("note".into()),
            title: None,
            date: d(2026, 8, 1),
            text: "今天有点头晕,是不是又高血压了,下次问问医生。",
        }];
        let agg = aggregate(&docs);
        assert!(agg.labs.is_empty());
        assert!(agg.meds.is_empty());
        assert!(
            agg.conditions.is_empty(),
            "笔记不该被读出诊断: {:?}",
            agg.conditions
                .iter()
                .map(|c| &c.raw_text)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn self_measurement_with_unparseable_payload_yields_no_labs_but_does_not_panic() {
        // 载荷损坏(标记丢失/版本不认识)→ 没有数值,不半猜,也不 panic。文档本身
        // 是否仍在时间线/档案里可见由调用方(vault_projections)决定,这里只保证
        // aggregate() 本身对损坏输入是安全、确定的空结果。
        let docs = vec![SourceDoc {
            index: 0,
            doc_type: Some("self_measurement".into()),
            title: None,
            date: d(2026, 8, 1),
            text: "损坏的自测记录,没有任何标记行。",
        }];
        let agg = aggregate(&docs);
        assert!(agg.labs.is_empty());
    }
}
