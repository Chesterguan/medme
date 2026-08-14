// Diagnostic companion to medrep.rs's own scoring (not one of the protected
// eval fixtures — this is a read-only lens on top of them, changing it can't
// move the reported numbers). `terminology::resolve` now has a fuzzy fallback
// (see packages/terminology/src/lib.rs's fuzzy_lookup); this traces how much
// of its effect comes from GT-side reinterpretation (resolve() applied to
// *ground-truth* names — that's how medrep.rs's own scoring buckets items into
// dictionary-covered vs not) vs OCR-extraction-side fuzzy hits, and dumps
// concrete examples so a regression in match quality is inspectable, not just
// a percentage.
//
// Modes:
//   --out <dir>                 GT-side + extraction-side fuzzy rescue dump (default).
//   --probe <name> [unit]       resolve() one string, show which candidates fired.
//   --bench --out <dir>         parser::extract_labs wall time, one arm, no GT overhead.
//
// Run: cargo run --release -p ocr --example medrep_fuzzy_diag --features engine,testing -- --out out_fuzzy

use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::PathBuf;

const ROOT: &str = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/datasets/medrepbench";
const VALUE_EPS: f64 = 0.01;

struct GtItem {
    name: String,
    value: Option<f64>,
    unit: String,
}

fn load_gt() -> Result<BTreeMap<String, Vec<GtItem>>> {
    let text = std::fs::read_to_string(format!("{ROOT}/gt.tsv")).context("读 gt.tsv")?;
    let mut out: BTreeMap<String, Vec<GtItem>> = BTreeMap::new();
    for line in text.lines() {
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() < 7 {
            continue;
        }
        let num = |s: &str| {
            if s == "NA" {
                None
            } else {
                s.parse::<f64>().ok()
            }
        };
        out.entry(c[0].to_string()).or_default().push(GtItem {
            name: c[1].to_string(),
            value: num(c[2]),
            unit: c[3].to_string(),
        });
    }
    Ok(out)
}

/// Would this name resolve via the EXACT path alone (no fuzzy)? Approximates
/// terminology::resolve's exact branch using only public API.
fn has_exact_hit(name: &str) -> bool {
    terminology::term_candidates(name)
        .iter()
        .any(|c| terminology::normalize(c).is_some())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1).cloned())
        .unwrap_or_else(|| "out_fuzzy".to_string());
    let dir = PathBuf::from(ROOT).join(&out).join("arm2_geo");

    if args.iter().any(|a| a == "--bench") {
        // 只量 parser::extract_labs 本身(单臂、一份份文档单独解析),不掺进 harness
        // 的 GT 侧重复 resolve() 调用——那是评测脚手架的开销,不是产品导入路径的一部分。
        let mut texts: Vec<String> = Vec::new();
        for entry in std::fs::read_dir(&dir)? {
            let p = entry?.path();
            if p.extension().is_some_and(|e| e == "txt") {
                texts.push(std::fs::read_to_string(&p)?);
            }
        }
        println!("{} 份文档(单臂:{}", texts.len(), dir.display());
        // 先跑一遍热身(词典 OnceLock 首次构建),再计时。
        for t in &texts {
            std::hint::black_box(parser::extract_labs(t));
        }
        let reps = 5usize;
        let start = std::time::Instant::now();
        for _ in 0..reps {
            for t in &texts {
                std::hint::black_box(parser::extract_labs(t));
            }
        }
        let elapsed = start.elapsed();
        let per_doc_us = elapsed.as_micros() as f64 / (texts.len() * reps) as f64;
        println!(
            "parser::extract_labs: {:.1} us/份(共 {reps} 轮 x {} 份 = {:.2}s)",
            per_doc_us,
            texts.len(),
            elapsed.as_secs_f64()
        );
        return Ok(());
    }

    if let Some(i) = args.iter().position(|a| a == "--probe") {
        let name = args.get(i + 1).cloned().unwrap_or_default();
        let unit = args.get(i + 2).filter(|s| !s.starts_with("--")).cloned();
        println!("probe name={name:?} unit={unit:?}");
        println!(
            "term_candidates = {:?}",
            terminology::term_candidates(&name)
        );
        println!("has_exact_hit = {}", has_exact_hit(&name));
        println!(
            "resolve() = {:?}",
            terminology::resolve(&name, unit.as_deref()).map(|m| (
                m.key,
                m.matched_alias,
                m.confidence
            ))
        );
        return Ok(());
    }

    let gt = load_gt()?;

    // 1) GT-side contamination: GT items with NO exact hit, but resolve() (fuzzy
    //    enabled) now returns Some.
    let mut gt_fuzzy_rescued: Vec<(String, String, String)> = Vec::new(); // (doc, name, key)
    for (doc, items) in &gt {
        for gi in items {
            let unit = if gi.unit.is_empty() {
                None
            } else {
                Some(gi.unit.as_str())
            };
            if has_exact_hit(&gi.name) {
                continue;
            }
            if let Some(m) = terminology::resolve(&gi.name, unit) {
                gt_fuzzy_rescued.push((doc.clone(), gi.name.clone(), m.key.clone()));
            }
        }
    }
    println!(
        "GT 侧:名字本身查不到精确命中、但 resolve()(模糊开启)给出了 key 的条目 = {}",
        gt_fuzzy_rescued.len()
    );
    for (doc, name, key) in gt_fuzzy_rescued.iter().take(40) {
        println!("  [{doc}] {name:?} -> {key}");
    }

    // 2) OCR-extraction-side: rows parser produced with a fuzzy-sourced key
    //    (raw_name has no exact hit, but got assigned a key).
    let mut extract_fuzzy_total = 0usize;
    let mut extract_fuzzy_wrong_doc = 0usize;
    let mut examples: Vec<(String, String, String, f64)> = Vec::new();
    for (doc, items) in &gt {
        let p = dir.join(format!("{doc}.txt"));
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let rows = parser::extract_labs(&text);
        for r in &rows {
            let Some(k) = &r.analyte_key else { continue };
            if has_exact_hit(&r.raw_name) {
                continue;
            }
            extract_fuzzy_total += 1;
            // Was this row's key/value actually right per GT?
            let gt_vals: Vec<f64> = items
                .iter()
                .filter(|gi| {
                    let unit = if gi.unit.is_empty() {
                        None
                    } else {
                        Some(gi.unit.as_str())
                    };
                    terminology::resolve(&gi.name, unit).map(|m| m.key) == Some(k.clone())
                })
                .filter_map(|gi| gi.value)
                .collect();
            let correct = gt_vals.iter().any(|v| (v - r.value_num).abs() < VALUE_EPS);
            if !correct {
                extract_fuzzy_wrong_doc += 1;
                if examples.len() < 40 {
                    examples.push((doc.clone(), r.raw_name.clone(), k.clone(), r.value_num));
                }
            }
        }
    }
    println!();
    println!(
        "OCR 抽取侧:raw_name 本身查不到精确命中、但抽出了某 key 的行 = {extract_fuzzy_total},其中数值对不上真值(该 key 下任何真值)= {extract_fuzzy_wrong_doc}"
    );
    for (doc, raw, key, val) in &examples {
        println!("  [{doc}] raw={raw:?} -> key={key} val={val}");
    }

    Ok(())
}
