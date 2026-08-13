// MedRepBench baseline:在 819 份**真实**中文化验单上量我们的抽取质量。
//
// 之前所有对比(layout_eval / arena)用的都是我们自己写的 21 份语料、自己渲染的
// 页面 —— 版式单一、字体统一、无拍摄退化。这份评测换成 MedRepBench:1,925 份
// 去标识的真实中文医疗报告图(手持拍照 / PDF / 手机截图),其中 819 份 Laboratory
// 带**项目级真值**(名称/数值/单位/参考区间/异常标志),共 6,099 条。
// 数据集 CC BY-NC 4.0,仅用于研发期评测,不随产品分发、不用于训练。
//
// ## 三个分母,必须分开报
//
// 把它们混在一起,就会分不清「叫不出名字」和「版面读错了」——这正是这份评测
// 要拆开的两件事:
//
//   A. **词典未覆盖**:真值项目名过不了 `terminology::resolve`。哪怕 OCR 与版面
//      都完美,这些条目也拿不到 analyte_key,进不了趋势。这是**上游天花板**,
//      与识别质量无关,单独报。
//   B. **定性条目**:真值数值不是纯数字(阴性/未见/+/++)。`parser::labs` 明确
//      不处理定性结果,不该算进版面保真度的分母,单独报。
//   C. **可比条目**:词典认得 + 数值是纯数字。**只有这部分进三条指标的分母。**
//
// ## 三条指标(与 layout_eval / arena 逐字同口径)
//
// - 项目召回:产出里有没有同 `analyte_key` 的行
// - 值-名配对:那一行的数值和真值一致
// - 参考区间归属:参考范围跟着正确的项目(真值区间能解析成数字区间时才计入)
//
// ## 跑法
//
// ```
// cargo run --release -p ocr --example medrep --features engine,testing -- \
//   --produce --models <结构模型目录> [--limit N]
// cargo run --release -p ocr --example medrep --features engine,testing -- --score
// ```

use anyhow::{Context, Result};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Instant;

use oar_ocr::domain::tasks::LayoutDetectionConfig;
use oar_ocr::prelude::OARStructureBuilder;

const ROOT: &str = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/datasets/medrepbench";

const VALUE_EPS: f64 = 0.01;

/// 产出目录,`--out <名字>` 指定,默认 `out`。
///
/// **并行改进实验必须各用各的目录。** 多条改进线同时跑 `--produce` 时,若共用
/// 一个 `out/`,后跑的会覆盖先跑的,两边的 `--score` 就都在读对方的产出 ——
/// 数字看着有变化,其实是串了。每条线用 `--out out_<线名>`,互不相干。
fn out_root(name: &str) -> PathBuf {
    PathBuf::from(ROOT).join(name)
}

/// 真值里的一条项目(已由 `make_gt.py` 规范化,参考区间的 18 种写法在那里统一解析)。
#[derive(Debug, Clone)]
struct GtItem {
    name: String,
    value: Option<f64>,
    unit: String,
    low: Option<f64>,
    high: Option<f64>,
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
            low: num(c[4]),
            high: num(c[5]),
        });
    }
    Ok(out)
}

fn bound_matches(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => (x - y).abs() < VALUE_EPS,
        _ => false,
    }
}

#[derive(Default, Clone, Copy)]
struct Tally {
    /// C 类可比条目的三条指标
    recall: (usize, usize),
    pairing: (usize, usize),
    range: (usize, usize),
    /// A/B 两类被排除的条目数(只统计,不计分)
    no_dict: usize,
    qualitative: usize,
    /// 产出为空(该臂在这份图上整个失败)
    empty_docs: usize,
    docs: usize,
    /// 只统计**该臂产出非空**的那些文档的三条指标 —— 把「整份失败」和「读错了」
    /// 分开看。③ 在真实照片上有两成多的文档直接吐空(版面模型把整张照片判成
    /// 一张图片),混在一起报会让人以为它是"读得差",实际是"根本没读"。
    ok_recall: (usize, usize),
    ok_pairing: (usize, usize),
    ok_range: (usize, usize),
}

fn produce(models: &Path, limit: Option<usize>, out: &str) -> Result<()> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mob = manifest.join("../../apps/mobile_flutter/rust/ocr-models");
    // 与 arena.rs 同一套配置(那三个坑的结论:17cls 版面模型、不开表格分类器、
    // NMS 收到 0.2 防重叠重复)。配置不同就没法和上一轮的数字比。
    let structure = OARStructureBuilder::new(models.join("picodet-s_layout_17cls.onnx"))
        .layout_model_name("PicoDet-S_layout_17cls")
        .layout_detection_config(LayoutDetectionConfig {
            nms_threshold: 0.2,
            ..Default::default()
        })
        .with_wireless_table_structure(models.join("slanet_plus.onnx"))
        .wireless_table_structure_model_name("SLANet_plus")
        .table_structure_dict_path(models.join("table_structure_dict_ch.txt"))
        .use_e2e_wireless_table_rec(true)
        .with_ocr(
            mob.join("pp-ocrv5_mobile_det.onnx"),
            mob.join("pp-ocrv5_mobile_rec.onnx"),
            mob.join("ppocrv5_dict.txt"),
        )
        .text_detection_model_name("PP-OCRv5_mobile_det")
        .text_recognition_model_name("PP-OCRv5_mobile_rec")
        .build()
        .map_err(|e| anyhow::anyhow!("构建结构流水线失败: {e}"))?;

    let gt = load_gt()?;
    let mut docs: Vec<String> = gt.keys().cloned().collect();
    if let Some(n) = limit {
        docs.truncate(n);
    }

    let mut secs = [0f64; 3];
    let mut arm_fail = [0usize; 3];
    let mut skipped = 0usize;
    for (i, doc) in docs.iter().enumerate() {
        let img_path = PathBuf::from(ROOT).join("images").join(doc);
        let Ok(bytes) = std::fs::read(&img_path) else {
            skipped += 1;
            continue;
        };
        if bytes.is_empty() {
            skipped += 1;
            continue;
        }
        if i % 25 == 0 {
            eprintln!("[{}/{}] {doc}", i + 1, docs.len());
        }

        // 每条臂各自 catch:一份图上某条臂炸了不该带走另外两条的结果。
        let t = Instant::now();
        let bare = ocr::testing::recognize_engine_bare(&bytes)
            .map(|o| o.text)
            .unwrap_or_else(|_| {
                arm_fail[0] += 1;
                String::new()
            });
        secs[0] += t.elapsed().as_secs_f64();

        let t = Instant::now();
        let geo = ocr::recognize_engine_layout(&bytes)
            .map(|o| o.text)
            .unwrap_or_else(|_| {
                arm_fail[1] += 1;
                String::new()
            });
        secs[1] += t.elapsed().as_secs_f64();

        let t = Instant::now();
        let structured = match image::load_from_memory(&bytes) {
            Ok(img) => match structure.predict_image(img.to_rgb8()) {
                Ok(r) => html_tables_to_rows(&r.to_markdown()),
                Err(_) => {
                    arm_fail[2] += 1;
                    String::new()
                }
            },
            Err(_) => {
                arm_fail[2] += 1;
                String::new()
            }
        };
        secs[2] += t.elapsed().as_secs_f64();

        for (dir, text) in [
            ("arm1_bare", &bare),
            ("arm2_geo", &geo),
            ("arm3_struct", &structured),
        ] {
            let d = out_root(out).join(dir);
            std::fs::create_dir_all(&d)?;
            std::fs::write(d.join(format!("{doc}.txt")), text)?;
        }
    }
    let n = (docs.len() - skipped).max(1) as f64;
    eprintln!(
        "跑了 {} 份(图片缺失跳过 {skipped} 份)",
        docs.len() - skipped
    );
    for (i, name) in ["① 裸拼接", "② 几何重建", "③ PP-StructureV3"]
        .iter()
        .enumerate()
    {
        eprintln!(
            "{name}: {:.0}s 合计,{:.2}s/份,整份失败 {} 次",
            secs[i],
            secs[i] / n,
            arm_fail[i]
        );
    }
    Ok(())
}

/// 与 arena.rs 逐字相同:把 `to_markdown()` 的 HTML 表格摊成对齐文本行。
fn html_tables_to_rows(md: &str) -> String {
    let mut out = String::new();
    let chars: Vec<char> = md.chars().collect();
    let mut i = 0usize;
    let mut row: Option<Vec<String>> = None;
    let mut cell: Option<String> = None;
    while i < chars.len() {
        if chars[i] == '<' {
            let Some(p) = chars[i..].iter().position(|c| *c == '>') else {
                break;
            };
            let end = i + p;
            let tag: String = chars[i + 1..end].iter().collect::<String>().to_lowercase();
            let name = tag
                .trim_start_matches('/')
                .split([' ', '/'])
                .next()
                .unwrap_or("")
                .to_string();
            match (tag.starts_with('/'), name.as_str()) {
                (false, "tr") => row = Some(Vec::new()),
                (true, "tr") => {
                    if let Some(cells) = row.take() {
                        let line = cells.join("  ");
                        if !line.trim().is_empty() {
                            out.push_str(line.trim());
                            out.push('\n');
                        }
                    }
                }
                (false, "td") | (false, "th") => cell = Some(String::new()),
                (true, "td") | (true, "th") => {
                    if let (Some(c), Some(r)) = (cell.take(), row.as_mut()) {
                        r.push(c.split_whitespace().collect::<Vec<_>>().join(" "));
                    }
                }
                _ => {}
            }
            i = end + 1;
            continue;
        }
        let ch = chars[i];
        match (&mut cell, &row) {
            (Some(c), _) => c.push(ch),
            (None, None) => out.push(ch),
            (None, Some(_)) => {}
        }
        i += 1;
    }
    out
}

fn score(out: &str) -> Result<()> {
    let gt = load_gt()?;
    let out_root = out_root(out);
    let mut arms: Vec<(String, PathBuf)> = Vec::new();
    for (label, dir) in [
        ("① 裸拼接", "arm1_bare"),
        ("② 几何重建", "arm2_geo"),
        ("③ PP-StructureV3", "arm3_struct"),
    ] {
        let p = out_root.join(dir);
        if p.is_dir() {
            arms.push((label.to_string(), p));
        }
    }
    // 第 ④ 列(LLM)按模型分子目录,跑了几个算几个。
    if let Ok(rd) = std::fs::read_dir(out_root.join("arm4_llm")) {
        let mut ms: Vec<PathBuf> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_dir())
            .collect();
        ms.sort();
        for m in ms {
            let n = m.file_name().unwrap().to_string_lossy().to_string();
            arms.push((format!("④ LLM {n}"), m));
        }
    }
    anyhow::ensure!(
        !arms.is_empty(),
        "{} 下没有任何产出目录,先跑 --produce",
        out_root.display()
    );

    let mut tally: Vec<Tally> = vec![Tally::default(); arms.len()];
    // 词典未覆盖的项目名 → 出现次数,报告末尾给最高频的一批(可据此补词表)。
    let mut miss_names: HashMap<String, usize> = HashMap::new();
    let mut counted_docs = 0usize;

    for (doc, items) in &gt {
        // 只统计**所有臂都产出了**的文档,分母才对齐。
        if !arms
            .iter()
            .all(|(_, d)| d.join(format!("{doc}.txt")).is_file())
        {
            continue;
        }
        counted_docs += 1;
        for (ai, (_, dir)) in arms.iter().enumerate() {
            let text = std::fs::read_to_string(dir.join(format!("{doc}.txt")))?;
            let rows = parser::extract_labs(&text);
            let t = &mut tally[ai];
            t.docs += 1;
            let non_empty = !text.trim().is_empty();
            if !non_empty {
                t.empty_docs += 1;
            }
            for gi in items {
                // A 类:词典不认识这个名字 —— 与识别质量无关的上游天花板。
                let Some(m) = terminology::resolve(
                    &gi.name,
                    if gi.unit.is_empty() {
                        None
                    } else {
                        Some(gi.unit.as_str())
                    },
                ) else {
                    t.no_dict += 1;
                    if ai == 0 {
                        *miss_names.entry(gi.name.clone()).or_default() += 1;
                    }
                    continue;
                };
                // B 类:定性结果,labs.rs 明确不处理。
                let Some(gv) = gi.value else {
                    t.qualitative += 1;
                    continue;
                };
                let key = m.key.as_str();
                let cands: Vec<&parser::LabObservation> = rows
                    .iter()
                    .filter(|r| r.analyte_key.as_deref() == Some(key))
                    .collect();

                let got_row = !cands.is_empty();
                let got_val = cands.iter().any(|r| (r.value_num - gv).abs() < VALUE_EPS);
                t.recall.1 += 1;
                if got_row {
                    t.recall.0 += 1;
                }
                t.pairing.1 += 1;
                if got_val {
                    t.pairing.0 += 1;
                }
                if non_empty {
                    t.ok_recall.1 += 1;
                    if got_row {
                        t.ok_recall.0 += 1;
                    }
                    t.ok_pairing.1 += 1;
                    if got_val {
                        t.ok_pairing.0 += 1;
                    }
                }
                if gi.low.is_some() || gi.high.is_some() {
                    let got_rng = cands.iter().any(|r| {
                        bound_matches(r.ref_low, gi.low) && bound_matches(r.ref_high, gi.high)
                    });
                    t.range.1 += 1;
                    if got_rng {
                        t.range.0 += 1;
                    }
                    if non_empty {
                        t.ok_range.1 += 1;
                        if got_rng {
                            t.ok_range.0 += 1;
                        }
                    }
                }
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
    println!(
        "# MedRepBench —— {counted_docs} 份真实化验单(产出目录 {})",
        out_root.display()
    );
    println!();
    println!("## 三条指标(分母 = 可比条目:词典认得 + 数值是纯数字)");
    println!();
    print!("| 指标 |");
    for (n, _) in &arms {
        print!(" {n} |");
    }
    println!();
    print!("|---|");
    for _ in &arms {
        print!("---|");
    }
    println!();
    for (label, pick) in [("项目召回", 0usize), ("值-名配对", 1), ("参考区间归属", 2)]
    {
        print!("| {label} |");
        for t in &tally {
            let (h, d) = match pick {
                0 => t.recall,
                1 => t.pairing,
                _ => t.range,
            };
            print!(" {:.1}% ({h}/{d}) |", pct(h, d));
        }
        println!();
    }
    print!("| 产出为空的份数 |");
    for t in &tally {
        print!(" {}/{} |", t.empty_docs, t.docs);
    }
    println!();
    println!();
    println!("## 只算「该臂产出非空」的文档(把「整份没读到」和「读错了」分开)");
    println!();
    print!("| 指标 |");
    for (n, _) in &arms {
        print!(" {n} |");
    }
    println!();
    print!("|---|");
    for _ in &arms {
        print!("---|");
    }
    println!();
    for (label, pick) in [("项目召回", 0usize), ("值-名配对", 1), ("参考区间归属", 2)]
    {
        print!("| {label} |");
        for t in &tally {
            let (h, d) = match pick {
                0 => t.ok_recall,
                1 => t.ok_pairing,
                _ => t.ok_range,
            };
            print!(" {:.1}% ({h}/{d}) |", pct(h, d));
        }
        println!();
    }
    println!();
    println!("## 端到端(分母 = 真值全部条目,含词典未覆盖与定性)");
    println!();
    print!("| 指标 |");
    for (n, _) in &arms {
        print!(" {n} |");
    }
    println!();
    print!("|---|");
    for _ in &arms {
        print!("---|");
    }
    println!();
    let all_items = tally[0].no_dict + tally[0].qualitative + tally[0].recall.1;
    print!("| 数值抽对的条目占全部真值 |");
    for t in &tally {
        print!(
            " {:.1}% ({}/{}) |",
            pct(t.pairing.0, all_items),
            t.pairing.0,
            all_items
        );
    }
    println!();

    let t0 = &tally[0];
    let excluded = t0.no_dict + t0.qualitative;
    let total = excluded + t0.recall.1;
    println!();
    println!("## 被排除在分母外的条目(与识别质量无关,单独报)");
    println!();
    println!(
        "- **词典未覆盖 {} 条**({:.1}% of {total}):真值项目名过不了 `terminology::resolve`。\
         哪怕 OCR 与版面完美也进不了趋势 —— 这是上游天花板。",
        t0.no_dict,
        pct(t0.no_dict, total)
    );
    println!(
        "- **定性条目 {} 条**({:.1}%):真值数值不是纯数字(阴性/未见/+ 等),\
         `parser::labs` 明确不处理。",
        t0.qualitative,
        pct(t0.qualitative, total)
    );
    println!(
        "- **可比条目 {} 条**({:.1}%):进上表分母的部分。",
        t0.recall.1,
        pct(t0.recall.1, total)
    );

    let mut miss: Vec<(String, usize)> = miss_names.into_iter().collect();
    miss.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    println!();
    println!("## 词典缺口最高频的 40 个(共 {} 个不同项目名)", miss.len());
    println!();
    for (n, c) in miss.iter().take(40) {
        println!("- {c:>4}  {n}");
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let arg = |k: &str| {
        args.iter()
            .position(|a| a == k)
            .and_then(|i| args.get(i + 1).cloned())
    };
    let out = arg("--out").unwrap_or_else(|| "out".to_string());
    if args.iter().any(|a| a == "--produce") {
        let models = arg("--models").context("--produce 需要 --models <目录>")?;
        let limit = arg("--limit").and_then(|s| s.parse().ok());
        produce(Path::new(&models), limit, &out)?;
    }
    if args.iter().any(|a| a == "--score") {
        score(&out)?;
    }
    Ok(())
}
