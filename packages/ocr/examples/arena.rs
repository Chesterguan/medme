// 四列对比实验:同一张页面图片,四条抽取路径,同一把尺子。
//
// | 列 | 路径 | 谁做 |
// |---|---|---|
// | ① 裸拼接 | `recognize_engine`(改前的生产默认,`"\n".join`,丢弃几何) | 本 example |
// | ② 几何重建 | `recognize_engine_layout`(2026-08 起的生产默认,按检测框重建列) | 本 example |
// | ③ PP-StructureV3 | 版面检测 → 表格结构(SLANet+)→ Markdown/HTML 表格 | 本 example |
// | ④ LLM API | 整页图直接喂视觉大模型,让它吐化验行 | 外部脚本,产物落 `arm4_llm/<模型>/` |
//
// ## 为什么四列都要过同一个 `parser::extract_labs`
//
// 这个实验要回答的是「**谁把版面还原得更忠实**」,不是「谁的术语字典更全」。
// 四条路径的产出统一是纯文本,统一过我们生产在用的规则抽取器,再和同样过一遍该
// 抽取器的真值比 —— 下游完全一致,差异才只可能来自上游。LLM 那一列因此也被要求
// 吐「项目名 数值 单位 参考范围」的文本行(它另外还产一份直接结构化的 JSON,
// 作为不受我们正则限制时的上界,由评分脚本单独报,不混进这张表)。
//
// ## 输入:真实 PDF 渲染,不是合成扫描页
//
// 之前用 `render_scan.py` 合成的「扫描纸」有个致命问题:它在页面四周画了一圈矩形
// 边框模拟纸张边缘,PP-DocLayout 类版面模型看到就把**整页判成一张 Image**,
// `to_markdown()` 于是只吐一个 `<img>` 标签,把已经识别出来的几十个文本区全部丢掉
// (实测:某份文档 `text_regions: Some(12)` 而 markdown 只有一行 img 标签)。
// 所以本实验的页面来自 `demo-data/corpus/*.pdf` 经 `pdftoppm -r 200` 栅格化,
// 1653×2339 的真实 A4 形状、无人工边框。16 份有 PDF(6 份检验报告全在)。
//
// ## 结构流水线的配置,以及两个踩过的坑
//
// - **版面模型必须用 `PicoDet-S_layout_17cls`,不能用 `PP-DocLayout-S`。** 后者
//   (同为 4.7MB)把化验表格那一块判成 `Image`,表格分支根本不触发;前者正确判成
//   `Table`,并把红章单独标成 `Seal` 不再往正文掺字。
// - **不能开表格有线/无线分类器。** 开了之后它把中文化验单判成「有线」,路由到有线
//   分支,而有线分支的默认结构模型是 SLANeXt_wired(350MB,手机装不下);拿
//   SLANet+(无线模型)顶上会直接报 `structure recognition produced no cells`
//   整份失败。去掉分类器、全按无线走 SLANet+ 自己的配置就正常。少 6.5MB,还更准。
// - 单元格检测模型 RT-DETR-L 123.4MB/个,移动端不可能带,故 e2e 模式(结构模型
//   自己出格)。
//
// ## 跑法
//
// ```
// # 产出三列(需先下模型,见 structure_eval.rs 头部)
// cargo run --release -p ocr --example arena --features engine,testing -- --produce --models <dir>
// # 评分(四列一起,LLM 那列有多少算多少)
// cargo run --release -p ocr --example arena --features engine,testing -- --score
// ```

use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use oar_ocr::domain::tasks::LayoutDetectionConfig;
use oar_ocr::prelude::OARStructureBuilder;

const ARENA: &str = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/arena";

fn is_tabular(doc: &str) -> bool {
    doc.contains("检验报告")
}

const VALUE_EPS: f64 = 0.01;

fn bound_matches(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => (x - y).abs() < VALUE_EPS,
        _ => false,
    }
}

/// 三条临床指标 (命中, 分母):化验行召回 / 值-名配对 / 参考区间归属。与
/// `layout_eval.rs` 的同名函数逐行等价 —— 两份评测必须共用同一把尺子。
fn eval_tabular(
    truth: &[parser::LabObservation],
    got: &[parser::LabObservation],
) -> [(usize, usize); 3] {
    let mut m = [(0usize, 0usize); 3];
    for t in truth {
        let Some(key) = t.analyte_key.as_deref() else {
            continue;
        };
        let cands: Vec<&parser::LabObservation> = got
            .iter()
            .filter(|e| e.analyte_key.as_deref() == Some(key))
            .collect();
        m[0].1 += 1;
        if !cands.is_empty() {
            m[0].0 += 1;
        }
        m[1].1 += 1;
        if cands
            .iter()
            .any(|e| (e.value_num - t.value_num).abs() < VALUE_EPS)
        {
            m[1].0 += 1;
        }
        if t.ref_low.is_some() || t.ref_high.is_some() {
            m[2].1 += 1;
            if cands.iter().any(|e| {
                bound_matches(e.ref_low, t.ref_low) && bound_matches(e.ref_high, t.ref_high)
            }) {
                m[2].0 += 1;
            }
        }
    }
    m
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut cur = vec![0usize; m + 1];
    for i in 1..=n {
        cur[0] = i;
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[m]
}

const LINE_MATCH_THRESHOLD: f64 = 0.6;

/// 逐行内容召回。比较前把每行压成「单空格分隔」——四列的空白填充策略天差地别
/// (几何重建按像素补空格、结构流水线出 Markdown、LLM 想怎么写就怎么写),不归一
/// 化的话量到的是排版风格差异,不是内容有没有丢。
/// 返回 (相似命中, 逐字一致命中, 真值行数)。
///
/// **两个口径都要报,因为宽的那个会放过替换错。** 阈值 0.6 的相似匹配衡量的是
/// 「这行内容还在不在」;它对**改字**几乎无感 —— 实测 LLM 把「阿司匹林肠溶片」
/// 写成「阿司匹林胶囊片」(剂型变了)、把医师「周芸」写成「陈丽霞」(换了个人),
/// 这两行在 0.6 阈值下都算命中。对病历产品来说,这类安静的、看着合理的改写比
/// 漏一行危险得多,所以再加一条**逐字一致率**:归一化空白后与真值行完全相同才算。
/// OCR 的错字同样过不了这一条,两边一视同仁。
fn eval_generic(truth_text: &str, got: &str) -> (usize, usize, usize) {
    let norm = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let truth: Vec<String> = truth_text
        .lines()
        .map(norm)
        .filter(|l| !l.is_empty())
        .collect();
    let got: Vec<String> = got.lines().map(norm).filter(|l| !l.is_empty()).collect();
    let mut sim = 0usize;
    let mut exact = 0usize;
    for t in &truth {
        if got.iter().any(|g| g == t) {
            exact += 1;
        }
        if got.iter().any(|g| {
            let (ct, cg): (Vec<char>, Vec<char>) = (t.chars().collect(), g.chars().collect());
            1.0 - levenshtein(&ct, &cg) as f64 / ct.len().max(cg.len()).max(1) as f64
                >= LINE_MATCH_THRESHOLD
        }) {
            sim += 1;
        }
    }
    (sim, exact, truth.len())
}

/// 把 `to_markdown()` 里的 HTML 表格摊成「每行一条、单元格用两个空格分隔」的
/// 纯文本,其余 HTML 标签整段剥掉。
///
/// **这一步是结构流水线真正的价值落地点,也是它必须有的一步。** `extract_labs`
/// 是为「一行 = 一个项目名 + 数值 + 单位 + 参考范围」的文本行写的规则抽取器,
/// 喂它 `<td>白细胞计数</td><td>11.8</td>` 只会什么都抽不到。结构流水线给出的是
/// **行列关系**,把它摊成对齐文本行是零信息损失的格式转换;而 ①② 两列压根没有
/// 行列关系可摊,只能靠猜。
fn html_tables_to_rows(md: &str) -> String {
    let mut out = String::new();
    let bytes: Vec<char> = md.chars().collect();
    let mut i = 0usize;
    // 当前正在积累的一行单元格;`None` 表示不在 <tr> 里。
    let mut row: Option<Vec<String>> = None;
    let mut cell: Option<String> = None;
    while i < bytes.len() {
        if bytes[i] == '<' {
            let end = match bytes[i..].iter().position(|c| *c == '>') {
                Some(p) => i + p,
                None => break,
            };
            let tag: String = bytes[i + 1..end].iter().collect::<String>().to_lowercase();
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
                // 其余标签(div/img/table/tbody/br...)整个丢掉,不进文本。
                _ => {}
            }
            i = end + 1;
            continue;
        }
        let ch = bytes[i];
        match (&mut cell, &row) {
            (Some(c), _) => c.push(ch),
            // 表格之外的正文:原样保留(结构流水线把段落按阅读顺序排好了)。
            (None, None) => out.push(ch),
            (None, Some(_)) => {} // <tr> 与 <td> 之间的空白,丢掉
        }
        i += 1;
    }
    out
}

fn arm_dirs() -> Vec<(String, PathBuf)> {
    let mut v = vec![
        (
            "① 裸拼接".to_string(),
            PathBuf::from(ARENA).join("arm1_bare"),
        ),
        (
            "② 几何重建".to_string(),
            PathBuf::from(ARENA).join("arm2_geo"),
        ),
        (
            "③ PP-StructureV3".to_string(),
            PathBuf::from(ARENA).join("arm3_struct"),
        ),
    ];
    // 第 ④ 列由外部脚本按模型分子目录产出,有几个算几个 —— 没跑完也能先看前三列。
    // 第 ④ 列的 JSON 上界:LLM 自己吐的结构化行渲染成规范文本(见 arena 目录下的
    // 转换脚本),同样过 extract_labs —— 量它不受我们正则行格式束缚时能到多好。
    if let Ok(rd) = std::fs::read_dir(PathBuf::from(ARENA)) {
        let mut ds: Vec<PathBuf> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.is_dir()
                    && p.file_name()
                        .is_some_and(|n| n.to_string_lossy().starts_with("arm4json_"))
            })
            .collect();
        ds.sort();
        for d in ds {
            let n = d
                .file_name()
                .unwrap()
                .to_string_lossy()
                .replace("arm4json_", "");
            v.push((format!("④json {n}"), d));
        }
    }
    let llm_root = PathBuf::from(ARENA).join("arm4_llm");
    if let Ok(rd) = std::fs::read_dir(&llm_root) {
        let mut models: Vec<PathBuf> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_dir())
            .collect();
        models.sort();
        for m in models {
            let name = m.file_name().unwrap().to_string_lossy().to_string();
            v.push((format!("④ LLM {name}"), m));
        }
    }
    v
}

fn produce(models: &Path, nms: f32) -> Result<()> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mob = manifest.join("../../apps/mobile_flutter/rust/ocr-models");
    eprintln!("构建 PP-StructureV3(PicoDet-S_layout_17cls + SLANet+ e2e,不带分类器)...");
    // 版面区域重叠时同一段文字会被吐好几遍(实测一份处方 361 字被吐成 819 字,
    // 「酒石酸美托洛尔」一行里出现三次)——默认 nms_threshold=0.5 抑制不掉这种
    // 重叠。收紧它,让重叠框只留一个。
    let layout_cfg = LayoutDetectionConfig {
        nms_threshold: nms,
        ..Default::default()
    };
    let structure = OARStructureBuilder::new(models.join("picodet-s_layout_17cls.onnx"))
        .layout_model_name("PicoDet-S_layout_17cls")
        .layout_detection_config(layout_cfg)
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

    let pages_dir = PathBuf::from(ARENA).join("pages");
    let mut pages: Vec<PathBuf> = std::fs::read_dir(&pages_dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "png"))
        .collect();
    pages.sort();

    let mut secs = [0f64; 3];
    let mut fails: Vec<String> = Vec::new();
    for (i, p) in pages.iter().enumerate() {
        let doc = p.file_stem().unwrap().to_string_lossy().to_string();
        eprintln!("[{}/{}] {doc}", i + 1, pages.len());
        let bytes = std::fs::read(p)?;

        let t = Instant::now();
        let bare = ocr::testing::recognize_engine_bare(&bytes)?.text;
        secs[0] += t.elapsed().as_secs_f64();

        let t = Instant::now();
        let geo = ocr::recognize_engine_layout(&bytes)?.text;
        secs[1] += t.elapsed().as_secs_f64();

        let t = Instant::now();
        let img = image::load_from_memory(&bytes)?.to_rgb8();
        // 结构流水线整份失败时**记名跳过、不静默** —— 分母照算,报告里点名。
        let structured = match structure.predict_image(img) {
            Ok(r) => html_tables_to_rows(&r.to_markdown()),
            Err(e) => {
                fails.push(format!("{doc}: {e}"));
                String::new()
            }
        };
        secs[2] += t.elapsed().as_secs_f64();

        for (dir, text) in [
            ("arm1_bare", &bare),
            ("arm2_geo", &geo),
            ("arm3_struct", &structured),
        ] {
            let d = PathBuf::from(ARENA).join(dir);
            std::fs::create_dir_all(&d)?;
            std::fs::write(d.join(format!("{doc}.txt")), text)?;
        }
    }
    let n = pages.len() as f64;
    for (i, name) in ["① 裸拼接", "② 几何重建", "③ PP-StructureV3"]
        .iter()
        .enumerate()
    {
        eprintln!("{name}: 总 {:.1}s,{:.2}s/份", secs[i], secs[i] / n);
    }
    if fails.is_empty() {
        eprintln!("结构流水线:16/16 全部成功");
    } else {
        eprintln!("结构流水线失败 {} 份(产出记为空,分母不缩):", fails.len());
        for f in &fails {
            eprintln!("  {f}");
        }
    }
    Ok(())
}

fn score() -> Result<()> {
    let corpus = Path::new(env!("CARGO_MANIFEST_DIR")).join("../parser/tests/fixtures/corpus");
    let pages_dir = PathBuf::from(ARENA).join("pages");
    let mut docs: Vec<String> = std::fs::read_dir(&pages_dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "png"))
        .map(|p| p.file_stem().unwrap().to_string_lossy().to_string())
        .collect();
    docs.sort();

    let arms = arm_dirs();
    let mut agg: Vec<[(usize, usize); 3]> = vec![[(0, 0); 3]; arms.len()];
    let mut gen: Vec<(usize, usize, usize)> = vec![(0, 0, 0); arms.len()];
    let mut missing: BTreeMap<String, usize> = BTreeMap::new();

    println!("## 逐文档(表格类:召回/配对/区间;非表格类:逐行召回)");
    println!();
    print!("| 文档 | 类型 |");
    for (n, _) in &arms {
        print!(" {n} |");
    }
    println!();
    print!("|---|---|");
    for _ in &arms {
        print!("---|");
    }
    println!();

    for doc in &docs {
        let truth_text = std::fs::read_to_string(corpus.join(format!("{doc}.txt")))
            .with_context(|| format!("读真值 {doc}"))?;
        let truth_rows = parser::extract_labs(&truth_text);
        let tab = is_tabular(doc);
        print!("| {doc} | {} |", if tab { "表格类" } else { "非表格类" });
        for (ai, (name, dir)) in arms.iter().enumerate() {
            let path = dir.join(format!("{doc}.txt"));
            let Ok(text) = std::fs::read_to_string(&path) else {
                *missing.entry(name.clone()).or_default() += 1;
                print!(" — |");
                continue;
            };
            if tab {
                let m = eval_tabular(&truth_rows, &parser::extract_labs(&text));
                for k in 0..3 {
                    agg[ai][k].0 += m[k].0;
                    agg[ai][k].1 += m[k].1;
                }
                print!(
                    " {}/{} {}/{} {}/{} |",
                    m[0].0, m[0].1, m[1].0, m[1].1, m[2].0, m[2].1
                );
            } else {
                let g = eval_generic(&truth_text, &text);
                gen[ai].0 += g.0;
                gen[ai].1 += g.1;
                gen[ai].2 += g.2;
                print!(" {}/{} (逐字 {}) |", g.0, g.2, g.1);
            }
        }
        println!();
    }

    println!();
    println!("## 汇总");
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
    let labels = ["化验行召回", "值-名配对", "参考区间归属"];
    for k in 0..3 {
        print!("| {} |", labels[k]);
        for a in agg.iter() {
            let (h, d) = a[k];
            print!(
                " {:.1}% ({h}/{d}) |",
                if d == 0 {
                    0.0
                } else {
                    h as f64 / d as f64 * 100.0
                }
            );
        }
        println!();
    }
    let pct = |hit: usize, den: usize| {
        if den == 0 {
            0.0
        } else {
            hit as f64 / den as f64 * 100.0
        }
    };
    print!("| 非表格逐行召回(相似≥0.6) |");
    for g in gen.iter() {
        print!(" {:.1}% ({}/{}) |", pct(g.0, g.2), g.0, g.2);
    }
    println!();
    // 宽口径放过改字(「肠溶片」→「胶囊片」仍算命中),严口径抓得住。两个都报。
    print!("| 非表格**逐字一致** |");
    for g in gen.iter() {
        print!(" {:.1}% ({}/{}) |", pct(g.1, g.2), g.1, g.2);
    }
    println!();

    if !missing.is_empty() {
        println!();
        println!("**产出缺失(分母未缩,缺的记 0):**");
        for (arm, n) in &missing {
            println!("- {arm}: 缺 {n}/{} 份", docs.len());
        }
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--produce") {
        let models = args
            .iter()
            .position(|a| a == "--models")
            .and_then(|i| args.get(i + 1))
            .context("--produce 需要 --models <目录>")?;
        let nms = args
            .iter()
            .position(|a| a == "--nms")
            .and_then(|i| args.get(i + 1))
            .map(|s| s.parse::<f32>())
            .transpose()?
            .unwrap_or(0.5);
        eprintln!("版面 NMS 阈值 = {nms}");
        produce(Path::new(models), nms)?;
    }
    if args.iter().any(|a| a == "--score") {
        score()?;
    }
    Ok(())
}
