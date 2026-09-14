// 第 ④ 臂:本地 OCR → deid 脱敏 → DeepSeek → verify → 渲染成 medrep.rs::score()
// 能读的行。产出目录 arm4_llm/deepseek-<mode>/,与 medrep.rs 头注释里「第 ④ 列
// 按模型分子目录」的约定一致,score() 不用改解析器就能读。
//
// 跑法(先 `export MEDREP_ROOT=<medrepbench 下载目录>` `DEEPSEEK_API_KEY=…`):
//
// ```
// cargo run --release -p ocr --example medrep_llm --features engine,testing -- \
//   --mode text  [--limit N] [--out out]
// cargo run --release -p ocr --example medrep_llm --features engine,testing -- \
//   --mode image [--limit N] [--out out]
// cargo run --release -p ocr --example medrep --features engine,testing -- --score --out out
// ```
//
// 每份文档写两个文件:`{doc}.txt`(校验后的化验行,score() 用
// `parser::extract_labs` 读)、`{doc}.halluc.json`(`labs_*` / `all_*` 两组
// total/rejected/unverified + token 用量 + 本份 LLM 毫秒数——medrep.rs 的
// `score()` 跨全部文档累加,打成两条**分别标注**的幻觉率)。
// 顺带把 ② 几何重建臂的文本写进 `<out>/arm2_geo/`(同一遍 OCR 的产物,见
// 循环里的注释)。可续跑:两个产出都在的文档直接跳过。

use anyhow::{bail, Context, Result};
use base64::Engine;
use deid::{
    assert_clean, parse_extraction, redact_boxes, redact_text, verify, Box as DBox, Extraction,
    KnownIdentity, Mode,
};
use image::GenericImageView;
use ocr::{rebuild_layout_text, recognize_engine_lines, redact_image, PaintRect};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Instant;

/// 抽取用的系统提示词(schema v1)。云端抽取路径(`services/api/extract.py`)
/// 复用同一份文件——改这里就是改两处的行为,不要各写各的(两边 byte-identical
/// 由 `services/api/test_api.py` 的 `test_extract_system_prompt_matches_eval_fixture`
/// 兜底)。
const SYSTEM: &str = include_str!("../../deid/prompts/extract_v1_system.txt");
/// 图片档 user message 里的提示文本,同样与 `services/api/extract.py` 共享一份文件。
const IMAGE_USER_TEXT: &str = include_str!("../../deid/prompts/extract_v1_image_user.txt");

const DEEPSEEK_URL: &str = "https://api.deepseek.com/chat/completions";
/// 模型**默认值**,不是硬绑定:`DEEPSEEK_MODEL_TEXT` / `DEEPSEEK_MODEL_VISION`
/// 可以覆盖,跑出来的每个数字都在运行头和 `{doc}.halluc.json` 里带着它是哪个
/// 模型跑的 —— 换了模型的数字不许和旧数字混在一张表里。
///
/// 计划里写的是 `deepseek-v4-flash` / `deepseek-v4-flash-vision-exp`:这两个名字
/// `GET /models` 已经不列(只剩 `deepseek-flash` 和 `deepseek-v4-pro`),但官方
/// 定价文档写明它们是旧名、仍然受理、同一档价钱,指向的就是 `deepseek-flash`。
/// `deepseek-flash` 自己吃 `image_url`,两档共用它。换模型前先自己打一次 /models。
const MODEL_TEXT: &str = "deepseek-flash";
const MODEL_IMAGE: &str = "deepseek-flash";

fn root() -> String {
    std::env::var("MEDREP_ROOT").expect("设置 MEDREP_ROOT=<medrepbench 目录>(见 medrep.rs 头注释)")
}

/// 该模式用哪个模型:环境变量优先,空串当没设(别让一个手滑的 `export X=`
/// 把模型名变成空字符串送出去)。
fn model_for(mode: Mode) -> String {
    let (var, default) = match mode {
        Mode::Text => ("DEEPSEEK_MODEL_TEXT", MODEL_TEXT),
        Mode::Image => ("DEEPSEEK_MODEL_VISION", MODEL_IMAGE),
    };
    std::env::var(var)
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| default.to_string())
}

fn mode_dir_name(mode: Mode) -> &'static str {
    match mode {
        Mode::Text => "text",
        Mode::Image => "image",
    }
}

/// 纯函数:拼 DeepSeek 请求体。不碰网络,单测直接验证形状。
fn request_body(model: &str, user_content: serde_json::Value) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user_content}
        ]
    })
}

/// 纯函数:从 DeepSeek 响应 JSON 里取出 `choices[0].message.content`。不碰网络,
/// 单测用一份罐头 JSON 验证。
fn response_content(resp: &serde_json::Value) -> Option<&str> {
    resp["choices"][0]["message"]["content"].as_str()
}

/// 纯函数:从响应里取 token 用量。DeepSeek 不保证带 `usage`,缺了按 0 算——
/// 报告里的每份 token 只能是"这批里报了用量的那些"的和,别把缺失当成 0 用量。
fn response_usage(resp: &serde_json::Value) -> (u64, u64) {
    let u = &resp["usage"];
    (
        u["prompt_tokens"].as_u64().unwrap_or(0),
        u["completion_tokens"].as_u64().unwrap_or(0),
    )
}

/// 唯一碰网络的函数。`key` 由调用方传入,绝不打印(错误信息里也不带)。
/// 返回:模型文本 + (prompt_tokens, completion_tokens)。
fn call_deepseek(
    key: &str,
    model: &str,
    user_content: serde_json::Value,
) -> Result<(String, (u64, u64))> {
    let body = request_body(model, user_content);
    let mut resp = ureq::post(DEEPSEEK_URL)
        .header("Authorization", &format!("Bearer {key}"))
        .send_json(&body)
        .context("deepseek http 请求失败")?;
    let v: serde_json::Value = resp
        .body_mut()
        .read_json()
        .context("deepseek 响应不是合法 json")?;
    let content = response_content(&v)
        .map(str::to_string)
        .context("deepseek 响应里没有 choices[0].message.content")?;
    Ok((content, response_usage(&v)))
}

/// verify 后的 labs → `name value unit low-high` 一行,score() 用
/// `parser::extract_labs` 读(其列切分是 `split_whitespace`,单空格分隔即可)。
fn render_rows(e: &Extraction) -> String {
    e.labs
        .iter()
        .map(|l| {
            let range = match (l.ref_low.is_empty(), l.ref_high.is_empty()) {
                (false, false) => format!("{}-{}", l.ref_low, l.ref_high),
                (false, true) => format!(">{}", l.ref_low),
                (true, false) => format!("<{}", l.ref_high),
                _ => String::new(),
            };
            format!("{} {} {} {}", l.name, l.value, l.unit, range)
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// 只渲染**逐字校验通过**的化验行。
///
/// 图片档的 `verify` 是"打标不丢弃"(verify.rs:122-129:图片才是原件,OCR 文本
/// 只是旁证,对不上算"待核"而不是"编的"),所以图片档的 `{doc}.txt` 里混着没过
/// 校验的行;文本档的 `verify` 直接丢,`{doc}.txt` 本来就只剩过了校验的。两边
/// **处置规则不同**,拿一张表比就是比错了对象(评审 F1)。图片档因此多写一份
/// `-verified` 目录,score() 把它当独立一列,与文本档同口径。
///
/// 文本档不写这份:`verify` 已经丢过一轮,再写只是同一批数字的第二列。
fn render_rows_verified(e: &Extraction) -> String {
    let kept = Extraction {
        labs: e.labs.iter().filter(|l| !l.unverified).cloned().collect(),
        ..Default::default()
    };
    render_rows(&kept)
}

/// 一次调用里累计的计数。**每个 worker 线程各持一份**,跑完合并一次——
/// 逐份抢锁没必要。失败分五类,不许混成一个"整份失败":OCR 炸了、
/// **脱敏门拦下**、API 失败、模型回的不是合法 JSON、落盘出错。脱敏门那一类
/// 必须单独报(spec:拦下就跳过,绝不绕过),混进去就看不出门拦了几份。
#[derive(Default)]
struct Stats {
    labs_total: usize,
    labs_rejected: usize,
    labs_unverified: usize,
    all_total: usize,
    all_rejected: usize,
    all_unverified: usize,
    ocr_failed: usize,
    deid_blocked: usize,
    api_failed: usize,
    parse_failed: usize,
    io_failed: usize,
    done: usize,
    prompt_tok: u64,
    completion_tok: u64,
    /// 各线程耗时之和(不是墙钟);除以 `done` 得每份延迟,这才是要报的数。
    ocr_secs: f64,
    llm_secs: f64,
}

impl Stats {
    fn merge(&mut self, o: Stats) {
        self.labs_total += o.labs_total;
        self.labs_rejected += o.labs_rejected;
        self.labs_unverified += o.labs_unverified;
        self.all_total += o.all_total;
        self.all_rejected += o.all_rejected;
        self.all_unverified += o.all_unverified;
        self.ocr_failed += o.ocr_failed;
        self.deid_blocked += o.deid_blocked;
        self.api_failed += o.api_failed;
        self.parse_failed += o.parse_failed;
        self.io_failed += o.io_failed;
        self.done += o.done;
        self.prompt_tok += o.prompt_tok;
        self.completion_tok += o.completion_tok;
        self.ocr_secs += o.ocr_secs;
        self.llm_secs += o.llm_secs;
    }
}

/// 每份文档都要的只读上下文(线程间共享)。
struct Ctx<'a> {
    root: &'a str,
    dir: &'a Path,
    /// 只有图片档有:同一批产出里"只留校验通过的行"的那一份(见
    /// `render_rows_verified`)。文本档是 `None`。
    verified_dir: Option<&'a Path>,
    arm2_dir: &'a Path,
    key: &'a str,
    model: &'a str,
    mode: Mode,
    known: &'a KnownIdentity,
}

/// 一份文档的整条路:读图 → 本地 OCR → 脱敏 → **过门** → DeepSeek → 逐字校验
/// → 落盘。`Err` 只用于"落盘/编码这类本不该失败的事",各类业务失败都记进
/// `s` 后正常返回。
fn process_doc(c: &Ctx, doc: &str, s: &mut Stats) -> Result<()> {
    let img_path = PathBuf::from(c.root).join("images").join(doc);
    let Ok(bytes) = std::fs::read(&img_path) else {
        return Ok(());
    };
    if bytes.is_empty() {
        return Ok(()); // 上游 LFS 空对象
    }
    let row_path = c.dir.join(format!("{doc}.txt"));
    let arm2_path = c.arm2_dir.join(format!("{doc}.txt"));
    let verified_path = c.verified_dir.map(|d| d.join(format!("{doc}.txt")));
    let verified_done = verified_path.as_ref().is_none_or(|p| p.exists());
    if row_path.exists() && arm2_path.exists() && verified_done {
        return Ok(()); // 可续跑
    }

    let t_ocr = Instant::now();
    let Ok((el, _conf)) = recognize_engine_lines(&bytes) else {
        s.ocr_failed += 1;
        return Ok(());
    };
    let text = rebuild_layout_text(&el.lines);
    s.ocr_secs += t_ocr.elapsed().as_secs_f64();
    // ② 几何重建臂:`recognize_engine_layout` 就是 `recognize_engine_lines`
    // + `rebuild_layout_text`(lib.rs:960),上面两行已经把它算完了。基线和
    // ④ 臂共用这一遍 OCR,而不是让 `medrep --produce` 对同一批图再跑一遍
    // (全库一遍 OCR 按小时算)。产出逐字等价,`--produce` 那条路仍然可用。
    if !arm2_path.exists() {
        std::fs::write(&arm2_path, &text)?;
    }
    if row_path.exists() && verified_done {
        return Ok(()); // ④ 臂这份跑过了,刚才只是补基线
    }

    let red = redact_text(&text, c.known, 0);
    if assert_clean(&red.text, c.known).is_err() {
        // 脱敏门拦下:计数并跳过,**不送云**。
        s.deid_blocked += 1;
        return Ok(());
    }

    let content = match c.mode {
        Mode::Text => serde_json::json!(red.text),
        Mode::Image => {
            // 坐标系必须是 `el.frame`(recognize_engine_lines 内部预处理后的
            // working frame),不能重新解码原始字节——那是另一套坐标系,见
            // ocr::redact_image_bytes 的坐标系警告。
            let (w, h) = el.frame.dimensions();
            let boxes: Vec<DBox> = el
                .lines
                .iter()
                .map(|l| DBox {
                    text: l.text.clone(),
                    left: l.left,
                    top: l.top,
                    right: l.right,
                    bottom: l.top + l.height,
                })
                .collect();
            let rects: Vec<PaintRect> = redact_boxes(&boxes, c.known, w as f32, h as f32)
                .into_iter()
                .map(|r| PaintRect {
                    left: r.left,
                    top: r.top,
                    right: r.right,
                    bottom: r.bottom,
                })
                .collect();
            let jpg = redact_image(&el.frame, &rects)?;
            let b64 = base64::engine::general_purpose::STANDARD.encode(&jpg);
            serde_json::json!([
                {"type": "text", "text": IMAGE_USER_TEXT},
                {"type": "image_url", "image_url": {"url": format!("data:image/jpeg;base64,{b64}")}}
            ])
        }
    };

    let t_llm = Instant::now();
    let (raw, (ptok, ctok)) = match call_deepseek(c.key, c.model, content) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{doc}: deepseek 调用失败:{e:#}");
            s.api_failed += 1;
            return Ok(());
        }
    };
    s.llm_secs += t_llm.elapsed().as_secs_f64();
    let llm_ms = t_llm.elapsed().as_millis() as u64;
    s.prompt_tok += ptok;
    s.completion_tok += ctok;

    let parsed = match parse_extraction(&raw) {
        Ok(p) => p,
        Err(_) => {
            s.parse_failed += 1;
            std::fs::write(&row_path, "")?;
            return Ok(());
        }
    };
    // 两个分母,分开报(评审:原来分子跨全字段、分母只算 labs,比出来没意义)。
    // labs_*:只看化验条目,与三条指标同一批对象。
    // all_*:`verify` 真正校验的全部对象 —— labs + meds + diagnoses 三类条目,
    //        外加 doc_date/impression/notes 三个顶层标量字段(空值算通过)。
    let n_labs = parsed.labs.len();
    let n_all = n_labs + parsed.meds.len() + parsed.diagnoses.len() + 3;
    let v = verify(parsed, &red.text, c.mode);
    // 文本档不过 = 条目被丢掉;图片档不过 = 留着但打 unverified。一条式子两档都对。
    let labs_rejected = n_labs - v.extraction.labs.len();
    let labs_unverified = v.extraction.labs.iter().filter(|l| l.unverified).count();
    s.labs_total += n_labs;
    s.labs_rejected += labs_rejected;
    s.labs_unverified += labs_unverified;
    s.all_total += n_all;
    s.all_rejected += v.rejected;
    s.all_unverified += v.unverified;
    s.done += 1;

    std::fs::write(&row_path, render_rows(&v.extraction))?;
    if let Some(p) = &verified_path {
        std::fs::write(p, render_rows_verified(&v.extraction))?;
    }
    // 留一份模型原话。这一轮之所以要**重跑整条图片臂**才能算"只看校验通过的行",
    // 就是因为上一轮没存它——校验结果重算不出来,行渲染时 flag/ref 已经压扁了。
    // 一个 write 换一次重跑,值。
    std::fs::write(c.dir.join(format!("{doc}.raw.json")), &raw)?;
    std::fs::write(
        c.dir.join(format!("{doc}.halluc.json")),
        serde_json::json!({
            "labs_total": n_labs,
            "labs_rejected": labs_rejected,
            "labs_unverified": labs_unverified,
            "all_total": n_all,
            "all_rejected": v.rejected,
            "all_unverified": v.unverified,
            "prompt_tokens": ptok,
            "completion_tokens": ctok,
            "llm_ms": llm_ms,
            "model": c.model,
        })
        .to_string(),
    )?;
    eprintln!("{doc}: labs {n_labs},丢 {labs_rejected},待核 {labs_unverified}");
    Ok(())
}

/// MedRepBench 已去标识,没有真实身份可填 K 层;给一个绝不会出现在报告图里的
/// 占位名,让 K 层照常跑(no-op)、A/P 两层正常生效。**跑和重算必须用同一个**,
/// 否则重算出来的 `red.text` 与当初送云、当初校验的那份对不上。
fn eval_known() -> KnownIdentity {
    KnownIdentity {
        name: "＿评测占位＿".into(),
        id_number: None,
        phone: None,
    }
}

/// 离线重算图片档「校验通过」的那一列(Task 9b),**不碰网络**。
///
/// 输入全在盘上:`{doc}.raw.json`(模型原话,fix round 1 起落盘)+
/// `arm2_geo/{doc}.txt`(同一遍本地 OCR 的文本)。`redact_text` 是纯函数,
/// 重跑逐字节复现当初送去校验的那份原文,所以换了校验规则不需要重调一次 API。
///
/// 产出写进**另一个**目录(默认 `deepseek-image-verified-tol/`,
/// 用 `REVERIFY_OUT_DIR=` 换名字以免盖掉上一轮的产出),旧的
/// `deepseek-image-verified/` 原样留着 —— `score()` 于是把新旧两列并排打出来,
/// 两列相减就是「这一轮新放行的行」对真值的表现,不用另写一套打分逻辑。
///
/// stdout:`NEW\t{doc}\t{行}`(新放行)、`PEND\t{doc}\t{行}`(仍待核),供抽样手看。
/// stderr:汇总数字。
fn reverify(root: &str, out: &str) -> Result<()> {
    let base = PathBuf::from(root).join(out).join("arm4_llm");
    let (src_dir, old_dir) = (
        base.join("deepseek-image"),
        base.join("deepseek-image-verified"),
    );
    let new_dir = base.join(
        std::env::var("REVERIFY_OUT_DIR").unwrap_or_else(|_| "deepseek-image-verified-tol".into()),
    );
    std::fs::create_dir_all(&new_dir)?;
    let arm2 = PathBuf::from(root).join(out).join("arm2_geo");
    let known = eval_known();

    let mut raws: Vec<PathBuf> = std::fs::read_dir(&src_dir)
        .with_context(|| format!("读 {}", src_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.to_string_lossy().ends_with(".raw.json"))
        .collect();
    raws.sort();
    anyhow::ensure!(
        !raws.is_empty(),
        "{} 下没有 .raw.json(round 0 的产出没存模型原话,重算不了)",
        src_dir.display()
    );

    let (mut docs, mut labs, mut before, mut after) = (0usize, 0usize, 0usize, 0usize);
    let (mut released, mut withdrawn, mut parse_failed, mut no_ocr) =
        (0usize, 0usize, 0usize, 0usize);
    for p in &raws {
        let doc = p
            .file_name()
            .and_then(|s| s.to_str())
            .and_then(|s| s.strip_suffix(".raw.json"))
            .context("文件名不是 {doc}.raw.json")?
            .to_string();
        let raw = std::fs::read_to_string(p)?;
        let Ok(parsed) = parse_extraction(&raw) else {
            parse_failed += 1;
            std::fs::write(new_dir.join(format!("{doc}.txt")), "")?;
            continue;
        };
        let Ok(text) = std::fs::read_to_string(arm2.join(format!("{doc}.txt"))) else {
            no_ocr += 1;
            continue;
        };
        let red = redact_text(&text, &known, 0);
        let n = parsed.labs.len();
        let v = verify(parsed, &red.text, Mode::Image);
        docs += 1;
        labs += n;
        after += v.extraction.labs.iter().filter(|l| l.unverified).count();
        // before 用当初记下的数,不是我这轮推算的——那才是「改之前」的事实。
        if let Ok(h) = std::fs::read_to_string(src_dir.join(format!("{doc}.halluc.json"))) {
            if let Ok(j) = serde_json::from_str::<serde_json::Value>(&h) {
                before += j["labs_unverified"].as_u64().unwrap_or(0) as usize;
            }
        }

        let rows = render_rows_verified(&v.extraction);
        // 行集合按**重数**比,同名同值的两行不许互相抵消
        let mut delta: std::collections::HashMap<&str, i64> = std::collections::HashMap::new();
        for l in rows.lines() {
            *delta.entry(l).or_default() += 1;
        }
        let old = std::fs::read_to_string(old_dir.join(format!("{doc}.txt"))).unwrap_or_default();
        for l in old.lines() {
            *delta.entry(l).or_default() -= 1;
        }
        for (line, d) in &delta {
            if *d > 0 {
                released += *d as usize;
                for _ in 0..*d {
                    println!("NEW\t{doc}\t{line}");
                }
            } else if *d < 0 {
                withdrawn += (-*d) as usize;
                // fix round 1 起会出现:单位词边界/数值锚点/标志独立词三条是**收紧**,
                // 新规则不再是旧规则的超集。收回的都要能说清是哪条挡的。
                eprintln!("WITHDRAWN\t{doc}\t{line}");
            }
        }
        let pending = Extraction {
            labs: v
                .extraction
                .labs
                .iter()
                .filter(|l| l.unverified)
                .cloned()
                .collect(),
            ..Default::default()
        };
        let pending_rows = render_rows(&pending);
        for line in pending_rows.lines() {
            println!("PEND\t{doc}\t{line}");
        }
        // 每条待核行是**哪个字段**没过:把该行拆成 6 份"只填一个字段"的条目分别
        // 过一遍校验(空字段一律算通过,所以剩下的那个字段就是结论)。用的是同一个
        // 公开的 `verify`,没有为了诊断而把内部判定暴露出去。
        for l in &pending.labs {
            let fails = |one: deid::LabItem| {
                let probe = Extraction {
                    labs: vec![one],
                    ..Default::default()
                };
                verify(probe, &red.text, Mode::Image).extraction.labs[0].unverified
            };
            let d = deid::LabItem::default;
            let probes: [(&str, deid::LabItem); 6] = [
                (
                    "name",
                    deid::LabItem {
                        name: l.name.clone(),
                        ..d()
                    },
                ),
                (
                    "value",
                    deid::LabItem {
                        value: l.value.clone(),
                        ..d()
                    },
                ),
                (
                    "unit",
                    deid::LabItem {
                        unit: l.unit.clone(),
                        ..d()
                    },
                ),
                (
                    "ref_low",
                    deid::LabItem {
                        ref_low: l.ref_low.clone(),
                        ..d()
                    },
                ),
                (
                    "ref_high",
                    deid::LabItem {
                        ref_high: l.ref_high.clone(),
                        ..d()
                    },
                ),
                (
                    "flag",
                    deid::LabItem {
                        flag: l.flag.clone(),
                        ..d()
                    },
                ),
            ];
            let bad: Vec<&str> = probes
                .into_iter()
                .filter(|(_, one)| fails(one.clone()))
                .map(|(n, _)| n)
                .collect();
            println!(
                "WHY\t{doc}\t{}\t{} | {} | {} | {}-{} | {}",
                bad.join(","),
                l.name,
                l.value,
                l.unit,
                l.ref_low,
                l.ref_high,
                l.flag
            );
        }
        // 还有待核行的文档,把**校验真正比对的那份原文**(脱敏后的)一起打出来:
        // 手看「为什么还待核」时,看 arm2 的原始 OCR 文本会漏掉一整类原因 ——
        // 脱敏层把某些串涂了(日期偏移、疑似证件号),值自然就对不上了。
        if !pending_rows.is_empty() {
            for line in red.text.lines() {
                println!("RED\t{doc}\t{line}");
            }
        }
        std::fs::write(new_dir.join(format!("{doc}.txt")), rows)?;
    }

    let pct = |a: usize, b: usize| {
        if b == 0 {
            0.0
        } else {
            a as f64 / b as f64 * 100.0
        }
    };
    eprintln!(
        "重算 {docs} 份(JSON 不合法 {parse_failed},缺 OCR 文本 {no_ocr}):\
         labs {labs} 条;待核 {before} → {after}({:.1}% → {:.1}%);\
         新放行 {released} 行,收回 {withdrawn} 行",
        pct(before, labs),
        pct(after, labs),
    );
    eprintln!("新的一列写在 {}", new_dir.display());
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let arg = |k: &str| {
        args.iter()
            .position(|a| a == k)
            .and_then(|i| args.get(i + 1).cloned())
    };
    let mode = match arg("--mode").as_deref() {
        Some("image") => Mode::Image,
        Some("text") | None => Mode::Text,
        Some(other) => bail!("--mode 只能是 text 或 image,收到 {other}"),
    };
    let limit: Option<usize> = arg("--limit").and_then(|s| s.parse().ok());
    let out = arg("--out").unwrap_or_else(|| "out".into());

    // 离线重算:只读盘,不要 key,也不该被误当成"又跑了一轮"。
    if args.iter().any(|a| a == "--reverify") {
        return reverify(&root(), &out);
    }

    // 提前失败,别跑到一半才发现 key 没设——绝不打印 key 本身,连报错信息里都不带。
    let key = std::env::var("DEEPSEEK_API_KEY")
        .context("DEEPSEEK_API_KEY 未设置——先 export DEEPSEEK_API_KEY=<key> 再跑")?;

    let root = root();
    let model = model_for(mode);
    let dir = PathBuf::from(&root)
        .join(&out)
        .join("arm4_llm")
        .join(format!("deepseek-{}", mode_dir_name(mode)));
    std::fs::create_dir_all(&dir)?;

    let gt = std::fs::read_to_string(format!("{root}/gt.tsv"))
        .context("读 gt.tsv——先跑 medrep_make_gt.py")?;
    let mut docs: Vec<String> = gt
        .lines()
        .filter_map(|l| l.split('\t').next())
        .map(str::to_string)
        .collect();
    docs.dedup();
    if let Some(n) = limit {
        docs.truncate(n);
    }

    // 测的是脱敏管线本身,不是找不到身份信息就绕过它。占位名见 `eval_known`。
    let known = eval_known();

    // ② 几何重建(基线臂)的产出目录。见 process_doc 里写入处的注释:与
    // `medrep --produce` 的 arm2 逐字同源,顺手落盘省一遍全库 OCR。
    let arm2_dir = PathBuf::from(&root).join(&out).join("arm2_geo");
    std::fs::create_dir_all(&arm2_dir)?;

    // 图片档多一份"只留校验通过的行"的产出目录。沿用「第 ④ 列按模型分子目录」
    // 的约定,score() 自动把它当成独立一列,不用改打分器的取文件逻辑。
    let verified_dir = match mode {
        Mode::Image => {
            let d = dir.with_file_name(format!("deepseek-{}-verified", mode_dir_name(mode)));
            std::fs::create_dir_all(&d)?;
            Some(d)
        }
        Mode::Text => None,
    };

    let ctx = Ctx {
        root: &root,
        dir: &dir,
        verified_dir: verified_dir.as_deref(),
        arm2_dir: &arm2_dir,
        key: &key,
        model: &model,
        mode,
        known: &known,
    };

    // 并发只为**等网络**:单份 LLM 往返实测 ~12s,683 份串着跑一条臂就两个半
    // 小时。8 条线程把它压到二十来分钟。OCR 也在线程里跑——引擎是 `&'static`
    // 单例(lib.rs 的 `static PIPELINE: OnceLock<OAROCR>`,静态量本身就要求
    // `Sync`),多线程调用安全。落盘各写各的文件,不冲突。
    let jobs: usize = arg("--jobs")
        .and_then(|s| s.parse().ok())
        .unwrap_or(8)
        .max(1);
    // 运行头:模式 + **模型** + 并发 + 产出目录。每一轮的数字都得说清是哪个
    // 模型跑的 —— 模型可由环境变量换,换了还混在一张表里就是比错了。
    eprintln!(
        "④ 臂:模式 {} / 模型 {model} / 并发 {jobs} / 产出 {}",
        mode_dir_name(mode),
        dir.display()
    );

    let next = AtomicUsize::new(0);
    let merged = Mutex::new(Stats::default());
    let wall = Instant::now();

    std::thread::scope(|sc| {
        for _ in 0..jobs {
            sc.spawn(|| {
                let mut s = Stats::default();
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(doc) = docs.get(i) else { break };
                    if let Err(e) = process_doc(&ctx, doc, &mut s) {
                        eprintln!("{doc}: 落盘失败:{e:#}");
                        s.io_failed += 1;
                    }
                }
                // 只有 panic 会毒化这把锁,而 panic 本来就该让整轮作废。
                merged
                    .lock()
                    .expect("统计锁被毒化 = 某个 worker panic 了,这轮数据不可信")
                    .merge(s);
            });
        }
    });

    let s = merged
        .into_inner()
        .expect("统计锁被毒化 = 某个 worker panic 了,这轮数据不可信");
    let per = |x: f64| if s.done > 0 { x / s.done as f64 } else { 0.0 };
    eprintln!(
        "跑完 {} 份({jobs} 并发,墙钟 {:.0}s):labs {} 条(丢 {},待核 {});\
         全字段 {} 项(丢 {},待核 {})",
        s.done,
        wall.elapsed().as_secs_f64(),
        s.labs_total,
        s.labs_rejected,
        s.labs_unverified,
        s.all_total,
        s.all_rejected,
        s.all_unverified
    );
    eprintln!(
        "失败:OCR {},脱敏门拦下 {},API {},JSON 不合法 {},落盘 {}",
        s.ocr_failed, s.deid_blocked, s.api_failed, s.parse_failed, s.io_failed
    );
    eprintln!(
        "token:prompt {} + completion {},每份 {:.0};\
         每份延迟:OCR {:.2}s,LLM {:.2}s",
        s.prompt_tok,
        s.completion_tok,
        per((s.prompt_tok + s.completion_tok) as f64),
        per(s.ocr_secs),
        per(s.llm_secs)
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_body_has_system_and_user_messages() {
        let body = request_body(MODEL_TEXT, serde_json::json!("待抽取文本"));
        assert_eq!(body["model"], MODEL_TEXT);
        assert_eq!(body["temperature"], 0);
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], SYSTEM);
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["messages"][1]["content"], "待抽取文本");
    }

    #[test]
    fn request_body_carries_image_content_array_untouched() {
        let content = serde_json::json!([
            {"type": "text", "text": "请抽取这张单据。"},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,AAAA"}}
        ]);
        let body = request_body(MODEL_IMAGE, content.clone());
        assert_eq!(body["messages"][1]["content"], content);
    }

    #[test]
    fn response_content_reads_canned_deepseek_reply() {
        let resp: serde_json::Value = serde_json::from_str(
            r#"{"choices":[{"message":{"content":"{\"doc_type\":\"lab\",\"labs\":[]}"}}]}"#,
        )
        .unwrap();
        let content = response_content(&resp).expect("content 应该能取到");
        let e = parse_extraction(content).unwrap();
        assert_eq!(e.doc_type, "lab");
    }

    #[test]
    fn response_usage_reads_tokens_and_defaults_to_zero() {
        let resp: serde_json::Value =
            serde_json::from_str(r#"{"usage":{"prompt_tokens":428,"completion_tokens":231}}"#)
                .unwrap();
        assert_eq!(response_usage(&resp), (428, 231));
        // 缺 usage 不该 panic,按 0 算(报告里说明这是"没报用量",不是"0 用量")
        assert_eq!(response_usage(&serde_json::json!({})), (0, 0));
    }

    #[test]
    fn response_content_missing_choices_is_none() {
        let resp = serde_json::json!({"choices": []});
        assert!(response_content(&resp).is_none());
    }

    #[test]
    fn render_rows_is_single_space_joined_and_skips_empty_range() {
        let e = Extraction {
            labs: vec![
                deid::LabItem {
                    name: "白细胞计数".into(),
                    value: "5.6".into(),
                    unit: "10^9/L".into(),
                    ref_low: "4.0".into(),
                    ref_high: "10.0".into(),
                    ..Default::default()
                },
                deid::LabItem {
                    name: "血糖".into(),
                    value: "7.1".into(),
                    unit: "mmol/L".into(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let rendered = render_rows(&e);
        assert_eq!(rendered, "白细胞计数 5.6 10^9/L 4.0-10.0\n血糖 7.1 mmol/L");
    }

    #[test]
    fn render_rows_verified_drops_only_the_flagged_labs() {
        // 图片档 verify 打标不丢弃,所以 `-verified` 这一列必须自己滤一遍;
        // 滤错了整条 F1 修复就白做(数字照样混着待核行)。
        let e = Extraction {
            labs: vec![
                deid::LabItem {
                    name: "白细胞计数".into(),
                    value: "5.6".into(),
                    unit: "10^9/L".into(),
                    ref_low: "4.0".into(),
                    ref_high: "10.0".into(),
                    ..Default::default()
                },
                deid::LabItem {
                    name: "血糖".into(),
                    value: "7.1".into(),
                    unit: "mmol/L".into(),
                    unverified: true,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert_eq!(render_rows(&e).lines().count(), 2, "全量列保持两行不变");
        assert_eq!(render_rows_verified(&e), "白细胞计数 5.6 10^9/L 4.0-10.0");
    }

    #[test]
    fn render_rows_output_is_readable_by_score_via_extract_labs() {
        // score() 靠 parser::extract_labs 读行——这里不新写解析器,直接验证
        // render_rows 的输出真的能被它读出至少一行,不是自说自话的格式。
        let e = Extraction {
            labs: vec![deid::LabItem {
                name: "白细胞计数".into(),
                value: "5.6".into(),
                unit: "10^9/L".into(),
                ref_low: "4.0".into(),
                ref_high: "10.0".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let rows = parser::extract_labs(&render_rows(&e));
        assert_eq!(rows.len(), 1, "应该解出恰好一条化验行");
        assert!((rows[0].value_num - 5.6).abs() < 1e-9);
    }
}
