// 金标集评分:第一次同时量得准**召回**和**精度**。
//
// ## 为什么非做不可
//
// MedRepBench 自带的标注有两个性质,使它**量不了精度**:
//
// 1. **子集标注** —— 纸上印着的化验项它只标了一部分。看原图逐条核实过:某份报告
//    我们正确抽出的 `球蛋白=41`、`C反应蛋白=16.0`、`葡萄糖=16.1` 它一条都没标。
//    于是「我们抽出、真值里没有」这件事既可能是我们无中生有,也可能是它漏标,
//    **无法区分** → 精度不可测。
// 2. **去标识化把部分结果值涂成了灰块,而标注来自原始报告** —— 那些数字图上根本
//    不存在,任何方法都读不出来,却一直算我们「漏掉」。
//
// 金标集是人工看原图、对 50 份报告**逐条全量誊录**的结果,每条带状态:
//   - `ok`       项目名与结果值都清晰可读 —— **只有这类进召回分母**
//   - `redacted` 该行存在但结果值被灰块涂掉 —— 任何方法都读不出。**不进召回分母**,
//                但如果我们竟然为它产出了一个数值,那一定是**伪造**的,计入精度的错误项。
//   - `unclear`  模糊/反光/裁切,标注者自己不敢担保 —— 两边都不计,避免用不确定的
//                标注去判别人对错。
//
// ## 三个指标
//
// - **召回** = 抽对的 ok 条目 / 全部 ok 条目
// - **精度** = 抽对的行 / 我们产出的全部行(**这是新的,MedRepBench 给不了**)
// - **伪造率** = 为 `redacted` 行产出了数值的次数 / 我们产出的全部行。这是最危险的
//   一类:图上那个格子是空的,我们却报了一个看着合理的数 —— 已知的一个来源是把
//   参考区间的下界当成了结果值(实测尿酸报成 208,而 208 是区间下限 208—428)。
//
// 跑法:`cargo run --release -p ocr --example medrep_gold --features engine,testing -- --out out_ALL`

use anyhow::{Context, Result};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

const ROOT: &str = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/datasets/medrepbench";
const VALUE_EPS: f64 = 0.01;

#[derive(Debug, Clone)]
struct GoldItem {
    name: String,
    value: Option<f64>,
    unit: String,
    status: String,
    /// 由 `terminology::resolve` 解析出的指标 key;解析不出为 None(词典缺口,
    /// 单独统计,不算在召回分母里 —— 否则会把「词典没收这个指标」和
    /// 「版面读错了」混成一个数)。
    key: Option<String>,
}

fn load_gold() -> Result<BTreeMap<String, Vec<GoldItem>>> {
    let dir = PathBuf::from(ROOT).join("gold");
    let mut out: BTreeMap<String, Vec<GoldItem>> = BTreeMap::new();
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .with_context(|| format!("读 {}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "tsv"))
        .collect();
    files.sort();
    anyhow::ensure!(!files.is_empty(), "gold/ 下没有 .tsv,标注还没完成");
    for f in files {
        for line in std::fs::read_to_string(&f)?.lines() {
            let c: Vec<&str> = line.split('\t').collect();
            if c.len() < 6 {
                continue;
            }
            let (doc, name, val, unit, status) =
                (c[0], c[1].trim(), c[2].trim(), c[3].trim(), c[5].trim());
            if doc.is_empty() || name.is_empty() {
                continue;
            }
            let key = terminology::resolve(name, if unit.is_empty() { None } else { Some(unit) })
                .map(|m| m.key.to_string());
            out.entry(doc.to_string()).or_default().push(GoldItem {
                name: name.to_string(),
                value: val.parse::<f64>().ok(),
                unit: unit.to_string(),
                status: status.to_string(),
                key,
            });
        }
    }
    Ok(out)
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1).cloned())
        .unwrap_or_else(|| "out_ALL".to_string());

    let gold = load_gold()?;
    println!(
        "# 金标集评分 —— {} 份报告(人工看原图逐条全量标注)",
        gold.len()
    );
    println!();

    for arm in ["arm1_bare", "arm2_geo", "arm3_struct"] {
        let dir = PathBuf::from(ROOT).join(&out).join(arm);
        if !dir.is_dir() {
            continue;
        }
        // 召回侧
        let (mut rec_hit, mut rec_den) = (0usize, 0usize);
        let mut no_dict = 0usize; // ok 条目但词典不认得 —— 上游天花板,不进召回分母
        let mut qual = 0usize; // ok 条目但结果是定性的 —— labs.rs 不处理
                               // 精度侧
        let (mut prec_ok, mut prec_all) = (0usize, 0usize);
        let mut wrong_value = 0usize; // 指标对、数值错
        let mut fabricated = 0usize; // 为 redacted 行产出了数值
        let mut not_on_page = 0usize; // 金标里根本没有这个指标 —— 无中生有
        let mut docs = 0usize;

        for (doc, items) in &gold {
            let Ok(text) = std::fs::read_to_string(dir.join(format!("{doc}.txt"))) else {
                continue;
            };
            docs += 1;
            let rows = parser::extract_labs(&text);

            // key → 该文档金标里这个指标的(可读数值集合, 是否有被涂掉的行)
            let mut ok_vals: HashMap<&str, Vec<f64>> = HashMap::new();
            let mut redacted_keys: HashSet<&str> = HashSet::new();
            for g in items {
                let Some(k) = g.key.as_deref() else { continue };
                match g.status.as_str() {
                    "ok" => {
                        if let Some(v) = g.value {
                            ok_vals.entry(k).or_default().push(v);
                        }
                    }
                    "redacted" => {
                        redacted_keys.insert(k);
                    }
                    _ => {}
                }
            }

            // ---- 召回:只数 status=ok 且词典认得且数值是数的
            for g in items {
                if g.status != "ok" {
                    continue;
                }
                let Some(k) = g.key.as_deref() else {
                    no_dict += 1;
                    continue;
                };
                let Some(v) = g.value else {
                    qual += 1;
                    continue;
                };
                rec_den += 1;
                if rows.iter().any(|r| {
                    r.analyte_key.as_deref() == Some(k) && (r.value_num - v).abs() < VALUE_EPS
                }) {
                    rec_hit += 1;
                }
            }

            // ---- 精度:我们产出的每一行,是不是纸上真有、且值对
            for r in &rows {
                let Some(k) = r.analyte_key.as_deref() else {
                    continue; // 没解析出指标的行不进入趋势,不计
                };
                prec_all += 1;
                match ok_vals.get(k) {
                    Some(vals) if vals.iter().any(|v| (v - r.value_num).abs() < VALUE_EPS) => {
                        prec_ok += 1
                    }
                    Some(_) => wrong_value += 1,
                    None if redacted_keys.contains(k) => fabricated += 1,
                    None => not_on_page += 1,
                }
            }
        }

        let pct = |h: usize, d: usize| {
            if d == 0 {
                0.0
            } else {
                h as f64 / d as f64 * 100.0
            }
        };
        println!("## {arm}({docs} 份)");
        println!();
        println!("| 指标 | 值 |");
        println!("|---|---|");
        println!(
            "| **召回**(抽对 / 清晰可读的化验项) | {:.1}% ({rec_hit}/{rec_den}) |",
            pct(rec_hit, rec_den)
        );
        println!(
            "| **精度**(抽对 / 我们产出的全部行) | {:.1}% ({prec_ok}/{prec_all}) |",
            pct(prec_ok, prec_all)
        );
        println!(
            "| ├ 指标对、数值错 | {:.1}% ({wrong_value}/{prec_all}) |",
            pct(wrong_value, prec_all)
        );
        println!(
            "| ├ **为被涂掉的行伪造了数值** | {:.1}% ({fabricated}/{prec_all}) |",
            pct(fabricated, prec_all)
        );
        println!(
            "| └ 纸上根本没有这个指标 | {:.1}% ({not_on_page}/{prec_all}) |",
            pct(not_on_page, prec_all)
        );
        println!("| 词典不认得(不进召回分母) | {no_dict} 条 |");
        println!("| 定性结果(labs.rs 不处理) | {qual} 条 |");
        println!();
    }
    Ok(())
}
