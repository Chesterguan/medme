//! 通用病程档案层(2026-10-22 spec):不靠包,从诊断/用药/化验/就诊直接推三视图。
use chrono::NaiveDate;

/// 一次就诊(`core-model` 的 `Encounter` 投影),调用方按 `Vault::encounters_with_docs()`
/// 给;`doc_indices` 是 `parser::SourceDoc::index`。parser 不认识 encounter,所以它是
/// 引擎的独立输入(spec §8.1 决定 1)。
#[derive(Debug, Clone)]
pub struct EncounterRef {
    /// `inpatient` / `emergency` / `outpatient` / `exam`(`EncounterKind::as_str`)。
    pub kind: String,
    pub start: Option<NaiveDate>,
    pub end: Option<NaiveDate>,
    pub provider: Option<String>,
    pub title: Option<String>,
    pub doc_indices: Vec<usize>,
}

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::generic_tables::{
    family_of_icd, family_rank, normalize_icd, FAMILIES, LAB_KEYS, PACKAGE_ICD_PREFIXES,
    PANEL_FAMILY, RECENT_DAYS,
};
use crate::package::Package;
use crate::rules::Ctx;
use crate::state::{self, EvidenceBook};
use crate::view::{PackageOut, ProfileView, Section, SourceOut};

pub(crate) const GENERAL_ID: &str = "general";

fn general_section(kind: &str, id: &str, title: &str, body: serde_json::Value) -> Section {
    Section {
        kind: kind.into(),
        id: Some(id.into()),
        title: Some(title.into()),
        empty_hint: None,
        body,
        package_id: Some(GENERAL_ID.into()),
    }
}

fn doc_date(ctx: &Ctx<'_>, index: usize) -> Option<NaiveDate> {
    ctx.docs
        .iter()
        .find(|d| d.index == index)
        .and_then(|d| d.date)
}

fn doc_origin(ctx: &Ctx<'_>, index: usize) -> &'static str {
    if ctx.extracted.contains(&index) {
        "llm"
    } else {
        "regex"
    }
}

// ─────────────────────────── 现在:诊断按族 ───────────────────────────

#[derive(Debug, Clone, Serialize)]
struct DiagnosisOut {
    code: Option<String>,
    /// `raw_text` 的不同写法,去重排序。
    texts: Vec<String>,
    first_seen: Option<String>,
    last_seen: Option<String>,
    /// 提到它的**文档数**(界面叫「N 份记录提到」)。
    doc_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    secondary: Option<&'static str>,
    evidence: Vec<String>,
    unverified: bool,
}

#[derive(Debug, Clone, Serialize)]
struct LabRow {
    key: String,
    label: String,
    value: String,
    unit: Option<String>,
    #[serde(rename = "ref")]
    reference: Option<String>,
    date: Option<String>,
    flag: Option<String>,
    evidence: String,
    unverified: bool,
}

#[derive(Debug, Clone, Serialize)]
struct FamilyOut {
    key: &'static str,
    label: &'static str,
    count: usize,
    last_seen: Option<String>,
    diagnoses: Vec<DiagnosisOut>,
    labs: Vec<LabRow>,
}

/// 诊断的合并键:有码按归一后的码,无码按原文。
#[derive(Default)]
struct DxBuilder {
    code: Option<String>,
    /// 每种写法 → 提到它的文档。
    variants: BTreeMap<String, BTreeSet<usize>>,
    first_seen: Option<NaiveDate>,
    last_seen: Option<NaiveDate>,
    sources: BTreeSet<usize>,
    unverified: bool,
}

fn merge_diagnoses(ctx: &Ctx<'_>) -> BTreeMap<String, DxBuilder> {
    let mut out: BTreeMap<String, DxBuilder> = BTreeMap::new();
    for c in &ctx.clinical.conditions {
        let code = c.icd_code.as_deref().and_then(normalize_icd);
        let key = match &code {
            Some(code) => format!("code:{code}"),
            None => format!("text:{}", c.raw_text),
        };
        let b = out.entry(key).or_default();
        b.code = code;
        b.variants
            .entry(c.raw_text.clone())
            .or_default()
            .extend(c.sources.iter().copied());
        b.first_seen = match (b.first_seen, c.onset) {
            (Some(a), Some(x)) => Some(a.min(x)),
            (a, x) => a.or(x),
        };
        for &s in &c.sources {
            b.last_seen = b.last_seen.max(doc_date(ctx, s));
        }
        b.sources.extend(c.sources.iter().copied());
        b.unverified |= c.unverified;
    }
    out
}

fn diagnosis_out(ctx: &Ctx<'_>, b: &DxBuilder, book: &mut EvidenceBook) -> DiagnosisOut {
    let mut evidence = Vec::new();
    for (text, sources) in &b.variants {
        // 每种写法引最早与最近那两份;原文里找得到那一行才算逐字。
        let first = sources.iter().min_by_key(|s| doc_date(ctx, **s));
        let last = sources.iter().max_by_key(|s| doc_date(ctx, **s));
        for s in [first, last].into_iter().flatten() {
            let id = book.cite(
                ctx,
                Some(*s),
                text,
                &[],
                doc_origin(ctx, *s),
                !b.unverified,
                None,
                true,
            );
            if !evidence.contains(&id) {
                evidence.push(id);
            }
        }
    }
    DiagnosisOut {
        code: b.code.clone(),
        texts: b.variants.keys().cloned().collect(),
        first_seen: b.first_seen.map(|d| d.to_string()),
        last_seen: b.last_seen.map(|d| d.to_string()),
        doc_count: b.sources.len(),
        secondary: b.code.as_deref().and_then(|c| family_of_icd(c).1),
        evidence,
        unverified: b.unverified,
    }
}

/// 一条序列的最近值那一行。
fn lab_row(ctx: &Ctx<'_>, key: &str, book: &mut EvidenceBook) -> Option<LabRow> {
    let (s, p) = state::latest_point(ctx, key)?;
    let e = state::point_evidence(s, p, key);
    let id = state::cite_lab(ctx, book, &e, &s.group_name, !p.unverified);
    let reference = match (s.ref_low, s.ref_high) {
        (Some(lo), Some(hi)) => Some(format!("{}-{}", state::fmt_num(lo), state::fmt_num(hi))),
        (None, Some(hi)) => Some(format!("<{}", state::fmt_num(hi))),
        (Some(lo), None) => Some(format!(">{}", state::fmt_num(lo))),
        (None, None) => None,
    };
    Some(LabRow {
        key: key.into(),
        label: s.group_name.clone(),
        value: state::fmt_num(p.value),
        unit: state::point_unit(s, p),
        reference,
        date: p.date.map(|d| d.to_string()),
        flag: p.flag.clone(),
        evidence: id,
        unverified: p.unverified,
    })
}

/// 这个族的化验 key:覆盖表的 key 在前,再按词典 panel 兜底补上;只给**有数据**的。
fn family_lab_keys(ctx: &Ctx<'_>, family: &str) -> Vec<String> {
    let mut keys: Vec<String> = LAB_KEYS
        .iter()
        .find(|(f, _)| *f == family)
        .map(|(_, ks)| ks.iter().map(|k| k.to_string()).collect())
        .unwrap_or_default();
    let mut by_panel: Vec<String> = ctx
        .clinical
        .labs
        .iter()
        .filter(|s| !s.self_measured)
        .filter_map(|s| s.analyte_key.clone())
        .filter(|k| panel_family(k) == Some(family))
        .collect();
    by_panel.sort();
    by_panel.dedup();
    for k in by_panel {
        if !keys.contains(&k) {
            keys.push(k);
        }
    }
    keys
}

fn panel_family(key: &str) -> Option<&'static str> {
    let panel = terminology::panel_for(key)?;
    PANEL_FAMILY
        .iter()
        .find(|(p, _)| *p == panel)
        .map(|(_, f)| *f)
}

/// 一批诊断 → 族卡(分族、族内排序、族排序;`with_labs` 决定要不要挂该族的化验小表)。
fn families_of(
    ctx: &Ctx<'_>,
    builders: &[&DxBuilder],
    with_labs: bool,
    book: &mut EvidenceBook,
) -> Vec<FamilyOut> {
    let mut per_family: BTreeMap<&'static str, Vec<DiagnosisOut>> = BTreeMap::new();
    for b in builders {
        let fam = match b.code.as_deref() {
            Some(c) => family_of_icd(c).0,
            None => "uncoded",
        };
        per_family
            .entry(fam)
            .or_default()
            .push(diagnosis_out(ctx, b, book));
    }
    let mut families: Vec<FamilyOut> = Vec::new();
    for (key, label) in FAMILIES {
        let Some(mut dx) = per_family.remove(key) else {
            continue;
        };
        // 族内:最近出现日倒序,无日期最后;并列按文档数再按原文。
        dx.sort_by(|a, b| {
            b.last_seen
                .is_some()
                .cmp(&a.last_seen.is_some())
                .then(b.last_seen.cmp(&a.last_seen))
                .then(b.doc_count.cmp(&a.doc_count))
                .then(a.texts.cmp(&b.texts))
        });
        let labs = if !with_labs || matches!(*key, "other" | "uncoded") {
            Vec::new()
        } else {
            family_lab_keys(ctx, key)
                .iter()
                .filter_map(|k| lab_row(ctx, k, book))
                .collect()
        };
        families.push(FamilyOut {
            key,
            label,
            count: dx.len(),
            last_seen: dx.iter().filter_map(|d| d.last_seen.clone()).max(),
            diagnoses: dx,
            labs,
        });
    }
    // 族:最近出现日倒序,无日期最后,并列按诊断数再按族表顺序;
    // `other` 固定倒数第二、`uncoded` 固定最后(§9 第 4 条)。
    families.sort_by(|a, b| {
        let pin = |k: &str| match k {
            "uncoded" => 2,
            "other" => 1,
            _ => 0,
        };
        pin(a.key)
            .cmp(&pin(b.key))
            .then(b.last_seen.is_some().cmp(&a.last_seen.is_some()))
            .then(b.last_seen.cmp(&a.last_seen))
            .then(b.count.cmp(&a.count))
            .then(family_rank(a.key).cmp(&family_rank(b.key)))
    });
    families
}

pub(crate) fn family_section(ctx: &Ctx<'_>, book: &mut EvidenceBook) -> Section {
    let merged = merge_diagnoses(ctx);
    // 「现在」只留最近 RECENT_DAYS 天内有记录提到的诊断(spec 2026-10-23 §4.1);更早的、
    // 没有日期的另列 `earlier_families`,不挂化验。判定只看事实(最近出现日),不判活动/已解决。
    let (recent, earlier): (Vec<&DxBuilder>, Vec<&DxBuilder>) = merged.values().partition(|b| {
        b.last_seen
            .is_some_and(|d| (ctx.today - d).num_days() <= RECENT_DAYS)
    });
    let families = families_of(ctx, &recent, true, book);
    let earlier_families = families_of(ctx, &earlier, false, book);
    // 通用一排:血常规 / 电解质 / 肝功能 / 尿液 的最近值,不归任何族。
    let mut common_keys: Vec<String> = ctx
        .clinical
        .labs
        .iter()
        .filter(|s| !s.self_measured)
        .filter_map(|s| s.analyte_key.clone())
        .filter(|k| panel_family(k) == Some("common"))
        .collect();
    common_keys.sort();
    common_keys.dedup();
    let common_labs: Vec<LabRow> = common_keys
        .iter()
        .filter_map(|k| lab_row(ctx, k, book))
        .collect();
    general_section(
        "family_cards",
        "general_families",
        "现在",
        serde_json::json!({
            "families": families,
            "earlier_families": earlier_families,
            "recent_days": RECENT_DAYS,
            "common_labs": common_labs,
        }),
    )
}

// ─────────────────────────── 现在:用药表 ───────────────────────────

/// 用药 stale 默认阈值(§9 第 3 条):慢病门诊常隔 3–6 个月,90 天误报太多。
pub(crate) const STALE_DAYS: i64 = 180;

/// 剂量键 = 剂量串里第一个数字 + 紧跟的单位 token,小写(`5mg qd`、`5 mg daily`、
/// `5mg daily` 同键;频次不进键;`5mg/ml` 取到 `5mg` 为止)。没有数字 → `None`。
pub(crate) fn dose_key(dose: &str) -> Option<String> {
    let chars: Vec<char> = dose.chars().collect();
    let start = chars.iter().position(|c| c.is_ascii_digit())?;
    let mut i = start;
    let mut out = String::new();
    while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == '.') {
        out.push(chars[i]);
        i += 1;
    }
    while i < chars.len() && chars[i] == ' ' {
        i += 1;
    }
    while i < chars.len() && (chars[i].is_ascii_alphabetic() || matches!(chars[i], 'µ' | 'μ' | '%'))
    {
        out.push(chars[i].to_ascii_lowercase());
        i += 1;
    }
    Some(out)
}

/// 这一行写了停药吗。只认写在原文里的:中文 `停用|停药|停服|已停`,英文整词
/// `discontinued|stopped|stop taking|dc'd|d/c'd`(大小写不敏感)。裸 `d/c`、
/// `discharge`、`stoppage` 不算 —— 这里**不**判「停的是哪味药」,调用方只对含药名的行调它。
pub(crate) fn is_stop_line(line: &str) -> bool {
    const CN: &[&str] = &["停用", "停药", "停服", "已停"];
    const EN: &[&str] = &["discontinued", "stopped", "stop taking", "dc'd", "d/c'd"];
    if CN.iter().any(|k| line.contains(k)) {
        return true;
    }
    let lower = line.to_ascii_lowercase();
    EN.iter().any(|k| {
        lower.match_indices(k).any(|(start, _)| {
            let end = start + k.len();
            let before = lower[..start].chars().next_back();
            let after = lower[end..].chars().next();
            !before.is_some_and(|c| c.is_ascii_alphanumeric())
                && !after.is_some_and(|c| c.is_ascii_alphanumeric())
        })
    })
}

/// 这一行写了停**这味药**吗(审查 C1)。按 `;；。,，` 拆子句:药名与停词必须在**同一个子句**里
/// (「Aspirin stopped; continue metoprolol」停的是阿司匹林),且该子句在停词之前没有否定
/// (「Do not stop taking warfarin」「不可自行停药」「勿擅自停用」是叮嘱继续吃)。
pub(crate) fn stops_drug(line: &str, name: &str) -> bool {
    const NEG: &[&str] = &[
        "do not", "don't", "not ", "never", "without", "不可", "不要", "勿", "切勿", "禁止",
        "避免", "自行", "擅自", "是否",
    ];
    let name_l = name.trim().to_ascii_lowercase();
    if name_l.is_empty() {
        return false;
    }
    line.split([';', '；', '。', ',', '，'])
        .filter(|c| c.to_ascii_lowercase().contains(&name_l))
        .filter(|c| is_stop_line(c))
        .any(|c| {
            let lower = c.to_ascii_lowercase();
            // 停词在子句里的位置;它前面那一截里有否定就不算停。
            let stop_at = [
                "停",
                "discontinued",
                "stopped",
                "stop taking",
                "dc'd",
                "d/c'd",
            ]
            .iter()
            .filter_map(|k| lower.find(k))
            .min()
            .unwrap_or(0);
            let before = &lower[..stop_at];
            !NEG.iter().any(|n| before.contains(n))
        })
}

#[derive(Debug, Clone, Serialize)]
struct Stopped {
    at: String,
    evidence: String,
}

#[derive(Debug, Clone, Serialize)]
struct MedRow {
    name: String,
    raw_name: String,
    dose: Option<String>,
    /// 「记录中自 YYYY-MM-DD 起」:该剂量键连续出现的起点。
    since: Option<String>,
    first_seen: Option<String>,
    last_seen: Option<String>,
    days_since: Option<i64>,
    stale: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    stopped: Option<Stopped>,
    family: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    family_note: Option<&'static str>,
    evidence: Vec<String>,
    unverified: bool,
}

/// 一味药的进程泳道(剂量变化 + 原文写了的停药),给 `journey_section` 用。
pub(crate) struct MedLane {
    pub(crate) key: String,
    pub(crate) label: String,
    pub(crate) nodes: Vec<state::Node>,
}

/// 某次提及所在文档里,写了停**这味药**的那一整行([`stops_drug`]);没有就 `None`。
fn stop_line_of(ctx: &Ctx<'_>, m: &parser::MedMention) -> Option<String> {
    let d = ctx.docs.iter().find(|d| d.index == m.source)?;
    d.text
        .lines()
        .map(str::trim)
        .find(|l| stops_drug(l, &m.raw_name))
        .map(str::to_string)
}

fn med_row(ctx: &Ctx<'_>, m: &parser::MedSpan, book: &mut EvidenceBook) -> (MedRow, MedLane) {
    // 提及已按日期升序(无日期在最后);这里只看有日期的。
    let dated: Vec<&parser::MedMention> = m.mentions.iter().filter(|x| x.date.is_some()).collect();
    let mut nodes: Vec<state::Node> = Vec::new();
    let mut prev_key: Option<String> = None;
    let mut prev_dose: Option<String> = None;
    let mut stopped: Option<Stopped> = None;
    // 「自何日起」的候选:当前剂量键连续出现的起点;剂量键变了或中间有停药就重置。
    let mut since: Option<NaiveDate> = None;
    for x in &dated {
        if let Some(line) = stop_line_of(ctx, x) {
            let id = book.cite(
                ctx,
                Some(x.source),
                &line,
                &[],
                &x.origin,
                !x.unverified,
                None,
                true,
            );
            let at = x.date.map(|d| d.to_string()).unwrap_or_default();
            nodes.push(state::Node {
                at: Some(at.clone()),
                kind: "stopped".into(),
                from: prev_dose.clone(),
                to: "病历写了停药".into(),
                text: Some(line),
                equiv_mg_per_day: None,
                evidence: vec![id.clone()],
                unverified: x.unverified,
            });
            stopped = Some(Stopped { at, evidence: id });
            since = None;
            prev_key = None;
            continue;
        }
        let Some(dose) = x.dose.as_deref() else {
            continue;
        };
        let key = dose_key(dose);
        if key.is_none() {
            continue;
        }
        // 停之后又出现带剂量的提及 → 回到正常行,停那一次只留在泳道里。
        stopped = None;
        if key != prev_key {
            let num = state::dose_number(dose);
            let id = book.cite(
                ctx,
                Some(x.source),
                &x.raw_name,
                &[num.as_str()],
                &x.origin,
                !x.unverified,
                None,
                true,
            );
            nodes.push(state::Node {
                at: x.date.map(|d| d.to_string()),
                kind: if prev_key.is_none() {
                    "first"
                } else {
                    "change"
                }
                .into(),
                from: prev_dose.clone(),
                to: dose.to_string(),
                text: Some(x.raw_name.clone()),
                equiv_mg_per_day: None,
                evidence: vec![id],
                unverified: x.unverified,
            });
            since = x.date;
            prev_key = key;
        }
        prev_dose = Some(dose.to_string());
    }
    let (family, family_note) = crate::generic_tables::family_of_atc(m.atc.as_deref());
    let days_since = m.end.map(|e| (ctx.today - e).num_days());
    let row = MedRow {
        name: m.name.clone(),
        raw_name: m.latest_raw_name.clone().unwrap_or_else(|| m.name.clone()),
        dose: m.latest_dose.clone(),
        since: if stopped.is_some() {
            None
        } else {
            since.map(|d| d.to_string())
        },
        first_seen: m.start.map(|d| d.to_string()),
        last_seen: m.end.map(|d| d.to_string()),
        days_since,
        stale: days_since.is_some_and(|n| n > STALE_DAYS),
        stopped,
        family,
        family_note,
        evidence: state::cite_span(ctx, book, m),
        unverified: m.unverified,
    };
    let lane = MedLane {
        key: format!(
            "med:{}",
            m.drug_key.clone().unwrap_or_else(|| m.name.clone())
        ),
        label: m.name.clone(),
        nodes,
    };
    (row, lane)
}

/// 用药表(spec §3.2)。全部药都列:包的状态行在「现在」的包段,药表在「用药」tab,不在同一屏,不替换。
pub(crate) fn med_section(ctx: &Ctx<'_>, book: &mut EvidenceBook) -> (Section, Vec<MedLane>) {
    let mut rows: Vec<MedRow> = Vec::new();
    let mut lanes: Vec<MedLane> = Vec::new();
    for m in &ctx.clinical.meds {
        let (row, lane) = med_row(ctx, m, book);
        rows.push(row);
        lanes.push(lane);
    }
    // 停了的沉底;其余按最近记录日倒序,无日期最后,并列按名字。
    rows.sort_by(|a, b| {
        a.stopped
            .is_some()
            .cmp(&b.stopped.is_some())
            .then(b.last_seen.is_some().cmp(&a.last_seen.is_some()))
            .then(b.last_seen.cmp(&a.last_seen))
            .then(a.name.cmp(&b.name))
    });
    let section = general_section(
        "med_table",
        "general_meds",
        "现在",
        serde_json::json!({ "rows": rows, "stale_after_days": STALE_DAYS }),
    );
    (section, lanes)
}

// ─────────────────────────── 进程 ───────────────────────────

fn doc_node(
    ctx: &Ctx<'_>,
    d: &crate::rules::Doc<'_>,
    text: Option<String>,
    book: &mut EvidenceBook,
) -> state::Node {
    let id = book.cite_doc(ctx, d.index);
    state::Node {
        at: d.date.map(|x| x.to_string()),
        kind: "doc".into(),
        from: None,
        to: d.title.clone().unwrap_or_default(),
        text,
        equiv_mg_per_day: None,
        evidence: vec![id],
        unverified: false,
    }
}

/// 住院/急诊节点:`起 → 止 · 住院 N 天`(N = 出院 − 入院,同日/缺止日/止早于起 记 1,
/// 与时间线页同口径);依据 = 该次就诊的每份文档(整份)。
fn encounter_node(ctx: &Ctx<'_>, e: &EncounterRef, book: &mut EvidenceBook) -> state::Node {
    let start = e.start.map(|d| d.to_string()).unwrap_or_default();
    // 止日早于起日当缺止日(数据坏了就只写起日,不出负数)。
    let end = e.end.filter(|t| e.start.is_none_or(|s| *t >= s));
    let to = match (e.start, end) {
        (Some(s), Some(t)) if e.kind == "inpatient" => {
            let days = (t - s).num_days().max(1);
            format!("{s} → {t} · 住院 {days} 天")
        }
        // 没有出院日就不编天数(审查 I2;时间线页同样只写「住院 · N 份」)。
        (Some(s), _) if e.kind == "inpatient" => format!("{s} · 住院"),
        (Some(s), _) => s.to_string(),
        (None, _) => e.title.clone().unwrap_or_default(),
    };
    let mut parts: Vec<String> = Vec::new();
    if let Some(p) = &e.provider {
        parts.push(p.clone());
    }
    if !e.doc_indices.is_empty() {
        parts.push(format!("{} 份", e.doc_indices.len()));
    }
    let evidence: Vec<String> = e
        .doc_indices
        .iter()
        .map(|&i| book.cite_doc(ctx, i))
        .collect();
    state::Node {
        at: (!start.is_empty()).then_some(start),
        kind: e.kind.clone(),
        from: None,
        to,
        text: (!parts.is_empty()).then(|| parts.join(" · ")),
        equiv_mg_per_day: None,
        evidence,
        unverified: false,
    }
}

fn make_lane(key: &str, label: &str, severity: &str, mut nodes: Vec<state::Node>) -> state::Lane {
    state::sort_nodes(&mut nodes);
    state::Lane {
        key: key.into(),
        label: label.into(),
        quality: state::quality(&nodes).into(),
        severity: severity.into(),
        nodes,
    }
}

pub(crate) fn journey_section(
    ctx: &Ctx<'_>,
    encounters: &[EncounterRef],
    med_lanes: Vec<MedLane>,
    book: &mut EvidenceBook,
) -> Section {
    let mut lanes: Vec<state::Lane> = Vec::new();
    for (kind, key, label) in [
        ("inpatient", "enc_inpatient", "住院"),
        ("emergency", "enc_emergency", "急诊"),
    ] {
        let nodes: Vec<state::Node> = encounters
            .iter()
            .filter(|e| e.kind == kind)
            .map(|e| encounter_node(ctx, e, book))
            .collect();
        lanes.push(make_lane(key, label, "high", nodes));
    }
    for (doc_type, key, label) in [
        ("surgery", "surgery", "手术"),
        ("imaging_report", "imaging", "影像"),
        ("pathology", "pathology", "病理"),
    ] {
        let nodes: Vec<state::Node> = ctx
            .docs
            .iter()
            .filter(|d| d.doc_type.as_deref() == Some(doc_type))
            .map(|d| {
                let text = match doc_type {
                    "imaging_report" => parser::imaging_impression(d.text),
                    "pathology" => parser::pathology_impression(d.text),
                    _ => None,
                };
                doc_node(ctx, d, text, book)
            })
            .collect();
        lanes.push(make_lane(key, label, "normal", nodes));
    }
    for m in med_lanes {
        lanes.push(make_lane(&m.key, &m.label, "normal", m.nodes));
    }
    // 诊断首次出现:每族一条,节点 = 该族每条诊断的首次提及。
    let merged = merge_diagnoses(ctx);
    let mut per_family: BTreeMap<&'static str, Vec<state::Node>> = BTreeMap::new();
    for b in merged.values() {
        let fam = match b.code.as_deref() {
            Some(c) => family_of_icd(c).0,
            None => "uncoded",
        };
        // 最早那份文档里的那种写法。
        let Some((text, doc)) = b
            .variants
            .iter()
            .flat_map(|(t, srcs)| srcs.iter().map(move |s| (t, *s)))
            .min_by_key(|(_, s)| (doc_date(ctx, *s).is_none(), doc_date(ctx, *s), *s))
        else {
            continue;
        };
        let id = book.cite(
            ctx,
            Some(doc),
            text,
            &[],
            doc_origin(ctx, doc),
            !b.unverified,
            None,
            true,
        );
        per_family.entry(fam).or_default().push(state::Node {
            at: b.first_seen.map(|d| d.to_string()),
            kind: "first".into(),
            from: None,
            to: match &b.code {
                Some(c) => format!("{text} · {c}"),
                None => text.clone(),
            },
            text: None,
            equiv_mg_per_day: None,
            evidence: vec![id],
            unverified: b.unverified,
        });
    }
    for (key, label) in FAMILIES {
        if let Some(nodes) = per_family.remove(key) {
            lanes.push(make_lane(
                &format!("dx:{key}"),
                &format!("诊断 · {label}"),
                "normal",
                nodes,
            ));
        }
    }
    // 排序沿用三视图 spec §9 决定 3:有核过节点的先、需核对的后;空道不出(折叠)。
    lanes.retain(|l| !l.nodes.is_empty());
    let rank = |l: &state::Lane| match l.quality.as_str() {
        "verified" => 0,
        _ => 1,
    };
    lanes.sort_by_key(rank);
    general_section(
        "journey",
        "general_journey",
        "进程",
        serde_json::json!({ "lanes": lanes }),
    )
}

/// 包出不出现(spec 2026-10-23 §4.4):保险箱里任一诊断的原文含包 `triggers.diagnosis_patterns`
/// 任一项(子串,大小写不敏感),**或**任一诊断归一后的 ICD 以 [`PACKAGE_ICD_PREFIXES`] 里该包的
/// 前缀开头。纯函数,不看 `enable`/`disable` 事件——那是查看器/分享单包路径的事。
pub fn package_applies(pkg: &Package, conditions: &[parser::AggregatedCondition]) -> bool {
    let patterns: Vec<String> = pkg
        .triggers
        .diagnosis_patterns
        .iter()
        .map(|p| p.to_lowercase())
        .filter(|p| !p.is_empty())
        .collect();
    let prefixes: &[&str] = PACKAGE_ICD_PREFIXES
        .iter()
        .find(|(id, _)| *id == pkg.manifest.id)
        .map_or(&[], |(_, p)| p);
    conditions.iter().any(|c| {
        let text = c.raw_text.to_lowercase();
        if patterns.iter().any(|p| text.contains(p.as_str())) {
            return true;
        }
        c.icd_code
            .as_deref()
            .and_then(normalize_icd)
            .is_some_and(|code| prefixes.iter().any(|p| code.starts_with(p)))
    })
}

// ─────────────────────────── 装配 ───────────────────────────

/// 通用层 + 每个**命中触发**的包叠在后面(spec 2026-10-23 §4.4)。**纯函数**。
///
/// `installed` 是缓存里装着的全部包;出不出按 [`package_applies`] 判,`events` 只喂 `Ctx`
/// (自填/动作日志),不再读 `enable`/`disable`。覆盖层由调用方装。
pub fn materialize_generic(
    docs: &[parser::SourceDoc<'_>],
    encounters: &[EncounterRef],
    events: &[parser::ProfileEvent],
    installed: &[Package],
    today: NaiveDate,
) -> ProfileView {
    let ctx = Ctx::build(docs, events, today);
    let mut book = EvidenceBook::default();
    let mut sections = vec![family_section(&ctx, &mut book)];
    let (meds, med_lanes) = med_section(&ctx, &mut book);
    sections.push(meds);
    sections.push(journey_section(&ctx, encounters, med_lanes, &mut book));
    // 包段与通用段**共用这一本**依据簿(审查 I1:各自从 1 编号会撞 id,界面合并后点开错的
    // 那句);通用的 evidence 段等包都登记完再装,固定排在通用三段之后、包段之前。
    let mut sources: Vec<SourceOut> = Vec::new();
    let packages: Vec<PackageOut> = installed
        .iter()
        .map(|p| PackageOut {
            id: p.manifest.id.clone(),
            display_name: p.manifest.display.name.clone(),
            family: p.manifest.family.clone(),
            applies: package_applies(p, &ctx.clinical.conditions),
        })
        .collect();
    for (pkg, out) in installed.iter().zip(&packages) {
        if !out.applies {
            continue;
        }
        for mut s in crate::sections_for(&ctx, pkg, &mut book) {
            s.package_id = Some(pkg.manifest.id.clone());
            sections.push(s);
        }
        for s in &pkg.manifest.sources {
            if !sources.iter().any(|x| x.id == s.id) {
                sources.push(SourceOut {
                    id: s.id.clone(),
                    cite: s.cite.clone(),
                    url: s.url.clone(),
                });
            }
        }
    }
    sections.insert(
        3,
        general_section(
            "evidence",
            "general_evidence",
            "依据",
            serde_json::json!({ "items": book.items }),
        ),
    );
    ProfileView {
        package_id: GENERAL_ID.into(),
        package_version: "1".into(),
        display_name: "病程档案".into(),
        enabled: true,
        disclaimer: "只整理你病历里已有的记录,不做诊断。".into(),
        sections,
        sources,
        packages,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dose_key_is_first_number_plus_unit() {
        assert_eq!(dose_key("5mg qd").as_deref(), Some("5mg"));
        assert_eq!(dose_key("5 mg daily").as_deref(), Some("5mg"));
        assert_eq!(dose_key("5mg").as_deref(), Some("5mg"));
        assert_eq!(dose_key("0.5g bid").as_deref(), Some("0.5g"));
        assert_eq!(dose_key("5mg/ml").as_deref(), Some("5mg"));
        assert_eq!(dose_key("qd"), None);
        assert_eq!(dose_key(""), None);
        assert_eq!(dose_key("5").as_deref(), Some("5"));
    }

    #[test]
    fn stop_line_only_matches_written_discontinuation() {
        assert!(is_stop_line(
            "Voriconazole discontinued after 24 weeks of therapy."
        ));
        assert!(is_stop_line("Stopped warfarin due to bleeding"));
        assert!(is_stop_line("停用阿司匹林"));
        assert!(is_stop_line("华法林已停"));
        assert!(is_stop_line("Lisinopril dc'd"));
        assert!(!is_stop_line("d/c summary reviewed."));
        assert!(!is_stop_line("Discharge medications: Warfarin 5mg"));
        assert!(!is_stop_line("Metoprolol 25mg twice daily"));
        assert!(!is_stop_line("stoppage"));
    }

    /// 审查 C1:停词必须与**这味药**在同一个子句里,且前面没有否定 —— 「Do not stop taking
    /// warfarin」「不可自行停药」是叮嘱继续吃;「Aspirin stopped; continue metoprolol」停的是另一味。
    #[test]
    fn stop_clause_needs_same_clause_and_no_negation() {
        assert!(stops_drug(
            "Voriconazole discontinued after 24 weeks of therapy.",
            "Voriconazole"
        ));
        assert!(stops_drug("Stopped warfarin due to bleeding", "warfarin"));
        assert!(stops_drug(
            "阿司匹林肠溶片已停用,改用氯吡格雷。",
            "阿司匹林肠溶片"
        ));
        assert!(stops_drug(
            "Aspirin stopped; continue metoprolol.",
            "Aspirin"
        ));
        assert!(!stops_drug(
            "Do not stop taking warfarin without calling the clinic.",
            "warfarin"
        ));
        assert!(!stops_drug("Warfarin: do not discontinue.", "Warfarin"));
        assert!(!stops_drug(
            "Never stop taking metoprolol abruptly.",
            "metoprolol"
        ));
        assert!(!stops_drug(
            "Aspirin stopped; continue metoprolol.",
            "metoprolol"
        ));
        assert!(!stops_drug(
            "阿司匹林肠溶片 100mg qd,不可自行停药。",
            "阿司匹林肠溶片"
        ));
        assert!(!stops_drug(
            "服用阿司匹林 1 年后门诊评估是否停用;阿托伐他汀继续。",
            "阿司匹林"
        ));
        assert!(!stops_drug("勿擅自停用华法林", "华法林"));
        assert!(!stops_drug("Metoprolol 25mg twice daily", "Metoprolol"));
        assert!(!stops_drug(
            "Aspirin stopped; continue metoprolol.",
            "lisinopril"
        ));
    }
}
