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

use crate::{
    extract_conditions, extract_labs, extract_meds, self_entry, LabObservation, MedObservation,
};
use chrono::NaiveDate;
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
    /// `value_canonical` if the observation had one, else `value_num`.
    pub value: f64,
    /// `unit_canonical` if present, else `unit_raw`.
    pub unit: Option<String>,
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
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
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

/// The section kind a header line starts, or `None` if it isn't a header. `Other`
/// headers (诊断/病史/…) aren't mined but still bound a section so a meds/labs
/// section ends where the next section begins.
///
/// Prefix match **after [`terminology::normalize_term`]** on both sides. Comparing
/// the raw line only worked when the report typeset the header exactly the way
/// this list spells it: `出院　医嘱:` (ideographic space U+3000, ordinary in
/// Chinese typesetting) and `出 院 医 嘱:` (OCR splitting CJK) both failed the
/// prefix test, the section went unrecognized, and every discharge medication in
/// the document silently disappeared from the summary. Same defect that emptied
/// the diabetes lane — one comparison of Chinese text against a curated literal
/// without normalizing first.
fn header_kind(line: &str) -> Option<SecKind> {
    let raw = line.trim_start();
    let folded = terminology::normalize_term(line);
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
    // Two ways to be a header, and the split matters — both halves were learned
    // the hard way.
    //
    // 1. The **raw** prefix, exactly as before. Real headers trail all sorts of
    //    things: `出院医嘱如下:`, `出院带药(共2种):`, `带药如下`, `出院医嘱 1.`,
    //    `用药医嘱 -`. An earlier attempt demanded a delimiter right after the
    //    prefix and lost every one of them — worse than the bug it was fixing.
    //
    // 2. The **normalized** prefix, but only when what follows is a delimiter or
    //    the line ends. Normalization exists here for `出 院 医 嘱:` (OCR splits
    //    CJK) and `ＲＰ:` (full-width) — but it also lowercases and deletes all
    //    internal whitespace, so an unguarded prefix test on the normalized line
    //    reads ordinary content as a header. `RPR 阴性` (routine syphilis screen)
    //    matched the lowercased `Rp`; `用 药 后 患者症状缓解` matched `用药`. And a
    //    false header is much worse than a missed one: `sections_text` treats
    //    headers as boundaries, so it truncates the block and everything below it
    //    vanishes — one RPR row deleted 肌酐 and 血钾 from a real summary.
    //
    // Together: never less than the raw rule recognized, plus the despaced and
    // full-width spellings, and nothing that merely happens to start with a
    // header word.
    let hit = |hs: &[&str]| {
        hs.iter().any(|h| {
            raw.starts_with(h)
                || folded
                    .strip_prefix(terminology::normalize_term(h).as_str())
                    .is_some_and(|rest| rest.is_empty() || rest.starts_with([':', '.', '、']))
        })
    };
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

struct LabBuilder {
    analyte_key: Option<String>,
    group_name: String,
    loinc: Option<String>,
    /// Whether `group_name`/`loinc` were taken from a matched observation yet.
    meta_from_match: bool,
    /// Reference range of the mention currently winning "most recent ref".
    ref_low: Option<f64>,
    ref_high: Option<f64>,
    ref_date: Option<NaiveDate>,
    has_ref: bool,
    points: Vec<LabPoint>,
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
        flag,
        // 不是术语模糊匹配出来的置信度(那个字段的原意),而是"这是用户在封闭
        // 五选一里选的项,结构上精确无歧义" —— 满置信度是如实的,不是编的。
        confidence: 1.0,
        self_measured: true,
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
        // 其余按原规则:whole-doc for lab reports,否则只从embedded 化验 sections
        // 抽(section-scoped,so a discharge summary's prose 血压 stays out) —— #148. ---
        let doc_labs: Vec<LabObservation> = if dt == Some("self_measurement") {
            self_entry::parse_self_measurement_payload(doc.text)
                .unwrap_or_default()
                .iter()
                .map(build_self_measured_observation)
                .collect()
        } else if wants_labs(dt) {
            extract_labs(doc.text)
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
            let point = LabPoint {
                date: doc.date,
                value: obs.value_canonical.unwrap_or(obs.value_num),
                unit: obs.unit_canonical.clone().or_else(|| obs.unit_raw.clone()),
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
                ref_date: None,
                has_ref: false,
                points: Vec::new(),
                any_abnormal: false,
                self_measured: obs.self_measured,
            });
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
            AnalyteSeries {
                analyte_key: b.analyte_key,
                group_name: b.group_name,
                loinc: b.loinc,
                ref_low: b.ref_low,
                ref_high: b.ref_high,
                points: b.points,
                any_abnormal: b.any_abnormal,
                self_measured: b.self_measured,
            }
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
