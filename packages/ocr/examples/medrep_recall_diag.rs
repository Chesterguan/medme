// 诊断专用,不是评测夹具:把「项目召回」的失配案例按根因分桶计数,给改进线定位
// 该先啃哪一块。不影响 medrep.rs / medrep_attrib.rs 的任何评分逻辑,只读它们已经
// 产出的 arm2_geo 文本 + gt.tsv 真值,自己再跑一遍 parser::extract_labs 做归类。
//
// 跑法:
// cargo run --release -p ocr --example medrep_recall_diag -- --out out_recall [--samples 5]

use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::PathBuf;

const ROOT: &str = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/datasets/medrepbench";

/// 与 medrep_attrib.rs 的 norm() 逐字相同 —— 判据必须一致,不能各诊断各的。
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

#[derive(Default)]
struct Bucket {
    count: usize,
    samples: Vec<(String, String)>, // (doc, context)
}

impl Bucket {
    fn hit(&mut self, doc: &str, ctx: String, keep: usize) {
        self.count += 1;
        if self.samples.len() < keep {
            self.samples.push((doc.to_string(), ctx));
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let out = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1).cloned())
        .unwrap_or_else(|| "out_recall".to_string());
    let samples: usize = args
        .iter()
        .position(|a| a == "--samples")
        .and_then(|i| args.get(i + 1).cloned())
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);

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

    let dir = PathBuf::from(ROOT).join(&out).join("arm2_geo");
    anyhow::ensure!(dir.is_dir(), "{} 不存在,先跑 --produce", dir.display());

    let mut b_name_missing = Bucket::default(); // OCR 没读到名字(不管数值)
    let mut b_value_missing = Bucket::default(); // 名字读到了,数值没读到
    let mut b_same_line_serial = Bucket::default(); // 同行,行首粘着序号且行内还有别的列(bare-pair 限制卡住)
    let mut b_same_line_multi = Bucket::default(); // 同行,这一行已经被解析成另一条目(双栏/多项目挤一行)
    let mut b_same_line_other = Bucket::default(); // 同行,原因待查
    let mut b_wrap_adjacent = Bucket::default(); // 名在一行、数在紧邻的下一行/上一行
    let mut b_wrap_far = Bucket::default(); // 名与数都读到了,但隔了 2+ 行
    let mut b_dict_key_mismatch = Bucket::default(); // 名和数同行且被抽出,但 analyte_key 对不上真值(词典歧义)

    let mut n_total = 0usize;
    let mut n_miss = 0usize;

    for (doc, items) in &gt {
        let Ok(body) = std::fs::read_to_string(dir.join(format!("{doc}.txt"))) else {
            continue;
        };
        let lines: Vec<&str> = body.lines().collect();
        let rows = parser::extract_labs(&body);

        for it in items {
            let Some(m) = terminology::resolve(
                &it.name,
                if it.unit.is_empty() {
                    None
                } else {
                    Some(it.unit.as_str())
                },
            ) else {
                continue; // 词典未覆盖,不属于本诊断范围
            };
            n_total += 1;

            let recalled = rows
                .iter()
                .any(|r| r.analyte_key.as_deref() == Some(m.key.as_str()));
            if recalled {
                continue;
            }
            n_miss += 1;

            let name_norm = norm(&it.name);
            let value_raw = norm(&format!("{}", it.value));
            let name_ok = name_norm.chars().count() >= 2;

            let name_lines: Vec<usize> = if name_ok {
                lines
                    .iter()
                    .enumerate()
                    .filter(|(_, l)| norm(l).contains(&name_norm))
                    .map(|(i, _)| i)
                    .collect()
            } else {
                Vec::new()
            };
            let value_lines: Vec<usize> = lines
                .iter()
                .enumerate()
                .filter(|(_, l)| norm(l).contains(&value_raw))
                .map(|(i, _)| i)
                .collect();

            if name_lines.is_empty() {
                b_name_missing.hit(
                    doc,
                    format!("真值名={} 数值={}", it.name, it.value),
                    samples,
                );
                continue;
            }
            if value_lines.is_empty() {
                b_value_missing.hit(
                    doc,
                    format!(
                        "真值名={} 数值={} | 名字所在行: {:?}",
                        it.name,
                        it.value,
                        name_lines.iter().map(|&i| lines[i]).collect::<Vec<_>>()
                    ),
                    samples,
                );
                continue;
            }

            // 名字和数值都读到了 —— 找同一行的交集
            let same_line: Vec<usize> = name_lines
                .iter()
                .copied()
                .filter(|i| value_lines.contains(i))
                .collect();

            if let Some(&li) = same_line.first() {
                let line = lines[li];
                let trimmed = line.trim_start();
                let starts_with_serial = trimmed.chars().next().is_some_and(|c| c.is_ascii_digit());
                // 这一行是否已经被 parser 解析成了别的行(说明它被消费给了别的项目,
                // 常见于双栏/一行挤两项目 —— parser 一行只产一条)
                let line_already_used = rows.iter().any(|r| {
                    line.contains(&r.raw_name) && {
                        let vs = format!("{}", r.value_num);
                        line.contains(&vs)
                    }
                });
                if line_already_used {
                    b_same_line_multi.hit(
                        doc,
                        format!("真值名={} 数值={} | 行: {:?}", it.name, it.value, line),
                        samples,
                    );
                } else if starts_with_serial {
                    b_same_line_serial.hit(
                        doc,
                        format!("真值名={} 数值={} | 行: {:?}", it.name, it.value, line),
                        samples,
                    );
                } else {
                    // 检查该行是否真被 parser 抽出过(任何 analyte),但 key 对不上
                    // 真值(词典歧义/别名冲突)。
                    let parsed_here = rows.iter().find(|r| line.contains(&r.raw_name));
                    if let Some(r) = parsed_here {
                        b_dict_key_mismatch.hit(
                            doc,
                            format!(
                                "真值名={}(key={}) 数值={} | 抽成 raw_name={} key={:?} 行: {:?}",
                                it.name, m.key, it.value, r.raw_name, r.analyte_key, line
                            ),
                            samples,
                        );
                    } else {
                        b_same_line_other.hit(
                            doc,
                            format!("真值名={} 数值={} | 行: {:?}", it.name, it.value, line),
                            samples,
                        );
                    }
                }
                continue;
            }

            // 不同行:找最近距离
            let min_dist = name_lines
                .iter()
                .flat_map(|&ni| value_lines.iter().map(move |&vi| ni.abs_diff(vi)))
                .min()
                .unwrap_or(usize::MAX);
            if min_dist == 1 {
                // 定位具体是哪一对相邻行,取第一对
                let pair = name_lines
                    .iter()
                    .flat_map(|&ni| value_lines.iter().map(move |&vi| (ni, vi)))
                    .find(|(ni, vi)| ni.abs_diff(*vi) == 1)
                    .unwrap();
                b_wrap_adjacent.hit(
                    doc,
                    format!(
                        "真值名={} 数值={} | 名行[{}]: {:?} 数行[{}]: {:?}",
                        it.name, it.value, pair.0, lines[pair.0], pair.1, lines[pair.1]
                    ),
                    samples,
                );
            } else {
                b_wrap_far.hit(
                    doc,
                    format!(
                        "真值名={} 数值={} 相距{}行 | 名行示例: {:?}",
                        it.name, it.value, min_dist, lines[name_lines[0]]
                    ),
                    samples,
                );
            }
        }
    }

    println!("# 项目召回失配分类({n_miss}/{n_total} 条未召回,arm2_geo,--out {out})\n");
    let report = |label: &str, b: &Bucket| {
        println!(
            "## {label}: {} 条 ({:.1}%)",
            b.count,
            b.count as f64 / n_miss.max(1) as f64 * 100.0
        );
        for (doc, ctx) in &b.samples {
            println!("- [{doc}] {ctx}");
        }
        println!();
    };
    report("OCR 没读到名字(上游天花板)", &b_name_missing);
    report("OCR 没读到数值(名字读到了)", &b_value_missing);
    report("同行:被序号前缀卡住(非 bare-pair)", &b_same_line_serial);
    report(
        "同行:这一行已被解析成另一项目(疑似双栏/多项目挤一行)",
        &b_same_line_multi,
    );
    report("同行:词典 key 对不上真值(别名/歧义)", &b_dict_key_mismatch);
    report("同行:原因待查", &b_same_line_other);
    report("折行:名与数相邻(距离=1行)", &b_wrap_adjacent);
    report("名与数都读到但相距 2+ 行", &b_wrap_far);

    Ok(())
}
