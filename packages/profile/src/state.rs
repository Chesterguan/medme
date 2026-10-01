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
//! 不下结论:变量只陈述已知值与截至日期;`stale` 只说「多久没有新证据」,不说「可能已停药」。
use std::collections::HashMap;

use chrono::NaiveDate;
use serde::Serialize;

use crate::package::{Package, StateVar};
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
    pub verified: bool,
}

#[derive(Default)]
pub(crate) struct EvidenceBook {
    items: Vec<EvidenceOut>,
    seen: HashMap<(Option<usize>, String, String), String>,
    per_doc: HashMap<Option<usize>, usize>,
}

impl EvidenceBook {
    /// 登记一条依据,返回它的 id;同一份文档同一句同一路径只登记一次。
    pub(crate) fn cite(
        &mut self,
        ctx: &Ctx<'_>,
        doc: Option<usize>,
        needle: &str,
        origin: &str,
        verified: bool,
        date_if_no_doc: Option<NaiveDate>,
        whole_line: bool,
    ) -> String {
        let key = (doc, needle.to_string(), origin.to_string());
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
        let (quote, span) = match d {
            Some(d) if !needle.is_empty() => match d.text.find(needle) {
                Some(start) => {
                    let end = start + needle.len();
                    // 药名、化验值这种短 token 给人看要带上下文,取含它的一整行;模型抽
                    // 的 evidence 本来就是一句完整原话,原样给。span 都只圈 needle 本身。
                    let quote = if whole_line {
                        let line_start = d.text[..start].rfind('\n').map_or(0, |i| i + 1);
                        let line_end = d.text[end..]
                            .find('\n')
                            .map_or(d.text.len(), |i| end + i);
                        d.text[line_start..line_end].trim().to_string()
                    } else {
                        needle.to_string()
                    };
                    (quote, Some([start, end]))
                }
                None => (needle.to_string(), None),
            },
            _ => (needle.to_string(), None),
        };
        self.items.push(EvidenceOut {
            id: id.clone(),
            doc,
            date: d.and_then(|x| x.date).or(date_if_no_doc).map(|x| x.to_string()),
            title: d.and_then(|x| x.title.clone()),
            quote,
            span,
            origin: origin.to_string(),
            verified,
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
    text: Option<String>,
    evidence: Vec<String>,
    unverified: bool,
}

#[derive(Debug, Clone, Serialize)]
struct Lane {
    key: String,
    label: String,
    /// `verified`(有核过的节点)/ `needs_review`(节点全是没核上的)/ `empty`。
    quality: String,
    nodes: Vec<Node>,
}

/// 事件型 fact 的泳道;顺序即展示顺序。标签是族级通用词,不是病种文案。
const EVENT_LANES: [(&str, &str); 6] = [
    ("flare", "复发 / 加重"),
    ("hospitalization", "住院"),
    ("biopsy", "活检"),
    ("infusion", "输注"),
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

fn spans_of_class<'c>(ctx: &'c Ctx<'_>, pkg: &Package, class: &str) -> Vec<&'c parser::MedSpan> {
    ctx.clinical
        .meds
        .iter()
        .filter(|m| rules::drug_class(pkg, m).is_some_and(|d| d.class == class))
        .collect()
}

fn lab_origin(ctx: &Ctx<'_>, doc: usize) -> &'static str {
    if ctx.raw_labs.iter().any(|(i, _, _)| *i == doc) {
        "llm"
    } else {
        "regex"
    }
}

fn cite_span(ctx: &Ctx<'_>, book: &mut EvidenceBook, m: &parser::MedSpan) -> Vec<String> {
    let needle = m.latest_raw_name.clone().unwrap_or_else(|| m.name.clone());
    vec![book.cite(
        ctx,
        m.latest_source,
        &needle,
        m.latest_origin.as_deref().unwrap_or("regex"),
        !m.unverified,
        None,
        true,
    )]
}

fn cite_lab(ctx: &Ctx<'_>, book: &mut EvidenceBook, e: &rules::Evidence) -> String {
    let origin = lab_origin(ctx, e.document_index);
    book.cite(ctx, Some(e.document_index), &e.value, origin, true, None, true)
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
            row.note = body.get("reason").and_then(|v| v.as_str()).map(str::to_string);
            if let Some(m) = newest {
                as_of = m.end;
                row.evidence = cite_span(ctx, book, m);
            }
            if let Some((at, kg, src, doc)) = rules::latest_weight_kg(ctx, &pkg.manifest.id) {
                let id = match (src.as_str(), doc) {
                    ("record", Some(d)) => book.cite(ctx, Some(d), &fmt_num(kg), lab_origin(ctx, d), true, at, true),
                    _ => book.cite(ctx, None, &format!("自测体重 {} kg", fmt_num(kg)), "self_entry", true, at, false),
                };
                row.evidence.push(id);
            }
        }
        "band" => {
            let a = &pkg.rules.activity;
            if activity.hits.is_empty() && activity.missed.is_empty() {
                row.note = Some(format!("最近 {} 天内没有化验结果,算不出来", a.window_days));
                return Some(row);
            }
            let score = rules::weight_sum(&activity.hits);
            let band = pkg.rules.bands.bands.iter().find(|b| {
                b.min.is_none_or(|lo| score >= lo) && b.max.is_none_or(|hi| score <= hi)
            });
            row.value = band.map(|b| b.label.clone());
            row.note = Some(format!("化验可算部分 {score}/{}", a.max));
            if row.source.is_none() {
                row.source = band.and_then(|b| b.source.clone()).or(pkg.rules.bands.source.clone());
            }
            for h in &activity.hits {
                for e in &h.evidence {
                    let d = e.date.as_deref().and_then(|s| s.parse::<NaiveDate>().ok());
                    as_of = as_of.max(d);
                    let id = cite_lab(ctx, book, e);
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
            let actual = out.get("actual").and_then(|v| v.as_f64()).map(fmt_num);
            let unit = rules::str_field(&out, "actual_unit");
            row.note = match actual {
                Some(a) if !unit.is_empty() => Some(format!("最近值 {a} {unit}")),
                Some(a) => Some(format!("最近值 {a}")),
                None => out.get("reason").and_then(|v| v.as_str()).map(str::to_string),
            };
            as_of = out.get("actual_at").and_then(|v| v.as_str()).and_then(|s| s.parse().ok());
            if let Some(evs) = out.get("evidence").and_then(|v| v.as_array()) {
                for e in evs {
                    let Ok(e) = serde_json::from_value::<rules::Evidence>(e.clone()) else {
                        continue;
                    };
                    let id = cite_lab(ctx, book, &e);
                    if !row.evidence.contains(&id) {
                        row.evidence.push(id);
                    }
                }
            }
            // 「现在」要的是**最近一次**该指标的值与日期,不是里程碑第一次达到的那天:
            // `upcr_below_500_any` 判的是「任一时点」,它的 actual_at 是首次达标日,拿来
            // 当截至日期会把半年后仍然达标的人标成「陈旧」。verdict 仍用里程碑的判定。
            let key = rules::str_field(item, "key");
            let latest = ctx
                .clinical
                .labs
                .iter()
                .filter(|s| s.analyte_key.as_deref() == Some(key) && !s.self_measured)
                .flat_map(|s| s.points.iter().map(move |p| (s, p)))
                .filter(|(_, p)| p.date.is_some_and(|d| d <= ctx.today))
                .max_by_key(|(_, p)| p.date);
            if let Some((s, p)) = latest {
                let unit = s.unit_canonical.clone().unwrap_or_default();
                row.note = Some(if unit.is_empty() {
                    format!("最近值 {}", fmt_num(p.value))
                } else {
                    format!("最近值 {} {unit}", fmt_num(p.value))
                });
                as_of = p.date;
                let e = rules::Evidence {
                    document_index: p.source,
                    date: p.date.map(|d| d.to_string()),
                    analyte: key.to_string(),
                    value: fmt_num(p.value),
                    unit: p.unit.clone(),
                    value_canonical: p.value_canonical,
                    unit_canonical: s.unit_canonical.clone(),
                    values_converted: s.values_converted,
                };
                let id = cite_lab(ctx, book, &e);
                if !row.evidence.contains(&id) {
                    row.evidence.insert(0, id);
                }
            }
            if row.source.is_none() {
                row.source = out.get("source").and_then(|v| v.as_str()).map(str::to_string);
            }
        }
        "latest_value" => {
            let marker = var.marker.as_deref().unwrap_or_default();
            let best = ctx
                .clinical
                .labs
                .iter()
                .filter(|s| s.analyte_key.as_deref() == Some(marker) && !s.self_measured)
                .flat_map(|s| s.points.iter().map(move |p| (s, p)))
                .filter(|(_, p)| p.date.is_some_and(|d| d <= ctx.today))
                .max_by_key(|(_, p)| p.date);
            match best {
                Some((s, p)) => {
                    row.value = Some(fmt_num(p.value));
                    if row.unit.is_none() {
                        row.unit = s.unit_canonical.clone();
                    }
                    as_of = p.date;
                    let e = rules::Evidence {
                        document_index: p.source,
                        date: p.date.map(|d| d.to_string()),
                        analyte: marker.to_string(),
                        value: fmt_num(p.value),
                        unit: p.unit.clone(),
                        value_canonical: p.value_canonical,
                        unit_canonical: s.unit_canonical.clone(),
                        values_converted: s.values_converted,
                    };
                    row.evidence = vec![cite_lab(ctx, book, &e)];
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
        empty_hint: if any_value { None } else { empty_hint(pkg, "state") },
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

fn fact_date(doc_date: Option<NaiveDate>, f: &deid::Fact) -> Option<NaiveDate> {
    [f.date.as_str(), f.date_start.as_str()]
        .iter()
        .find_map(|s| s.parse::<NaiveDate>().ok())
        .or(doc_date)
}

fn dose_lane_nodes(
    ctx: &Ctx<'_>,
    pkg: &Package,
    class: &str,
    book: &mut EvidenceBook,
) -> Vec<Node> {
    let mut mentions: Vec<&parser::MedMention> = spans_of_class(ctx, pkg, class)
        .iter()
        .flat_map(|m| m.mentions.iter())
        .filter(|x| x.dose.is_some())
        .collect();
    mentions.sort_by_key(|x| x.date.map_or((1, NaiveDate::MAX), |d| (0, d)));
    let mut nodes: Vec<Node> = Vec::new();
    let mut prev: Option<&str> = None;
    for m in mentions {
        let dose = m.dose.as_deref().unwrap_or_default();
        if prev == Some(dose) {
            continue;
        }
        let id = book.cite(ctx, Some(m.source), &m.raw_name, &m.origin, !m.unverified, None, true);
        nodes.push(Node {
            at: m.date.map(|d| d.to_string()),
            kind: if prev.is_none() { "first" } else { "change" }.into(),
            from: prev.map(str::to_string),
            to: dose.to_string(),
            text: Some(m.raw_name.clone()),
            evidence: vec![id],
            unverified: m.unverified,
        });
        prev = Some(dose);
    }
    // 模型抽出来的 dose_change 事实(「激素减至 10mg」):药名对得上这一类就并进来。
    let names: Vec<&str> = pkg
        .drugs
        .iter()
        .filter(|d| d.class == class)
        .flat_map(|d| d.names.iter().map(String::as_str))
        .collect();
    for (doc, doc_date, f) in &ctx.facts {
        if f.r#type != "dose_change" || f.drug.trim().is_empty() {
            continue;
        }
        if !names.iter().any(|n| f.drug.contains(n) || n.contains(f.drug.as_str())) {
            continue;
        }
        let at = fact_date(*doc_date, f).map(|d| d.to_string());
        // 同一天、同一个目标剂量,「提及」已经出过节点(「激素 10mg 每日一次」)就不再
        // 为 dose_change 事实(to:"10mg")重复出一条:两边写法长短不一,按前缀对。
        let same = |a: &str, b: &str| {
            let (a, b) = (a.trim(), b.trim());
            !a.is_empty() && !b.is_empty() && (a == b || a.starts_with(b) || b.starts_with(a))
        };
        if nodes.iter().any(|n| n.at == at && same(&n.to, &f.to)) {
            continue;
        }
        let id = book.cite(ctx, Some(*doc), &f.evidence, "llm", !f.unverified, None, false);
        nodes.push(Node {
            at,
            kind: "dose_change".into(),
            from: (!f.from.trim().is_empty()).then(|| f.from.clone()),
            to: f.to.clone(),
            text: Some(f.evidence.clone()),
            evidence: vec![id],
            unverified: f.unverified,
        });
    }
    nodes.sort_by(|a, b| a.at.cmp(&b.at));
    nodes
}

fn series_lane_nodes(ctx: &Ctx<'_>, key: &str, book: &mut EvidenceBook) -> Vec<Node> {
    let mut pts: Vec<(&parser::AnalyteSeries, &parser::LabPoint)> = ctx
        .clinical
        .labs
        .iter()
        .filter(|s| s.analyte_key.as_deref() == Some(key) && !s.self_measured)
        .flat_map(|s| s.points.iter().map(move |p| (s, p)))
        .filter(|(_, p)| p.date.is_some())
        .collect();
    pts.sort_by_key(|(_, p)| p.date);
    pts.into_iter()
        .map(|(s, p)| {
            let e = rules::Evidence {
                document_index: p.source,
                date: p.date.map(|d| d.to_string()),
                analyte: key.to_string(),
                value: fmt_num(p.value),
                unit: p.unit.clone(),
                value_canonical: p.value_canonical,
                unit_canonical: s.unit_canonical.clone(),
                values_converted: s.values_converted,
            };
            let id = cite_lab(ctx, book, &e);
            Node {
                at: p.date.map(|d| d.to_string()),
                kind: "point".into(),
                from: None,
                to: match &s.unit_canonical {
                    Some(u) => format!("{} {u}", fmt_num(p.value)),
                    None => fmt_num(p.value),
                },
                text: p.flag.clone(),
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

pub(crate) fn journey_section(ctx: &Ctx<'_>, pkg: &Package, book: &mut EvidenceBook) -> Option<Section> {
    if pkg.state_vars.is_empty() {
        return None;
    }
    // (排序键, 泳道):变量泳道有核过的变更 → 0;事件泳道 → 1;需核对 → 2;空 → 3。
    let mut lanes: Vec<(u8, Lane)> = Vec::new();
    for var in &pkg.state_vars {
        let nodes = match var.derive.as_str() {
            "latest_dose" | "ratio_to_weight" => {
                dose_lane_nodes(ctx, pkg, var.drug_class.as_deref().unwrap_or_default(), book)
            }
            "milestone" => {
                let key = pkg
                    .rules
                    .milestones
                    .iter()
                    .find(|it| rules::str_field(it, "id") == var.milestone.as_deref().unwrap_or_default())
                    .map(|it| rules::str_field(it, "key").to_string())
                    .unwrap_or_default();
                series_lane_nodes(ctx, &key, book)
            }
            "latest_value" => series_lane_nodes(ctx, var.marker.as_deref().unwrap_or_default(), book),
            // 分档没有逐日历史(分数只对今天的窗口算),泳道留空。
            _ => Vec::new(),
        };
        let q = quality(&nodes);
        let rank = match q {
            "verified" => 0,
            "needs_review" => 2,
            _ => 3,
        };
        lanes.push((rank, Lane { key: var.key.clone(), label: var.label.clone(), quality: q.into(), nodes }));
    }
    for (ty, label) in EVENT_LANES {
        let mut nodes: Vec<Node> = ctx
            .facts
            .iter()
            .filter(|(_, _, f)| f.r#type == ty)
            .map(|(doc, doc_date, f)| {
                let id = book.cite(ctx, Some(*doc), &f.evidence, "llm", !f.unverified, None, false);
                let to = match ty {
                    "hospitalization" if !f.date_start.is_empty() && !f.date_end.is_empty() => {
                        format!("{} → {}", f.date_start, f.date_end)
                    }
                    "infusion" => [f.drug.as_str(), f.dose.as_str()]
                        .iter()
                        .filter(|s| !s.is_empty())
                        .copied()
                        .collect::<Vec<_>>()
                        .join(" "),
                    "biopsy" => [f.organ.as_str(), f.result.as_str()]
                        .iter()
                        .filter(|s| !s.is_empty())
                        .copied()
                        .collect::<Vec<_>>()
                        .join(" "),
                    _ => [f.text.as_str(), f.reason.as_str(), f.status.as_str(), f.evidence.as_str()]
                        .iter()
                        .find(|s| !s.trim().is_empty())
                        .map_or(String::new(), |s| s.to_string()),
                };
                Node {
                    at: fact_date(*doc_date, f).map(|d| d.to_string()),
                    kind: ty.into(),
                    from: None,
                    to,
                    text: (!f.evidence.is_empty()).then(|| f.evidence.clone()),
                    evidence: vec![id],
                    unverified: f.unverified,
                }
            })
            .collect();
        if nodes.is_empty() {
            continue;
        }
        nodes.sort_by(|a, b| a.at.cmp(&b.at));
        let q = quality(&nodes);
        let rank = if q == "verified" { 1 } else { 2 };
        lanes.push((rank, Lane { key: ty.into(), label: label.into(), quality: q.into(), nodes }));
    }
    lanes.sort_by_key(|(r, _)| *r);
    let any = lanes.iter().any(|(_, l)| !l.nodes.is_empty());
    let lanes: Vec<Lane> = lanes.into_iter().map(|(_, l)| l).collect();
    Some(Section {
        kind: "journey".into(),
        id: rules::view_id(pkg, "journey", None),
        title: rules::view_title(pkg, "journey", None),
        empty_hint: if any { None } else { empty_hint(pkg, "journey") },
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
        empty_hint: if book.is_empty() { empty_hint(pkg, "evidence") } else { None },
        body: serde_json::json!({ "items": book.items }),
    })
}
