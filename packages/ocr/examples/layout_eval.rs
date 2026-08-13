// 布局重建评测:量出「手机端 recognize_platform_best 的 engine 兜底分支,从
// recognize_engine(裸 "\n".join)切到 recognize_engine_layout(按检测框重建表格列)」
// 对 21 份语料文档分别带来什么变化 —— 不是只报一个汇总数字,每份文档一行。
//
// ## 为什么不直接调 recognize_platform_best 来测(甲板陷阱,踩过一次见
// WORKLIST.md「验证纪律」一节)
//
// 在这台 macOS 开发机上,recognize_platform_best 会先走 Apple Vision;
// Vision 没有逐行检测框,根本用不上 rebuild_layout_text,而且它和手机端真正跑
// 的 PP-OCRv5 引擎是两个完全不同的识别器,误读模式不可互推。改不改
// recognize_platform_best 的 engine 兜底分支,在 mac 上调它拿到的都是 Vision
// 的输出,量不出引擎侧的任何变化。`default-features = false` 也关不掉 Vision——
// 它是按 target_os 分流,不是按 feature。
//
// 所以本评测直接调两个 engine-only 函数本身:
//   - `ocr::testing::recognize_engine_bare`(= 私有的 recognize_engine,裸拼接,
//     经由 ocr crate 的 `testing` feature 转发出来,见 lib.rs `mod testing`)
//   - `ocr::recognize_engine_layout`(同一个引擎,带版面重建)
// 这就是「手机端 catch-all 分支从 recognize_engine 切到 recognize_engine_layout
// 会带来什么变化」的直接证据 —— 手机上 recognize_platform_best 的 catch-all 分支
// 本来就是纯引擎调用(见 packages/ocr/Cargo.toml `engine` feature 注释),跟桌面
// 走 Vision 是两回事。
//
// ## 语料从哪来
//
// 真值是 packages/parser/tests/fixtures/corpus/*.txt(21 份,人工书写的干净文本,
// 表格用空格对齐列)。demo-dataset 里的示例 PDF 大多带真实文本层,走
// pdf_extract 直接抽取、根本不进 OCR,测不出布局重建的效果,所以不能用;本评测
// 用 examples/demo-dataset/render_scan.py 把每份 .txt 现渲染成一张不带文本层的
// 「扫描纸」图片(渲染有确定性:render_scan.py 按输出路径的 hash 做随机数种子,
// 同一个输出文件名每次渲染出的噪点/倾斜位图完全一致,不会给前后两次评测引入
// 渲染层面的随机波动),再喂给上面两个函数。
//
// ## 指标怎么定义,为什么这么定
//
// 21 份文档分两类(判断依据见 `classify` 的注释):
//
// 1. **表格类**(6 份文件名含"检验报告"的化验单):跑三条临床指标——
//    - **化验行召回率**:真值里的化验项目,OCR 产出里有没有识别出对应的行
//      (按 terminology 词典 key 匹配,不看数值对不对)。
//    - **值-名配对正确率**:识别出的行,数值是不是配对到了正确的项目(不是
//      随便一个数字凑巧对,而是真值 key 匹配到的行,其数值和真值一致)。
//    - **参考区间归属正确率**:参考范围有没有跟着正确的项目走(而不是从相邻
//      项目串行过来)。
//
//    这三条都通过 `parser::extract_labs` 复用——它是生产已经在用、经过真实
//    语料反复调校的规则抽取器(见 packages/parser/src/labs.rs 模块头),不是
//    评测另起一套解析逻辑。真值文本本身也过一遍同一个函数得到结构化真值,这样
//    「真值怎么解析」和「OCR 产出怎么解析」用的是同一套规则,不存在两套口径
//    互相打架的问题。用户明确要求"不是字符准确率,要反映临床后果"——这三条
//    都是"某个具体临床数值有没有配对到正确的化验项目"这个问题的不同切面。
//
// 2. **非表格类**(其余 15 份,含处方、病历、影像/病理报告,以及血压记录):
//    跑一条通用的**逐行内容召回率**——真值的每一行(去掉首尾空白后)是否在
//    OCR 输出里找到一行归一化编辑距离相似度 >= 0.6 的对应行。这条指标不是字符
//    准确率(不要求整份文档字符对齐),但比"随便有没有这几个字"更能反映内容
//    保真度。
//
//    「血压记录」文件名虽然是表格版式(逐日一行:日期/时间/收缩压舒张压/心率/
//    血糖),但归入非表格类而不是套用上面三条化验指标——三条化验指标的结构
//    假设是"一行 = 一个项目名 + 一个数值 + 一个参考范围",而血压记录的行结构
//    是"一行 = 一个日期 + 好几个并列的生命体征值",没有项目名/参考范围这个
//    维度(表里也确实没有参考范围列)。`parser::labs` 模块文档明确把"一个
//    token 里的比值型结果(血压 120/80)"列为 Deliberately NOT handled(`/80`
//    会被误当单位)。硬套三条化验指标需要现造一套"日期当项目名"的匹配规则,
//    这正是任务说的"别为了凑指标硬套"——所以血压记录改用通用的逐行召回率,
//    和其余非表格文档一样对待。
//
// ## 怎么跑
//
// ```
// cargo run -p ocr --example layout_eval --features testing --release
// ```
// (不加 --release 也能跑,只是每份文档的 OCR 推理会慢不少;21 份 × 2 个引擎
// 调用,预计几分钟量级,属于正常耗时,不要因为慢就抽样。)

use anyhow::{Context, Result};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

/// 文档分两类,决定跑哪一套指标——见文件头注释。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DocKind {
    /// 化验单/检验报告:项目名 + 数值 + 单位 + 参考范围的表格结构。
    Tabular,
    /// 其余散文/记录类结构(含血压记录——理由见文件头注释)。
    Generic,
}

/// 按文件名判断文档类别。语料文件名形如
/// `2025-11-05_检验报告_血常规肾功能.txt`,类型字段是下划线分隔的第二段。
/// 只有"检验报告"这一类具备(项目名, 数值, 单位, 参考范围)的表格结构,见文件
/// 头注释里对 21 份语料的人工分类依据。
fn classify(doc_name: &str) -> DocKind {
    if doc_name.contains("检验报告") {
        DocKind::Tabular
    } else {
        DocKind::Generic
    }
}

/// 一份文档在表格类三条指标上的 (命中数, 分母) —— 分母是真值里的化验行数
/// (或其中带参考范围的行数)。
#[derive(Debug, Clone, Copy, Default)]
struct TabularMetrics {
    row_recall: (usize, usize),
    pairing_accuracy: (usize, usize),
    range_attribution: (usize, usize),
}

/// 一份非表格文档的逐行内容召回率 (命中行数, 真值总行数)。
#[derive(Debug, Clone, Copy, Default)]
struct GenericMetrics {
    line_recall: (usize, usize),
}

#[derive(Debug, Clone, Copy)]
enum DocMetrics {
    Tabular(TabularMetrics),
    Generic(GenericMetrics),
}

impl DocMetrics {
    /// 打印成表格一列用的紧凑文本,e.g. `召回 8/8 配对 7/8 区间 8/8`。
    fn format(&self) -> String {
        match self {
            DocMetrics::Tabular(m) => format!(
                "召回 {}/{}  配对 {}/{}  区间 {}/{}",
                m.row_recall.0,
                m.row_recall.1,
                m.pairing_accuracy.0,
                m.pairing_accuracy.1,
                m.range_attribution.0,
                m.range_attribution.1
            ),
            DocMetrics::Generic(m) => {
                format!("逐行召回 {}/{}", m.line_recall.0, m.line_recall.1)
            }
        }
    }
}

/// 两个数值(参考区间的一个界)是否视为相等:都缺失算相等,一个有一个没有算
/// 不等,都有则在容差内算相等。容差 0.01 覆盖真值文本最多两位小数的印刷精度,
/// 同时严格到不会把"数值读错了但凑巧接近"算对——见文件头注释关于
/// "不能允许数值随便配"的原则。
const VALUE_EPS: f64 = 0.01;

fn bound_matches(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => (x - y).abs() < VALUE_EPS,
        _ => false,
    }
}

/// 对表格类文档算三条临床指标。`truth`/`extracted` 都是
/// `parser::extract_labs` 的产出(见文件头注释:真值和 OCR 产出用同一套规则
/// 抽取器)。匹配键是 terminology 词典解析出的 `analyte_key`,而不是原始文本
/// (原始名字受 OCR 噪声影响,词典 key 才是"这是同一个化验项目"的可靠判据)。
///
/// 一个真值项目在 OCR 产出里可能对应零个、一个或多个同 key 的候选行(同一版面
/// 缺陷有时会把一行拆成两条候选);只要**存在**一条候选满足条件就算命中——
/// 这反映的是"一个认真核对报告的人能不能从 OCR 产出里找到正确信息",而不是
/// "OCR 有没有精确地一行对一行"。
fn eval_tabular(
    truth: &[parser::LabObservation],
    extracted: &[parser::LabObservation],
) -> TabularMetrics {
    let mut m = TabularMetrics::default();
    for t in truth {
        // 21 份语料里的 6 份检验报告,词典对每个项目缩写/中文名都有覆盖
        // (creatinine/egfr/urea/uric_acid/glucose/hba1c/cholesterol/ldl/hdl/
        // triglycerides/wbc/hgb/plt/neut_pct 均在 terminology 必备 key 列表
        // 里,渲染前跑过 `parser::extract_labs` 直接吃真值文本核实过 42/42
        // 行全部解析出 analyte_key)。真出现真值行未能解析出 key 的情况,不
        // 静默跳过——响亮地报出来,不然分母会悄悄缩小,数字看起来比实际更好看。
        let Some(key) = t.analyte_key.as_deref() else {
            eprintln!(
                "  [WARN] 真值行 {:?} 没有解析出 analyte_key,已跳过——三条指标的分母不含它,请检查 terminology 词典覆盖",
                t.raw_name
            );
            continue;
        };
        let candidates: Vec<&parser::LabObservation> = extracted
            .iter()
            .filter(|e| e.analyte_key.as_deref() == Some(key))
            .collect();

        m.row_recall.1 += 1;
        if !candidates.is_empty() {
            m.row_recall.0 += 1;
        }

        m.pairing_accuracy.1 += 1;
        if candidates
            .iter()
            .any(|e| (e.value_num - t.value_num).abs() < VALUE_EPS)
        {
            m.pairing_accuracy.0 += 1;
        }

        if t.ref_low.is_some() || t.ref_high.is_some() {
            m.range_attribution.1 += 1;
            if candidates.iter().any(|e| {
                bound_matches(e.ref_low, t.ref_low) && bound_matches(e.ref_high, t.ref_high)
            }) {
                m.range_attribution.0 += 1;
            }
        }
    }
    m
}

/// 字符级(不是字节级,CJK 一个字一个 cell)Levenshtein 编辑距离。行长度都在
/// 几十字符量级,O(n*m) 的 DP 足够快,不需要引入额外的字符串相似度依赖。
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

/// 两行文本的归一化相似度:1 - 编辑距离 / 较长行的字符数。空行视为距离 0
/// (相似度 1),但调用方已经过滤掉空行,不会走到这个分支。
fn line_similarity(a: &str, b: &str) -> f64 {
    let (ca, cb): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let max_len = ca.len().max(cb.len()).max(1);
    1.0 - (levenshtein(&ca, &cb) as f64 / max_len as f64)
}

/// 行匹配相似度阈值——见文件头注释:不是要求逐字符对齐,只要求"能认出这是
/// 同一行内容",容忍空格/标点/个别错字这类 OCR 噪声,但两行内容确实不同时
/// 应该落在阈值以下。0.6 是凭经验选的:短句(十几字)错 1-2 个字仍然 >= 0.6,
/// 但整行内容不同(比如串行到相邻行)会明显低于它。
const LINE_MATCH_THRESHOLD: f64 = 0.6;

fn eval_generic(truth_text: &str, ocr_text: &str) -> GenericMetrics {
    let truth_lines: Vec<&str> = truth_text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    let ocr_lines: Vec<&str> = ocr_text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();

    let mut hit = 0usize;
    for tl in &truth_lines {
        let best = ocr_lines
            .iter()
            .map(|ol| line_similarity(tl, ol))
            .fold(0.0_f64, f64::max);
        if best >= LINE_MATCH_THRESHOLD {
            hit += 1;
        }
    }
    GenericMetrics {
        line_recall: (hit, truth_lines.len()),
    }
}

fn eval_doc(kind: DocKind, truth_text: &str, ocr_text: &str) -> DocMetrics {
    match kind {
        DocKind::Tabular => {
            let truth_rows = parser::extract_labs(truth_text);
            let extracted_rows = parser::extract_labs(ocr_text);
            DocMetrics::Tabular(eval_tabular(&truth_rows, &extracted_rows))
        }
        DocKind::Generic => DocMetrics::Generic(eval_generic(truth_text, ocr_text)),
    }
}

/// 把一份语料 txt 渲染成一张不带文本层的"扫描纸"图片,调用
/// `examples/demo-dataset/render_scan.py`(从 stdin 读正文,写 PNG/JPG 到给定
/// 路径)。渲染按输出路径的字符串 hash 做随机种子(脚本自己的实现),同一个
/// out_path 每次渲染出的噪点/倾斜完全一致——这保证了"改代码前"和"改代码后"
/// 两次独立评测跑吃到的是逐比特相同的输入图片,前后数字的差异只可能来自
/// recognize_engine → recognize_engine_layout 这一步,不会被渲染的随机性污染。
fn render_scan(script: &Path, text: &str, out: &Path, scale: f64) -> Result<()> {
    let mut child = Command::new("python3")
        .arg(script)
        .arg(out)
        .arg("--scale")
        .arg(scale.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("spawn python3 {}", script.display()))?;
    child
        .stdin
        .take()
        .expect("stdin was piped")
        .write_all(text.as_bytes())
        .context("write corpus text to render_scan.py stdin")?;
    let status = child.wait().context("wait for render_scan.py")?;
    anyhow::ensure!(
        status.success(),
        "render_scan.py exited with {status} for {}",
        out.display()
    );
    Ok(())
}

/// 渲染倍率,`--scale <N>` 传入,默认 1.0。**这个参数决定评测有没有走到分块路径。**
///
/// 引擎对高度 > `TILE_CORE_H`(1100px)的图会切成带 120px 重叠的横条分别 `predict`
/// 再缝合(见 packages/ocr/src/lib.rs)。倍率 1.0 时,21 份语料渲出来最高 998px ——
/// **一份都不过门槛**,全部按单帧走,分块与缝合的代码一行都没被执行到。而真机上
/// 用户拍的是整张 A4,3000×4000px,必然分三块以上。所以「切块导致对齐错」这个
/// 假设,只有在倍率 3.0(21 份全部分 3 块)下才测得到。
///
/// 两档都要跑:倍率 1.0 是「没有分块」的对照组,倍率 3.0 是「有分块」的实验组。
/// 同一份文档在两档之间的差,才是分块本身的代价;只跑一档区分不出「布局重建的
/// 收益」和「分块的损失」这两件事。
const DEFAULT_SCALE: f64 = 1.0;

/// PNG 的宽高就在 IHDR 里,固定偏移 16..24 两个大端 u32。只为在日志里报出
/// 「这张图被切几块」,不值得为此把 `image` crate 拉进 example 的依赖。
fn image_dimensions(png: &[u8]) -> Result<(u32, u32)> {
    anyhow::ensure!(
        png.len() >= 24 && png.starts_with(&[0x89, b'P', b'N', b'G']),
        "渲染产物不是 PNG,读不出尺寸"
    );
    let rd = |o: usize| u32::from_be_bytes([png[o], png[o + 1], png[o + 2], png[o + 3]]);
    Ok((rd(16), rd(20)))
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let scale = args
        .iter()
        .position(|a| a == "--scale")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.parse::<f64>())
        .transpose()
        .context("--scale 的值不是合法浮点数")?
        .unwrap_or(DEFAULT_SCALE);

    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let corpus_dir = manifest_dir.join("../parser/tests/fixtures/corpus");
    let render_script = manifest_dir.join("../../examples/demo-dataset/render_scan.py");
    // 渲染产物是构建输出,不入库(仓库 .gitignore 里 /target 已经忽略)。
    let images_dir = manifest_dir.join("../../target/ocr_layout_eval_images");
    std::fs::create_dir_all(&images_dir).context("create images_dir")?;

    anyhow::ensure!(
        corpus_dir.is_dir(),
        "corpus dir not found: {}",
        corpus_dir.display()
    );
    anyhow::ensure!(
        render_script.is_file(),
        "render_scan.py not found: {}",
        render_script.display()
    );

    let mut corpus_files: Vec<PathBuf> = std::fs::read_dir(&corpus_dir)
        .context("read corpus dir")?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "txt"))
        .collect();
    corpus_files.sort();
    // 21 份语料全跑,不挑样本——见任务要求,子集会掩盖"哪份文档变差了"这个
    // 报告最需要的信息。
    anyhow::ensure!(
        corpus_files.len() == 21,
        "expected 21 corpus files, found {} in {} — 语料集是否变了?本评测按 21 份写死校验,发现变化时先确认是否需要跟着改",
        corpus_files.len(),
        corpus_dir.display()
    );

    println!("### 渲染倍率 {scale}x(倍率 1.0 = 单帧不分块;3.0 = 每份切 3 块,走缝合路径)");
    println!();
    println!(
        "| # | 文档 | 类型 | recognize_engine(基线,裸拼接) | recognize_engine_layout(布局重建) |"
    );
    println!("|---|---|---|---|---|");

    // 汇总:表格类三条指标各自的命中/分母,非表格类逐行召回的命中/分母 —— 分
    // 别对基线和布局重建两套统计,PR 描述里的"几份变好/几份不变/几份变差"从
    // 逐文档结果里数,这里的汇总只是佐证整体方向没有反过来。
    let mut improved = 0usize;
    let mut unchanged = 0usize;
    let mut regressed = 0usize;

    for (idx, path) in corpus_files.iter().enumerate() {
        let doc_name = path
            .file_stem()
            .expect("txt file has a stem")
            .to_string_lossy()
            .to_string();
        let kind = classify(&doc_name);
        let truth_text = std::fs::read_to_string(path)
            .with_context(|| format!("read corpus file {}", path.display()))?;

        // 倍率进文件名:两档渲出来的是不同尺寸的图,不能共用一个路径互相覆盖;
        // 而且 render_scan.py 的随机种子取自输出路径,同名就会拿到同一组噪点——
        // 两档之间的差就不再只来自尺寸了。
        let image_path = images_dir.join(format!("{doc_name}@{scale}x.png"));
        eprintln!("[{}/21] 渲染 {doc_name} (倍率 {scale}) ...", idx + 1);
        render_scan(&render_script, &truth_text, &image_path, scale)?;
        let image_bytes = std::fs::read(&image_path)
            .with_context(|| format!("read rendered image {}", image_path.display()))?;
        // 如实报出这张图会被切几块——「这一档到底有没有走分块路径」不能靠推断,
        // 得跟识别结果印在同一份日志里。门槛与 packages/ocr/src/lib.rs 的
        // TILE_CORE_H 保持一致(那是私有常量,这里按值复刻,只用于报告)。
        let (img_w, img_h) = image_dimensions(&image_bytes)?;
        let bands = if img_h <= 1100 {
            1
        } else {
            img_h.div_ceil(1100)
        };
        eprintln!("         {img_w}x{img_h}px → {bands} 块");

        eprintln!("[{}/21] OCR(recognize_engine 基线){doc_name} ...", idx + 1);
        let t0 = Instant::now();
        let baseline = ocr::testing::recognize_engine_bare(&image_bytes)
            .with_context(|| format!("recognize_engine_bare failed for {doc_name}"))?;
        eprintln!(
            "         {:?}, confidence={:.3}",
            t0.elapsed(),
            baseline.confidence
        );

        eprintln!(
            "[{}/21] OCR(recognize_engine_layout){doc_name} ...",
            idx + 1
        );
        let t1 = Instant::now();
        let layout = ocr::recognize_engine_layout(&image_bytes)
            .with_context(|| format!("recognize_engine_layout failed for {doc_name}"))?;
        eprintln!(
            "         {:?}, confidence={:.3}",
            t1.elapsed(),
            layout.confidence
        );

        let before = eval_doc(kind, &truth_text, &baseline.text);
        let after = eval_doc(kind, &truth_text, &layout.text);

        let direction = match (&before, &after) {
            (DocMetrics::Tabular(b), DocMetrics::Tabular(a)) => {
                let score = |m: &TabularMetrics| {
                    let ratio = |p: (usize, usize)| {
                        if p.1 == 0 {
                            1.0
                        } else {
                            p.0 as f64 / p.1 as f64
                        }
                    };
                    ratio(m.row_recall) + ratio(m.pairing_accuracy) + ratio(m.range_attribution)
                };
                score(a).partial_cmp(&score(b)).expect("no NaN")
            }
            (DocMetrics::Generic(b), DocMetrics::Generic(a)) => {
                let ratio = |p: (usize, usize)| {
                    if p.1 == 0 {
                        1.0
                    } else {
                        p.0 as f64 / p.1 as f64
                    }
                };
                ratio(a.line_recall)
                    .partial_cmp(&ratio(b.line_recall))
                    .expect("no NaN")
            }
            _ => unreachable!("kind is the same on both sides"),
        };
        match direction {
            std::cmp::Ordering::Greater => improved += 1,
            std::cmp::Ordering::Equal => unchanged += 1,
            std::cmp::Ordering::Less => regressed += 1,
        }

        let kind_label = match kind {
            DocKind::Tabular => "表格类",
            DocKind::Generic => "非表格类",
        };
        println!(
            "| {} | {doc_name} | {kind_label} | {} | {} |",
            idx + 1,
            before.format(),
            after.format()
        );
    }

    println!();
    println!(
        "汇总:{improved} 份变好,{unchanged} 份不变,{regressed} 份变差(共 21 份。\
         打分口径:表格类取三条指标比例之和,非表格类取逐行召回率;严格改善/持平/\
         退步按浮点比较,不设容差缓冲。逐文档表格里的具体分子分母才是判断是否\
         真的变差的依据,这里只给方向计数。)"
    );

    Ok(())
}
