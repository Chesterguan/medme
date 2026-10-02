//! 三视图(spec 2026-09-30 §2–§4):一份事件日志三个投影。
//!
//! - `state`:每个包声明的状态变量折叠到今天的值 + 截至日期 + 陈旧标记。
//! - `journey`:状态变量的变更日志(相邻两次值不同才是节点)+ 事件型 fact 各一条泳道。
//! - `evidence`:上面每个值、每个节点点回去的原件位置(`ev:<doc>:<n>`)。
//!
//! 三段共用一本 [`EvidenceBook`],所以同一份文档的同一句话只登记一次。所有数值都
//! 复用 `rules.rs` 已有的求值(`regimen_eval` / `hcq_body` / `activity_eval` /
//! `eval_milestone`),这里**不另算一遍**:状态卡上那个 7.5 和这里的 7.5 必须是同一个数。
//!
//! 不下结论:变量只陈述已知值与截至日期;`stale` 只说「多久没有新证据」,不说「可能已停药」;
//! 活动度只给化验可算的分数,**不套分档**(分档表只用于症状项勾选后的总评分,见包
//! `rules.bands.note`)。
use std::collections::HashMap;

use chrono::NaiveDate;
use serde::Serialize;

use crate::package::{Drug, Package, StateVar};
use crate::rules::{self, Activity, Ctx, Regimen};
use crate::view::Section;

/// 一条依据:哪份文档、原文哪一句、哪条路径读的、逐字核过没有。
#[derive(Debug, Clone, Serialize)]
pub(crate) struct EvidenceOut {
    pub id: String,
    /// `parser::SourceDoc::index`;自测/手录(`self_entry`)没有文档,为 `None`。
    pub doc: Option<usize>,
    pub date: Option<String>,
    pub title: Option<String>,
    /// 原文逐字(找得到时是含它的那一整行;找不到时就是传进来的那句)。
    pub quote: String,
    /// `quote` 里被引用的那段在文档正文里的字节区间;找不到就 `None`。
    pub span: Option<[usize; 2]>,
    /// `llm` / `regex` / `self_entry`。
    pub origin: String,
    /// 逐字核过:文档里真找到了这一句/这个值,且来源本身不是「需核对」。原文里找不到
    /// 的(换算过的数、模型给的数)一律 `false` —— 引擎造的字符串不能冒充逐字。
    pub verified: bool,
}

#[derive(Default)]
pub(crate) struct EvidenceBook {
    items: Vec<EvidenceOut>,
    seen: HashMap<(Option<usize>, String, String, String), String>,
    per_doc: HashMap<Option<usize>, usize>,
}

/// 数字 needle 不许粘在别的数字/小数点上:「88」不能命中「0885」。
fn standalone(text: &str, start: usize, end: usize) -> bool {
    let before = text[..start].chars().next_back();
    let after = text[end..].chars().next();
    let glue = |c: Option<char>| c.is_some_and(|c| c.is_ascii_digit() || c == '.');
    !(glue(before) || glue(after))
}

impl EvidenceBook {
    /// 登记一条依据,返回它的 id;同一份文档同一句同一路径同一上下文只登记一次。
    ///
    /// `needle` 在原文里可能出现不止一次(门诊号里的「88」、两项都是「18」的化验):
    /// 逐处候选打分 —— 所在行含 `hints` 里的词(项目名、单位)各加分,数字 needle
    /// 必须独立成数 —— 取分最高的;并列取最早的。
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn cite(
        &mut self,
        ctx: &Ctx<'_>,
        doc: Option<usize>,
        needle: &str,
        hints: &[&str],
        origin: &str,
        verified: bool,
        date_if_no_doc: Option<NaiveDate>,
        whole_line: bool,
    ) -> String {
        let key = (
            doc,
            needle.to_string(),
            origin.to_string(),
            hints.join("\u{1f}"),
        );
        if let Some(id) = self.seen.get(&key) {
            return id.clone();
        }
        let n = self.per_doc.entry(doc).or_insert(0);
        *n += 1;
        let id = match doc {
            Some(d) => format!("ev:{d}:{n}"),
            None => format!("ev:self:{n}"),
        };
        let d = doc.and_then(|i| ctx.docs.iter().find(|x| x.index == i));
        let numeric = needle
            .chars()
            .all(|c| c.is_ascii_digit() || c == '.' || c == '-')
            && needle.chars().any(|c| c.is_ascii_digit());
        let mut best: Option<(i32, usize, usize, usize)> = None; // (score, start, line_start, line_end)
        if let Some(d) = d {
            if !needle.is_empty() {
                for (start, _) in d.text.match_indices(needle) {
                    let end = start + needle.len();
                    if numeric && !standalone(d.text, start, end) {
                        continue;
                    }
                    let line_start = d.text[..start].rfind('\n').map_or(0, |i| i + 1);
                    let line_end = d.text[end..].find('\n').map_or(d.text.len(), |i| end + i);
                    let line = &d.text[line_start..line_end];
                    let score: i32 = hints
                        .iter()
                        .filter(|h| !h.is_empty() && line.contains(*h))
                        .count() as i32;
                    if best.is_none_or(|(s, ..)| score > s) {
                        best = Some((score, start, line_start, line_end));
                    }
                }
            }
        }
        let (quote, span, found) = match (d, best) {
            (Some(d), Some((_, start, ls, le))) => {
                let quote = if whole_line {
                    d.text[ls..le].trim().to_string()
                } else {
                    needle.to_string()
                };
                (quote, Some([start, start + needle.len()]), true)
            }
            _ => (needle.to_string(), None, false),
        };
        self.items.push(EvidenceOut {
            id: id.clone(),
            doc,
            date: d
                .and_then(|x| x.date)
                .or(date_if_no_doc)
                .map(|x| x.to_string()),
            title: d.and_then(|x| x.title.clone()),
            quote,
            span,
            origin: origin.to_string(),
            // 有文档却没在原文里找到 → 不是逐字(审查 I-3);没有文档的自测条目按
            // 调用方说的算。
            verified: verified && (doc.is_none() || found),
        });
        self.seen.insert(key, id.clone());
        id
    }

    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

#[derive(Debug, Clone, Serialize)]
struct StateRow {
    key: String,
    label: String,
    value: Option<String>,
    unit: Option<String>,
    as_of: Option<String>,
    stale: bool,
    stale_after_days: Option<i64>,
    evidence: Vec<String>,
    note: Option<String>,
    source: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
struct Node {
    at: Option<String>,
    /// `first` / `change` / `dose_change` / `point` / 事件类型名。
    kind: String,
    from: Option<String>,
    to: String,
    /// 药名(用药节点)或原话(事件节点)。
    text: Option<String>,
    /// 激素类的泼尼松等效日剂量(mg/天),换药时看这个才知道是不是减量;算不出为 `None`。
    #[serde(skip_serializing_if = "Option::is_none")]
    equiv_mg_per_day: Option<f64>,
    evidence: Vec<String>,
    unverified: bool,
}

#[derive(Debug, Clone, Serialize)]
struct Lane {
    key: String,
    label: String,
    /// `verified`(有核过的节点)/ `needs_review`(节点全是没核上的)/ `empty`。
    quality: String,
    /// `high` = 包在 `views.sections[timeline].severity_high` 里点名的(复发、住院);否则 `normal`。
    severity: String,
    nodes: Vec<Node>,
}

/// 事件型 fact 的泳道;顺序即展示顺序。标签是族级通用词,不是病种文案。
/// `dose_change` 这一条只收没并进任何状态变量泳道的那些(其它药的调整)。
const EVENT_LANES: [(&str, &str); 7] = [
    ("flare", "复发 / 加重"),
    ("hospitalization", "住院"),
    ("biopsy", "活检"),
    ("infusion", "输注"),
    ("dose_change", "用药调整"),
    ("infection", "感染"),
    ("pregnancy", "妊娠"),
];

fn fmt_num(x: f64) -> String {
    let r = (x * 100.0).round() / 100.0;
    if r.fract() == 0.0 {
        format!("{}", r as i64)
    } else {
        format!("{r}")
    }
}

fn fmt_1dec(x: f64) -> String {
    format!("{:.1}", (x * 10.0).round() / 10.0)
}

fn stale(today: NaiveDate, as_of: Option<NaiveDate>, after: Option<i64>) -> bool {
    match (as_of, after) {
        (Some(d), Some(n)) => (today - d).num_days() > n,
        _ => false,
    }
}

fn class_drug<'p>(pkg: &'p Package, class: &str) -> Option<&'p Drug> {
    pkg.drugs.iter().find(|d| d.class == class)
}

/// 某一类药的全部用药区间;激素类剔除外用/局部制剂(与 `regimen_eval` 同一条筛选,
/// 审查 I-5)。
fn spans_of_class<'c>(ctx: &'c Ctx<'_>, pkg: &Package, class: &str) -> Vec<&'c parser::MedSpan> {
    ctx.clinical
        .meds
        .iter()
        .filter(|m| rules::drug_class(pkg, m).is_some_and(|d| d.class == class))
        .filter(|m| class != "gc" || !rules::is_nonsystemic_gc(m))
        .collect()
}

fn lab_origin(ctx: &Ctx<'_>, doc: usize) -> &'static str {
    if ctx.raw_labs.iter().any(|(i, _, _)| *i == doc) {
        "llm"
    } else {
        "regex"
    }
}

fn dose_number(dose: &str) -> String {
    dose.chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect()
}

/// 一条用药区间「现在」那个值的依据:最新剂量来自的那份文档里,含药名**且含剂量数字**
/// 的那一行(同一份病历里既往剂量和现剂量都写着药名时,靠剂量分开,审查 I-2)。
fn cite_span(ctx: &Ctx<'_>, book: &mut EvidenceBook, m: &parser::MedSpan) -> Vec<String> {
    let needle = m.latest_raw_name.clone().unwrap_or_else(|| m.name.clone());
    let num = dose_number(m.latest_dose.as_deref().unwrap_or_default());
    vec![book.cite(
        ctx,
        m.latest_source,
        &needle,
        &[num.as_str()],
        m.latest_origin.as_deref().unwrap_or("regex"),
        !m.unverified,
        None,
        true,
    )]
}

/// 一个化验点的依据:值所在的那一行,用项目名和印刷单位把同一个数的别的行排开。
fn cite_lab(
    ctx: &Ctx<'_>,
    book: &mut EvidenceBook,
    e: &rules::Evidence,
    name_hint: &str,
    verified: bool,
) -> String {
    let origin = lab_origin(ctx, e.document_index);
    let unit = e.unit.clone().unwrap_or_default();
    book.cite(
        ctx,
        Some(e.document_index),
        &e.value,
        &[name_hint, unit.as_str()],
        origin,
        verified,
        None,
        true,
    )
}

fn point_evidence(s: &parser::AnalyteSeries, p: &parser::LabPoint, key: &str) -> rules::Evidence {
    rules::Evidence {
        document_index: p.source,
        date: p.date.map(|d| d.to_string()),
        analyte: key.to_string(),
        value: fmt_num(p.value),
        unit: p.unit.clone(),
        value_canonical: p.value_canonical,
        unit_canonical: s.unit_canonical.clone(),
        values_converted: s.values_converted,
    }
}

/// 显示基准值配**印刷单位**(`LabPoint.value` ↔ `LabPoint.unit`,审查 I-4);没印单位
/// 时才退到序列的规范单位。
fn point_unit(s: &parser::AnalyteSeries, p: &parser::LabPoint) -> Option<String> {
    p.unit.clone().or_else(|| s.unit_canonical.clone())
}

fn latest_point<'c>(
    ctx: &'c Ctx<'_>,
    key: &str,
) -> Option<(&'c parser::AnalyteSeries, &'c parser::LabPoint)> {
    ctx.clinical
        .labs
        .iter()
        .filter(|s| s.analyte_key.as_deref() == Some(key) && !s.self_measured)
        .flat_map(|s| s.points.iter().map(move |p| (s, p)))
        .filter(|(_, p)| p.date.is_some_and(|d| d <= ctx.today))
        .max_by_key(|(_, p)| p.date)
}

fn eval_var(
    ctx: &Ctx<'_>,
    pkg: &Package,
    var: &StateVar,
    regimen: &Regimen,
    activity: &Activity,
    book: &mut EvidenceBook,
) -> Option<StateRow> {
    let mut row = StateRow {
        key: var.key.clone(),
        label: var.label.clone(),
        value: None,
        unit: var.unit.clone(),
        as_of: None,
        stale: false,
        stale_after_days: var.stale_after_days,
        evidence: Vec::new(),
        note: None,
        source: var.source.clone(),
    };
    let mut as_of: Option<NaiveDate> = None;
    match var.derive.as_str() {
        "latest_dose" => {
            let class = var.drug_class.as_deref().unwrap_or_default();
            let spans = spans_of_class(ctx, pkg, class);
            let Some(newest) = spans.iter().max_by_key(|m| m.end) else {
                row.note = Some(format!("还没读到{}的处方", var.label));
                return Some(row);
            };
            if class == "gc" {
                match regimen.gc.daily_mg {
                    Some(mg) => row.value = Some(fmt_num(mg)),
                    None => {
                        row.note = regimen.gc.blocked_reason.clone().or_else(|| {
                            regimen.gc.unconvertible.first().and_then(|u| {
                                u.get("reason").and_then(|r| r.as_str()).map(str::to_string)
                            })
                        });
                    }
                }
                if row.value.is_some() {
                    row.note = newest.latest_dose.clone().map(|d| format!("处方:{d}"));
                }
            } else {
                row.value = newest.latest_dose.clone();
            }
            as_of = newest.end;
            row.evidence = cite_span(ctx, book, newest);
        }
        "ratio_to_weight" => {
            let class = var.drug_class.as_deref().unwrap_or("hcq");
            let body = rules::hcq_body(ctx, pkg);
            let spans = spans_of_class(ctx, pkg, class);
            let newest = spans.iter().max_by_key(|m| m.end);
            row.value = body.get("mg_per_kg").and_then(|v| v.as_f64()).map(fmt_1dec);
            row.note = body
                .get("reason")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            if let Some(m) = newest {
                as_of = m.end;
                row.evidence = cite_span(ctx, book, m);
            }
            if let Some((at, kg, src, doc)) = rules::latest_weight_kg(ctx, &pkg.manifest.id) {
                let id = match (src.as_str(), doc) {
                    ("record", Some(d)) => book.cite(
                        ctx,
                        Some(d),
                        &fmt_num(kg),
                        &["kg", "体重"],
                        lab_origin(ctx, d),
                        true,
                        at,
                        true,
                    ),
                    _ => book.cite(
                        ctx,
                        None,
                        &format!("自测体重 {} kg", fmt_num(kg)),
                        &[],
                        "self_entry",
                        true,
                        at,
                        false,
                    ),
                };
                row.evidence.push(id);
            }
        }
        "band" => {
            // 只给化验可算的分数,**不套分档**:分档表是给症状项勾选后的总评分用的
            // (包 `rules.bands.note` 原文),化验部分分落进「轻度活动」就是替医生下
            // 结论(审查 C-1)。症状分进引擎之后这里才出档名。
            let a = &pkg.rules.activity;
            if activity.hits.is_empty() && activity.missed.is_empty() {
                row.note = Some(format!("最近 {} 天内没有化验结果,算不出来", a.window_days));
                return Some(row);
            }
            let score = rules::weight_sum(&activity.hits);
            row.note = Some(format!(
                "化验可算部分 {score}/{} · 症状项未录,不分档",
                a.max
            ));
            for h in &activity.hits {
                for e in &h.evidence {
                    let d = e.date.as_deref().and_then(|s| s.parse::<NaiveDate>().ok());
                    as_of = as_of.max(d);
                    let id = cite_lab(ctx, book, e, &h.label, true);
                    if !row.evidence.contains(&id) {
                        row.evidence.push(id);
                    }
                }
            }
        }
        "milestone" => {
            let want = var.milestone.as_deref().unwrap_or_default();
            let Some(item) = pkg
                .rules
                .milestones
                .iter()
                .find(|it| rules::str_field(it, "id") == want)
            else {
                row.note = Some(format!("包里没有里程碑 {want}"));
                return Some(row);
            };
            if !rules::milestones_apply(ctx, &pkg.rules.milestones) {
                row.note = Some("暂不适用:还没有相关器官受累或治疗记录".into());
                return Some(row);
            }
            let Some(out) = rules::eval_milestone(ctx, pkg, item) else {
                return Some(row);
            };
            row.value = Some(
                match rules::str_field(&out, "verdict") {
                    "yes" => "是",
                    "no" => "否",
                    _ => "未知",
                }
                .into(),
            );
            row.note = out
                .get("reason")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            if let Some(evs) = out.get("evidence").and_then(|v| v.as_array()) {
                for e in evs {
                    let Ok(e) = serde_json::from_value::<rules::Evidence>(e.clone()) else {
                        continue;
                    };
                    // 提示词用序列的显示名(与下面「最近值」那条同一把钥匙),同一行只登记一次。
                    let hint = ctx
                        .clinical
                        .labs
                        .iter()
                        .find(|s| s.analyte_key.as_deref() == Some(e.analyte.as_str()))
                        .map(|s| s.group_name.clone())
                        .unwrap_or_else(|| e.analyte.clone());
                    let id = cite_lab(ctx, book, &e, &hint, true);
                    if !row.evidence.contains(&id) {
                        row.evidence.push(id);
                    }
                }
            }
            // 「现在」要的是**最近一次**该指标的值与日期,不是里程碑第一次达到的那天:
            // `upcr_below_500_any` 判的是「任一时点」,它的 actual_at 是首次达标日,拿来
            // 当截至日期会把半年后仍然达标的人标成「陈旧」。verdict 仍用里程碑的判定。
            let key = rules::str_field(item, "key");
            if let Some((s, p)) = latest_point(ctx, key) {
                let unit = point_unit(s, p).unwrap_or_default();
                row.note = Some(if unit.is_empty() {
                    format!("最近值 {}", fmt_num(p.value))
                } else {
                    format!("最近值 {} {unit}", fmt_num(p.value))
                });
                as_of = p.date;
                let e = point_evidence(s, p, key);
                let id = cite_lab(ctx, book, &e, &s.group_name, !p.unverified);
                if !row.evidence.contains(&id) {
                    row.evidence.insert(0, id);
                }
            }
            if row.source.is_none() {
                row.source = out
                    .get("source")
                    .and_then(|v| v.as_str())
                    .map(str::to_string);
            }
        }
        "latest_value" => {
            let marker = var.marker.as_deref().unwrap_or_default();
            match latest_point(ctx, marker) {
                Some((s, p)) => {
                    row.value = Some(fmt_num(p.value));
                    if row.unit.is_none() {
                        row.unit = point_unit(s, p);
                    }
                    as_of = p.date;
                    let e = point_evidence(s, p, marker);
                    row.evidence = vec![cite_lab(ctx, book, &e, &s.group_name, !p.unverified)];
                    if p.unverified {
                        row.note = Some("这条结果还没核对".into());
                    }
                }
                None => row.note = Some(format!("还没有 {} 的化验结果", var.label)),
            }
        }
        // 认不出的 derive:包可以先于引擎走,这一行不出。
        _ => return None,
    }
    row.as_of = as_of.map(|d| d.to_string());
    row.stale = stale(ctx.today, as_of, var.stale_after_days);
    Some(row)
}

pub(crate) fn state_section(
    ctx: &Ctx<'_>,
    pkg: &Package,
    regimen: &Regimen,
    activity: &Activity,
    book: &mut EvidenceBook,
) -> Option<Section> {
    if pkg.state_vars.is_empty() {
        return None;
    }
    let vars: Vec<StateRow> = pkg
        .state_vars
        .iter()
        .filter_map(|v| eval_var(ctx, pkg, v, regimen, activity, book))
        .collect();
    let any_value = vars.iter().any(|r| r.value.is_some());
    Some(Section {
        kind: "state".into(),
        id: rules::view_id(pkg, "state", None),
        title: rules::view_title(pkg, "state", None),
        empty_hint: if any_value {
            None
        } else {
            empty_hint(pkg, "state")
        },
        body: serde_json::json!({ "vars": vars }),
    })
}

fn empty_hint(pkg: &Package, kind: &str) -> Option<String> {
    pkg.views
        .sections
        .iter()
        .find(|s| rules::str_field(s, "kind") == kind)
        .and_then(|s| s.get("empty_hint").and_then(|v| v.as_str()))
        .map(str::to_string)
}

/// 包在 `views.sections[kind=timeline].severity_high` 里点名要标红的事件类型(spec §3)。
fn severity_high(pkg: &Package) -> Vec<String> {
    pkg.views
        .sections
        .iter()
        .find(|s| rules::str_field(s, "kind") == "timeline")
        .and_then(|s| s.get("severity_high").and_then(|v| v.as_array()))
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn fact_date(doc_date: Option<NaiveDate>, f: &deid::Fact) -> Option<NaiveDate> {
    [f.date.as_str(), f.date_start.as_str()]
        .iter()
        .find_map(|s| s.parse::<NaiveDate>().ok())
        .or(doc_date)
}

/// 无日期排最后,有日期按日期;stable。
fn sort_nodes(nodes: &mut [Node]) {
    nodes.sort_by_key(|n| match &n.at {
        Some(d) => (0, d.clone()),
        None => (1, String::new()),
    });
}

fn same_dose(a: &str, b: &str) -> bool {
    let (a, b) = (a.trim(), b.trim());
    !a.is_empty() && !b.is_empty() && (a == b || a.starts_with(b) || b.starts_with(a))
}

/// 一类药的泳道节点:逐次提及按日期串起来,剂量变了才是节点;并入药名对得上这一类
/// 的 `dose_change` 事实(并入的记进 `consumed`,其余留给「用药调整」泳道)。
fn dose_lane_nodes(
    ctx: &Ctx<'_>,
    pkg: &Package,
    class: &str,
    book: &mut EvidenceBook,
    consumed: &mut Vec<(usize, String)>,
) -> Vec<Node> {
    let drug = class_drug(pkg, class);
    let equiv = |raw_name: &str, dose: &str| -> Option<f64> {
        if class != "gc" {
            return None;
        }
        drug.and_then(|d| rules::equiv_mg_per_day(d, raw_name, dose))
    };
    let mut mentions: Vec<&parser::MedMention> = spans_of_class(ctx, pkg, class)
        .iter()
        .flat_map(|m| m.mentions.iter())
        .filter(|x| x.dose.is_some())
        .filter(|x| class != "gc" || !rules::is_nonsystemic_gc_name(&x.raw_name))
        .collect();
    mentions.sort_by_key(|x| x.date.map_or((1, NaiveDate::MAX), |d| (0, d)));
    let mut nodes: Vec<Node> = Vec::new();
    let mut prev: Option<&str> = None;
    for m in mentions {
        let dose = m.dose.as_deref().unwrap_or_default();
        if prev == Some(dose) {
            continue;
        }
        let num = dose_number(dose);
        let id = book.cite(
            ctx,
            Some(m.source),
            &m.raw_name,
            &[num.as_str()],
            &m.origin,
            !m.unverified,
            None,
            true,
        );
        nodes.push(Node {
            at: m.date.map(|d| d.to_string()),
            kind: if prev.is_none() { "first" } else { "change" }.into(),
            from: prev.map(str::to_string),
            to: dose.to_string(),
            text: Some(m.raw_name.clone()),
            equiv_mg_per_day: equiv(&m.raw_name, dose),
            evidence: vec![id],
            unverified: m.unverified,
        });
        prev = Some(dose);
    }
    // 模型抽出来的 dose_change 事实(「激素减至 10mg」):药名对得上这一类就并进来。
    // 泛称别名(两个字以内)只认整名,与 `rules::drug_class` 同一条规矩。
    let names: Vec<&str> = drug
        .map(|d| d.names.iter().map(String::as_str).collect())
        .unwrap_or_default();
    for (doc, doc_date, f) in &ctx.facts {
        if f.r#type != "dose_change" || f.drug.trim().is_empty() {
            continue;
        }
        let hit = names.iter().any(|n| {
            f.drug == *n
                || (n.chars().count() > 2 && (f.drug.contains(n) || n.contains(f.drug.as_str())))
        });
        if !hit {
            continue;
        }
        consumed.push((*doc, f.evidence.clone()));
        let at = fact_date(*doc_date, f).map(|d| d.to_string());
        // 同一天、同一个目标剂量,「提及」已经出过节点就不再为事实重复出一条:
        // 两边写法长短不一,按前缀对。
        if nodes.iter().any(|n| n.at == at && same_dose(&n.to, &f.to)) {
            continue;
        }
        let id = book.cite(
            ctx,
            Some(*doc),
            &f.evidence,
            &[],
            "llm",
            !f.unverified,
            None,
            false,
        );
        nodes.push(Node {
            at,
            kind: "dose_change".into(),
            from: (!f.from.trim().is_empty()).then(|| f.from.clone()),
            to: f.to.clone(),
            text: Some(f.evidence.clone()),
            equiv_mg_per_day: equiv(&f.drug, &f.to),
            evidence: vec![id],
            unverified: f.unverified,
        });
    }
    sort_nodes(&mut nodes);
    nodes
}

fn series_lane_nodes(ctx: &Ctx<'_>, key: &str, book: &mut EvidenceBook) -> Vec<Node> {
    let mut pts: Vec<(&parser::AnalyteSeries, &parser::LabPoint)> = ctx
        .clinical
        .labs
        .iter()
        .filter(|s| s.analyte_key.as_deref() == Some(key) && !s.self_measured)
        .flat_map(|s| s.points.iter().map(move |p| (s, p)))
        .filter(|(_, p)| p.date.is_some_and(|d| d <= ctx.today))
        .collect();
    pts.sort_by_key(|(_, p)| p.date);
    pts.into_iter()
        .map(|(s, p)| {
            let e = point_evidence(s, p, key);
            let id = cite_lab(ctx, book, &e, &s.group_name, !p.unverified);
            Node {
                at: p.date.map(|d| d.to_string()),
                kind: "point".into(),
                from: None,
                to: match point_unit(s, p) {
                    Some(u) => format!("{} {u}", fmt_num(p.value)),
                    None => fmt_num(p.value),
                },
                text: p.flag.clone(),
                equiv_mg_per_day: None,
                evidence: vec![id],
                unverified: p.unverified,
            }
        })
        .collect()
}

fn quality(nodes: &[Node]) -> &'static str {
    if nodes.is_empty() {
        "empty"
    } else if nodes.iter().all(|n| n.unverified) {
        "needs_review"
    } else {
        "verified"
    }
}

/// 事件节点上「发生了什么」那一格。
fn event_headline(ty: &str, f: &deid::Fact) -> String {
    let join = |parts: &[&str]| {
        parts
            .iter()
            .filter(|s| !s.trim().is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" ")
    };
    match ty {
        "hospitalization" if !f.date_start.is_empty() && !f.date_end.is_empty() => {
            format!("{} → {}", f.date_start, f.date_end)
        }
        "infusion" => join(&[&f.drug, &f.dose]),
        "biopsy" => join(&[&f.organ, &f.result]),
        "dose_change" => f.to.clone(),
        _ => [
            f.text.as_str(),
            f.reason.as_str(),
            f.status.as_str(),
            f.evidence.as_str(),
        ]
        .iter()
        .find(|s| !s.trim().is_empty())
        .map_or(String::new(), |s| s.to_string()),
    }
}

pub(crate) fn journey_section(
    ctx: &Ctx<'_>,
    pkg: &Package,
    book: &mut EvidenceBook,
) -> Option<Section> {
    if pkg.state_vars.is_empty() {
        return None;
    }
    let high = severity_high(pkg);
    let sev = |key: &str| {
        if high.iter().any(|h| h == key) {
            "high"
        } else {
            "normal"
        }
    };
    // (排序键, 泳道):变量泳道有核过的变更 → 0;事件泳道 → 1;需核对 → 2;空 → 3。
    let mut lanes: Vec<(u8, Lane)> = Vec::new();
    let mut consumed: Vec<(usize, String)> = Vec::new();
    for var in &pkg.state_vars {
        let nodes = match var.derive.as_str() {
            "latest_dose" | "ratio_to_weight" => dose_lane_nodes(
                ctx,
                pkg,
                var.drug_class.as_deref().unwrap_or_default(),
                book,
                &mut consumed,
            ),
            "milestone" => {
                let key = pkg
                    .rules
                    .milestones
                    .iter()
                    .find(|it| {
                        rules::str_field(it, "id") == var.milestone.as_deref().unwrap_or_default()
                    })
                    .map(|it| rules::str_field(it, "key").to_string())
                    .unwrap_or_default();
                series_lane_nodes(ctx, &key, book)
            }
            "latest_value" => {
                series_lane_nodes(ctx, var.marker.as_deref().unwrap_or_default(), book)
            }
            // 分档没有逐日历史(分数只对今天的窗口算),泳道留空。
            _ => Vec::new(),
        };
        let q = quality(&nodes);
        let rank = match q {
            "verified" => 0,
            "needs_review" => 2,
            _ => 3,
        };
        lanes.push((
            rank,
            Lane {
                key: var.key.clone(),
                label: var.label.clone(),
                quality: q.into(),
                severity: sev(&var.key).into(),
                nodes,
            },
        ));
    }
    for (ty, label) in EVENT_LANES {
        let mut nodes: Vec<Node> = ctx
            .facts
            .iter()
            .filter(|(doc, _, f)| {
                f.r#type == ty
                    && !(ty == "dose_change"
                        && consumed.iter().any(|(d, e)| d == doc && *e == f.evidence))
            })
            .map(|(doc, doc_date, f)| {
                let id = book.cite(
                    ctx,
                    Some(*doc),
                    &f.evidence,
                    &[],
                    "llm",
                    !f.unverified,
                    None,
                    false,
                );
                Node {
                    at: fact_date(*doc_date, f).map(|d| d.to_string()),
                    kind: ty.into(),
                    from: (ty == "dose_change" && !f.from.trim().is_empty())
                        .then(|| f.from.clone()),
                    to: event_headline(ty, f),
                    text: (!f.evidence.is_empty()).then(|| f.evidence.clone()),
                    equiv_mg_per_day: None,
                    evidence: vec![id],
                    unverified: f.unverified,
                }
            })
            .collect();
        if nodes.is_empty() {
            continue;
        }
        sort_nodes(&mut nodes);
        let q = quality(&nodes);
        let rank = if q == "verified" { 1 } else { 2 };
        lanes.push((
            rank,
            Lane {
                key: ty.into(),
                label: label.into(),
                quality: q.into(),
                severity: sev(ty).into(),
                nodes,
            },
        ));
    }
    lanes.sort_by_key(|(r, _)| *r);
    let any = lanes.iter().any(|(_, l)| !l.nodes.is_empty());
    let lanes: Vec<Lane> = lanes.into_iter().map(|(_, l)| l).collect();
    Some(Section {
        kind: "journey".into(),
        id: rules::view_id(pkg, "journey", None),
        title: rules::view_title(pkg, "journey", None),
        empty_hint: if any {
            None
        } else {
            empty_hint(pkg, "journey")
        },
        body: serde_json::json!({ "lanes": lanes }),
    })
}

pub(crate) fn evidence_section(pkg: &Package, book: &EvidenceBook) -> Option<Section> {
    if pkg.state_vars.is_empty() {
        return None;
    }
    Some(Section {
        kind: "evidence".into(),
        id: rules::view_id(pkg, "evidence", None),
        title: rules::view_title(pkg, "evidence", None),
        empty_hint: if book.is_empty() {
            empty_hint(pkg, "evidence")
        } else {
            None
        },
        body: serde_json::json!({ "items": book.items }),
    })
}
