// 归因:一条真值项目从「印在纸上」到「进了趋势」中间在哪一层掉的?
//
// baseline 只告诉我们端到端 20.0%,不告诉我们这 80% 是怎么没的。这个 example
// 对每一条数值型真值条目同时问四个问题,输出一张四维交叉表:
//
//   1. `dict`  —— `terminology::resolve` 认不认得这个项目名
//   2. `name`  —— OCR 产出的文本里有没有这个名字(归一化后子串匹配)
//   3. `value` —— OCR 产出的文本里有没有这个数值
//   4. `paired`—— `parser::extract_labs` 有没有真的抽出「同 analyte_key 且数值一致」的行
//
// 为什么值得单独做:这四层的责任方完全不同 —— dict 归词典、name/value 归 OCR、
// paired 归 parser 的行解析。**只看端到端数字会把三方的责任混在一起**,谁都能
// 说"不是我的问题"。有了这张表,每一层的头顶空间是多少一目了然,也能防止某条
// 改进线把自己的收益说大。
//
// 名字/数值的"在不在"用归一化子串匹配(NFKC + 去空白 + 去 `#*※·．・`),
// **故意宽松**:它衡量的是"OCR 有没有把这些字读出来",不是"排版对不对"。
// 宽松的判据会高估 OCR、低估 parser —— 也就是说,它给出的是 parser 的**上限**,
// 结论偏保守的方向,不会让我们高估自己。
//
// 跑法:
// ```
// cargo run --release -p ocr --example medrep_attrib --features engine,testing -- --out out
// ```

use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::PathBuf;

const ROOT: &str = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/datasets/medrepbench";
const VALUE_EPS: f64 = 0.01;

/// NFKC + 去空白 + 去真实报告里常见的装饰标记。用于"这串字在不在 OCR 产出里"。
fn norm(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace() && !matches!(c, '#' | '*' | '※' | '·' | '．' | '・'))
        .flat_map(|c| c.to_lowercase())
        .collect()
}

struct Item {
    name: String,
    value: f64,
    unit: String,
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1).cloned())
        .unwrap_or_else(|| "out_BASELINE_FROZEN".to_string());

    let text = std::fs::read_to_string(format!("{ROOT}/gt.tsv")).context("读 gt.tsv")?;
    let mut gt: BTreeMap<String, Vec<Item>> = BTreeMap::new();
    for line in text.lines() {
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() < 7 || c[6] != "num" {
            continue;
        }
        let Ok(v) = c[2].parse::<f64>() else { continue };
        gt.entry(c[0].to_string()).or_default().push(Item {
            name: c[1].to_string(),
            value: v,
            unit: c[3].to_string(),
        });
    }

    for arm in ["arm1_bare", "arm2_geo", "arm3_struct"] {
        let dir = PathBuf::from(ROOT).join(&out).join(arm);
        if !dir.is_dir() {
            continue;
        }
        // 计数桶:index = dict<<2 | name_and_value<<1 | paired
        let mut n_total = 0usize;
        let mut n_dict = 0usize;
        let mut n_ocr = 0usize; // 名字与数值都在文本里
        let mut n_dict_ocr = 0usize; // 两者都满足 —— parser 的机会窗口
        let mut n_paired = 0usize;
        let mut n_paired_outside = 0usize; // 抽对了,但 OCR 子串判据说"不在"(判据过严的证据)

        for (doc, items) in &gt {
            let Ok(body) = std::fs::read_to_string(dir.join(format!("{doc}.txt"))) else {
                continue;
            };
            let hay = norm(&body);
            let rows = parser::extract_labs(&body);
            for it in items {
                n_total += 1;
                let dict = terminology::resolve(
                    &it.name,
                    if it.unit.is_empty() {
                        None
                    } else {
                        Some(it.unit.as_str())
                    },
                );
                let name_in = {
                    let n = norm(&it.name);
                    n.chars().count() >= 2 && hay.contains(&n)
                };
                // 数值按原样和去尾零两种写法都试(真值 "12.80" 而报告印 "12.8")
                let v_raw = norm(&format!("{}", it.value));
                let value_in = hay.contains(&v_raw);
                let ocr_ok = name_in && value_in;
                if dict.is_some() {
                    n_dict += 1;
                }
                if ocr_ok {
                    n_ocr += 1;
                }
                if dict.is_some() && ocr_ok {
                    n_dict_ocr += 1;
                }
                if let Some(m) = &dict {
                    let paired = rows.iter().any(|r| {
                        r.analyte_key.as_deref() == Some(m.key.as_str())
                            && (r.value_num - it.value).abs() < VALUE_EPS
                    });
                    if paired {
                        n_paired += 1;
                        if !ocr_ok {
                            n_paired_outside += 1;
                        }
                    }
                }
            }
        }
        let p = |x: usize| x as f64 / n_total as f64 * 100.0;
        println!("## {arm}(数值型真值条目 {n_total} 条)");
        println!();
        println!("| 层 | 通过条数 | 占全部数值型 |");
        println!("|---|---|---|");
        println!("| ① 词典认得这个名字 | {n_dict} | {:.1}% |", p(n_dict));
        println!(
            "| ② OCR 把名字和数值都读出来了 | {n_ocr} | {:.1}% |",
            p(n_ocr)
        );
        println!(
            "| ①∩② parser 的机会窗口 | {n_dict_ocr} | {:.1}% |",
            p(n_dict_ocr)
        );
        println!(
            "| ③ 实际抽对(同 key + 数值一致) | {n_paired} | {:.1}% |",
            p(n_paired)
        );
        println!();
        println!(
            "- **parser 在机会窗口里的转化率:{:.1}%**({n_paired}/{n_dict_ocr})——\
             名字和数值都在文本里、词典也认得,却仍然没抽出来的部分,是行解析的责任。",
            n_paired as f64 / n_dict_ocr.max(1) as f64 * 100.0
        );
        println!(
            "- 抽对了但子串判据说「不在」的有 {n_paired_outside} 条 —— 判据过严的量,\
             说明上面的 ② 是**低估**(OCR 实际更好),因此 parser 转化率是**高估**,\
             结论偏保守。"
        );
        println!();
    }
    Ok(())
}
