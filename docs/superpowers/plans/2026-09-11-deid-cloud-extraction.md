# 子项目 A · 本地脱敏 + 云抽取管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 手机上 OCR 文本/检测框 → 本地脱敏 → 经代理送 DeepSeek → 结构化 JSON → 逐字校验 → `ExtractionAdded` 落盘 → 摘要/趋势/分享优先吃抽取结果;并在 MedRepBench 683 份上用数字证明它打赢正则,达标才接产品。

**Architecture:** 新 crate `packages/deid`(纯函数:redact / restore / verify / 日期偏移 / 发送前闸,无 IO),`packages/ocr` 暴露检测框并提供按框涂黑;`core-model` 加 `Event::ExtractionAdded` + `extraction` 派生表;`parser::SourceDoc` 加 `extraction_json`,`aggregate` 有抽取结果时用它代替 `extract_labs`;移动端 Rust FRB 出 `prepare_cloud_extraction` / `commit_cloud_extraction`,Dart 只管 HTTP;代理是一个独立的 stdlib Python 函数(照抄 `services/claim-signer` 的样子),B 子项目日后并进 `services/api`。评测扩展 `packages/ocr/examples/medrep.rs` 的第 ④ 臂目录约定 + 幻觉率。

**Tech Stack:** Rust 2021(workspace 已有 `regex` / `serde` / `serde_json` / `sha2` / `hmac` / `chrono` / `thiserror`;`image` / `imageproc` 已是 `ocr` 的依赖;`ureq 3.3.0` 已在 Cargo.lock 里,作 `ocr` 的 dev-dependency 供评测调 DeepSeek),Flutter/Dart(`net.dart` 的 `Net` 作 HTTP),Python 3 stdlib(代理),flutter_rust_bridge 2.12(`apps/mobile_flutter/flutter_rust_bridge.yaml`:`rust_input: crate::api`,`dart_output: lib/src/rust`)。

**Spec:** `docs/superpowers/specs/2026-09-11-deid-cloud-extraction-design.md`(总纲 `2026-09-11-advanced-edition-overview-design.md`)

## Global Constraints

- 医疗数据:**只输出原文逐字内容,逐字子串校验挡幻觉**(CLAUDE.md)。校验不过:文本档丢弃并计幻觉,图片档标 `unverified` 保留。
- 生产代码 **no `unwrap()`**;错误用 `thiserror`(core-model 用 `MedmeError`,新 crate 自带 `DeidError`)。FRB 层用 `anyhow`(与 `apps/mobile_flutter/rust/src/api/vault.rs` 一致)。
- 密钥/口令只从环境变量读(`DEEPSEEK_API_KEY`、`MEDME_UPLOAD_TOKEN`),**不进代码、不进提交、不打印**。
- 脱敏**保留**:年龄、性别、检验项目/值/单位/区间、科室。**日期加同一偏移**(±90 天内,按档案固定),**医院名**掩成 `[H1]` 本地还原。
- 输出 schema **v1** 固定(spec §3);字段全是原文逐字,缺失留空。
- 事件类型新增 = 动 vault 格式;桌面兼容约束已解除(总纲),但事件必须保持 `serde(tag="type")` 可反序列化、旧日志不受影响。
- **评测不达标不接产品**(spec §6):项目召回 / 值-名配对 / 参考区间归属三项全部高于 58.7% / 49.7% / 24.3%,幻觉率有数。
- 提交:**不许 `git add -A`**,逐文件 add;提交信息说明 what + why;测试通过才提交(CLAUDE.md)。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `Cargo.toml`(根) | `members` 加 `packages/deid` |
| `packages/deid/Cargo.toml` `src/lib.rs` | crate 入口、`DeidError`、公开 API 再导出 |
| `packages/deid/src/known.rs` | K 层:已知身份精确删(含粘连形态) |
| `packages/deid/src/anchors.rs` | A 层:锚点词表 + 锚点后值换占位符;医院名 `[H1]` |
| `packages/deid/src/patterns.rs` | P 层:身份证/手机/长数字串/URL/邮箱 |
| `packages/deid/src/dates.rs` | 日期识别 + 偏移/还原 + `shift_days_from_secret` |
| `packages/deid/src/redact.rs` | `redact_text` / `redact_boxes` / `RestoreMap` / `restore` 组合三层 |
| `packages/deid/src/gate.rs` | 发送前闸 `assert_clean` |
| `packages/deid/src/verify.rs` | `verify` + schema v1 类型 `Extraction` / `LabItem` … |
| `packages/deid/tests/fixtures/*.txt` + `*.expected.txt` | 按 HIPAA 类别的真实形态样本 |
| `packages/deid/tests/fixtures.rs` | 逐对 fixture 断言 |
| `packages/deid/README.md` | 中国单子可识别信息清单(初始版) |
| `packages/ocr/src/lib.rs` | `recognize_engine_lines`(公开检测框)+ `redact_image` |
| `packages/ocr/examples/medrep_llm.rs` | 第 ④ 臂产出:OCR → deid → DeepSeek → verify → `{doc}.txt` + `{doc}.halluc.json` |
| `packages/ocr/examples/medrep.rs` | `MEDREP_ROOT` 环境变量 + 幻觉率一行 |
| `packages/ocr/examples/medrep_make_gt.py` | `MEDREP_ROOT` 环境变量 |
| `packages/core-model/src/event.rs` `schema.rs` `materialize.rs` `query.rs` `types.rs` | `ExtractionAdded`、`extraction` 表(v6)、投影、`extraction_json()`、`add_extraction()` |
| `packages/parser/src/extraction.rs` | schema v1 JSON → `Vec<LabObservation>` |
| `packages/parser/src/aggregate.rs` | `SourceDoc.extraction_json`,有则用 |
| `packages/share/src/export.rs` `share.rs` `qr.rs` | `GatheredRecord.extraction_json` 透传 |
| `apps/mobile_flutter/rust/src/api/vault.rs` `dto.rs` `vault_projections.rs` `vault_ephemeral.rs` | FRB:`recognize_image_pp` 带框、`prepare_cloud_extraction`、`redact_image_bytes`、`commit_cloud_extraction`;SourceDoc 透传 |
| `apps/mobile_flutter/lib/cloud_extract.dart` | HTTP 调代理(`Net`) |
| `apps/mobile_flutter/lib/import_flow.dart` | 入库后接云抽取(失败不阻断导入) |
| `apps/mobile_flutter/lib/profile_manager.dart` | `Profile` 加 `idNumber` / `phone` / `secret` |
| `services/extract-proxy/app.py` `test_app.py` `README.md` | `/v1/extract` 代理(stdlib) |
| `docs/ADR/0010-cloud-llm-extraction-and-accounts.md` | 翻案 ADR |
| `docs/log/2026-09-XX-deepseek-vs-regex-medrep.md` | 评测结果 |
| `../Medme-ghpages/privacy.html`(gh-pages 分支 worktree) | 隐私政策 |

---

### Task 1: `packages/deid` 骨架 + 日期偏移

**Files:**
- Modify: `Cargo.toml`(根,`members`)
- Create: `packages/deid/Cargo.toml`, `packages/deid/src/lib.rs`, `packages/deid/src/dates.rs`

**Interfaces:**
- Produces: `deid::DeidError`;`deid::dates::shift_days_from_secret(secret: &[u8]) -> i64`(范围 −90..=90);`deid::dates::shift_dates(text: &str, days: i64) -> String`(所有 `YYYY[-/.]M[-/.]D` 与 `YYYY年M月D日` → `YYYY-MM-DD` 偏移后);`deid::dates::unshift_dates(text: &str, days: i64) -> String`(把 `YYYY-MM-DD` 减回)。

- [ ] **Step 1: 建 crate,加进 workspace**

`Cargo.toml`(根)第 3 行 `members` 加 `"packages/deid"`(放在 `"packages/parser"` 之后)。

`packages/deid/Cargo.toml`:
```toml
[package]
name = "deid"
version = "0.1.0"
edition = "2021"
description = "本地脱敏:发给云 LLM 之前删已知身份、掩锚点字段、偏移日期;结果回来后还原与逐字校验。纯函数,无 IO。"

[dependencies]
regex.workspace = true
serde.workspace = true
serde_json.workspace = true
sha2.workspace = true
hmac.workspace = true
chrono.workspace = true
thiserror.workspace = true
```

`packages/deid/src/lib.rs`:
```rust
//! 本地脱敏(spec: docs/superpowers/specs/2026-09-11-deid-cloud-extraction-design.md §1/§4)。
//! 三层 + 一道闸:K 已知值 → A 锚点 → P 模式 → gate。全部纯函数,不做网络、不读盘。
pub mod dates;

#[derive(Debug, thiserror::Error)]
pub enum DeidError {
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("payload 含已知身份信息,拒发:{0}")]
    IdentityLeak(String),
}
```

- [ ] **Step 2: 写失败测试(日期偏移)**

`packages/deid/src/dates.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shift_days_is_deterministic_and_bounded() {
        let a = shift_days_from_secret(b"secret-a");
        assert_eq!(a, shift_days_from_secret(b"secret-a"));
        assert!((-90..=90).contains(&a));
        // 不同秘密大概率不同偏移(只要不恒等于 0 就行)
        assert!((0..50).any(|i| shift_days_from_secret(format!("s{i}").as_bytes()) != 0));
    }

    #[test]
    fn shift_and_unshift_round_trip_both_date_styles() {
        let t = "采集时间:2024-03-05 08:10 报告时间 2024年3月6日 住院号HS-2024-08-2201";
        let s = shift_dates(t, 10);
        assert!(s.contains("2024-03-15"), "{s}");
        assert!(s.contains("2024-03-16"), "{s}");
        // 嵌在长数字串里的“日期”(住院号)不动
        assert!(s.contains("HS-2024-08-2201"), "{s}");
        let back = unshift_dates(&s, 10);
        assert!(back.contains("2024-03-05") && back.contains("2024-03-06"), "{back}");
    }
}
```

- [ ] **Step 3: 跑,确认失败**

Run: `cargo test -p deid dates`
Expected: 编译错误(函数不存在)

- [ ] **Step 4: 实现**

`packages/deid/src/dates.rs`(测试模块上方):
```rust
//! 日期偏移:同一档案所有文档共用一个 ±90 天内的偏移,LLM 看到的是假绝对日期、
//! 真相对顺序;还原时减回。偏移由档案秘密派生,不落盘、随档案同步。
use chrono::{Duration, NaiveDate};
use hmac::{Hmac, KeyInit, Mac};
use regex::Regex;
use sha2::Sha256;
use std::sync::OnceLock;

/// HMAC-SHA256(secret, "date-shift") 前 4 字节 mod 181 − 90 ∈ [−90, 90]。
pub fn shift_days_from_secret(secret: &[u8]) -> i64 {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret)
        .expect("HMAC-SHA256 accepts a key of any length");
    mac.update(b"date-shift");
    let out = mac.finalize().into_bytes();
    let x = u32::from_be_bytes([out[0], out[1], out[2], out[3]]);
    (x % 181) as i64 - 90
}

// 与 parser::lib.rs 的 iso_re / cn_re 同形(那两个是私有的;两条正则字面量,不值得为此开 pub)。
fn iso_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})").expect("iso date re"))
}
fn cn_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日").expect("cn date re"))
}

/// 两侧紧邻数字 = 嵌在更长数字串里(住院号 HS-2024-08-2201),不当日期。
fn embedded_in_digits(s: &str, start: usize, end: usize) -> bool {
    let before = s[..start].chars().next_back().is_some_and(|c| c.is_ascii_digit());
    let after = s[end..].chars().next().is_some_and(|c| c.is_ascii_digit());
    before || after
}

fn shifted(y: &str, m: &str, d: &str, days: i64) -> Option<String> {
    let date = NaiveDate::from_ymd_opt(y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)?;
    Some((date + Duration::days(days)).format("%Y-%m-%d").to_string())
}

fn apply(text: &str, re: &Regex, days: i64) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for caps in re.captures_iter(text) {
        let m = caps.get(0).expect("group 0");
        out.push_str(&text[last..m.start()]);
        let keep = embedded_in_digits(text, m.start(), m.end());
        match (keep, shifted(&caps[1], &caps[2], &caps[3], days)) {
            (false, Some(s)) => out.push_str(&s),
            _ => out.push_str(m.as_str()),
        }
        last = m.end();
    }
    out.push_str(&text[last..]);
    out
}

/// 所有日期(ISO 与中文两种写法)加 `days`,统一写成 `YYYY-MM-DD`。
pub fn shift_dates(text: &str, days: i64) -> String {
    let t = apply(text, cn_re(), days);
    apply(&t, iso_re(), days)
}

/// 把 `YYYY-MM-DD` 减回 `days`(LLM 输出只会是这种写法,因为它看到的就是这种)。
pub fn unshift_dates(text: &str, days: i64) -> String {
    apply(text, iso_re(), -days)
}
```

- [ ] **Step 5: 跑,确认通过**

Run: `cargo test -p deid dates`
Expected: 2 passed

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml packages/deid/Cargo.toml packages/deid/src/lib.rs packages/deid/src/dates.rs
git commit -m "feat(deid): 新 crate + 按档案秘密派生的日期偏移

云抽取(spec 2026-09-11)第一块:日期偏移 ±90 天由 HMAC(profile_secret) 派生,
不落盘、随档案同步;ISO/中文两种写法都偏,嵌在长数字串里的不动。"
```

---

### Task 2: K/A/P 三层 + `redact_text` / `RestoreMap` / `restore`

**Files:**
- Create: `packages/deid/src/known.rs`, `packages/deid/src/anchors.rs`, `packages/deid/src/patterns.rs`, `packages/deid/src/redact.rs`
- Modify: `packages/deid/src/lib.rs`

**Interfaces:**
- Consumes: Task 1 的 `dates::shift_dates` / `unshift_dates`。
- Produces:
  ```rust
  pub struct KnownIdentity { pub name: String, pub id_number: Option<String>, pub phone: Option<String> }
  #[derive(Serialize, Deserialize, Default)]
  pub struct RestoreMap { pub placeholders: Vec<(String, String)>, pub shift_days: i64 }
  pub struct Redacted { pub text: String, pub map: RestoreMap }
  pub fn redact_text(text: &str, known: &KnownIdentity, shift_days: i64) -> Redacted
  pub fn restore(text: &str, map: &RestoreMap) -> String
  pub fn anchors::ANCHORS: &[&str]   // 锚点词表(含 labs.rs PAGE_FURNITURE 的 22 个 + 本 spec 补的)
  ```
  占位符形如 `[P1]`(人)`[N1]`(号码)`[H1]`(医院)`[T1]`(电话)`[U1]`(网址/邮箱)。

- [ ] **Step 1: 写失败测试**

`packages/deid/src/redact.rs` 末尾:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn known() -> KnownIdentity {
        KnownIdentity { name: "孟丁".into(), id_number: Some("110101199001011234".into()), phone: Some("13800138000".into()) }
    }

    #[test]
    fn known_name_is_removed_even_when_glued() {
        let r = redact_text("姓名孟丁性别男 年龄2岁 门诊号90051065 科室儿科", &known(), 0);
        assert!(!r.text.contains("孟丁"), "{}", r.text);
        assert!(r.text.contains("性别男"), "性别保留:{}", r.text);
        assert!(r.text.contains("年龄2岁"), "年龄保留:{}", r.text);
        assert!(r.text.contains("科室儿科"), "科室保留:{}", r.text);
        assert!(!r.text.contains("90051065"), "门诊号掩掉:{}", r.text);
    }

    #[test]
    fn anchors_mask_value_and_doctor_names() {
        let r = redact_text("北京协和医院检验报告\n姓名:张建国  性别:男  年龄:60岁 病案号:62198842\n审核者樊笋  检验者:王涛", &known(), 0);
        assert!(!r.text.contains("张建国") && !r.text.contains("62198842") && !r.text.contains("樊笋") && !r.text.contains("王涛"), "{}", r.text);
        assert!(!r.text.contains("北京协和医院"), "医院名掩成 [H1]:{}", r.text);
        assert!(r.text.contains("[H1]"), "{}", r.text);
        assert!(r.text.contains("年龄:60岁"), "{}", r.text);
    }

    #[test]
    fn patterns_catch_id_phone_long_digits_url() {
        let r = redact_text("条码 2023061512345 电话 010-69156114 手机13912345678 身份证 44010519850101123X 网址 www.pumch.cn 白细胞 5.6 4.0-10.0", &known(), 0);
        for leak in ["2023061512345", "69156114", "13912345678", "44010519850101123X", "www.pumch.cn"] {
            assert!(!r.text.contains(leak), "{leak} 漏了:{}", r.text);
        }
        assert!(r.text.contains("白细胞 5.6 4.0-10.0"), "检验值与区间不动:{}", r.text);
    }

    #[test]
    fn restore_puts_everything_back() {
        let src = "北京协和医院 姓名:张建国 采集时间:2024-03-05 门诊号:20230615-1046";
        let r = redact_text(src, &known(), 7);
        assert!(r.text.contains("2024-03-12"), "{}", r.text);
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }
}
```

- [ ] **Step 2: 跑,确认失败**

Run: `cargo test -p deid redact`
Expected: 编译错误

- [ ] **Step 3: 实现三层与组合**

`packages/deid/src/known.rs`:
```rust
//! K 层:档案主人的姓名/证件号/手机全文精确删(粘连形态也删——精确子串,与形态无关)。
use super::redact::RestoreMap;

pub struct KnownIdentity {
    pub name: String,
    pub id_number: Option<String>,
    pub phone: Option<String>,
}

/// 把每个已知值换成一个占位符并登记到 map。空串/单字姓名不处理(避免把常见字全删)。
pub fn apply(text: &str, known: &KnownIdentity, map: &mut RestoreMap) -> String {
    let mut out = text.to_string();
    let mut items: Vec<(&str, &str)> = Vec::new();
    if known.name.chars().count() >= 2 {
        items.push((known.name.as_str(), "P"));
    }
    if let Some(id) = known.id_number.as_deref().filter(|s| !s.is_empty()) {
        items.push((id, "N"));
    }
    if let Some(ph) = known.phone.as_deref().filter(|s| !s.is_empty()) {
        items.push((ph, "T"));
    }
    for (value, kind) in items {
        if out.contains(value) {
            let ph = map.placeholder(kind, value);
            out = out.replace(value, &ph);
        }
    }
    out
}
```

`packages/deid/src/anchors.rs`:
```rust
//! A 层:锚点后的值换占位符。词表 = parser::labs::PAGE_FURNITURE 的 22 个(那边是私有 const,
//! 且语义是「挡假化验行」,这边是「掩身份」,两份各自演进,不共享)+ 本 spec 清单补的。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

/// 锚点 → 占位符种类。人名类 P,号码类 N,时间类不掩(日期由 dates 偏移;时间戳无身份信息)。
pub const ANCHORS: &[(&str, &str)] = &[
    ("姓名", "P"), ("名字", "P"), ("患者", "P"), ("病人", "P"), ("联系人", "P"), ("监护人", "P"),
    ("检验者", "P"), ("审核者", "P"), ("送检医生", "P"), ("申请医生", "P"), ("报告医生", "P"),
    ("审核医生", "P"), ("主治医师", "P"), ("报告医师", "P"), ("医师", "P"), ("医生", "P"),
    ("门诊号", "N"), ("住院号", "N"), ("病案号", "N"), ("病历号", "N"), ("就诊卡号", "N"), ("就诊卡", "N"),
    ("床号", "N"), ("样本号", "N"), ("标本号", "N"), ("样本编号", "N"), ("条码号", "N"), ("条码", "N"),
    ("检验号", "N"), ("检查号", "N"), ("影像号", "N"), ("申请单号", "N"), ("医保卡号", "N"), ("医保号", "N"),
    ("社保号", "N"), ("身份证号", "N"), ("身份证", "N"), ("发票号", "N"), ("收费单号", "N"), ("流水号", "N"),
    ("设备编号", "N"), ("仪器编号", "N"), ("住址", "A"), ("地址", "A"), ("家庭住址", "A"), ("工作单位", "A"),
    ("籍贯", "A"), ("民族", "A"), ("职业", "A"), ("婚姻", "A"),
];

/// 锚点后:可选冒号/空白,然后取到下一个空白/分隔符或 12 个字符为止。
fn anchor_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        let alts: Vec<String> = ANCHORS.iter().map(|(a, _)| regex::escape(a)).collect();
        Regex::new(&format!(
            r"({})[:：]?\s*([^\s:：,，;；、|]{{1,12}})",
            alts.join("|")
        ))
        .expect("anchor re")
    })
}

/// 「XX市XX医院 / XX大学附属XX医院 / XX人民医院」整串掩成 [H]。
fn hospital_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[\u{4e00}-\u{9fa5}]{2,12}(?:医院|卫生院|诊所|医学中心|医疗中心)(?:[\u{4e00}-\u{9fa5}]{0,4}(?:分院|院区))?").expect("hospital re"))
}

fn kind_of(anchor: &str) -> &'static str {
    ANCHORS.iter().find(|(a, _)| *a == anchor).map(|(_, k)| *k).unwrap_or("N")
}

/// 年龄/性别是**保留项**:锚点表里没有它们,所以「姓名孟丁性别男」在 K 层删掉名字后,
/// 这里不会再把「性别男」当成锚点值吃掉。
pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let t = hospital_re().replace_all(text, |c: &regex::Captures| map.placeholder("H", &c[0])).into_owned();
    anchor_re()
        .replace_all(&t, |c: &regex::Captures| {
            let anchor = &c[1];
            let value = &c[2];
            // 值本身已经是占位符(K 层删过)→ 原样
            if value.starts_with('[') {
                return c[0].to_string();
            }
            let ph = map.placeholder(kind_of(anchor), value);
            c[0].replacen(value, &ph, 1)
        })
        .into_owned()
}
```

`packages/deid/src/patterns.rs`:
```rust
//! P 层:形状兜底。检验值/参考区间不会是 18 位、11 位或 6 位以上连续数字,所以误伤面小。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

fn res() -> &'static [(Regex, &'static str)] {
    static R: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    R.get_or_init(|| {
        vec![
            (Regex::new(r"\b\d{17}[\dXx]\b").expect("id18"), "N"),
            (Regex::new(r"(?:https?://|www\.)[^\s]+|[\w.+-]+@[\w-]+\.[\w.]+").expect("url/email"), "U"),
            (Regex::new(r"\b1[3-9]\d{9}\b").expect("mobile"), "T"),
            (Regex::new(r"\b0\d{2,3}-\d{7,8}\b").expect("landline"), "T"),
            // 6 位以上连续数字(条码/样本号/病历号);前后不能是小数点或 `-`/`~`(那是区间)
            (Regex::new(r"(?:^|[^\d.\-~])(\d{6,})(?:$|[^\d.\-~])").expect("long digits"), "N"),
        ]
    })
}

pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let mut out = text.to_string();
    for (re, kind) in res() {
        out = re
            .replace_all(&out, |c: &regex::Captures| {
                // long-digits 那条有捕获组 1;其余整段
                match c.get(1) {
                    Some(m) => c[0].replacen(m.as_str(), &map.placeholder(kind, m.as_str()), 1),
                    None => map.placeholder(kind, &c[0]),
                }
            })
            .into_owned();
    }
    out
}
```

`packages/deid/src/redact.rs`(测试模块上方):
```rust
//! 三层组合。顺序即优先级:K(已知值)→ A(锚点)→ P(模式)→ 日期偏移。
use crate::{anchors, dates, known, patterns};
use serde::{Deserialize, Serialize};

pub use known::KnownIdentity;

/// 占位符 ↔ 原文。**永不离开手机。**
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
pub struct RestoreMap {
    pub placeholders: Vec<(String, String)>,
    pub shift_days: i64,
}

impl RestoreMap {
    /// 同一原文只发一个占位符(同一医院名出现三次 → 三处同一个 [H1])。
    pub fn placeholder(&mut self, kind: &str, value: &str) -> String {
        if let Some((p, _)) = self.placeholders.iter().find(|(_, v)| v == value) {
            return p.clone();
        }
        let n = self.placeholders.iter().filter(|(p, _)| p.starts_with(&format!("[{kind}"))).count() + 1;
        let p = format!("[{kind}{n}]");
        self.placeholders.push((p.clone(), value.to_string()));
        p
    }
}

pub struct Redacted {
    pub text: String,
    pub map: RestoreMap,
}

pub fn redact_text(text: &str, known: &KnownIdentity, shift_days: i64) -> Redacted {
    let mut map = RestoreMap { placeholders: Vec::new(), shift_days };
    let t = known::apply(text, known, &mut map);
    let t = anchors::apply(&t, &mut map);
    let t = patterns::apply(&t, &mut map);
    let t = dates::shift_dates(&t, shift_days);
    Redacted { text: t, map }
}

/// 先减日期,再把占位符按登记顺序倒着换回(后登记的可能嵌在先登记的里)。
pub fn restore(text: &str, map: &RestoreMap) -> String {
    let mut out = dates::unshift_dates(text, map.shift_days);
    for (p, v) in map.placeholders.iter().rev() {
        out = out.replace(p, v);
    }
    out
}
```

`packages/deid/src/lib.rs` 加:
```rust
pub mod anchors;
pub mod known;
pub mod patterns;
pub mod redact;
pub use redact::{redact_text, restore, KnownIdentity, Redacted, RestoreMap};
```

- [ ] **Step 4: 跑,调到通过**

Run: `cargo test -p deid`
Expected: 全部 passed。`restore_puts_everything_back` 要求 `restore` 把 `2024-03-12`→`2024-03-05`、`[H1]`→`北京协和医院`、`[P1]`→`张建国`、`[N1]`→`20230615-1046` 全部还原且**逐字节相等**;若锚点正则把冒号吃进了值,调 `anchor_re` 的字符类而不是改测试。

- [ ] **Step 5: Commit**

```bash
git add packages/deid/src/lib.rs packages/deid/src/known.rs packages/deid/src/anchors.rs packages/deid/src/patterns.rs packages/deid/src/redact.rs
git commit -m "feat(deid): K/A/P 三层脱敏 + 占位符还原表

已知身份精确删(粘连形态也删)、锚点后值换占位符(医生名/号码/住址)、
医院名整串掩成 [H]、模式兜底(身份证/手机/长数字串/URL);年龄性别科室保留。"
```

---

### Task 3: 发送前闸 `gate::assert_clean`

**Files:**
- Create: `packages/deid/src/gate.rs`
- Modify: `packages/deid/src/lib.rs`

**Interfaces:**
- Produces: `pub fn assert_clean(payload: &str, known: &KnownIdentity) -> Result<(), DeidError>`——payload 含已知姓名(≥2 字)/证件号/手机任一子串 → `Err(DeidError::IdentityLeak(<哪一类>))`,**不回显值**。

- [ ] **Step 1: 写失败测试**

`packages/deid/src/gate.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::KnownIdentity;

    fn k() -> KnownIdentity {
        KnownIdentity { name: "张建国".into(), id_number: Some("110101199001011234".into()), phone: None }
    }

    #[test]
    fn clean_payload_passes() {
        assert!(assert_clean("白细胞 5.6 [P1] [N1]", &k()).is_ok());
    }

    #[test]
    fn leaked_name_is_refused_without_echoing_it() {
        let e = assert_clean("姓名:张建国", &k()).unwrap_err().to_string();
        assert!(e.contains("姓名"));
        assert!(!e.contains("张建国"), "错误信息不能回显身份:{e}");
    }

    #[test]
    fn leaked_id_is_refused() {
        assert!(assert_clean("证件 110101199001011234", &k()).is_err());
    }
}
```

- [ ] **Step 2: 跑,确认失败**

Run: `cargo test -p deid gate`
Expected: 编译错误

- [ ] **Step 3: 实现**

```rust
//! 发送前的硬闸:可测试的保证,不是尽力而为。命中即拒发,调用方退回本地正则路径。
use crate::{DeidError, KnownIdentity};

pub fn assert_clean(payload: &str, known: &KnownIdentity) -> Result<(), DeidError> {
    if known.name.chars().count() >= 2 && payload.contains(known.name.as_str()) {
        return Err(DeidError::IdentityLeak("姓名".into()));
    }
    if known.id_number.as_deref().filter(|s| !s.is_empty()).is_some_and(|id| payload.contains(id)) {
        return Err(DeidError::IdentityLeak("证件号".into()));
    }
    if known.phone.as_deref().filter(|s| !s.is_empty()).is_some_and(|p| payload.contains(p)) {
        return Err(DeidError::IdentityLeak("手机号".into()));
    }
    Ok(())
}
```

`lib.rs` 加 `pub mod gate; pub use gate::assert_clean;`

- [ ] **Step 4: 跑,确认通过**

Run: `cargo test -p deid gate`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add packages/deid/src/gate.rs packages/deid/src/lib.rs
git commit -m "feat(deid): 发送前闸——payload 含已知身份即拒发,错误不回显"
```

---

### Task 4: schema v1 类型 + `verify`

**Files:**
- Create: `packages/deid/src/verify.rs`
- Modify: `packages/deid/src/lib.rs`

**Interfaces:**
- Produces:
  ```rust
  #[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
  pub struct LabItem { pub name: String, pub value: String, pub unit: String, pub ref_low: String, pub ref_high: String, pub flag: String, #[serde(default)] pub unverified: bool }
  #[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
  pub struct MedItem { pub name: String, pub dose: String, pub freq: String, pub route: String }
  #[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
  pub struct DiagnosisItem { pub text: String, pub icd: String }
  #[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
  pub struct Extraction { pub doc_type: String, pub doc_date: String, pub labs: Vec<LabItem>, pub meds: Vec<MedItem>, pub diagnoses: Vec<DiagnosisItem>, pub impression: String, pub notes: String }
  #[derive(Clone, Copy, PartialEq, Debug)] pub enum Mode { Text, Image }
  pub struct Verified { pub extraction: Extraction, pub rejected: usize, pub unverified: usize }
  pub fn parse_extraction(llm_json: &str) -> Result<Extraction, DeidError>   // 容忍 ```json 围栏
  pub fn verify(e: Extraction, source_text: &str, mode: Mode) -> Verified
  ```
  文本档:lab 的 name/value/unit/ref_low/ref_high 每个非空字段必须是 `source_text` 逐字子串,否则整条丢弃,`rejected += 1`。图片档:数值字段 `,`→`.` 归一后比;比不上**不丢**,`unverified = true`,`unverified += 1`。meds/diagnoses 同规则按 name/text 字段。

- [ ] **Step 1: 写失败测试**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    const SRC: &str = "白细胞计数 WBC 5.6 10^9/L 4.0-10.0\n血红蛋白 HGB 13,5 g/L 115-150\n诊断:2型糖尿病 E11.9";

    fn e() -> Extraction {
        Extraction {
            labs: vec![
                LabItem { name: "白细胞计数".into(), value: "5.6".into(), unit: "10^9/L".into(), ref_low: "4.0".into(), ref_high: "10.0".into(), ..Default::default() },
                LabItem { name: "血红蛋白".into(), value: "13.5".into(), unit: "g/L".into(), ref_low: "115".into(), ref_high: "150".into(), ..Default::default() },
                LabItem { name: "血小板".into(), value: "250".into(), ..Default::default() },
            ],
            diagnoses: vec![DiagnosisItem { text: "2型糖尿病".into(), icd: "E11.9".into() }],
            ..Default::default()
        }
    }

    #[test]
    fn text_mode_drops_anything_not_verbatim() {
        let v = verify(e(), SRC, Mode::Text);
        // 13.5 原文是 13,5 → 文本档严格,丢;血小板不在原文,丢
        assert_eq!(v.extraction.labs.len(), 1);
        assert_eq!(v.rejected, 2);
        assert_eq!(v.unverified, 0);
        assert_eq!(v.extraction.diagnoses.len(), 1);
    }

    #[test]
    fn image_mode_keeps_but_flags() {
        let v = verify(e(), SRC, Mode::Image);
        assert_eq!(v.extraction.labs.len(), 3);
        assert!(!v.extraction.labs[0].unverified);
        assert!(!v.extraction.labs[1].unverified, "13,5 归一后等于 13.5");
        assert!(v.extraction.labs[2].unverified);
        assert_eq!(v.unverified, 1);
        assert_eq!(v.rejected, 0);
    }

    #[test]
    fn parse_tolerates_code_fence() {
        let j = "```json\n{\"doc_type\":\"lab\",\"labs\":[]}\n```";
        assert_eq!(parse_extraction(j).unwrap().doc_type, "lab");
    }
}
```

- [ ] **Step 2: 跑,确认失败**

Run: `cargo test -p deid verify`
Expected: 编译错误

- [ ] **Step 3: 实现**

```rust
//! schema v1(spec §3)+ 逐字校验(spec §4)。
use crate::DeidError;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct LabItem {
    #[serde(default)] pub name: String,
    #[serde(default)] pub value: String,
    #[serde(default)] pub unit: String,
    #[serde(default)] pub ref_low: String,
    #[serde(default)] pub ref_high: String,
    #[serde(default)] pub flag: String,
    #[serde(default)] pub unverified: bool,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct MedItem {
    #[serde(default)] pub name: String,
    #[serde(default)] pub dose: String,
    #[serde(default)] pub freq: String,
    #[serde(default)] pub route: String,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct DiagnosisItem {
    #[serde(default)] pub text: String,
    #[serde(default)] pub icd: String,
}
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Extraction {
    #[serde(default)] pub doc_type: String,
    #[serde(default)] pub doc_date: String,
    #[serde(default)] pub labs: Vec<LabItem>,
    #[serde(default)] pub meds: Vec<MedItem>,
    #[serde(default)] pub diagnoses: Vec<DiagnosisItem>,
    #[serde(default)] pub impression: String,
    #[serde(default)] pub notes: String,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode { Text, Image }

pub struct Verified { pub extraction: Extraction, pub rejected: usize, pub unverified: usize }

/// LLM 偶尔包 ```json 围栏;剥掉再解析。其它形状的错误如实返回。
pub fn parse_extraction(llm_json: &str) -> Result<Extraction, DeidError> {
    let s = llm_json.trim();
    let s = s.strip_prefix("```json").or_else(|| s.strip_prefix("```")).unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s).trim();
    Ok(serde_json::from_str(s)?)
}

fn norm_num(s: &str) -> String { s.replace(',', ".").split_whitespace().collect() }
fn norm_txt(s: &str) -> String { s.split_whitespace().collect() }

/// 文本档:逐字子串;图片档:数值 `,`→`.`、去空白后子串。空字段不查。
fn field_ok(value: &str, src: &str, src_norm: &str, mode: Mode, numeric: bool) -> bool {
    if value.is_empty() { return true; }
    match mode {
        Mode::Text => src.contains(value),
        Mode::Image => {
            let v = if numeric { norm_num(value) } else { norm_txt(value) };
            src_norm.contains(&v)
        }
    }
}

pub fn verify(mut e: Extraction, source_text: &str, mode: Mode) -> Verified {
    let src_norm = norm_num(source_text);
    let (mut rejected, mut unverified) = (0usize, 0usize);
    let mut keep = |ok: bool, flag: &mut bool| -> bool {
        match (mode, ok) {
            (_, true) => true,
            (Mode::Text, false) => { rejected += 1; false }
            (Mode::Image, false) => { *flag = true; unverified += 1; true }
        }
    };
    e.labs.retain_mut(|l| {
        let ok = field_ok(&l.name, source_text, &src_norm, mode, false)
            && field_ok(&l.value, source_text, &src_norm, mode, true)
            && field_ok(&l.unit, source_text, &src_norm, mode, false)
            && field_ok(&l.ref_low, source_text, &src_norm, mode, true)
            && field_ok(&l.ref_high, source_text, &src_norm, mode, true);
        keep(ok, &mut l.unverified)
    });
    let mut dummy = false;
    e.meds.retain(|m| keep(field_ok(&m.name, source_text, &src_norm, mode, false), &mut dummy));
    e.diagnoses.retain(|d| keep(field_ok(&d.text, source_text, &src_norm, mode, false), &mut dummy));
    Verified { extraction: e, rejected, unverified }
}
```
`lib.rs` 加 `pub mod verify; pub use verify::{parse_extraction, verify, DiagnosisItem, Extraction, LabItem, MedItem, Mode, Verified};`

注意:meds/diagnoses 在图片档下没有 `unverified` 字段可标,`dummy` 吃掉标记——它们**不进趋势**,只展示,本轮够用;`ponytail: meds/diagnoses 图片档下不标 unverified,进 profile 时补字段`。

- [ ] **Step 4: 跑,确认通过**

Run: `cargo test -p deid`
Expected: 全部 passed

- [ ] **Step 5: Commit**

```bash
git add packages/deid/src/verify.rs packages/deid/src/lib.rs
git commit -m "feat(deid): schema v1 类型 + 逐字校验(文本档丢弃计幻觉/图片档标 unverified)"
```

---

### Task 5: 清单 fixture + README

**Files:**
- Create: `packages/deid/README.md`, `packages/deid/tests/fixtures.rs`, `packages/deid/tests/fixtures/*.txt` 与 `*.expected.txt`

**Interfaces:**
- Consumes: `deid::redact_text`, `deid::KnownIdentity`。
- 约定:`fixtures/<类别>_<n>.txt` 第一行是 `# known: <姓名>|<证件号或->|<手机或->`,其余是样本;`.expected.txt` 是脱敏后**逐字节**期望(偏移 0 天)。

- [ ] **Step 1: 写 README 清单(初始版)**

`packages/deid/README.md`:
```markdown
# deid · 中国医疗单据可识别信息清单(初始版 2026-09-11)

对照 HIPAA Safe Harbor 18 项。检测手段:**K** 已知值 / **A** 锚点 / **P** 模式 / **R** 区域(图片页眉页脚涂黑)/ **D** DICOM 标签。
「语料」= 2026-09-11 对 27 份(12 份真实 PP-OCR 输出 + 张建国示例集)的统计。

| HIPAA | 中国单子形态 | 手段 | 语料 |
|---|---|---|---|
| 1 姓名 | 患者姓名;医生姓名(检验者/审核者/送检医生/申请医生/主治医师/报告医师);监护人/联系人 | K + A | 患者 19/27,医生 11/27 |
| 2 地理 | 医院全名、院区、科室*、病区、床号;住院首页的家庭住址、工作单位、籍贯 | A + P(医院名) | 医院 23/27 |
| 3 日期 | 出生日期、采集/送检/报告/审核/打印时间、入院/出院日期(**偏移不删**);年龄**保留** | dates | 年龄 23/27,时间 6~7/27 |
| 4 电话 | 医院总机、患者手机、联系人电话 | P | 未见(住院首页必有) |
| 5 传真 | 页眉 | P | 未见 |
| 6 邮箱 | 极少 | P | 未见 |
| 7 SSN | 身份证号 18 位 | K + P | 未见(住院首页必有) |
| 8 病历号 | 门诊号/住院号/病案号/病历号/就诊卡号 | A + P | 门诊号 11/27 |
| 9 医保号 | 医保卡号/社保号 | A | 未见 |
| 10 账号 | 发票号/收费单号/流水号 | A + P | 发票 7/27 |
| 11 证照号 | 医生执业证号(章上) | R | 未见 |
| 13 设备号 | 影像设备/仪器编号 | A | 未见 |
| 14 URL | 医院网址、微信公众号、查询链接 | P | 未见 |
| 17 人脸 | 皮肤科/眼科照片 | 不走图片档 | |
| 18 其他编码 | 样本号/标本号/条码号、检验号、检查号/影像号、申请单号;条形码/二维码本身 | A + P + R | 检查号 2/27 |
| 中国特有 | 民族/职业/婚姻(住院首页);公章;手写签名 | A + R | 未见 |
| DICOM | PatientName/ID/BirthDate、InstitutionName;像素烧录 | D + R | `packages/dicom` |

\* 科室**保留**(临床需要)。

## 已知盲区(对外话术不承诺 100%)
- 手写姓名 OCR 漏检、二维码里的病人 ID:靠图片档页眉页脚整带涂黑覆盖,文本档覆盖不到。
- 「未见」≠「没有」:语料几乎全是化验单;**住院病案首页、门诊病历、影像报告各须补真实样本**(见 tests/fixtures 缺口)。

## 怎么加一种形态
`tests/fixtures/<类别>_<n>.txt`(首行 `# known: 姓名|证件号或-|手机或-`)+ 同名 `.expected.txt`;跑 `cargo test -p deid --test fixtures`。
```

- [ ] **Step 2: 写 fixture 驱动测试**

`packages/deid/tests/fixtures.rs`:
```rust
//! 每对 fixture:脱敏后逐字节等于 .expected.txt(偏移 0 天),且已知身份在输出里不出现。
use deid::{assert_clean, redact_text, KnownIdentity};
use std::fs;
use std::path::Path;

fn parse_known(first_line: &str) -> KnownIdentity {
    let body = first_line.trim_start_matches("# known:").trim();
    let mut it = body.split('|').map(str::trim);
    let name = it.next().unwrap_or("").to_string();
    let opt = |s: Option<&str>| s.filter(|v| *v != "-" && !v.is_empty()).map(str::to_string);
    KnownIdentity { name, id_number: opt(it.next()), phone: opt(it.next()) }
}

#[test]
fn every_fixture_pair_redacts_to_expected() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let mut n = 0;
    for entry in fs::read_dir(&dir).expect("fixtures dir") {
        let p = entry.expect("entry").path();
        let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !name.ends_with(".txt") || name.ends_with(".expected.txt") {
            continue;
        }
        let src = fs::read_to_string(&p).expect("read fixture");
        let (first, rest) = src.split_once('\n').expect("first line is # known:");
        let known = parse_known(first);
        let expected = fs::read_to_string(p.with_extension("expected.txt")).expect("expected file");
        let r = redact_text(rest, &known, 0);
        assert_eq!(r.text, expected, "fixture {name}");
        assert_clean(&r.text, &known).unwrap_or_else(|e| panic!("{name}: {e}"));
        n += 1;
    }
    assert!(n >= 6, "至少 6 对 fixture,现在 {n}");
}
```

- [ ] **Step 3: 写 6 对 fixture(每类一对,真实形态)**

内容取自仓库已有真实 OCR 形态(`packages/parser/src/lib.rs:607-628` 的测试串、`labs.rs:2613` 的审核者行、`examples/demo-dataset/corpus/*.txt` 的张建国页眉)。每份先写 `.txt`,跑一遍 `redact_text` 把输出**人工逐字核对**后存成 `.expected.txt`——不是把输出直接当期望,是核对后再存。

| 文件 | 覆盖 |
|---|---|
| `lab_header_1.txt` | 1/2/3/8:`北京协和医院 姓名:张建国 性别:男 年龄:60岁 病案号:62198842 采集时间:2024-03-05` |
| `lab_glued_2.txt` | 1/8 粘连:`独墅湖科教创新区医院化验报告单 年龄2岁 样本类型血液 姓名孟丁 性别男 门诊号90051065 科室儿科` |
| `lab_footer_3.txt` | 1/18:`打印时间2016-08-2411:08 审核者樊笋 检验者:王涛 条码号 2023061512345` |
| `discharge_1.txt` | 3/7/9/中国特有(住院首页形态,自写但字段名真实):`住院号:HS-2024-08-2201 入院日期:2024-08-08 出院日期:2024-08-12 身份证:110101199001011234 医保卡号:A123456789 民族:汉 职业:教师 家庭住址:北京市朝阳区…` |
| `outpatient_1.txt` | 4/14:`电话 010-69156114 手机13912345678 网址 www.pumch.cn 微信公众号 pumch_official` |
| `imaging_1.txt` | 13/18:`检查号:CT20240305001 设备编号:SOMATOM-7742 影像号 IMG-99887` + 一段所见/印象(须原样保留) |

期望里检验行(`白细胞 5.6 10^9/L 4.0-10.0`)、年龄、性别、科室、影像所见**必须原样**。

- [ ] **Step 4: 跑,确认通过**

Run: `cargo test -p deid --test fixtures`
Expected: 1 passed(6 对全部相等)。不等的先看是脱敏漏/过杀还是期望写错,**期望只在人工核过原文后才改**。

- [ ] **Step 5: Commit**

```bash
git add packages/deid/README.md packages/deid/tests/fixtures.rs packages/deid/tests/fixtures/
git commit -m "test(deid): 中国单据可识别信息清单 + 6 对 fixture 逐字节钉住脱敏结果"
```

---

### Task 6: `ocr` 暴露检测框 + 按框涂黑

**Files:**
- Modify: `packages/ocr/src/lib.rs`(`recognize_engine_layout` 附近 ~L921;`LayoutLine` ~L949)

**Interfaces:**
- Produces:
  ```rust
  #[cfg(feature = "engine")]
  pub fn recognize_engine_lines(image_bytes: &[u8]) -> anyhow::Result<(Vec<LayoutLine>, f32)>  // 框 + 平均置信度;文本仍用 rebuild_layout_text(&lines)
  #[derive(Debug, Clone, Copy, PartialEq)] pub struct PaintRect { pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
  pub fn redact_image(image_bytes: &[u8], rects: &[PaintRect]) -> anyhow::Result<Vec<u8>>  // 不依赖 engine;输出 JPEG q85
  ```
  `LayoutLine` 已是 `pub`(text/left/top/right/height)。

- [ ] **Step 1: 写失败测试(`redact_image` 纯图像,不需要 engine)**

`packages/ocr/src/lib.rs` 的 `#[cfg(test)] mod tests` 里加:
```rust
#[test]
fn redact_image_paints_rects_black() {
    use image::{ImageBuffer, Rgb};
    let img = ImageBuffer::from_pixel(100, 60, Rgb([255u8, 255, 255]));
    let mut png = Vec::new();
    image::DynamicImage::ImageRgb8(img)
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    let out = redact_image(&png, &[PaintRect { left: 10.0, top: 10.0, right: 50.0, bottom: 30.0 }]).unwrap();
    let back = image::load_from_memory(&out).unwrap().to_rgb8();
    assert!(back.get_pixel(20, 20)[0] < 30, "框内应为黑");
    assert!(back.get_pixel(80, 50)[0] > 220, "框外应为白");
}
```

- [ ] **Step 2: 跑,确认失败**

Run: `cargo test -p ocr --no-default-features redact_image`
Expected: 编译错误

- [ ] **Step 3: 实现两个函数**

在 `recognize_engine_layout` 之上:
```rust
/// 与 [`recognize_engine_layout`] 同一条识别路径,但把检测框交出去(脱敏要按框涂黑)。
/// 文本由调用方 `rebuild_layout_text(&lines)` 得到,与 layout 版逐字节相同。
#[cfg(feature = "engine")]
pub fn recognize_engine_lines(image_bytes: &[u8]) -> Result<(Vec<LayoutLine>, f32)> {
    let mut confidences = Vec::new();
    let mut out = Vec::new();
    for line in predict_lines(image_bytes)? {
        if let Some(c) = line.confidence {
            confidences.push(c);
        }
        out.push(LayoutLine { text: line.text, left: line.left, top: line.top, right: line.right, height: line.bottom - line.top });
    }
    Ok((out, mean_confidence(&confidences)))
}

/// 要涂黑的矩形(整图像素坐标,与 [`LayoutLine`] 同一坐标系)。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PaintRect { pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }

/// 按框涂黑,输出 JPEG q85(送云端的那份;原件不动)。不依赖 `engine`。
pub fn redact_image(image_bytes: &[u8], rects: &[PaintRect]) -> Result<Vec<u8>> {
    use imageproc::drawing::draw_filled_rect_mut;
    use imageproc::rect::Rect;
    let mut img = image::load_from_memory(image_bytes).context("redact_image: decode")?.to_rgb8();
    let (w, h) = (img.width() as f32, img.height() as f32);
    for r in rects {
        let l = r.left.max(0.0).min(w) as i32;
        let t = r.top.max(0.0).min(h) as i32;
        let rw = (r.right.min(w) - l as f32).max(1.0) as u32;
        let rh = (r.bottom.min(h) - t as f32).max(1.0) as u32;
        draw_filled_rect_mut(&mut img, Rect::at(l, t).of_size(rw, rh), image::Rgb([0u8, 0, 0]));
    }
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85)
        .encode_image(&image::DynamicImage::ImageRgb8(img))
        .context("redact_image: encode jpeg")?;
    Ok(out)
}
```
`recognize_engine_layout` 改为调 `recognize_engine_lines` 再 `rebuild_layout_text`(去重)。

- [ ] **Step 4: 跑**

Run: `cargo test -p ocr --no-default-features redact_image && cargo test -p ocr`
Expected: 新测试通过;既有 `rebuild_layout_text_*` 测试全绿(layout 函数行为未变)。

- [ ] **Step 5: Commit**

```bash
git add packages/ocr/src/lib.rs
git commit -m "feat(ocr): 暴露检测框 recognize_engine_lines + 按框涂黑 redact_image(脱敏图片档用)"
```

---

### Task 7: `deid::redact_boxes`(哪些框要涂 + 页眉页脚带)

**Files:**
- Modify: `packages/deid/src/redact.rs`, `packages/deid/src/lib.rs`

**Interfaces:**
- Produces:
  ```rust
  pub struct Box { pub text: String, pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
  pub struct Rect { pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
  pub fn redact_boxes(boxes: &[Box], known: &KnownIdentity, page_w: f32, page_h: f32) -> Vec<Rect>
  ```
  规则(spec §1 图片档):框文本经 `redact_text(…,0)` 后**发生了变化**(命中 K/A/P)→ 该框整框涂;**页眉带** = 第一条「像化验行」的框之上整宽涂(像化验行 = 含数字且含 `-`/`~`/单位 `/L` `%` `mmol` `g/L` 之一);**页脚带** = 第一个含 `检验者|审核者|打印时间|报告医生` 的框及其以下整宽涂。锚点/日期变化不算(日期偏移不涂框,时间戳不涂)。

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn redact_boxes_paints_hits_and_header_footer_bands() {
    let k = KnownIdentity { name: "张建国".into(), id_number: None, phone: None };
    let b = |t: &str, top: f32| Box { text: t.into(), left: 10.0, top, right: 300.0, bottom: top + 20.0 };
    let boxes = vec![
        b("北京协和医院检验报告", 0.0),
        b("姓名:张建国 性别:男 年龄:60岁", 30.0),
        b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
        b("血红蛋白 HGB 135 g/L 115-150", 130.0),
        b("审核者:樊笋 检验者:王涛", 400.0),
    ];
    let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
    // 页眉带:0..100 整宽;页脚带:400..500 整宽;命中框各一
    assert!(rects.iter().any(|r| r.top == 0.0 && r.bottom >= 100.0 && r.left == 0.0 && r.right == 400.0), "{rects:?}");
    assert!(rects.iter().any(|r| r.top <= 400.0 && r.bottom == 500.0 && r.left == 0.0), "{rects:?}");
    // 化验行不涂
    assert!(!rects.iter().any(|r| (r.top - 100.0).abs() < 1.0 && r.right == 300.0), "{rects:?}");
}
```

- [ ] **Step 2: 跑,确认失败** — `cargo test -p deid redact_boxes` → 编译错误

- [ ] **Step 3: 实现**

```rust
pub struct Box { pub text: String, pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect { pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }

fn looks_like_lab_row(t: &str) -> bool {
    let has_digit = t.chars().any(|c| c.is_ascii_digit());
    has_digit && (t.contains('-') || t.contains('~') || ["/L", "%", "mmol", "g/L", "umol", "μmol", "U/L"].iter().any(|u| t.contains(u)))
}
fn looks_like_footer(t: &str) -> bool {
    ["检验者", "审核者", "打印时间", "报告医生", "报告医师", "审核医生"].iter().any(|a| t.contains(a))
}

pub fn redact_boxes(boxes: &[Box], known: &KnownIdentity, page_w: f32, page_h: f32) -> Vec<Rect> {
    let mut out = Vec::new();
    for b in boxes {
        let r = redact_text(&b.text, known, 0);
        if r.text != b.text {
            out.push(Rect { left: b.left, top: b.top, right: b.right, bottom: b.bottom });
        }
    }
    if let Some(first) = boxes.iter().filter(|b| looks_like_lab_row(&b.text)).map(|b| b.top).reduce(f32::min) {
        out.push(Rect { left: 0.0, top: 0.0, right: page_w, bottom: first });
    }
    if let Some(foot) = boxes.iter().filter(|b| looks_like_footer(&b.text)).map(|b| b.top).reduce(f32::min) {
        out.push(Rect { left: 0.0, top: foot, right: page_w, bottom: page_h });
    }
    out
}
```
`lib.rs` 再导出 `Box, Rect, redact_boxes`。

- [ ] **Step 4: 跑** — `cargo test -p deid` → 全绿

- [ ] **Step 5: Commit**

```bash
git add packages/deid/src/redact.rs packages/deid/src/lib.rs
git commit -m "feat(deid): redact_boxes——命中框 + 页眉页脚整带涂黑(图片档)"
```

---

### Task 8: 评测第 ④ 臂 `medrep_llm` + 幻觉率 + `MEDREP_ROOT`

**Files:**
- Create: `packages/ocr/examples/medrep_llm.rs`
- Modify: `packages/ocr/Cargo.toml`(dev-deps + example 声明), `packages/ocr/examples/medrep.rs`(`ROOT`→环境变量;score 加幻觉率), `packages/ocr/examples/medrep_make_gt.py`(`D`→环境变量)

**Interfaces:**
- Consumes: `deid::{redact_text, redact_boxes, assert_clean, parse_extraction, verify, Mode, KnownIdentity, Box}`;`ocr::{recognize_engine_lines, rebuild_layout_text, redact_image, PaintRect}`。
- Produces:目录 `<MEDREP_ROOT>/<out>/arm4_llm/deepseek-<text|image>/{doc}.txt`(verify 后的 labs 渲染为 `name value unit low-high` 行,供 `score()` 沿用 `parser::extract_labs`)+ `{doc}.halluc.json` `{"total":N,"rejected":R,"unverified":U}`;`score()` 对每个 ④ 臂多打一行 `幻觉率 R/N`。
- 跑法:
  ```
  export MEDREP_ROOT=<下载目录>  DEEPSEEK_API_KEY=…
  cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode text  [--limit N] [--out out]
  cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode image [--limit N] [--out out]
  cargo run --release -p ocr --example medrep --features engine,testing -- --score --out out
  ```

- [ ] **Step 1: 数据重新下载(原 scratchpad 已清)**

```bash
pip install -U huggingface_hub
export MEDREP_ROOT=/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/<session>/scratchpad/datasets/medrepbench
hf download MedRepBench/MedRepBench --repo-type dataset --local-dir "$MEDREP_ROOT"
find "$MEDREP_ROOT/images" -size 0 | wc -l   # 预期 133(上游 LFS 空对象,不是下载失败)
python3 packages/ocr/examples/medrep_make_gt.py   # 生成 $MEDREP_ROOT/gt.tsv
```
数据 CC BY-NC 4.0,仅评测,不进仓库、不进 App。

- [ ] **Step 2: `ROOT` 改环境变量(两处)**

`medrep.rs`:把 `const ROOT: &str = "…"` 改为
```rust
fn root() -> String {
    std::env::var("MEDREP_ROOT").expect("设置 MEDREP_ROOT=<medrepbench 目录>(见 examples 头注释)")
}
```
并把所有 `ROOT` 用法改为 `root()`(`out_root`、`load_gt`、`produce` 里 images 路径)。`medrep_make_gt.py` 的 `D = "…"` 改为 `D = os.environ["MEDREP_ROOT"]`(加 `import os`)。

- [ ] **Step 3: Cargo 声明**

`packages/ocr/Cargo.toml` `[dev-dependencies]` 加:
```toml
deid = { path = "../deid" }
# medrep_llm 直调 DeepSeek(评测期不经代理)。3.3.0 已在 Cargo.lock(ort 传递依赖),不新增 crate。
ureq = { version = "3.3", features = ["json"] }
base64 = "0.23"
```
`[[example]]` 加:
```toml
[[example]]
name = "medrep_llm"
required-features = ["engine", "testing"]
```

- [ ] **Step 4: 写 `medrep_llm.rs`**

```rust
// 第 ④ 臂:本地 OCR → deid 脱敏 → DeepSeek → verify → 渲染成 score() 能读的行。
// 产出目录 arm4_llm/deepseek-<mode>/,与 medrep.rs 的「第 ④ 列按模型分子目录」约定一致。
use anyhow::{Context, Result};
use base64::Engine;
use deid::{assert_clean, parse_extraction, redact_boxes, redact_text, verify, Box as DBox, KnownIdentity, Mode};
use ocr::{recognize_engine_lines, rebuild_layout_text, redact_image, PaintRect};
use std::path::PathBuf;

const SYSTEM: &str = "你是医疗单据结构化抽取器。只输出一个 JSON 对象,不要解释、不要 markdown 围栏。\
所有字符串必须是单据上的原文逐字,缺失留空字符串,不许推断或换算。schema:\
{\"doc_type\":\"lab|discharge|outpatient|imaging|prescription|other\",\"doc_date\":\"YYYY-MM-DD\",\
\"labs\":[{\"name\":\"\",\"value\":\"\",\"unit\":\"\",\"ref_low\":\"\",\"ref_high\":\"\",\"flag\":\"H|L|\"}],\
\"meds\":[{\"name\":\"\",\"dose\":\"\",\"freq\":\"\",\"route\":\"\"}],\
\"diagnoses\":[{\"text\":\"\",\"icd\":\"\"}],\"impression\":\"\",\"notes\":\"\"}";

fn root() -> String { std::env::var("MEDREP_ROOT").expect("MEDREP_ROOT") }

fn call_deepseek(model: &str, user_content: serde_json::Value) -> Result<String> {
    let key = std::env::var("DEEPSEEK_API_KEY").context("DEEPSEEK_API_KEY 未设置")?;
    let body = serde_json::json!({
        "model": model,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user_content}
        ]
    });
    let mut resp = ureq::post("https://api.deepseek.com/chat/completions")
        .header("Authorization", &format!("Bearer {key}"))
        .send_json(&body)
        .context("deepseek http")?;
    let v: serde_json::Value = resp.body_mut().read_json().context("deepseek json")?;
    Ok(v["choices"][0]["message"]["content"].as_str().unwrap_or("").to_string())
}

/// verify 后的 labs → `name value unit low-high` 行(score() 用 parser::extract_labs 读)。
fn render_rows(e: &deid::Extraction) -> String {
    e.labs.iter().map(|l| {
        let range = match (l.ref_low.is_empty(), l.ref_high.is_empty()) {
            (false, false) => format!("{}-{}", l.ref_low, l.ref_high),
            (false, true) => format!(">{}", l.ref_low),
            (true, false) => format!("<{}", l.ref_high),
            _ => String::new(),
        };
        format!("{} {} {} {}", l.name, l.value, l.unit, range).trim().to_string()
    }).collect::<Vec<_>>().join("\n")
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let arg = |k: &str| args.iter().position(|a| a == k).and_then(|i| args.get(i + 1).cloned());
    let mode = match arg("--mode").as_deref() { Some("image") => Mode::Image, _ => Mode::Text };
    let limit: Option<usize> = arg("--limit").and_then(|s| s.parse().ok());
    let out = arg("--out").unwrap_or_else(|| "out".into());
    let model = if mode == Mode::Image { "deepseek-v4-flash-vision-exp" } else { "deepseek-v4-flash" };
    let dir = PathBuf::from(root()).join(&out).join("arm4_llm").join(format!("deepseek-{}", if mode == Mode::Image { "image" } else { "text" }));
    std::fs::create_dir_all(&dir)?;

    let gt = std::fs::read_to_string(format!("{}/gt.tsv", root()))?;
    let mut docs: Vec<String> = gt.lines().filter_map(|l| l.split('\t').next()).map(str::to_string).collect();
    docs.dedup();
    if let Some(n) = limit { docs.truncate(n); }
    // MedRepBench 已去标识,没有真名可删;K 层用一个不会出现的占位名,只验 A/P 层。
    let known = KnownIdentity { name: "＿评测占位＿".into(), id_number: None, phone: None };

    let (mut total, mut rejected, mut unverified, mut failed) = (0usize, 0usize, 0usize, 0usize);
    for doc in &docs {
        let img_path = PathBuf::from(root()).join("images").join(doc);
        let Ok(bytes) = std::fs::read(&img_path) else { continue };
        if bytes.is_empty() { continue; } // 上游 0 字节
        if dir.join(format!("{doc}.txt")).exists() { continue; } // 可续跑
        let (lines, _conf) = match recognize_engine_lines(&bytes) { Ok(x) => x, Err(_) => { failed += 1; continue; } };
        let text = rebuild_layout_text(&lines);
        let red = redact_text(&text, &known, 0);
        if assert_clean(&red.text, &known).is_err() { failed += 1; continue; }
        let content = match mode {
            Mode::Text => serde_json::json!(red.text),
            Mode::Image => {
                let (w, h) = image::load_from_memory(&bytes).map(|i| (i.width() as f32, i.height() as f32)).unwrap_or((0.0, 0.0));
                let boxes: Vec<DBox> = lines.iter().map(|l| DBox { text: l.text.clone(), left: l.left, top: l.top, right: l.right, bottom: l.top + l.height }).collect();
                let rects: Vec<PaintRect> = redact_boxes(&boxes, &known, w, h).into_iter().map(|r| PaintRect { left: r.left, top: r.top, right: r.right, bottom: r.bottom }).collect();
                let jpg = redact_image(&bytes, &rects)?;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&jpg);
                serde_json::json!([
                    {"type": "text", "text": "请抽取这张单据。"},
                    {"type": "image_url", "image_url": {"url": format!("data:image/jpeg;base64,{b64}")}}
                ])
            }
        };
        let raw = match call_deepseek(model, content) { Ok(r) => r, Err(e) => { eprintln!("{doc}: {e:#}"); failed += 1; continue; } };
        let parsed = match parse_extraction(&raw) { Ok(p) => p, Err(_) => { failed += 1; std::fs::write(dir.join(format!("{doc}.txt")), "")?; continue; } };
        let n = parsed.labs.len();
        let v = verify(parsed, &red.text, mode);
        total += n; rejected += v.rejected; unverified += v.unverified;
        std::fs::write(dir.join(format!("{doc}.txt")), render_rows(&v.extraction))?;
        std::fs::write(dir.join(format!("{doc}.halluc.json")), serde_json::json!({"total": n, "rejected": v.rejected, "unverified": v.unverified}).to_string())?;
        eprintln!("{doc}: labs {n}, 丢 {}, 待核 {}", v.rejected, v.unverified);
    }
    eprintln!("总计 labs {total},幻觉(丢弃){rejected},待核 {unverified},整份失败 {failed}");
    Ok(())
}
```

- [ ] **Step 5: `score()` 加幻觉率行**

`medrep.rs` `score()` 打印各臂结果的循环里(L~494 处 `for (n, _) in &arms`),在表格之后追加:
```rust
    for (n, dir) in &arms {
        if !n.starts_with("④") { continue; }
        let (mut t, mut r, mut u) = (0u64, 0u64, 0u64);
        for e in std::fs::read_dir(dir)?.flatten() {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) != Some("json") { continue; }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&std::fs::read_to_string(&p)?) {
                t += v["total"].as_u64().unwrap_or(0);
                r += v["rejected"].as_u64().unwrap_or(0);
                u += v["unverified"].as_u64().unwrap_or(0);
            }
        }
        println!("{n} 幻觉率(逐字校验不过被丢弃)= {r}/{t} = {:.1}%;待核 {u}", if t > 0 { r as f64 * 100.0 / t as f64 } else { 0.0 });
    }
```
(`serde_json` 已是 `ocr` 的传递依赖;若编译说不是直接依赖,在 dev-deps 加 `serde_json.workspace = true`。)

- [ ] **Step 6: 编译两个 example**

Run: `cargo build --release -p ocr --examples --features engine,testing`
Expected: 通过

- [ ] **Step 7: Commit**

```bash
git add packages/ocr/Cargo.toml packages/ocr/examples/medrep_llm.rs packages/ocr/examples/medrep.rs packages/ocr/examples/medrep_make_gt.py
git commit -m "eval(ocr): 第 ④ 臂 medrep_llm——脱敏后直调 DeepSeek,逐字校验,幻觉率进 score

MEDREP_ROOT 改环境变量(原 scratchpad 已清)。"
```

---

### Task 9: 跑评测,写 log,过门(**产品接入的前置条件**)

**Files:**
- Create: `docs/log/2026-09-XX-deepseek-vs-regex-medrep.md`(XX = 实跑日期)

- [ ] **Step 1: 先小样本验通**

```bash
cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode text --limit 5 --out out_llm
cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode image --limit 5 --out out_llm
```
Expected: 每份打印 `labs N, 丢 R, 待核 U`;图片档若 5 份里有 ≥3 份 labs 为 0 或整份失败 → 384 token/图分辨率不够,先在 `medrep_llm.rs` 里把图按 `looks_like_lab_row` 的框纵向切成 ≤3 块分别送再合并(每块一次调用,labs 合并去重),再跑。

- [ ] **Step 2: 全量 + 基线对照**

```bash
cargo run --release -p ocr --example medrep --features engine,testing -- --produce --models <结构模型目录> --out out_llm
cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode text --out out_llm
cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode image --out out_llm
cargo run --release -p ocr --example medrep --features engine,testing -- --score --out out_llm | tee /tmp/medrep_llm_score.txt
```
`score()` 只统计**所有臂都产出**的文档,分母对齐。

- [ ] **Step 3: 写 log(精炼,数字 + 结论 + 决定)**

`docs/log/2026-09-XX-deepseek-vs-regex-medrep.md` 结构:任务一句话;表格(② 几何重建 / ④ text / ④ image × 项目召回 / 值-名配对 / 参考区间归属 / 错配率 / 幻觉率 / 待核 / 整份失败 / 每份耗时 / 每份 token 与元);结论:哪一档做默认;门是否过(三项全部 > 58.7 / 49.7 / 24.3);未过则**停在这里**,把差距与下一步写清,不做 Task 10+。

- [ ] **Step 4: Commit**

```bash
git add docs/log/2026-09-XX-deepseek-vs-regex-medrep.md
git commit -m "docs(log): DeepSeek 文本档/图片档 vs 正则,MedRepBench 683 份实测"
```

---

### Task 10: `core-model`:`Event::ExtractionAdded` + `extraction` 表 + 投影 + 查询

**Files:**
- Modify: `packages/core-model/src/event.rs`(enum ~L31–99), `schema.rs`(`migrate` ~L80), `materialize.rs`(`rebuild_from_log` ~L138;`apply_event` ~L427;`DocumentDeleted` 分支 ~L690;审计 no-op 匹配 ~L710), `query.rs`(`ocr_text` ~L616 旁), `types.rs`(`add_ocr` ~L282 旁), `audit.rs`(~L101 的噪声事件列表)

**Interfaces:**
- Produces:
  ```rust
  Event::ExtractionAdded { document_ref: DocRef, backend: String, model_version: String, mode: String, schema: i32, result_hash: String, created_at: String }
  pub struct NewExtraction { pub document_id: i64, pub backend: String, pub model_version: String, pub mode: String, pub result_json: String }
  impl Vault { pub fn add_extraction(&self, e: NewExtraction) -> Result<(), MedmeError>; pub fn extraction_json(&self, document_id: i64) -> Result<Option<String>, MedmeError> }
  ```
  表:`extraction(document_id UNIQUE, backend, model_version, mode, schema, result_json, created_at)`;同文档后来的事件**覆盖**(重跑模型 = 新事件)。`user_version` 5→6。

- [ ] **Step 1: 写失败测试**

`packages/core-model/src/materialize.rs` 的 tests 里加(与 L722 `write_appends_event_and_materializes` 同款开箱方式):
```rust
#[test]
fn extraction_added_materializes_and_latest_wins_and_rebuilds() {
    let dir = tempfile::tempdir().unwrap();
    let v = Vault::open(dir.path()).unwrap();
    let imp = v.import("a.jpg", "image/jpeg", b"jpgbytes").unwrap();
    let doc = v.add_document(NewDocument { source_file_id: imp.source_file.id, doc_type: DocType::LabReport, doc_date: None, doc_date_end: None, title: None, language: None, page_count: 1 }).unwrap();
    v.add_extraction(NewExtraction { document_id: doc.id, backend: "deepseek".into(), model_version: "v4-flash".into(), mode: "text".into(), result_json: r#"{"labs":[]}"#.into() }).unwrap();
    v.add_extraction(NewExtraction { document_id: doc.id, backend: "deepseek".into(), model_version: "v4-flash".into(), mode: "image".into(), result_json: r#"{"labs":[{"name":"WBC"}]}"#.into() }).unwrap();
    assert_eq!(v.extraction_json(doc.id).unwrap().as_deref(), Some(r#"{"labs":[{"name":"WBC"}]}"#));
    v.rebuild_from_log().unwrap();
    assert_eq!(v.extraction_json(doc.id).unwrap().as_deref(), Some(r#"{"labs":[{"name":"WBC"}]}"#), "重放后仍是最后一条");
    v.delete_document(doc.id).unwrap();
    assert!(v.extraction_json(doc.id).unwrap().is_none(), "删文档连抽取一起删");
}
```

- [ ] **Step 2: 跑,确认失败** — `cargo test -p core-model extraction_added` → 编译错误

- [ ] **Step 3: 实现**

`event.rs` enum 里 `OcrAdded` 之后加:
```rust
    /// 云 LLM 结构化抽取结果(spec 2026-09-11 子项目 A §5)。结果 JSON 存 CAS,
    /// 事件只引用哈希——与 `OcrAdded` 同构。同一文档后来的事件覆盖先前的
    /// (重跑模型 = 再 append 一条);原件永远不动。
    ExtractionAdded {
        document_ref: DocRef,
        backend: String,
        model_version: String,
        mode: String,
        schema: i32,
        result_hash: String,
        created_at: String,
    },
```

`schema.rs` `migrate` 末尾加:
```rust
    if v < 6 {
        conn.execute_batch(
            "BEGIN;\n\
             CREATE TABLE extraction (\
               id INTEGER PRIMARY KEY, \
               document_id INTEGER NOT NULL UNIQUE REFERENCES document(id) ON DELETE CASCADE, \
               backend TEXT NOT NULL, model_version TEXT NOT NULL, mode TEXT NOT NULL, \
               schema INTEGER NOT NULL, result_json TEXT NOT NULL, created_at TEXT NOT NULL);\n\
             PRAGMA user_version = 6;\n\
             COMMIT;",
        )?;
    }
```
同文件测试里 `assert_eq!(v.user_version().unwrap(), 5)` 改 6。

`materialize.rs`:
- `rebuild_from_log` 的 DELETE 列表加 `tx.execute("DELETE FROM extraction", [])?;`(放 `ocr_result` 之后)。
- `apply_event` 加分支(仿 `OcrAdded`:suppressed 检查 → 找 document_id(没有则 `Deferred`)→ `cas::is_object_hash` 校验 → `vault.read_object` 三态 → UTF-8 → 写表):
```rust
        Event::ExtractionAdded { document_ref, backend, model_version, mode, schema, result_hash, created_at } => {
            if suppressed.contains(&(entry.device_id.clone(), entry.seq)) {
                return Ok(ApplyOutcome::Applied);
            }
            let document_id: i64 = match tx
                .query_row(
                    "SELECT d.id FROM document d JOIN source_file sf ON d.source_file_id = sf.id WHERE sf.content_hash = ?1",
                    [&document_ref.source_file_hash],
                    |r| r.get(0),
                )
                .optional()?
            {
                Some(id) => id,
                None => return Ok(ApplyOutcome::Deferred),
            };
            if !cas::is_object_hash(result_hash) {
                eprintln!("[materialize] skip ExtractionAdded: malformed result_hash");
                return Ok(ApplyOutcome::Applied);
            }
            let bytes = match vault.read_object(result_hash) {
                Ok(b) => b,
                Err(MedmeError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => return Ok(ApplyOutcome::Deferred),
                Err(MedmeError::Other(msg)) => { eprintln!("[materialize] skip ExtractionAdded: {msg}"); return Ok(ApplyOutcome::Applied); }
                Err(e) => return Err(e),
            };
            let Ok(result_json) = String::from_utf8(bytes) else {
                eprintln!("[materialize] skip ExtractionAdded: not UTF-8");
                return Ok(ApplyOutcome::Applied);
            };
            tx.execute(
                "INSERT INTO extraction (document_id, backend, model_version, mode, schema, result_json, created_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7)
                 ON CONFLICT(document_id) DO UPDATE SET backend=excluded.backend, model_version=excluded.model_version,
                 mode=excluded.mode, schema=excluded.schema, result_json=excluded.result_json, created_at=excluded.created_at",
                rusqlite::params![document_id, backend, model_version, mode, schema, result_json, created_at],
            )?;
        }
```
- `DocumentDeleted` 分支加 `tx.execute("DELETE FROM extraction WHERE document_id = ?1", [id])?;`。
- L~412 处按 `document_ref` 判 liveness 的 `match`(`Event::OcrAdded { document_ref, .. }`)加 `| Event::ExtractionAdded { document_ref, .. }`。

`audit.rs` L~101 噪声列表加 `| Event::ExtractionAdded { .. }`。

`types.rs`:
```rust
#[derive(Debug, Clone, PartialEq)]
pub struct NewExtraction {
    pub document_id: i64,
    pub backend: String,
    pub model_version: String,
    pub mode: String,
    pub result_json: String,
}

impl Vault {
    pub fn add_extraction(&self, e: NewExtraction) -> Result<(), MedmeError> {
        let doc = self.document_by_id(e.document_id)?
            .ok_or_else(|| MedmeError::Other(format!("document {} not found", e.document_id)))?;
        let sf = self.source_file_by_id(doc.source_file_id)?
            .ok_or_else(|| MedmeError::Other(format!("source_file {} not found", doc.source_file_id)))?;
        let (result_hash, _rel, _written) = self.store_object(e.result_json.as_bytes())?;
        self.append_event(crate::event::Event::ExtractionAdded {
            document_ref: crate::event::DocRef { source_file_hash: sf.content_hash },
            backend: e.backend,
            model_version: e.model_version,
            mode: e.mode,
            schema: 1,
            result_hash,
            created_at: Self::now_rfc3339(),
        })?;
        self.materialize()
    }
}
```
`query.rs`(`ocr_text` 旁):
```rust
    /// 文档的云抽取结果(schema v1 JSON);没跑过/被拒发/离线为 None → 调用方退回正则。
    pub fn extraction_json(&self, document_id: i64) -> Result<Option<String>, MedmeError> {
        Ok(self
            .conn()
            .query_row("SELECT result_json FROM extraction WHERE document_id = ?1", [document_id], |r| r.get::<_, String>(0))
            .optional()?)
    }
```
`lib.rs` 再导出 `NewExtraction`(与 `NewOcr` 同处)。

- [ ] **Step 4: 跑** — `cargo test -p core-model` → 全绿(含 schema 版本测试、审计噪声测试)

- [ ] **Step 5: Commit**

```bash
git add packages/core-model/src/event.rs packages/core-model/src/schema.rs packages/core-model/src/materialize.rs packages/core-model/src/query.rs packages/core-model/src/types.rs packages/core-model/src/audit.rs packages/core-model/src/lib.rs
git commit -m "feat(core-model): Event::ExtractionAdded + extraction 派生表(v6),同文档后者覆盖

云抽取结果落盘:JSON 进 CAS,事件引用哈希,与 OcrAdded 同构;重跑 = 再 append。"
```

---

### Task 11: `parser`:`SourceDoc.extraction_json`,有则用抽取结果代替 `extract_labs`

**Files:**
- Create: `packages/parser/src/extraction.rs`
- Modify: `packages/parser/src/aggregate.rs`(`SourceDoc` L68–80;labs 分支 L684–697), `packages/parser/src/lib.rs`(`pub mod extraction;` + 再导出), `packages/parser/Cargo.toml`(依赖 `deid`)
- 所有构造 `SourceDoc { … }` 的地方加 `extraction_json: None`(本 crate 内 tests/`handoff.rs` 等;跨 crate 的在 Task 12/13 处理)

**Interfaces:**
- Produces:`pub extraction_json: Option<&'a str>` on `SourceDoc`;`pub fn extraction::labs_from_json(json: &str) -> Vec<LabObservation>`(解析 `deid::Extraction`,每条 lab:数值可解析为 f64 才收;`terminology::resolve(name, unit)` 取 key/canonical/loinc;`ref_low/ref_high` 解析 f64;flag 优先 LLM 给的 H/L,否则按值 vs 区间;`unverified` → `confidence` 0.5)。

- [ ] **Step 1: 写失败测试**

`packages/parser/src/extraction.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labs_from_json_resolves_and_flags() {
        let j = r#"{"labs":[
          {"name":"白细胞计数","value":"11.8","unit":"10^9/L","ref_low":"4.0","ref_high":"10.0","flag":""},
          {"name":"血红蛋白","value":"13,5","unit":"g/L","ref_low":"115","ref_high":"150","flag":"","unverified":true},
          {"name":"乙肝表面抗原","value":"阴性","unit":"","ref_low":"","ref_high":"","flag":""}
        ]}"#;
        let v = labs_from_json(j);
        assert_eq!(v.len(), 2, "定性值不进数值序列");
        assert_eq!(v[0].flag.as_deref(), Some("H"));
        assert!(v[0].analyte_key.is_some(), "白细胞计数应能解析到词典 key");
        assert_eq!(v[1].value_num, 13.5);
        assert!(v[1].confidence < 1.0, "unverified 降置信度");
    }
}
```
(`LabObservation.confidence: f32` 在 `labs.rs:160`,unverified 时为 0.5。)

- [ ] **Step 2: 跑,确认失败** — `cargo test -p parser labs_from_json` → 编译错误

- [ ] **Step 3: 实现**

`packages/parser/Cargo.toml` `[dependencies]` 加 `deid = { path = "../deid" }`。

`packages/parser/src/extraction.rs`:
```rust
//! 云抽取结果(deid schema v1)→ `LabObservation`,与 `extract_labs` 的产物同构,
//! 好让 aggregate / assemble_summary / 趋势零改动地吃它。
use crate::labs::LabObservation;

fn num(s: &str) -> Option<f64> { s.trim().replace(',', ".").parse::<f64>().ok() }

pub fn labs_from_json(json: &str) -> Vec<LabObservation> {
    let Ok(e) = deid::parse_extraction(json) else { return Vec::new() };
    e.labs.iter().filter_map(|l| {
        let value_num = num(&l.value)?;
        let unit = (!l.unit.is_empty()).then(|| l.unit.clone());
        let m = terminology::resolve(&l.name, unit.as_deref());
        let (ref_low, ref_high) = (num(&l.ref_low), num(&l.ref_high));
        let flag = match l.flag.as_str() {
            "H" | "L" => Some(l.flag.clone()),
            _ if ref_high.is_some_and(|h| value_num > h) => Some("H".into()),
            _ if ref_low.is_some_and(|lo| value_num < lo) => Some("L".into()),
            _ if ref_low.is_some() || ref_high.is_some() => Some("N".into()),
            _ => None,
        };
        Some(LabObservation {
            raw_name: l.name.clone(),
            analyte_key: m.as_ref().map(|m| m.key.clone()),
            canonical_name: m.as_ref().map(|m| m.canonical_name.clone()),
            loinc: m.as_ref().and_then(|m| m.codes.loinc.clone()),
            value_num,
            // ponytail: 规范单位换算未接(与自测值同款恒等换算);跨院混单位画趋势时接 labs.rs 的 UnitConversion
            value_canonical: Some(value_num),
            unit_raw: unit.clone(),
            unit_canonical: unit,
            ref_low, ref_high,
            ref_low_canonical: ref_low,
            ref_high_canonical: ref_high,
            flag,
            // labs.rs:160——0.0 = 词典没认出;unverified(图片档校验不过)压到 0.5 送人工核对
            confidence: if l.unverified { 0.5 } else { m.as_ref().map(|m| m.confidence).unwrap_or(0.0) },
            self_measured: false,
        })
    }).collect()
}
```
(`LabObservation` 字段以 `labs.rs:137-170` 为准:上面已覆盖全部 15 个,含 `confidence: f32` 与 `self_measured: bool`。)

`aggregate.rs`:`SourceDoc` 加字段
```rust
    /// 云抽取结果(deid schema v1 JSON);`Some` 时 labs 用它,不再对 `text` 跑 `extract_labs`。
    pub extraction_json: Option<&'a str>,
```
labs 分支(L684)改为:
```rust
        let doc_labs: Vec<LabObservation> = if let Some(j) = doc.extraction_json {
            crate::extraction::labs_from_json(j)
        } else if dt == Some("self_measurement") {
```
`lib.rs` 加 `pub mod extraction; pub use extraction::labs_from_json;`。本 crate 内所有 `SourceDoc {` 构造点加 `extraction_json: None,`(`grep -rn "SourceDoc {" packages/parser` 逐个改)。

- [ ] **Step 4: 跑** — `cargo test -p parser` → 全绿(含 `tests/corpus_summary.rs` 等)

- [ ] **Step 5: Commit**

```bash
git add packages/parser/Cargo.toml packages/parser/src/extraction.rs packages/parser/src/aggregate.rs packages/parser/src/lib.rs $(git diff --name-only packages/parser)
git commit -m "feat(parser): SourceDoc.extraction_json——有云抽取结果就用它,否则退回正则"
```

---

### Task 12: `share` 透传 `extraction_json`

**Files:**
- Modify: `packages/share/src/export.rs`(`GatheredRecord` L30;`gather_records` L59–64), `packages/share/src/share.rs`(L306–317), `packages/share/src/qr.rs`(L233–242)

**Interfaces:**
- Produces:`GatheredRecord.extraction_json: Option<String>`(来自 `vault.extraction_json(doc.id)`);两处 `SourceDoc` 构造传 `extraction_json: rec.extraction_json.as_deref()`。

- [ ] **Step 1: 改三处**

`export.rs`:
```rust
pub(crate) struct GatheredRecord {
    pub doc: core_model::Document,
    pub source_file: SourceFile,
    pub text: String,
    pub extraction_json: Option<String>,
}
// gather_records 循环里:
        let extraction_json = vault.extraction_json(doc.id).map_err(|e| e.to_string())?;
        out.push(GatheredRecord { doc, source_file: sf, text, extraction_json });
```
`share.rs` L310 与 `qr.rs` L237 的 `parser::SourceDoc { … }` 各加 `extraction_json: rec.extraction_json.as_deref(),`。

- [ ] **Step 2: 加一条测试**

`packages/share/src/share.rs` tests(用该文件既有的建 vault 辅助):导入一份文本、`add_extraction` 写入 `{"labs":[{"name":"白细胞计数","value":"11.8","unit":"10^9/L","ref_low":"4.0","ref_high":"10.0"}]}`、`build_encrypted_share` 后解出的 summary JSON 里出现 `11.8`(断言 `summary.to_string().contains("11.8")`)。

- [ ] **Step 3: 跑** — `cargo test -p medme-share` → 全绿

- [ ] **Step 4: Commit**

```bash
git add packages/share/src/export.rs packages/share/src/share.rs packages/share/src/qr.rs
git commit -m "feat(share): 分享/二维码摘要优先吃云抽取结果"
```

---

### Task 13: 移动端 Rust FRB:检测框、prepare / redact / commit,三处 SourceDoc 透传

**Files:**
- Modify: `apps/mobile_flutter/rust/src/api/dto.rs`(`OcrPpResultDto` L183), `apps/mobile_flutter/rust/src/api/vault.rs`(`recognize_image_pp` L1673–1697;新函数放其后;`proxy_summary` L1233), `vault_projections.rs`(`ProjectionDoc` + L420), `vault_ephemeral.rs`(L625 与 `gather_ephemeral_docs`), `apps/mobile_flutter/rust/Cargo.toml`(依赖 `deid`)

**Interfaces:**
- Produces(FRB,Dart 侧同名驼峰):
  ```rust
  pub struct OcrLineDto { pub text: String, pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
  pub struct OcrPpResultDto { pub text: String, pub confidence: f32, pub lines: Vec<OcrLineDto> }   // 新增 lines
  pub struct CloudExtractionRequestDto { pub payload_text: String, pub paint: Vec<RectDto>, pub restore_map_json: String }
  pub struct RectDto { pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
  pub struct CloudExtractionResultDto { pub labs: i64, pub rejected: i64, pub unverified: i64 }
  pub fn prepare_cloud_extraction(document_id: i64, lines: Vec<OcrLineDto>, known_name: String, known_id_number: Option<String>, known_phone: Option<String>, profile_secret_hex: String, page_w: f32, page_h: f32) -> anyhow::Result<CloudExtractionRequestDto>
  pub fn redact_image_bytes(bytes: Vec<u8>, paint: Vec<RectDto>) -> anyhow::Result<Vec<u8>>
  pub fn commit_cloud_extraction(document_id: i64, mode: String, model_version: String, llm_json: String, restore_map_json: String) -> anyhow::Result<CloudExtractionResultDto>
  ```
  `prepare` 内部:`v.ocr_text(document_id)` → `redact_text` → `assert_clean`(失败即 `bail!`,Dart 据此退回本地路径)→ 有 lines 时 `redact_boxes`。`commit`:`parse_extraction` → `verify(mode)`(校验用**脱敏文本**,即再算一次 `redact_text` 或从 restore map 反推——直接重新 `redact_text(ocr_text)` 最省事,确定性)→ `restore` 把占位符/日期还原进 JSON 字符串 → `v.add_extraction`。

- [ ] **Step 1: 写失败测试(桌面可跑的部分)**

`vault.rs` tests 里(用本文件既有 `with_state` 测试夹具或 `vault_ephemeral` 的 tempdir 方式):建 vault、`ingest_image_with_text("a.jpg", 假字节, "北京协和医院 姓名:张建国 白细胞计数 11.8 10^9/L 4.0-10.0", 0.9)`;`prepare_cloud_extraction(doc_id, vec![], "张建国", None, None, "00ff", 0.0, 0.0)` → `payload_text` 不含 `张建国` 且含 `[H1]`;`commit_cloud_extraction(doc_id, "text", "v4", r#"{"labs":[{"name":"白细胞计数","value":"11.8","unit":"10^9/L","ref_low":"4.0","ref_high":"10.0"}]}"#, req.restore_map_json)` → `labs == 1, rejected == 0`;随后 `v.extraction_json(doc_id)` 是 `Some`。

- [ ] **Step 2: 跑,确认失败** — `cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml cloud_extraction` → 编译错误

- [ ] **Step 3: 实现**

`apps/mobile_flutter/rust/Cargo.toml` `[dependencies]` 加 `deid = { path = "../../../packages/deid" }`。

`dto.rs`:
```rust
#[derive(Debug, Clone)]
pub struct OcrLineDto { pub text: String, pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
#[derive(Debug, Clone)]
pub struct OcrPpResultDto { pub text: String, pub confidence: f32, pub lines: Vec<OcrLineDto> }
#[derive(Debug, Clone)]
pub struct RectDto { pub left: f32, pub top: f32, pub right: f32, pub bottom: f32 }
#[derive(Debug, Clone)]
pub struct CloudExtractionRequestDto { pub payload_text: String, pub paint: Vec<RectDto>, pub restore_map_json: String }
#[derive(Debug, Clone)]
pub struct CloudExtractionResultDto { pub labs: i64, pub rejected: i64, pub unverified: i64 }
```

`vault.rs` `recognize_image_pp`(`cfg(pp_ocr)` 版)改为:
```rust
    let (lines, confidence) =
        ocr::recognize_engine_lines(&bytes).map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let text = ocr::rebuild_layout_text(&lines);
    Ok(OcrPpResultDto {
        text,
        confidence,
        lines: lines.into_iter().map(|l| OcrLineDto { text: l.text, left: l.left, top: l.top, right: l.right, bottom: l.top + l.height }).collect(),
    })
```
新函数:
```rust
fn known_identity(name: String, id: Option<String>, phone: Option<String>) -> deid::KnownIdentity {
    deid::KnownIdentity { name, id_number: id, phone }
}

fn hex_to_bytes(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).filter_map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// 脱敏并生成送云端的 payload;闸不过直接报错(Dart 退回本地正则,不发)。
pub fn prepare_cloud_extraction(
    document_id: i64, lines: Vec<OcrLineDto>, known_name: String, known_id_number: Option<String>,
    known_phone: Option<String>, profile_secret_hex: String, page_w: f32, page_h: f32,
) -> anyhow::Result<CloudExtractionRequestDto> {
    with_state(|state| {
        let text = state.vault.ocr_text(document_id).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let known = known_identity(known_name, known_id_number, known_phone);
        let days = deid::dates::shift_days_from_secret(&hex_to_bytes(&profile_secret_hex));
        let red = deid::redact_text(&text, &known, days);
        deid::assert_clean(&red.text, &known).map_err(|e| anyhow::anyhow!("{e}"))?;
        let boxes: Vec<deid::Box> = lines.iter().map(|l| deid::Box { text: l.text.clone(), left: l.left, top: l.top, right: l.right, bottom: l.bottom }).collect();
        let paint = if boxes.is_empty() { Vec::new() } else {
            deid::redact_boxes(&boxes, &known, page_w, page_h).into_iter()
                .map(|r| RectDto { left: r.left, top: r.top, right: r.right, bottom: r.bottom }).collect()
        };
        Ok(CloudExtractionRequestDto { payload_text: red.text, paint, restore_map_json: serde_json::to_string(&red.map)? })
    })
}

#[cfg(pp_ocr)]
pub fn redact_image_bytes(bytes: Vec<u8>, paint: Vec<RectDto>) -> anyhow::Result<Vec<u8>> {
    let rects: Vec<ocr::PaintRect> = paint.iter().map(|r| ocr::PaintRect { left: r.left, top: r.top, right: r.right, bottom: r.bottom }).collect();
    ocr::redact_image(&bytes, &rects).map_err(|e| anyhow::anyhow!(e.to_string()))
}
#[cfg(not(pp_ocr))]
pub fn redact_image_bytes(_bytes: Vec<u8>, _paint: Vec<RectDto>) -> anyhow::Result<Vec<u8>> {
    anyhow::bail!("图片涂黑仅 iOS/安卓构建可用")
}

/// LLM 结果回来:校验(对脱敏文本)→ 还原 → 落盘。
pub fn commit_cloud_extraction(
    document_id: i64, mode: String, model_version: String, llm_json: String, restore_map_json: String,
) -> anyhow::Result<CloudExtractionResultDto> {
    with_state(|state| {
        let map: deid::RestoreMap = serde_json::from_str(&restore_map_json)?;
        let text = state.vault.ocr_text(document_id).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        // 校验基准 = LLM 看到的那份脱敏文本:占位符替换是确定性的,重算即得。
        let known = deid::KnownIdentity { name: String::new(), id_number: None, phone: None };
        let mut seen = deid::redact_text(&text, &known, map.shift_days);
        for (p, v) in &map.placeholders { seen.text = seen.text.replace(v, p); }
        let m = if mode == "image" { deid::Mode::Image } else { deid::Mode::Text };
        let parsed = deid::parse_extraction(&llm_json).map_err(|e| anyhow::anyhow!("{e}"))?;
        let v = deid::verify(parsed, &seen.text, m);
        let restored = deid::restore(&serde_json::to_string(&v.extraction)?, &map);
        state.vault.add_extraction(core_model::NewExtraction {
            document_id, backend: "deepseek".into(), model_version, mode, result_json: restored,
        }).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(CloudExtractionResultDto { labs: v.extraction.labs.len() as i64, rejected: v.rejected as i64, unverified: v.unverified as i64 })
    })
}
```
三处 `parser::SourceDoc { … }`(`vault.rs` L1233、`vault_projections.rs` L420、`vault_ephemeral.rs` L625):各自的 doc 结构体加 `extraction_json: Option<String>`(取 `state.vault.extraction_json(id).unwrap_or(None)`——取不到就当没有,不让摘要因它失败),构造时 `extraction_json: d.extraction_json.as_deref()`。

- [ ] **Step 4: 跑 + 重生成 FRB 绑定**

```bash
cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml
cd apps/mobile_flutter && flutter_rust_bridge_codegen generate && flutter analyze
```
Expected: Rust 测试全绿;`lib/src/rust/api/vault.dart` 出现 `prepareCloudExtraction` / `redactImageBytes` / `commitCloudExtraction`,`OcrPpResultDto.lines`;analyze 0 errors。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/rust/Cargo.toml apps/mobile_flutter/rust/src/api/dto.rs apps/mobile_flutter/rust/src/api/vault.rs apps/mobile_flutter/rust/src/api/vault_projections.rs apps/mobile_flutter/rust/src/api/vault_ephemeral.rs apps/mobile_flutter/rust/src/frb_generated.rs apps/mobile_flutter/lib/src/rust/
git commit -m "feat(mobile-rust): 云抽取 FRB——prepare(脱敏+闸)/redact_image/commit(校验+还原+落盘);PP 结果带检测框"
```

---

### Task 14: 代理 `services/extract-proxy`(stdlib,照 claim-signer)

**Files:**
- Create: `services/extract-proxy/app.py`, `services/extract-proxy/test_app.py`, `services/extract-proxy/README.md`

**Interfaces:**
- `POST /v1/extract`,Header `X-MedMe-Token`(与 claim-signer 同一约定,`MEDME_UPLOAD_TOKEN`),Body `{"mode":"text"|"image","schema":1,"payload":"<文本或 base64 JPEG>"}` → `{"content":"<LLM 原样文本>","model":"…","usage":{…}}`。环境变量 `DEEPSEEK_API_KEY`;**不落盘 payload**,只 `print` token 数。`GET /health` → `{"ok":true}`。
- 选独立小服务而不是塞进 claim-signer:那个函数的职责是「签上传许可」,混进去两边部署互相牵制;B 子项目会建 `services/api`,届时把这 100 行搬过去。

- [ ] **Step 1: 写自检(纯函数部分)**

`services/extract-proxy/test_app.py`:
```python
"""python3 services/extract-proxy/test_app.py —— 无依赖。"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from app import build_messages, SYSTEM_PROMPT, model_for  # noqa: E402

FAIL = []
def check(name, cond):
    print(("  ✓ " if cond else "  ✗ ") + name)
    if not cond: FAIL.append(name)

m = build_messages("text", "白细胞 5.6")
check("system prompt 在第一条", m[0]["role"] == "system" and m[0]["content"] == SYSTEM_PROMPT)
check("文本档 user content 是字符串", m[1]["content"] == "白细胞 5.6")
mi = build_messages("image", "AAAA")
check("图片档 user content 带 image_url", mi[1]["content"][1]["image_url"]["url"].startswith("data:image/jpeg;base64,AAAA"))
check("模型按档选", model_for("text") == "deepseek-v4-flash" and model_for("image") == "deepseek-v4-flash-vision-exp")
sys.exit(1 if FAIL else 0)
```

- [ ] **Step 2: 跑,确认失败** — `python3 services/extract-proxy/test_app.py` → ImportError

- [ ] **Step 3: 写 `app.py`**

```python
"""LLM 抽取代理(阿里云 FC 自定义运行时;与 services/claim-signer/app.py 同款:stdlib、监听 PORT)。

只干三件事:验口令、拼 prompt、转发 DeepSeek。**不落盘 payload**(里面是脱敏后的病历),
日志只记 token 数。启动:python3 app.py  端口:9000
环境变量:DEEPSEEK_API_KEY(必需)、MEDME_UPLOAD_TOKEN(可选,与 claim-signer 同一口令)。
"""
import hmac
import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "9000"))
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"

SYSTEM_PROMPT = (
    "你是医疗单据结构化抽取器。只输出一个 JSON 对象,不要解释、不要 markdown 围栏。"
    "所有字符串必须是单据上的原文逐字,缺失留空字符串,不许推断或换算。schema:"
    '{"doc_type":"lab|discharge|outpatient|imaging|prescription|other","doc_date":"YYYY-MM-DD",'
    '"labs":[{"name":"","value":"","unit":"","ref_low":"","ref_high":"","flag":"H|L|"}],'
    '"meds":[{"name":"","dose":"","freq":"","route":""}],'
    '"diagnoses":[{"text":"","icd":""}],"impression":"","notes":""}'
)


def model_for(mode: str) -> str:
    return "deepseek-v4-flash-vision-exp" if mode == "image" else "deepseek-v4-flash"


def build_messages(mode: str, payload: str):
    if mode == "image":
        user = [
            {"type": "text", "text": "请抽取这张单据。"},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{payload}"}},
        ]
    else:
        user = payload
    return [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user}]


def call_deepseek(mode: str, payload: str) -> dict:
    key = os.environ["DEEPSEEK_API_KEY"].strip()
    body = json.dumps({"model": model_for(mode), "temperature": 0, "messages": build_messages(mode, payload)}).encode()
    req = urllib.request.Request(
        DEEPSEEK_URL, data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/health"):
            return self._json(200, {"ok": True})
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/extract":
            return self._json(404, {"error": "not_found"})
        expected = os.environ.get("MEDME_UPLOAD_TOKEN", "").strip()
        if expected and not hmac.compare_digest(self.headers.get("X-MedMe-Token", ""), expected):
            return self._json(403, {"error": "forbidden"})
        if not os.environ.get("DEEPSEEK_API_KEY", "").strip():
            return self._json(500, {"error": "server_not_configured"})
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            req = json.loads(self.rfile.read(length).decode("utf-8"))
            mode = req.get("mode", "text")
            payload = req["payload"]
            if req.get("schema") != 1:
                return self._json(400, {"error": "schema_unsupported"})
        except (ValueError, KeyError):
            return self._json(400, {"error": "bad_request"})
        try:
            out = call_deepseek(mode, payload)
        except Exception as e:  # 上游失败如实报,客户端退回本地路径
            return self._json(502, {"error": "upstream_failed", "detail": str(e)[:200]})
        usage = out.get("usage", {})
        print(f"extract mode={mode} tokens_in={usage.get('prompt_tokens')} tokens_out={usage.get('completion_tokens')}", flush=True)
        self._json(200, {
            "content": out.get("choices", [{}])[0].get("message", {}).get("content", ""),
            "model": out.get("model", model_for(mode)),
            "usage": usage,
        })

    def log_message(self, fmt, *args):
        pass  # 静音:默认日志带 path,且这里的 body 是病历,绝不能进函数日志


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
```
`README.md`:照 claim-signer README 写部署三步(自定义运行时、`python3 app.py`、端口 9000、环境变量表)+ 一句「B 子项目合并进 services/api 后本目录删除」。

- [ ] **Step 4: 跑自检** — `python3 services/extract-proxy/test_app.py` → 全 ✓

- [ ] **Step 5: 本地冒烟(有 key 时)**

```bash
DEEPSEEK_API_KEY=$(cat ~/.deepseek_key) PORT=9000 python3 services/extract-proxy/app.py &
curl -s localhost:9000/v1/extract -H 'Content-Type: application/json' \
  -d '{"mode":"text","schema":1,"payload":"白细胞计数 WBC 5.6 10^9/L 4.0-10.0"}' | head -c 400
```
Expected: `content` 里是含 `labs` 的 JSON 文本。

- [ ] **Step 6: Commit**

```bash
git add services/extract-proxy/app.py services/extract-proxy/test_app.py services/extract-proxy/README.md
git commit -m "feat(services): extract-proxy——/v1/extract 转发 DeepSeek,不落盘 payload,只记 token"
```

---

### Task 15: Dart:`Profile` 身份字段 + `cloud_extract.dart` + 导入流程接入

**Files:**
- Modify: `apps/mobile_flutter/lib/profile_manager.dart`(`Profile` L291–301), `apps/mobile_flutter/lib/import_flow.dart`(L678–690 之后), `apps/mobile_flutter/lib/ocr_bridge.dart`(`OcrResult` 加 `lines`)
- Create: `apps/mobile_flutter/lib/cloud_extract.dart`, `apps/mobile_flutter/test/cloud_extract_test.dart`

**Interfaces:**
- `Profile { id, name, idNumber?, phone?, secretHex }`——`secretHex` 建档时 `Random.secure()` 32 字节 hex(老档案 `fromJson` 缺则**生成并保存一次**);B 子项目落地后改为档案密钥。
- `class CloudExtract { static const url = String.fromEnvironment('MEDME_EXTRACT_URL', defaultValue: ''); static Future<String> call({required String mode, required String payload}) }`——POST JSON,`X-MedMe-Token: ClaimStorage.uploadToken`,回 `content` 字符串;url 为空或任何异常 → 抛 `CloudExtractUnavailable`。
- `Future<CloudExtractionResultDto?> runCloudExtraction(ImportOutcomeDto outcome, OcrResult ocr, Uint8List imageBytes)`(放 `cloud_extract.dart`):`prepareCloudExtraction` → 文本档 `CloudExtract.call` → `commitCloudExtraction`;任何一步失败返回 `null`,**不阻断导入**。默认文本档;图片档由 `--dart-define=MEDME_EXTRACT_MODE=image` 切(评测决定默认后改 defaultValue)。

- [ ] **Step 1: 写失败测试**

`apps/mobile_flutter/test/cloud_extract_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/cloud_extract.dart';

void main() {
  test('call posts JSON with token header and returns content', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      expect(req.method, 'POST');
      expect(req.uri.path, '/v1/extract');
      expect(body['mode'], 'text');
      expect(body['schema'], 1);
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'content': '{"labs":[]}'}));
      await req.response.close();
    });
    final out = await CloudExtract.call(
      mode: 'text', payload: '白细胞 5.6',
      urlOverride: 'http://127.0.0.1:${server.port}/v1/extract',
    );
    expect(out, '{"labs":[]}');
    await server.close(force: true);
  });

  test('empty url throws CloudExtractUnavailable', () async {
    expect(() => CloudExtract.call(mode: 'text', payload: 'x', urlOverride: ''), throwsA(isA<CloudExtractUnavailable>()));
  });
}
```

- [ ] **Step 2: 跑,确认失败** — `cd apps/mobile_flutter && flutter test test/cloud_extract_test.dart` → 编译错误

- [ ] **Step 3: 实现**

`cloud_extract.dart`:
```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mobile_flutter/claim_storage.dart';
import 'package:mobile_flutter/net.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart' as rust_vault;

class CloudExtractUnavailable implements Exception {
  const CloudExtractUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'CloudExtractUnavailable($reason)';
}

/// 云抽取代理(services/extract-proxy)。空串 = 未配置 → 一律走本地正则。
class CloudExtract {
  static const url = String.fromEnvironment('MEDME_EXTRACT_URL', defaultValue: '');
  static const mode = String.fromEnvironment('MEDME_EXTRACT_MODE', defaultValue: 'text');

  static Future<String> call({required String mode, required String payload, String? urlOverride}) async {
    final target = urlOverride ?? url;
    if (target.isEmpty) throw const CloudExtractUnavailable('not_configured');
    try {
      return await Net.run((client) async {
        final req = await client.postUrl(Uri.parse(target));
        req.headers.contentType = ContentType.json;
        if (ClaimStorage.uploadToken.isNotEmpty) req.headers.set('X-MedMe-Token', ClaimStorage.uploadToken);
        req.write(jsonEncode({'mode': mode, 'schema': 1, 'payload': payload}));
        await Net.flush(req);
        final res = await Net.send(req, timeout: const Duration(seconds: 90));
        final text = await Net.text(res, timeout: const Duration(seconds: 90));
        if (res.statusCode != 200) throw CloudExtractUnavailable('http_${res.statusCode}');
        return (jsonDecode(text) as Map<String, dynamic>)['content'] as String;
      });
    } on CloudExtractUnavailable { rethrow; } catch (e) { throw CloudExtractUnavailable(e.toString()); }
  }
}

/// 导入落库之后跑;任何一步失败返回 null,导入本身不受影响(摘要退回正则)。
Future<CloudExtractionResultDto?> runCloudExtraction(ImportOutcomeDto outcome, OcrResult ocr, Uint8List imageBytes) async {
  final docId = outcome.documentId;
  if (docId == null || CloudExtract.url.isEmpty) return null;
  final p = ProfileManager.instance.current; // profile_manager.dart:67,非空
  try {
    final req = await rust_vault.prepareCloudExtraction(
      documentId: docId, lines: ocr.lines, knownName: p.name, knownIdNumber: p.idNumber, knownPhone: p.phone,
      profileSecretHex: p.secretHex, pageW: ocr.pageW, pageH: ocr.pageH,
    );
    final String payload;
    if (CloudExtract.mode == 'image') {
      final jpg = await rust_vault.redactImageBytes(bytes: imageBytes, paint: req.paint);
      payload = base64Encode(jpg);
    } else {
      payload = req.payloadText;
    }
    final content = await CloudExtract.call(mode: CloudExtract.mode, payload: payload);
    return await rust_vault.commitCloudExtraction(
      documentId: docId, mode: CloudExtract.mode, modelVersion: 'deepseek-v4-flash',
      llmJson: content, restoreMapJson: req.restoreMapJson,
    );
  } catch (_) {
    return null; // 闸拒发 / 无网 / 上游失败 / JSON 坏:都退回本地路径
  }
}
```
`ocr_bridge.dart`:`OcrResult` 加 `final List<OcrLineDto> lines; final double pageW; final double pageH;`(构造函数默认 `const []`, 0, 0);`recognizeImageText` 里 `OcrResult(res.text, res.confidence, lines: res.lines, pageW: 图宽, pageH: 图高)`——宽高用 `decodeImageFromList` 或直接把 `lines` 的 `right`/`bottom` 最大值当页面尺寸(后者零依赖,取它)。

`profile_manager.dart` `Profile`:
```dart
class Profile {
  const Profile({required this.id, required this.name, this.idNumber, this.phone, required this.secretHex});
  final String id; final String name; final String? idNumber; final String? phone;
  /// 32 字节随机,派生日期偏移(deid);B 子项目后换成档案密钥。
  final String secretHex;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'idNumber': idNumber, 'phone': phone, 'secretHex': secretHex};
  static Profile fromJson(Map<String, dynamic> j) => Profile(
    id: j['id'] as String, name: j['name'] as String,
    idNumber: j['idNumber'] as String?, phone: j['phone'] as String?,
    secretHex: (j['secretHex'] as String?) ?? newSecretHex(),
  );
  static String newSecretHex() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
```
`ProfileManager` 建档处传 `secretHex: Profile.newSecretHex()`;加载后若有档案是补出来的 secret,调一次 `_save()`。

`import_flow.dart` L690 `ingestImageWithText` 之后:
```dart
        stage = 'extract';
        await runCloudExtraction(outcome, ocr, bytes); // 失败返回 null,不阻断
```

- [ ] **Step 4: 跑** — `flutter test && flutter analyze` → 全绿、0 errors(既有 `profile_*` 相关测试若断言 `toJson` 形状,按新字段更新)

- [ ] **Step 5: 真机三态(memory `test-all-three-states`)**

`--dart-define=MEDME_EXTRACT_URL=<代理地址>` 装机:① 有网导入一张化验单 → 趋势页出现抽取项;② 关网导入 → 导入成功、摘要走正则;③ 档案名故意留在页面上(闸)→ 不发、导入成功。三条各截一张图记进 PR。

- [ ] **Step 6: Commit**

```bash
git add apps/mobile_flutter/lib/cloud_extract.dart apps/mobile_flutter/lib/ocr_bridge.dart apps/mobile_flutter/lib/profile_manager.dart apps/mobile_flutter/lib/import_flow.dart apps/mobile_flutter/test/cloud_extract_test.dart
git commit -m "feat(mobile): 导入后接云抽取——脱敏 → 代理 → 校验落盘;失败退回正则不阻断"
```

---

### Task 16: ADR 0010 + 隐私政策 + 官网话术

**Files:**
- Create: `docs/ADR/0010-cloud-llm-extraction-and-accounts.md`
- Modify(gh-pages worktree `../Medme-ghpages`):`privacy.html` L8(description)、L84(「没有账号…不经过我们的服务器」)、L90–94(「从不发送」列表里的 OCR 结果)、L111–115(「二、文字识别在你的手机上完成」)、L245(加密列表)

- [ ] **Step 1: 写 ADR(Nygard 格式,照 0009)**

```markdown
# ADR 0010 · 云 LLM 结构化抽取(本地脱敏后送境内模型)+ 账号

Status: Accepted · Date: 2026-09-11 · **Supersedes** ADR 0005/0006 中「识别全部在端上完成」的前提;取代 memory `ocr-v1-decisions-no-cloud` 的「不上云」决定。OCR 本身**仍在端上**。

## Context
正则抽取在 MedRepBench 683 份真实化验单上端到端 28%,且会安静伪造合理值(WORKLIST P0 #38/#49);
行对齐路线 2026-08-14 实测倒退已否决。纯本地无账号无法商业化、接不上 Prometheno。
团队 2026-09-11 决定做进阶版(总纲 docs/superpowers/specs/2026-09-11-advanced-edition-overview-design.md)。

## Decision
1. **OCR 留在端上**(PP-OCRv5),它的职责变为**脱敏与定位**;结构化识别交给云端 LLM(DeepSeek,境内)。
2. 发送前本地脱敏三层 + 一道闸(`packages/deid`):已知身份精确删、锚点值掩、模式兜底;年龄/性别/科室/检验值保留;
   日期按档案统一偏移 ±90 天;闸不过不发。图片档按检测框 + 页眉页脚带涂黑。
3. 结果逐字校验(文本档不过即丢;图片档标「需核对」),`Event::ExtractionAdded` 落盘,原件不动,换模型可全量重跑。
4. 只走我们的代理与 key,按订阅计费;不做 BYOK。
5. 对外话术:「存储端到端加密;识别时经本地脱敏后送境内云端」,两句分开说,**不再说「数据不出手机」**。

## Consequences
- (+) 识别质量:见 docs/log/2026-09-XX-deepseek-vs-regex-medrep.md 的数字。
- (−) 脱敏后的病历内容(无姓名/号码/医院名)会离开手机到 DeepSeek;脱敏不可能 100%(手写名、二维码)。隐私政策如实写。
- (−) 依赖网络;离线退回正则。
- 未变:查看器永不埋点(ADR 0009);分享包/代拍链路的 E2E 不变。
```

- [ ] **Step 2: 改隐私政策(gh-pages worktree)**

```bash
cd ../Medme-ghpages && git status   # 必须在 gh-pages 分支、干净
```
改动要点(每处一两句,措辞与政策既有风格一致):
- L8 description:去掉「无账号」,改「默认不联网;识别可选经本地脱敏后送境内云端」。
- L84:改为「默认情况下……只存在于你的设备上。**当你开启云端识别时**,识别出的文字会先在手机上抹去姓名、证件号、病历号、医院名等身份信息,再送到我们在中国境内的模型服务(DeepSeek)做结构化整理;结果回到手机后同样只存在你的设备上。我们的代理不保存这些内容,只记录用量。」
- L90–94:「从不发送」列表里的「文字识别(OCR)的结果」改为「原始照片;未脱敏的识别文字」,并加一条「你的姓名、证件号、手机号、病历号、医院名——在任何情况下都不会发送」。
- L111–115「二、文字识别在你的手机上完成」:保留;末尾加「结构化整理(把识别文字整理成化验项目/用药/诊断)可以选择在云端完成,见第一节。」
- L245:加一行「云端识别经本地脱敏,脱敏不可能做到绝对——手写姓名、二维码等可能漏网;我们持续补充脱敏规则」。

- [ ] **Step 3: 官网首页(若有「零服务器 / 不联网 / 无账号」字样)**

`grep -n "零服务器\|不联网\|无账号\|不经过我们的服务器" ../Medme-ghpages/index.html` 逐处改为与政策同口径(memory `landing-messaging-2026-07` 已松绑)。

- [ ] **Step 4: 独立核查(硬规矩 3)**

派一个独立 subagent 把 ADR 与 privacy.html 的每条对外陈述核到 `file:line`(`deid` 的三层与闸、`extract-proxy` 不落盘、`commit_cloud_extraction` 落盘路径);核出的错**改完再核一遍**。

- [ ] **Step 5: 推 gh-pages 并线上核实(硬规矩 4)**

```bash
cd ../Medme-ghpages && git add privacy.html index.html && git commit -m "privacy: 云端识别(本地脱敏后送境内 LLM)如实告知" && git push
curl -s https://medmenow.com/privacy.html | grep -c "脱敏"
```
Expected: ≥ 3。

- [ ] **Step 6: Commit(主仓库)**

```bash
git add docs/ADR/0010-cloud-llm-extraction-and-accounts.md
git commit -m "docs(adr): 0010 云 LLM 抽取 + 账号——翻案「不上云」,OCR 仍端上,脱敏后送境内模型"
```

---

## 自查(写完后对着 spec 过一遍)

| Spec 节 | Task |
|---|---|
| §1 三层 + 闸、保留项、日期、医院名、图片档涂黑规则 | 1, 2, 3, 6, 7 |
| §1 清单 = fixture + 测试、README、住院首页缺口 | 5 |
| §2 代理端点、静态 token、不落盘 | 14 |
| §3 schema v1、ICD 保留 | 4(类型)、10(JSON 原样落盘含 icd) |
| §4 文本档丢弃 / 图片档 unverified | 4, 13(commit) |
| §5 `ExtractionAdded`、CAS、materialize、`assemble_summary` 优先、退回正则 | 10, 11, 12, 13 |
| §6 评测:三分母三指标 + 幻觉率、两档、384 token 切块、log、不达标不接 | 8, 9(**门在 Task 9,Task 10+ 只在过门后做**) |
| §7 不做 | 无任务(BYOK/云 OCR/定性/用户 prompt 均未出现) |
| §8 风险:exp 接口变 → 代理隔离;脱敏漏网 → 带 + 清单 | 14, 5, 16 |
| 总纲横切 1/2/3(ADR、隐私政策、官网) | 16 |
| 总纲横切 4(导入压图) | **不在本计划**——它属于 B 的同步上传前置,B 计划里做;A 的 `redact_image` 已把送云端那份压到 q85 |

未能映射到真实代码的:无。
