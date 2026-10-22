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
    family_of_icd, family_rank, normalize_icd, FAMILIES, LAB_KEYS, PANEL_FAMILY,
};
use crate::package::Package;
use crate::rules::Ctx;
use crate::state::{self, EvidenceBook};
use crate::view::{ProfileView, Section, SourceOut};

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

pub(crate) fn family_section(ctx: &Ctx<'_>, book: &mut EvidenceBook) -> Section {
    let merged = merge_diagnoses(ctx);
    let mut per_family: BTreeMap<&'static str, Vec<DiagnosisOut>> = BTreeMap::new();
    for b in merged.values() {
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
        let labs = if matches!(*key, "other" | "uncoded") {
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
        serde_json::json!({ "families": families, "common_labs": common_labs }),
    )
}

// ─────────────────────────── 装配 ───────────────────────────

/// 通用层 + 每个**开着的**包叠在后面(spec §4)。**纯函数**。
///
/// `installed` 是缓存里装着的全部包;开没开按 `events` 里的 `enable`/`disable`
/// (`is_enabled`)判,没开的包一段都不出、也不碰它的 terms(覆盖层由调用方装)。
pub fn materialize_generic(
    docs: &[parser::SourceDoc<'_>],
    encounters: &[EncounterRef],
    events: &[parser::ProfileEvent],
    installed: &[Package],
    today: NaiveDate,
) -> ProfileView {
    let _ = encounters;
    let ctx = Ctx::build(docs, events, today);
    let mut book = EvidenceBook::default();
    let mut sections = vec![family_section(&ctx, &mut book)];
    sections.push(general_section(
        "evidence",
        "general_evidence",
        "依据",
        serde_json::json!({ "items": book.items }),
    ));
    let mut sources: Vec<SourceOut> = Vec::new();
    for pkg in installed {
        if !crate::is_enabled(events, &pkg.manifest.id) {
            continue;
        }
        for mut s in crate::sections_for(&ctx, pkg) {
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
    ProfileView {
        package_id: GENERAL_ID.into(),
        package_version: "1".into(),
        display_name: "病程档案".into(),
        enabled: true,
        disclaimer: "只整理你病历里已有的记录,不做诊断。".into(),
        sections,
        sources,
    }
}
