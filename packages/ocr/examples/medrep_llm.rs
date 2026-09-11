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
// `parser::extract_labs` 读)、`{doc}.halluc.json`
// (`{"total":N,"rejected":R,"unverified":U}`,N 是 LLM 原始产出的化验条数,
// R/U 是 `deid::verify` 判定的丢弃/待核数——medrep.rs 的 `score()` 跨全部文档
// 累加算幻觉率)。可续跑:`{doc}.txt` 已存在的文档直接跳过。

use anyhow::{bail, Context, Result};
use base64::Engine;
use deid::{
    assert_clean, parse_extraction, redact_boxes, redact_text, verify, Box as DBox, Extraction,
    KnownIdentity, Mode,
};
use image::GenericImageView;
use ocr::{rebuild_layout_text, recognize_engine_lines, redact_image, PaintRect};
use std::path::PathBuf;

/// 抽取用的系统提示词(schema v1)。云端抽取路径(`services/api/extract.py`,
/// 另一个 worktree)复用同一段文字——改这里就是改两处的行为,不要各写各的。
const SYSTEM: &str = "你是医疗单据结构化抽取器。只输出一个 JSON 对象,不要解释、不要 markdown 围栏。\
所有字符串必须是单据上的原文逐字,缺失留空字符串,不许推断或换算。schema:\
{\"doc_type\":\"lab|discharge|outpatient|imaging|prescription|other\",\"doc_date\":\"YYYY-MM-DD\",\
\"labs\":[{\"name\":\"\",\"value\":\"\",\"unit\":\"\",\"ref_low\":\"\",\"ref_high\":\"\",\"flag\":\"H|L|\"}],\
\"meds\":[{\"name\":\"\",\"dose\":\"\",\"freq\":\"\",\"route\":\"\"}],\
\"diagnoses\":[{\"text\":\"\",\"icd\":\"\"}],\"impression\":\"\",\"notes\":\"\"}";

const DEEPSEEK_URL: &str = "https://api.deepseek.com/chat/completions";
const MODEL_TEXT: &str = "deepseek-v4-flash";
const MODEL_IMAGE: &str = "deepseek-v4-flash-vision-exp";

fn root() -> String {
    std::env::var("MEDREP_ROOT").expect("设置 MEDREP_ROOT=<medrepbench 目录>(见 medrep.rs 头注释)")
}

fn model_for(mode: Mode) -> &'static str {
    match mode {
        Mode::Text => MODEL_TEXT,
        Mode::Image => MODEL_IMAGE,
    }
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

/// 唯一碰网络的函数。`key` 由调用方传入,绝不打印(错误信息里也不带)。
fn call_deepseek(key: &str, model: &str, user_content: serde_json::Value) -> Result<String> {
    let body = request_body(model, user_content);
    let mut resp = ureq::post(DEEPSEEK_URL)
        .header("Authorization", &format!("Bearer {key}"))
        .send_json(&body)
        .context("deepseek http 请求失败")?;
    let v: serde_json::Value = resp
        .body_mut()
        .read_json()
        .context("deepseek 响应不是合法 json")?;
    response_content(&v)
        .map(str::to_string)
        .context("deepseek 响应里没有 choices[0].message.content")
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

    // MedRepBench 已去标识,没有真实身份信息可填 K 层;给一个绝不会出现在报告图
    // 里的占位名,让 K 层照常跑(no-op)、A/P 两层正常生效——测的是脱敏管线本身,
    // 不是找不到身份信息就绕过它。
    let known = KnownIdentity {
        name: "＿评测占位＿".into(),
        id_number: None,
        phone: None,
    };

    let (mut total, mut rejected, mut unverified, mut failed) = (0usize, 0usize, 0usize, 0usize);
    for doc in &docs {
        let img_path = PathBuf::from(&root).join("images").join(doc);
        let Ok(bytes) = std::fs::read(&img_path) else {
            continue;
        };
        if bytes.is_empty() {
            continue; // 上游 LFS 空对象
        }
        let row_path = dir.join(format!("{doc}.txt"));
        if row_path.exists() {
            continue; // 可续跑
        }

        let (el, _conf) = match recognize_engine_lines(&bytes) {
            Ok(x) => x,
            Err(_) => {
                failed += 1;
                continue;
            }
        };
        let text = rebuild_layout_text(&el.lines);
        let red = redact_text(&text, &known, 0);
        if assert_clean(&red.text, &known).is_err() {
            failed += 1;
            continue;
        }

        let content = match mode {
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
                let rects: Vec<PaintRect> = redact_boxes(&boxes, &known, w as f32, h as f32)
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
                    {"type": "text", "text": "请抽取这张单据。"},
                    {"type": "image_url", "image_url": {"url": format!("data:image/jpeg;base64,{b64}")}}
                ])
            }
        };

        let raw = match call_deepseek(&key, model, content) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("{doc}: deepseek 调用失败:{e:#}");
                failed += 1;
                continue;
            }
        };
        let parsed = match parse_extraction(&raw) {
            Ok(p) => p,
            Err(_) => {
                failed += 1;
                std::fs::write(&row_path, "")?;
                continue;
            }
        };
        let n = parsed.labs.len();
        let v = verify(parsed, &red.text, mode);
        total += n;
        rejected += v.rejected;
        unverified += v.unverified;
        std::fs::write(&row_path, render_rows(&v.extraction))?;
        std::fs::write(
            dir.join(format!("{doc}.halluc.json")),
            serde_json::json!({"total": n, "rejected": v.rejected, "unverified": v.unverified})
                .to_string(),
        )?;
        eprintln!("{doc}: labs {n},丢 {},待核 {}", v.rejected, v.unverified);
    }
    eprintln!("总计 labs {total},幻觉(丢弃){rejected},待核 {unverified},整份失败 {failed}");
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
