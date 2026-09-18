# 病程档案 skill 框架 + SLE 包 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 MedMe 用一个签名的静态 JSON「病种包」+ 一个手机端纯函数规则引擎,把用户已有的病历算成一张「病程档案」,第一个病是 SLE。

**Architecture:** 一个病 = 一个服务端公开静态 JSON 包(Ed25519 签名、可热更新、不含用户数据);App 只有一个规则引擎(`packages/profile`,纯函数)和一个渲染引擎(Flutter,7 种 section)。抽取用「族级」prompt(schema 2,服务器看不出病种),病程档案在手机上从事件日志重算,永远可重算、永不落新事件类型。

**Tech Stack:** Rust(新 crate `packages/profile`;改 `core-model`/`parser`/`deid`/`terminology`)、Python FastAPI(`services/api`)、Flutter + flutter_rust_bridge 2.12.0、`ed25519-dalek` 2、DeepSeek `/v1/extract`。

**Spec:** `docs/superpowers/specs/2026-09-16-disease-profile-skill-framework-design.md`
**代码事实(file:line 的来源):** `.superpowers/sdd/disease-profile/fact-sheet.md`
**临床出处(包内每个数值的唯一合法来源):** `.superpowers/sdd/disease-profile/sle-clinical-sources.md`

## Global Constraints

- **工作树与分支:** 所有改动只在 `/Volumes/extraSupply/Projects/Medme-adv-a`,分支 `feat/advanced-a`。commit 只在这个分支。
- **请求里永远不带病种/包 id。** `POST /v1/extract` 的 body 只有 `{mode, schema, payload}`;任何 package id、病名、包版本都不许出现在任何发往服务端的请求里(spec §8)。
- **不新增 `Event` 变体。** 新状态一律走 `DocumentAdded{doc_type=profile_event}`(与 `SelfMeasurement`/`Note` 同一先例,`packages/core-model/src/types.rs:17,19`)。`ExtractionAdded` 只把 `schema` 从 1 升到 2,同事件、同表、同同步清单。
- **`recognize_image_pp` 的 FRB 下标 44 不动。** `apps/mobile_flutter/rust/src/frb_generated.rs:4262` 现为 `44 => wire__crate__api__vault__recognize_image_pp_impl`。派发表按函数名字典序排,新 FFI 函数名必须排在 `recognize_image_pp` 之后(`vault_profile_view` / `view_*` 都满足)。codegen 之后必须逐字核对这一行。
- **包里每个数值都带出处 id。** `manifest.sources[]` 声明 `{id, cite, url}`,规则/阈值/剂量每一条带 `"source":"<id>"`。没有 `source` 的数值不许进包。
- **只许引用 `sle-clinical-sources.md` 里标 `VERBATIM` 的值。** 标 `NOT VERIFIED` / `PARAPHRASE` 的一律写成 `null` + `"note":"待核"`,由 Task 19 逐条核。
- **界面不许出现「计算 SLEDAI」「判断缓解」字样。** 只能说「按指南把化验可算的部分整理出来、把该复查的列出来」。分数一律带「化验可算部分」标签,达标表逐条 ✔/✘/未知,不下结论(spec §8)。
- **所有测试前台跑**,不放后台;性能相关一律 `--release`。
- **C1–C4 不碰 `apps/mobile_flutter/lib`**(UX Stage 1 在另一条线并行改 Flutter);C5 才碰。`apps/mobile_flutter/rust/` 可以碰。
- **私钥不进仓库。** 签名脚本读 `~/.medme_skill_signing_key`,仓库里只有公钥常量和签好的包。
- **改了「数据往哪走」必须同步隐私政策**(gh-pages worktree `/Volumes/extraSupply/Projects/Medme-ghpages/privacy.html`,推上去即上线)。Task 24。

## File Structure

新建:
- `packages/profile/` — 新 crate。`src/package.rs`(包 schema + Ed25519 验签 + 引擎版本闸 + 磁盘缓存)、`src/rules.rs`(规则求值,纯函数)、`src/view.rs`(ProfileView 输出类型)、`src/lib.rs`(`materialize` 入口 + re-export)。每个文件一个职责,规则求值不碰 IO,包加载不碰规则。
- `packages/parser/src/profile_event.rs` — `###MEDME-PROFILE-V1###` 载荷的 render/parse,与 `self_entry.rs` 同构。
- `packages/deid/prompts/extract_v2_system.txt` — 族级 schema 2 prompt。
- `skills/sle/2026.09.1.src.json`(作者写的包)+ `skills/sle/2026.09.1.json`(签好的信封);
  `skills/index.src.json`(脚本生成的清单)+ `skills/index.json`(**同一种信封,也签名**)。
- `scripts/sign_skill.py` — 签名/公钥工具。
- `examples/demo-dataset/generate_sle.sh` + `packages/profile/testdata/corpus/` — 合成 SLE 病程语料(3 年 / 4 家医院 / 含活检、输注、眼科)。

改动:
- `packages/core-model/src/types.rs` — `DocType::ProfileEvent`;`NewExtraction.schema`。
- `packages/deid/src/verify.rs` — `Fact` 类型 + `Extraction.facts` + facts 的逐字校验。
- `packages/parser/src/aggregate.rs:697` — `profile_event` 与 `note`/`self_measurement` 同样不进临床聚合。
- `packages/terminology/src/lib.rs` — 运行时覆盖层(内置优先,包不能覆盖内置)。
- `packages/parser/src/labs.rs:381` — 换到覆盖层感知的 entry 查询。
- `services/api/extract.py` / `app.py` — schema 2 透传 + `/v1/skills/*` 两条无鉴权路由。
- `apps/mobile_flutter/rust/src/api/vault_projections.rs` — `vault_profile_view` FFI。
- `apps/mobile_flutter/lib/` — 渲染引擎 + 入口卡 + 独立页 + 交接单(仅 C5)。
- `packages/share/src/share.rs` — `build_share_blob_inner` 多一个 `profile` 参数 +
  `build_own_share_blob_with_profile` 入口(仅 C5)。
- `web/hosted-viewer/index.html` — `renderProfile` 渲染入口(仅 C5);改完必须跑
  `scripts/csp-hashes.py` 重算内联脚本的 CSP sha256,否则查看器整页白屏。

---

## C1 — 包格式、加载、签名、缓存、分发

### Task 1: `packages/profile` crate — 包 schema 与签名信封

**Files:**
- Create: `packages/profile/Cargo.toml`
- Create: `packages/profile/src/lib.rs`
- Create: `packages/profile/src/package.rs`
- Modify: `Cargo.toml:3`(workspace `members` 数组加 `"packages/profile"`)

**Interfaces:**
- Produces:
  - `profile::Package { manifest: Manifest, triggers: Triggers, terms: Terms, markers: Vec<Marker>, drugs: Vec<Drug>, rules: Rules, views: Views }`
  - `profile::Manifest { id: String, family: String, version: String, min_engine: u32, display: Display, disclaimer: String, sources: Vec<Source> }`
  - `profile::PackageError`(`Malformed(String)` / `BadSignature` / `EngineTooOld { needs: u32, have: u32 }`)
  - `profile::verify_envelope(envelope_json: &str) -> Result<Package, PackageError>`
  - `profile::SIGNING_PUBLIC_KEY_HEX: &str`
- 信封格式(**签名对象是内层 JSON 的原始 UTF-8 字节,不做任何规范化重序列化**):
  `{"sig":"<base64 标准表,64 字节 Ed25519 签名>","package":"<内层包 JSON 的原文字符串>"}`

- [ ] **Step 1: 写失败测试**

`packages/profile/src/package.rs` 末尾:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// 固定测试密钥(仅测试用,不是生产签名密钥)。seed 全 1。
    const TEST_SEED: [u8; 32] = [1u8; 32];

    fn sign_with_test_key(body: &str) -> String {
        use ed25519_dalek::{Signer, SigningKey};
        use base64::Engine as _;
        let sk = SigningKey::from_bytes(&TEST_SEED);
        let sig = base64::engine::general_purpose::STANDARD.encode(sk.sign(body.as_bytes()).to_bytes());
        serde_json::json!({ "sig": sig, "package": body }).to_string()
    }

    fn test_pubkey_hex() -> String {
        use ed25519_dalek::SigningKey;
        hex_encode(SigningKey::from_bytes(&TEST_SEED).verifying_key().as_bytes())
    }

    const MINIMAL: &str = r#"{"manifest":{"id":"t","family":"immune","version":"2026.09.1","min_engine":1,
      "display":{"name":"测试病","short":"测试"},"disclaimer":"仅整理你的病历,不做诊断",
      "sources":[{"id":"S1","cite":"test","url":null}]},
      "triggers":{"diagnosis_patterns":[],"serology_any_two":[]},
      "terms":{"aliases":{},"analytes":[]},"markers":[],"drugs":[],
      "rules":{"activity":{"window_days":10,"max":18,"items":[]},"states":[],"monitoring":[],"milestones":[]},
      "views":{"sections":[],"handoff":[]}}"#;

    #[test]
    fn valid_envelope_parses_and_keeps_manifest() {
        let env = sign_with_test_key(MINIMAL);
        let pkg = verify_envelope_with_key(&env, &test_pubkey_hex()).expect("valid envelope");
        assert_eq!(pkg.manifest.id, "t");
        assert_eq!(pkg.manifest.min_engine, 1);
        assert_eq!(pkg.manifest.sources[0].id, "S1");
    }

    #[test]
    fn one_flipped_byte_in_the_body_fails_the_signature() {
        let env = sign_with_test_key(MINIMAL);
        let tampered = env.replace("测试病", "别的病");
        assert!(tampered != env, "改写必须真的发生,否则这个测试什么也没验");
        assert!(matches!(
            verify_envelope_with_key(&tampered, &test_pubkey_hex()),
            Err(PackageError::BadSignature)
        ));
    }

    #[test]
    fn a_different_key_fails_the_signature() {
        let env = sign_with_test_key(MINIMAL);
        let other = hex_encode(
            ed25519_dalek::SigningKey::from_bytes(&[2u8; 32]).verifying_key().as_bytes(),
        );
        assert!(matches!(
            verify_envelope_with_key(&env, &other),
            Err(PackageError::BadSignature)
        ));
    }

    #[test]
    fn missing_sig_is_malformed_not_bad_signature() {
        let env = serde_json::json!({ "package": MINIMAL }).to_string();
        assert!(matches!(
            verify_envelope_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
    }
}
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: FAIL — `error: no such package 'profile'`(crate 还不存在)。

- [ ] **Step 3: 建 crate 与实现**

`packages/profile/Cargo.toml`:

```toml
[package]
name = "profile"
version = "0.1.0"
edition = "2021"
description = "病程档案规则引擎:病种包的加载/验签/缓存,以及从保险箱数据算出 ProfileView 的纯函数。不碰网络。"

[dependencies]
serde = { workspace = true }
serde_json = { workspace = true }
chrono.workspace = true
# 包签名:防的是 CDN/桶被改后往规则里塞东西(spec §2)。只用验签,不在客户端签名。
ed25519-dalek = "2"
# 与 packages/share 同版本,免得 workspace 里同时编两份 base64。
base64 = "0.23"

[dev-dependencies]
# 测试要临时生成一对密钥来签,生产路径只验签。
ed25519-dalek = { version = "2", features = ["rand_core"] }
tempfile.workspace = true
```

根 `Cargo.toml:3` 的 `members` 里,在 `"packages/parser"` 后面插入 `"packages/profile"`。

`packages/profile/src/lib.rs`:

```rust
//! 病程档案(disease profile):病种包的加载与规则求值。
//!
//! 两条硬边界:
//! 1. **本 crate 不碰网络。** 包从哪来(HTTP / 缓存文件 / 测试常量)是调用方的事,
//!    这里只接受字节、验签、求值 —— 这样规则引擎在纯 Rust 单测里可完整覆盖。
//! 2. **规则求值是纯函数。** 同一份输入 + 同一个包 + 同一个 `today` 永远得到同一份
//!    `ProfileView`,所以档案「永远可重算」(spec §0),不需要任何新的事件类型。
pub mod package;

pub use package::{
    verify_envelope, Analyte, Display, Drug, Manifest, Marker, Package, PackageError, Rules,
    Source, Terms, Triggers, UnitRow, Views, ENGINE_VERSION, SIGNING_PUBLIC_KEY_HEX,
};
```

`packages/profile/src/package.rs`:

```rust
//! 包格式(spec §2)与签名信封。
//!
//! **签名对象是内层包 JSON 的原始 UTF-8 字节**,不是「解析后再序列化」的结果:
//! 任何规范化重序列化(键序、空白、数字格式)都会让签名在跨语言/跨版本时随机失效。
//! 所以信封把包体当成一个**字符串**携带:`{"sig":"…","package":"{…}"}`。
//! 丑,但逐字节可核 —— 签名脚本签的就是这个文件里那串字符。
use serde::Deserialize;

/// 本二进制支持的渲染/规则引擎版本。包声明 `min_engine > ENGINE_VERSION` 就不加载
/// (新 section 类型或新规则类型才需要发版,spec §2)。
pub const ENGINE_VERSION: u32 = 1;

/// 我们的包签名公钥(hex,32 字节)。私钥只在 `~/.medme_skill_signing_key`,永不进仓库。
/// 生成/轮换见 `scripts/sign_skill.py --pubkey`。
/// Task 3 用真实公钥替换这一行的占位值。
pub const SIGNING_PUBLIC_KEY_HEX: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

#[derive(Debug)]
pub enum PackageError {
    /// 信封或包体不是我们认得的形状(缺字段、不是 JSON、签名不是 64 字节…)。
    Malformed(String),
    /// 签名验不过 —— 包被改过,或不是我们签的。**不加载,不降级,不「只用一部分」**。
    BadSignature,
    /// 包要求的引擎版本比本二进制新。老 App 装不上新包是正常的,如实告诉用户去升级。
    EngineTooOld { needs: u32, have: u32 },
}

impl std::fmt::Display for PackageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PackageError::Malformed(m) => write!(f, "包格式不对:{m}"),
            PackageError::BadSignature => write!(f, "包签名验证不通过"),
            PackageError::EngineTooOld { needs, have } => {
                write!(f, "这个病种包需要 App 引擎 v{needs},当前是 v{have}")
            }
        }
    }
}
impl std::error::Error for PackageError {}

/// 病种在界面上的名字。与 `std::fmt::Display` 同名但不冲突 —— 本文件里那个 trait
/// 只以全路径出现(`impl std::fmt::Display for PackageError`)。
#[derive(Debug, Clone, Deserialize)]
pub struct Display {
    pub name: String,
    pub short: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Source {
    pub id: String,
    pub cite: String,
    #[serde(default)]
    pub url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Manifest {
    pub id: String,
    pub family: String,
    pub version: String,
    pub min_engine: u32,
    pub display: Display,
    pub disclaimer: String,
    pub sources: Vec<Source>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Triggers {
    #[serde(default)]
    pub diagnosis_patterns: Vec<String>,
    #[serde(default)]
    pub serology_any_two: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UnitRow {
    pub unit: String,
    pub slope: f64,
    pub intercept: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Analyte {
    pub key: String,
    pub name: String,
    #[serde(default)]
    pub loinc: Option<String>,
    #[serde(default)]
    pub panel: Option<String>,
    #[serde(default)]
    pub canonical_unit: Option<String>,
    #[serde(default)]
    pub units: Vec<UnitRow>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Terms {
    /// 给**已有** key 加别名:`{"complement_c3":["补体C3","C3"]}`。
    #[serde(default)]
    pub aliases: std::collections::HashMap<String, Vec<String>>,
    /// 定义**新**分析物(词典里没有的,如 UPCR)。
    #[serde(default)]
    pub analytes: Vec<Analyte>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Marker {
    pub key: String,
    /// `activity` / `serology` / `inflammation` / `drug_monitor` / `organ:<器官>`。
    pub role: String,
    #[serde(default)]
    pub dir: Option<String>,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub qualitative_ok: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Drug {
    pub class: String,
    #[serde(default)]
    pub atc_prefix: Option<String>,
    pub names: Vec<String>,
    /// 泼尼松等效换算表。**`None` = 换算表未核实**,此时只有泼尼松本身(系数 1,
    /// 按定义)能算日剂量,其它糖皮质激素如实显示「等效表待核」。
    #[serde(default)]
    pub pred_equiv: Option<std::collections::HashMap<String, f64>>,
    #[serde(default)]
    pub pred_equiv_source: Option<String>,
    #[serde(default)]
    pub infusion: Option<std::collections::HashMap<String, String>>,
}

/// 规则块。字段的具体形状在 Task 11–15 逐条长出来;这里先按 spec §5 的四组固定下来,
/// 好让包 JSON 的顶层形状从第一天就是最终形状(改顶层 = 所有已签的包作废)。
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Rules {
    #[serde(default)]
    pub activity: ActivityRules,
    #[serde(default)]
    pub states: Vec<serde_json::Value>,
    #[serde(default)]
    pub monitoring: Vec<serde_json::Value>,
    #[serde(default)]
    pub milestones: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ActivityRules {
    /// 取值窗口:SLEDAI-2K 表格原文「评分日前 10 天内」(sle-clinical-sources §B)。
    pub window_days: i64,
    /// 化验可算部分的满分(SLE = 18)。
    pub max: u32,
    #[serde(default)]
    pub items: Vec<serde_json::Value>,
}

impl Default for ActivityRules {
    fn default() -> Self {
        ActivityRules { window_days: 10, max: 0, items: Vec::new() }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Views {
    #[serde(default)]
    pub sections: Vec<serde_json::Value>,
    #[serde(default)]
    pub handoff: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Package {
    pub manifest: Manifest,
    #[serde(default)]
    pub triggers: Triggers,
    #[serde(default)]
    pub terms: Terms,
    #[serde(default)]
    pub markers: Vec<Marker>,
    #[serde(default)]
    pub drugs: Vec<Drug>,
    #[serde(default)]
    pub rules: Rules,
    #[serde(default)]
    pub views: Views,
}

#[derive(Deserialize)]
struct Envelope {
    sig: String,
    package: String,
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_decode_32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        out[i] = u8::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?;
    }
    Some(out)
}

/// 用生产公钥验签并解析。
pub fn verify_envelope(envelope_json: &str) -> Result<Package, PackageError> {
    verify_envelope_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

/// 同上,但公钥可注入 —— 只给测试用(生产路径固定走上面那个)。
pub fn verify_envelope_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<Package, PackageError> {
    use base64::Engine as _;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    let env: Envelope = serde_json::from_str(envelope_json)
        .map_err(|e| PackageError::Malformed(format!("信封解析失败:{e}")))?;
    let sig_bytes = base64::engine::general_purpose::STANDARD
        .decode(env.sig.as_bytes())
        .map_err(|e| PackageError::Malformed(format!("签名不是合法 base64:{e}")))?;
    let sig_arr: [u8; 64] = sig_bytes
        .try_into()
        .map_err(|_| PackageError::Malformed("签名不是 64 字节".into()))?;
    let key_bytes =
        hex_decode_32(pubkey_hex).ok_or_else(|| PackageError::Malformed("公钥不是 32 字节 hex".into()))?;
    let vk = VerifyingKey::from_bytes(&key_bytes)
        .map_err(|e| PackageError::Malformed(format!("公钥不是合法 Ed25519 点:{e}")))?;
    // `verify_strict` 而不是 `verify`:拒掉小阶公钥/可延展签名,别在验签这道闸上省。
    vk.verify_strict(env.package.as_bytes(), &Signature::from_bytes(&sig_arr))
        .map_err(|_| PackageError::BadSignature)?;

    serde_json::from_str(&env.package)
        .map_err(|e| PackageError::Malformed(format!("包体解析失败:{e}")))
}
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS(4 个测试)。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo build --workspace`
Expected: 成功 —— 新 crate 进 workspace 不能打破现有构建。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add Cargo.toml Cargo.lock packages/profile
git commit -m "feat(profile): 病种包 schema 与 Ed25519 签名信封

签名对象是内层包 JSON 的原始字节,信封把包体当字符串携带,避免任何
规范化重序列化带来的跨版本签名漂移。验不过就不加载,不降级。"
```

---

### Task 2: 引擎版本闸 + 包的本机缓存

**Files:**
- Modify: `packages/profile/src/package.rs`(在 Task 1 的 `verify_envelope` 之后追加)
- Modify: `packages/profile/src/lib.rs`(re-export 新函数)

**Interfaces:**
- Consumes: Task 1 的 `verify_envelope_with_key`、`Package`、`PackageError`、`ENGINE_VERSION`
- Produces:
  - `profile::load_signed(envelope_json: &str) -> Result<Package, PackageError>` —— 验签 **+** 引擎版本闸
  - `profile::cache_store(dir: &std::path::Path, envelope_json: &str) -> Result<String, PackageError>` —— 返回写进去的包 id
  - `profile::cache_load(dir: &std::path::Path, id: &str) -> Option<Package>`
  - 缓存路径约定:`<dir>/skills/<id>.json`,内容就是**信封原文**

- [ ] **Step 1: 写失败测试**

追加到 `packages/profile/src/package.rs` 的 `mod tests`:

```rust
    #[test]
    fn a_package_needing_a_newer_engine_is_refused() {
        let body = MINIMAL.replace("\"min_engine\":1", "\"min_engine\":99");
        let env = sign_with_test_key(&body);
        match load_signed_with_key(&env, &test_pubkey_hex()) {
            Err(PackageError::EngineTooOld { needs, have }) => {
                assert_eq!(needs, 99);
                assert_eq!(have, ENGINE_VERSION);
            }
            other => panic!("应当拒绝,实际 {other:?}"),
        }
    }

    #[test]
    fn min_engine_equal_to_ours_is_accepted() {
        let body = MINIMAL.replace("\"min_engine\":1", &format!("\"min_engine\":{ENGINE_VERSION}"));
        let env = sign_with_test_key(&body);
        assert!(load_signed_with_key(&env, &test_pubkey_hex()).is_ok());
    }

    #[test]
    fn cache_round_trips_and_reverifies_on_read() {
        let dir = tempfile::tempdir().unwrap();
        let env = sign_with_test_key(MINIMAL);
        let id = cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).unwrap();
        assert_eq!(id, "t");
        let pkg = cache_load_with_key(dir.path(), "t", &test_pubkey_hex()).expect("缓存读回");
        assert_eq!(pkg.manifest.id, "t");
    }

    #[test]
    fn a_tampered_cache_file_is_ignored_not_trusted() {
        // 缓存在用户可写的磁盘上,是**不可信输入**:读回时必须重新验签,
        // 不能因为「是我们自己写进去的」就跳过。
        let dir = tempfile::tempdir().unwrap();
        let env = sign_with_test_key(MINIMAL);
        cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).unwrap();
        let path = dir.path().join("skills").join("t.json");
        let poisoned = std::fs::read_to_string(&path).unwrap().replace("测试病", "别的病");
        std::fs::write(&path, poisoned).unwrap();
        assert!(cache_load_with_key(dir.path(), "t", &test_pubkey_hex()).is_none());
    }

    #[test]
    fn cache_store_refuses_to_write_an_unsigned_envelope() {
        let dir = tempfile::tempdir().unwrap();
        let env = sign_with_test_key(MINIMAL).replace("测试病", "别的病");
        assert!(cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).is_err());
        assert!(!dir.path().join("skills").join("t.json").exists());
    }
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: FAIL — `cannot find function 'load_signed_with_key' in this scope`。

- [ ] **Step 3: 实现**

追加到 `packages/profile/src/package.rs`(`mod tests` 之前):

```rust
/// 验签 + 引擎版本闸。**生产路径唯一的包入口**。
pub fn load_signed(envelope_json: &str) -> Result<Package, PackageError> {
    load_signed_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

pub fn load_signed_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<Package, PackageError> {
    let pkg = verify_envelope_with_key(envelope_json, pubkey_hex)?;
    if pkg.manifest.min_engine > ENGINE_VERSION {
        return Err(PackageError::EngineTooOld {
            needs: pkg.manifest.min_engine,
            have: ENGINE_VERSION,
        });
    }
    Ok(pkg)
}

fn cache_file(dir: &std::path::Path, id: &str) -> std::path::PathBuf {
    dir.join("skills").join(format!("{id}.json"))
}

/// 把**信封原文**写进缓存,文件名取包自己声明的 `manifest.id`。写之前先验签:
/// 缓存里只放验得过的东西,免得下次开机拿一份坏包去试。返回写进去的 id。
pub fn cache_store(dir: &std::path::Path, envelope_json: &str) -> Result<String, PackageError> {
    cache_store_with_key(dir, envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

pub fn cache_store_with_key(
    dir: &std::path::Path,
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<String, PackageError> {
    let pkg = load_signed_with_key(envelope_json, pubkey_hex)?;
    // id 会变成文件名 —— 它来自包体,包体来自网络,所以按路径分量校验一次。
    // 验签已经证明包是我们签的,这道闸是给「我们自己签了一个带斜杠的 id」兜底。
    if pkg.manifest.id.is_empty()
        || !pkg
            .manifest
            .id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    {
        return Err(PackageError::Malformed(format!(
            "包 id 只允许小写字母/数字/下划线,实际 {:?}",
            pkg.manifest.id
        )));
    }
    let path = cache_file(dir, &pkg.manifest.id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| PackageError::Malformed(format!("建缓存目录失败:{e}")))?;
    }
    std::fs::write(&path, envelope_json)
        .map_err(|e| PackageError::Malformed(format!("写缓存失败:{e}")))?;
    Ok(pkg.manifest.id)
}

/// 从缓存读回。**每次都重新验签** —— 缓存文件在用户可写的目录里,是不可信输入。
/// 任何失败(文件不在、验不过、引擎太老)一律 `None`:调用方的处置都一样
/// (没有包 = 不显示病程档案),不需要区分。
pub fn cache_load(dir: &std::path::Path, id: &str) -> Option<Package> {
    cache_load_with_key(dir, id, SIGNING_PUBLIC_KEY_HEX)
}

pub fn cache_load_with_key(
    dir: &std::path::Path,
    id: &str,
    pubkey_hex: &str,
) -> Option<Package> {
    let raw = std::fs::read_to_string(cache_file(dir, id)).ok()?;
    load_signed_with_key(&raw, pubkey_hex).ok()
}
```

`packages/profile/src/lib.rs` 的 `pub use` 里追加 `cache_load, cache_store, load_signed,`。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS(9 个测试)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): 引擎版本闸与包的本机缓存

缓存文件在用户可写目录里,是不可信输入:写前验、读回也验。
min_engine 比本二进制新就明确拒绝,不半加载。"
```

---

### Task 3: `skills/` 目录与签名脚本(私钥不进仓库)

**Files:**
- Create: `scripts/sign_skill.py`
- Create: `skills/README.md`
- Create: `skills/index.json`
- Modify: `packages/profile/src/package.rs`(`SIGNING_PUBLIC_KEY_HEX` 换成真实公钥)
- Create: `packages/profile/tests/repo_packages_verify.rs`

**Interfaces:**
- Consumes: Task 2 的 `profile::load_signed`
- Produces:
  - `python3 scripts/sign_skill.py --pubkey` → 打印 32 字节公钥 hex
  - `python3 scripts/sign_skill.py skills/<id>/<ver>.src.json` → 写出 `skills/<id>/<ver>.json`(信封)
  - `skills/index.json` 形状:`{"skills":[{"id","version","min_engine","name"}]}`

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/repo_packages_verify.rs`:

```rust
//! 仓库里每一个 `skills/<id>/<ver>.json` 都必须能用**编进二进制的生产公钥**验过签。
//!
//! 这条测试是签名这件事的唯一自动化保障:没有它,谁手改了一个字节、或者拿错
//! 私钥重签,都要等到真机上「包加载不出来」才发现。
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

fn signed_packages() -> Vec<PathBuf> {
    let skills = repo_root().join("skills");
    let mut out = Vec::new();
    let Ok(ids) = std::fs::read_dir(&skills) else {
        return out;
    };
    for id in ids.flatten().filter(|e| e.path().is_dir()) {
        for f in std::fs::read_dir(id.path()).unwrap().flatten() {
            let p = f.path();
            let name = p.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with(".json") && !name.ends_with(".src.json") {
                out.push(p);
            }
        }
    }
    out
}

#[test]
fn every_signed_package_in_the_repo_verifies_with_the_production_key() {
    let pkgs = signed_packages();
    for p in &pkgs {
        let raw = std::fs::read_to_string(p).unwrap();
        profile::load_signed(&raw)
            .unwrap_or_else(|e| panic!("{} 验签/加载失败:{e}", p.display()));
    }
    // 目录空也算过(C1 阶段还没有包内容),但一旦有文件就必须全过。
    eprintln!("verified {} signed package(s)", pkgs.len());
}

#[test]
fn index_json_lists_exactly_the_signed_packages_present() {
    let idx_path = repo_root().join("skills").join("index.json");
    let idx: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&idx_path).unwrap()).unwrap();
    let listed: Vec<(String, String)> = idx["skills"]
        .as_array()
        .expect("index.json 必须有 skills 数组")
        .iter()
        .map(|s| {
            (
                s["id"].as_str().unwrap().to_string(),
                s["version"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    let mut on_disk: Vec<(String, String)> = signed_packages()
        .iter()
        .map(|p| {
            (
                p.parent().unwrap().file_name().unwrap().to_string_lossy().to_string(),
                p.file_stem().unwrap().to_string_lossy().to_string(),
            )
        })
        .collect();
    let mut listed_sorted = listed.clone();
    listed_sorted.sort();
    on_disk.sort();
    assert_eq!(listed_sorted, on_disk, "index.json 与 skills/ 目录不一致");
}

#[test]
fn the_production_public_key_is_not_the_placeholder() {
    assert_ne!(
        profile::SIGNING_PUBLIC_KEY_HEX,
        "0000000000000000000000000000000000000000000000000000000000000000",
        "还是 Task 1 的占位公钥 —— 用 scripts/sign_skill.py --pubkey 换成真的"
    );
}
```

`packages/profile/Cargo.toml` 的 `[dev-dependencies]` 追加 `serde_json = { workspace = true }`。

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test repo_packages_verify`
Expected: FAIL — `index.json` 不存在(`No such file or directory`),且 `the_production_public_key_is_not_the_placeholder` 失败。

- [ ] **Step 3: 写脚本、生成密钥、落公钥**

`scripts/sign_skill.py`:

```python
#!/usr/bin/env python3
"""给病种 skill 包签名(Ed25519)。

私钥只在本机 `~/.medme_skill_signing_key`(64 个 hex 字符 = 32 字节 seed,
文件权限 600),**永远不进仓库、不进 CI、不进任何日志**。公钥编进 App
(`packages/profile/src/package.rs` 的 `SIGNING_PUBLIC_KEY_HEX`)。

首次使用:
    python3 scripts/sign_skill.py --gen-key      # 只在私钥文件不存在时生成
    python3 scripts/sign_skill.py --pubkey       # 打印公钥 hex,粘进 package.rs

签一个包:
    python3 scripts/sign_skill.py skills/sle/2026.09.1.src.json
        -> 写出 skills/sle/2026.09.1.json(信封),并刷新 skills/index.json
"""
import base64
import json
import os
import pathlib
import stat
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

KEY_PATH = pathlib.Path.home() / ".medme_skill_signing_key"
ROOT = pathlib.Path(__file__).resolve().parents[1]
SKILLS = ROOT / "skills"


def _load_key() -> Ed25519PrivateKey:
    if not KEY_PATH.exists():
        sys.exit(f"没有私钥 {KEY_PATH}。先跑 --gen-key(只在你是发布者时)。")
    return Ed25519PrivateKey.from_private_bytes(bytes.fromhex(KEY_PATH.read_text().strip()))


def gen_key() -> None:
    if KEY_PATH.exists():
        sys.exit(f"{KEY_PATH} 已存在 —— 不覆盖。轮换密钥要手动改名备份,别让脚本替你决定。")
    seed = os.urandom(32)
    KEY_PATH.write_text(seed.hex())
    KEY_PATH.chmod(stat.S_IRUSR | stat.S_IWUSR)
    print(f"已生成 {KEY_PATH}(权限 600)。公钥:")
    print_pubkey()


def print_pubkey() -> None:
    from cryptography.hazmat.primitives import serialization

    pub = _load_key().public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    print(pub.hex())


def refresh_index() -> None:
    skills = []
    for d in sorted(p for p in SKILLS.iterdir() if p.is_dir()):
        for f in sorted(d.glob("*.json")):
            if f.name.endswith(".src.json"):
                continue
            env = json.loads(f.read_text(encoding="utf-8"))
            m = json.loads(env["package"])["manifest"]
            skills.append(
                {"id": m["id"], "version": m["version"], "min_engine": m["min_engine"],
                 "name": m["display"]["name"]}
            )
    (SKILLS / "index.json").write_text(
        json.dumps({"skills": skills}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"index.json: {len(skills)} 个包")


def sign(src: pathlib.Path) -> None:
    if not src.name.endswith(".src.json"):
        sys.exit("输入必须是 <ver>.src.json(仓库里作者维护的那一份)")
    body = src.read_text(encoding="utf-8")
    manifest = json.loads(body)["manifest"]  # 先确认是合法 JSON 且有 manifest,再签
    out = src.with_name(src.name[: -len(".src.json")] + ".json")
    if out.stem != manifest["version"]:
        sys.exit(f"文件名 {out.stem} 与 manifest.version {manifest['version']} 不一致")
    sig = base64.b64encode(_load_key().sign(body.encode("utf-8"))).decode()
    out.write_text(
        json.dumps({"sig": sig, "package": body}, ensure_ascii=False), encoding="utf-8"
    )
    print(f"已签名 -> {out.relative_to(ROOT)}")
    refresh_index()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    arg = sys.argv[1]
    if arg == "--gen-key":
        gen_key()
    elif arg == "--pubkey":
        print_pubkey()
    else:
        sign(pathlib.Path(arg).resolve())
```

`skills/README.md`:

```markdown
# skills/ — 病种包(公开静态资源,不含任何用户数据)

`<id>/<version>.src.json` 是人写的包;`<id>/<version>.json` 是 `scripts/sign_skill.py`
签出来的信封,**它才是 `GET /v1/skills/{id}/{ver}.json` 实际返回的字节**。两份都进仓库。

改包内容的唯一流程:改 `.src.json` → `python3 scripts/sign_skill.py <那个文件>` →
`cargo test -p profile --test repo_packages_verify` 必须绿 → commit 两份 + index.json。

私钥在发布者本机 `~/.medme_skill_signing_key`,不在仓库、不在 CI。
App 里编死的是公钥(`packages/profile/src/package.rs::SIGNING_PUBLIC_KEY_HEX`)。
```

跑:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
mkdir -p skills
python3 scripts/sign_skill.py --gen-key   # 私钥不存在时才跑;已存在就跑 --pubkey
python3 scripts/sign_skill.py --pubkey
```

把打印出来的 64 位 hex 替换进 `packages/profile/src/package.rs` 的 `SIGNING_PUBLIC_KEY_HEX`(连同上面那条「Task 3 用真实公钥替换」的注释一并删掉)。

然后手写一个空的 `skills/index.json`(此时还没有包):

```json
{
  "skills": []
}
```

> 这份清单**本任务里还没有签名**。Task 27(排在 Task 4 之后)把它换成与包同一种
> 签名信封,并把下面那条 `index_json_lists_exactly_the_signed_packages_present`
> 改成验签版本 —— 在那之前的两个任务里,清单是裸 JSON。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。`repo_packages_verify` 里三个测试全绿(`skills/` 下还没有包,前两个测试对空集成立)。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && git status --porcelain | grep -c medme_skill_signing_key`
Expected: `0` —— 私钥不在工作树里。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add scripts/sign_skill.py skills/README.md skills/index.json packages/profile
git commit -m "feat(skills): 包签名脚本与 skills/ 目录约定

私钥只在 ~/.medme_skill_signing_key,仓库里只有公钥常量与签好的信封。
repo_packages_verify 测试钉住:仓库里每个签名包都能用生产公钥验过。"
```

---

### Task 4: `GET /v1/skills/index.json` 与 `/v1/skills/{id}/{ver}.json`

**Files:**
- Modify: `services/api/app.py:87-89`(`/health` 之后插入两条新路由)
- Modify: `services/api/test_api.py`(文件末尾追加测试)

**Interfaces:**
- Consumes: `skills/` 目录布局(Task 3)
- Produces:
  - `GET /v1/skills/index.json` → `skills/index.json` 原文,`Content-Type: application/json`,带 `ETag`
  - `GET /v1/skills/{skill_id}/{version}.json` → 签名信封原文,带 `ETag`
  - 两条都**无鉴权、不读任何账号头**;`If-None-Match` 命中返回 304

- [ ] **Step 1: 写失败测试**

追加到 `services/api/test_api.py` 末尾:

```python
# --- /v1/skills:无鉴权的公开静态包分发(disease-profile spec §8)-------------

def test_skills_index_needs_no_auth_and_lists_packages():
    r = client.get("/v1/skills/index.json")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/json")
    assert isinstance(r.json()["skills"], list)
    assert r.headers.get("etag")


def test_skills_index_honours_if_none_match():
    first = client.get("/v1/skills/index.json")
    etag = first.headers["etag"]
    again = client.get("/v1/skills/index.json", headers={"If-None-Match": etag})
    assert again.status_code == 304
    assert again.content == b""


def test_skills_route_never_reads_the_authorization_header():
    # 带一个**错的** bearer 也必须照样 200:这条路由不认账号,也就不可能把
    # 「你开启了哪个病」和账号关联起来(spec §8 的隐私前提)。
    r = client.get("/v1/skills/index.json", headers={"Authorization": "Bearer not-a-real-token"})
    assert r.status_code == 200


def test_skills_package_path_traversal_is_rejected():
    # id / version 都会拼进文件路径,是信任边界。放行任何 . 或 / 都是任意文件读。
    for sid, ver in [("..", "x"), ("sle", ".."), ("a/b", "x"), ("sle", "../../app")]:
        r = client.get(f"/v1/skills/{sid}/{ver}.json")
        assert r.status_code in (400, 404), f"{sid}/{ver} 竟然是 {r.status_code}"


def test_skills_unknown_package_is_404():
    assert client.get("/v1/skills/nosuchdisease/2026.09.1.json").status_code == 404


def test_skills_package_is_served_verbatim_when_present(tmp_path):
    import app as app_mod

    root = tmp_path / "skills"
    (root / "demo").mkdir(parents=True)
    body = '{"sig":"AA","package":"{}"}'
    (root / "demo" / "2026.09.1.json").write_text(body, encoding="utf-8")
    old = app_mod.SKILLS_DIR
    app_mod.SKILLS_DIR = root
    try:
        r = client.get("/v1/skills/demo/2026.09.1.json")
        assert r.status_code == 200
        assert r.text == body  # 逐字节原样,签名才验得过
        assert r.headers.get("etag")
    finally:
        app_mod.SKILLS_DIR = old
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -k skills -v`
Expected: FAIL — 6 个测试全部 404(路由不存在)。

- [ ] **Step 3: 实现**

`services/api/app.py`,在 `import` 段(第 10 行 `import auth, db, extract, oss` 之后)加:

```python
import hashlib
import pathlib

# 病种 skill 包的静态根目录(仓库 `skills/`)。这两条路由是本服务**唯一**不读
# 账号头的非 /health 路由:请求里没有账号、没有病种偏好,服务端因此看不出
# 谁开启了哪种病(disease-profile spec §8)。测试会把它换成 tmp 目录。
SKILLS_DIR = pathlib.Path(__file__).resolve().parents[2] / "skills"
_SKILL_ID = re.compile(r"[a-z0-9_]{1,32}")
_SKILL_VER = re.compile(r"[0-9]{4}\.[0-9]{2}\.[0-9]{1,3}")
```

在 `/health`(`app.py:87-89`)之后插入:

```python
def _static_json(path: pathlib.Path, request: Request) -> Response:
    """原样回一份 JSON 文件,带 ETag。**逐字节**——包体的签名就是对这些字节签的,
    任何重新序列化(键序/空白)都会让客户端验签失败。"""
    try:
        raw = path.read_bytes()
    except OSError:
        raise HTTPException(404, "not found")
    etag = '"' + hashlib.sha256(raw).hexdigest()[:32] + '"'
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers={"ETag": etag})
    return Response(
        content=raw,
        media_type="application/json",
        headers={"ETag": etag, "Cache-Control": "public, max-age=300"},
    )


@app.get("/v1/skills/index.json")
def skills_index(request: Request):
    """公开的包清单。无鉴权、无账号头。"""
    return _static_json(SKILLS_DIR / "index.json", request)


@app.get("/v1/skills/{skill_id}/{version}.json")
def skills_package(skill_id: str, version: str, request: Request):
    """公开的签名包。无鉴权、无账号头。

    `skill_id`/`version` 会拼进文件路径,是信任边界:用 `fullmatch` 白名单挡,
    不做 `..` 黑名单(黑名单挡不住 `%2e%2e`、Unicode 变体这类写法)。"""
    if not _SKILL_ID.fullmatch(skill_id) or not _SKILL_VER.fullmatch(version):
        raise HTTPException(400, "bad skill id or version")
    return _static_json(SKILLS_DIR / skill_id / f"{version}.json", request)
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -k skills -v`
Expected: PASS(6 个)。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -q`
Expected: 全绿 —— 新路由不能碰坏任何既有路由。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add services/api/app.py services/api/test_api.py
git commit -m "feat(api): GET /v1/skills/index.json 与 /v1/skills/{id}/{ver}.json

无鉴权、不读账号头(服务端因此看不出谁开启了哪个病),带 ETag,
文件原样回避免破坏签名。id/version 走白名单正则挡路径穿越。"
```

---

### Task 27: 清单也签名 + 客户端单调版本闸(防降级)

> 排在 Task 4 之后、C2 之前:Task 3/4 先把**未签名**的 `index.json` 跑通,本任务把它
> 换成同一种信封并加上防降级。之所以单独一个任务,是因为它有自己的评审面
> (信任边界 + 一个能拒装包的新失败模式),而不是 Task 4 的收尾。

**Files:**
- Modify: `packages/profile/src/package.rs`(抽出 `verify_envelope_body`;加 `Index`/`IndexEntry`/`load_signed_index`/`version_tuple`;给 `cache_store` 加单调闸与 `PackageError::Downgrade`)
- Modify: `packages/profile/src/lib.rs`(re-export)
- Modify: `scripts/sign_skill.py`(`refresh_index` 改成生成 `index.src.json` 并签成 `index.json`)
- Modify: `packages/profile/tests/repo_packages_verify.rs`(index 测试改读签名信封)
- Modify: `services/api/test_api.py`(`test_skills_index_needs_no_auth_and_lists_packages` 改读信封)
- Create: `skills/index.src.json`(由脚本生成)

**Interfaces:**
- Consumes: Task 1 的 `Envelope` / `verify_envelope_with_key` / `PackageError`;Task 2 的 `cache_store` / `cache_load`
- Produces:
  - `profile::verify_envelope_body(envelope_json: &str, pubkey_hex: &str) -> Result<String, PackageError>` —— 验签后返回**内层原文字符串**(包与清单共用这一半)
  - `profile::Index { skills: Vec<IndexEntry> }`,`profile::IndexEntry { id: String, version: String, min_engine: u32, name: String }`
  - `profile::load_signed_index(envelope_json: &str) -> Result<Index, PackageError>`
  - `profile::PackageError::Downgrade { have: String, offered: String }`
  - `cache_store` 行为变更:待装版本**低于**已缓存版本时返回 `Downgrade`,不写盘
- 版本形状:`YYYY.MM.N`(`N` 为 1–3 位十进制),按 `(u32,u32,u32)` 元组比较;形状不合就是 `Malformed`

> **单调的「见过的最高版本」存在哪:** 就是**已缓存的那个包自己的 `manifest.version`**。
> 不另开一个状态文件 —— 装包只会往前走,缓存里那份就是见过的最高版本,多一份记录就多
> 一处能和事实不一致的地方。
> `ponytail:` 缓存被整个抹掉(重装 App)会把下限重置。要挡这一手得把版本写进
> 设备钥匙串一类的持久位置;能抹掉应用沙盒的攻击者此时已经能做更多事,不为它加层。

- [ ] **Step 1: 写失败测试**

追加到 `packages/profile/src/package.rs` 的 `mod tests`:

```rust
    const INDEX_BODY: &str = r#"{"skills":[{"id":"t","version":"2026.09.2","min_engine":1,"name":"测试病"}]}"#;

    #[test]
    fn a_signed_index_parses() {
        let env = sign_with_test_key(INDEX_BODY);
        let idx = load_signed_index_with_key(&env, &test_pubkey_hex()).expect("清单要能验过");
        assert_eq!(idx.skills.len(), 1);
        assert_eq!(idx.skills[0].id, "t");
        assert_eq!(idx.skills[0].version, "2026.09.2");
        assert_eq!(idx.skills[0].min_engine, 1);
    }

    #[test]
    fn a_tampered_index_is_refused_so_nobody_can_redirect_the_client() {
        // 清单不签名的话,中间人改一个 version 就能把客户端引到任意路径,或者
        // 把新版本从清单里删掉让用户永远停在旧规则上。
        let env = sign_with_test_key(INDEX_BODY).replace("2026.09.2", "2026.09.1");
        assert!(matches!(
            load_signed_index_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::BadSignature)
        ));
    }

    #[test]
    fn an_unsigned_plain_index_is_refused() {
        // 老形状(裸 {"skills":[…]})不再接受 —— 不留「验不过就当没签」的后门。
        assert!(load_signed_index_with_key(INDEX_BODY, &test_pubkey_hex()).is_err());
    }

    #[test]
    fn version_tuple_orders_by_year_month_serial() {
        assert!(version_tuple("2026.09.2").unwrap() > version_tuple("2026.09.1").unwrap());
        assert!(version_tuple("2026.10.1").unwrap() > version_tuple("2026.09.9").unwrap());
        assert!(version_tuple("2027.01.1").unwrap() > version_tuple("2026.12.9").unwrap());
        // 字典序会把 "2026.09.10" 排在 "2026.09.9" 前面 —— 必须按数字比。
        assert!(version_tuple("2026.09.10").unwrap() > version_tuple("2026.09.9").unwrap());
        assert!(version_tuple("v2").is_none());
        assert!(version_tuple("2026.9.1").is_none(), "月份定宽两位");
    }

    #[test]
    fn installing_an_older_version_over_a_newer_one_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let newer = sign_with_test_key(&MINIMAL.replace("2026.09.1", "2026.09.2"));
        cache_store_with_key(dir.path(), &newer, &test_pubkey_hex()).unwrap();

        let older = sign_with_test_key(MINIMAL); // 2026.09.1,签名合法,只是旧
        match cache_store_with_key(dir.path(), &older, &test_pubkey_hex()) {
            Err(PackageError::Downgrade { have, offered }) => {
                assert_eq!(have, "2026.09.2");
                assert_eq!(offered, "2026.09.1");
            }
            other => panic!("应当拒绝降级,实际 {other:?}"),
        }
        // 缓存里仍是新的那份,没被旧包覆盖。
        assert_eq!(
            cache_load_with_key(dir.path(), "t", &test_pubkey_hex()).unwrap().manifest.version,
            "2026.09.2"
        );
    }

    #[test]
    fn reinstalling_the_same_version_is_allowed() {
        // 刷新/修缓存是常规操作,不能被单调闸拦住。
        let dir = tempfile::tempdir().unwrap();
        let env = sign_with_test_key(MINIMAL);
        cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).unwrap();
        assert!(cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).is_ok());
    }

    #[test]
    fn a_newer_version_installs_normally() {
        let dir = tempfile::tempdir().unwrap();
        cache_store_with_key(dir.path(), &sign_with_test_key(MINIMAL), &test_pubkey_hex()).unwrap();
        let newer = sign_with_test_key(&MINIMAL.replace("2026.09.1", "2026.10.1"));
        cache_store_with_key(dir.path(), &newer, &test_pubkey_hex()).unwrap();
        assert_eq!(
            cache_load_with_key(dir.path(), "t", &test_pubkey_hex()).unwrap().manifest.version,
            "2026.10.1"
        );
    }
```

改 `packages/profile/tests/repo_packages_verify.rs` 的 `index_json_lists_exactly_the_signed_packages_present`:

```rust
#[test]
fn index_json_is_signed_and_lists_exactly_the_signed_packages_present() {
    let raw = std::fs::read_to_string(repo_root().join("skills").join("index.json")).unwrap();
    let idx = profile::load_signed_index(&raw).expect("清单必须用生产公钥验过");
    let mut listed: Vec<(String, String)> =
        idx.skills.iter().map(|s| (s.id.clone(), s.version.clone())).collect();
    let mut on_disk: Vec<(String, String)> = signed_packages()
        .iter()
        .map(|p| (
            p.parent().unwrap().file_name().unwrap().to_string_lossy().to_string(),
            p.file_stem().unwrap().to_string_lossy().to_string(),
        ))
        .collect();
    listed.sort();
    on_disk.sort();
    assert_eq!(listed, on_disk, "index.json 与 skills/ 目录不一致");
}
```

改 `services/api/test_api.py` 的清单测试:

```python
def test_skills_index_needs_no_auth_and_is_a_signed_envelope():
    r = client.get("/v1/skills/index.json")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/json")
    env = r.json()
    # 路由只管原样发字节;验签是客户端的事。这里只钉住形状没退回裸清单。
    assert set(env) == {"sig", "package"}
    assert isinstance(json.loads(env["package"])["skills"], list)
    assert r.headers.get("etag")
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: FAIL — `cannot find function 'load_signed_index_with_key'`。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -k skills_index -v`
Expected: FAIL — 当前 `index.json` 还是裸清单,`set(env) == {"sig","package"}` 不成立。

- [ ] **Step 3: 实现**

`packages/profile/src/package.rs`:把 Task 1 的 `verify_envelope_with_key` 拆成两半,
公开取字节的那一半(包与清单共用同一种信封,只有内层解析不同):

```rust
/// 验签,返回**内层原文字符串**。包和清单共用这一半 —— 两者是同一种信封,
/// 区别只在内层解析成什么。
pub fn verify_envelope_body(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<String, PackageError> {
    use base64::Engine as _;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};

    let env: Envelope = serde_json::from_str(envelope_json)
        .map_err(|e| PackageError::Malformed(format!("信封解析失败:{e}")))?;
    let sig_bytes = base64::engine::general_purpose::STANDARD
        .decode(env.sig.as_bytes())
        .map_err(|e| PackageError::Malformed(format!("签名不是合法 base64:{e}")))?;
    let sig_arr: [u8; 64] = sig_bytes
        .try_into()
        .map_err(|_| PackageError::Malformed("签名不是 64 字节".into()))?;
    let key_bytes = hex_decode_32(pubkey_hex)
        .ok_or_else(|| PackageError::Malformed("公钥不是 32 字节 hex".into()))?;
    let vk = VerifyingKey::from_bytes(&key_bytes)
        .map_err(|e| PackageError::Malformed(format!("公钥不是合法 Ed25519 点:{e}")))?;
    vk.verify_strict(env.package.as_bytes(), &Signature::from_bytes(&sig_arr))
        .map_err(|_| PackageError::BadSignature)?;
    Ok(env.package)
}

pub fn verify_envelope_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<Package, PackageError> {
    let body = verify_envelope_body(envelope_json, pubkey_hex)?;
    serde_json::from_str(&body)
        .map_err(|e| PackageError::Malformed(format!("包体解析失败:{e}")))
}

/// 分发清单。与包一样签名 —— 不签的话中间人能把新版本从清单里删掉(把用户按在
/// 旧规则上),或者把 `version` 改成一个任意串去拼路径。
#[derive(Debug, Clone, Deserialize)]
pub struct IndexEntry {
    pub id: String,
    pub version: String,
    pub min_engine: u32,
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Index {
    pub skills: Vec<IndexEntry>,
}

pub fn load_signed_index(envelope_json: &str) -> Result<Index, PackageError> {
    load_signed_index_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

pub fn load_signed_index_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<Index, PackageError> {
    let body = verify_envelope_body(envelope_json, pubkey_hex)?;
    serde_json::from_str(&body)
        .map_err(|e| PackageError::Malformed(format!("清单解析失败:{e}")))
}

/// `YYYY.MM.N` → 可比较的元组。**必须按数字比**:字典序会把 `2026.09.10` 排在
/// `2026.09.9` 前面,单调闸就成了反向的。形状不对返回 `None`(调用方按 `Malformed` 处理)。
pub fn version_tuple(v: &str) -> Option<(u32, u32, u32)> {
    let mut it = v.split('.');
    let (y, m, n) = (it.next()?, it.next()?, it.next()?);
    if it.next().is_some() || y.len() != 4 || m.len() != 2 || n.is_empty() || n.len() > 3 {
        return None;
    }
    Some((y.parse().ok()?, m.parse().ok()?, n.parse().ok()?))
}
```

`PackageError` 加变体与文案:

```rust
    /// 待装的版本比已经装过的**低**。签名是合法的(确实是我们签的),但这是
    /// 降级 —— 中间人重放一个旧包就能把用户按在过时的规则上。不装。
    Downgrade { have: String, offered: String },
```
```rust
            PackageError::Downgrade { have, offered } => {
                write!(f, "拒绝降级:已有 {have},送来的是更旧的 {offered}")
            }
```

`cache_store_with_key` 在写盘之前、id 校验之后插入单调闸:

```rust
    let offered = version_tuple(&pkg.manifest.version)
        .ok_or_else(|| PackageError::Malformed(format!("版本号形状不对:{}", pkg.manifest.version)))?;
    // 「见过的最高版本」就是缓存里那份自己的版本 —— 装包只会往前走,不另存状态。
    if let Some(cur) = cache_load_with_key(dir, &pkg.manifest.id, pubkey_hex) {
        if let Some(have) = version_tuple(&cur.manifest.version) {
            if offered < have {
                return Err(PackageError::Downgrade {
                    have: cur.manifest.version,
                    offered: pkg.manifest.version,
                });
            }
        }
    }
```

`packages/profile/src/lib.rs` 的 `pub use` 追加 `load_signed_index, verify_envelope_body, version_tuple, Index, IndexEntry,`。

`scripts/sign_skill.py` 的 `refresh_index` 改成先写 `index.src.json` 再签成 `index.json`:

```python
def refresh_index() -> None:
    skills = []
    for d in sorted(p for p in SKILLS.iterdir() if p.is_dir()):
        for f in sorted(d.glob("*.json")):
            if f.name.endswith(".src.json"):
                continue
            env = json.loads(f.read_text(encoding="utf-8"))
            m = json.loads(env["package"])["manifest"]
            skills.append(
                {"id": m["id"], "version": m["version"], "min_engine": m["min_engine"],
                 "name": m["display"]["name"]}
            )
    # 清单与包用**同一种信封**、同一把私钥:不签的话中间人删掉一行就能把用户
    # 按在旧规则上,改一行 version 就能拿它去拼任意路径。
    body = json.dumps({"skills": skills}, ensure_ascii=False, indent=2) + "\n"
    (SKILLS / "index.src.json").write_text(body, encoding="utf-8")
    sig = base64.b64encode(_load_key().sign(body.encode("utf-8"))).decode()
    (SKILLS / "index.json").write_text(
        json.dumps({"sig": sig, "package": body}, ensure_ascii=False), encoding="utf-8"
    )
    print(f"index.json: {len(skills)} 个包(已签名)")
```

`sign()` 里 `refresh_index()` 的调用位置不变。另外加一个 `--reindex` 入口(只重签清单,
不动任何包),供「删了一个包之后刷新清单」用。

重新生成(此刻 `skills/` 还是空的,清单是 `{"skills": []}` 的签名信封):

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
python3 scripts/sign_skill.py --reindex
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS(新增 7 条 + 既有全部)。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -q`
Expected: 全绿。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && python3 -c "import json;e=json.load(open('skills/index.json'));print(sorted(e))"`
Expected: `['package', 'sig']`。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile scripts/sign_skill.py services/api/test_api.py skills
git commit -m "feat(skills): 清单也签名,客户端拒绝降级

不签清单的话中间人删掉一行就能把用户按在旧规则上。清单与包用同一种信封、
同一把私钥。装包时按 YYYY.MM.N 的数字元组比版本,低于缓存里那份就拒装
(字典序会把 2026.09.10 排在 2026.09.9 前面,必须按数字比)。"
```
---

## C2 — 抽取 schema 2(族级 facts)

### Task 5: `deid` 的 `Fact` 类型与 `Extraction.facts`

**Files:**
- Modify: `packages/deid/src/verify.rs:46-62`(`Extraction` 结构体加 `facts`;上方加 `Fact` 类型)
- Modify: `packages/deid/src/lib.rs:14`(`pub use verify::{…}` 里加 `Fact`)

**Interfaces:**
- Produces:
  - `deid::Fact { r#type: String, organ: String, date: String, date_start: String, date_end: String, text: String, reason: String, result: String, drug: String, dose: String, from: String, to: String, name: String, value: String, modality: String, finding: String, status: String, evidence: String, unverified: bool }` —— **一个扁平结构覆盖 spec §3 的全部 12 种 `type`**,缺席字段是空串(与 `LabItem`/`MedItem` 同一约定:`#[serde(default)]` + 空串表示「这份没有」)
  - `deid::Extraction.facts: Vec<Fact>`,`#[serde(default)]` —— schema 1 的老 JSON 照样解析成 `facts: []`
- Consumes: 无(本任务不改 `verify()`,那是 Task 6)

> **为什么是一个扁平结构而不是 12 个 enum 变体:** 这些字段全是**原文逐字的字符串**,
> 校验规则对每个字段完全一样(Task 6),消费方(`packages/profile`)按 `type` 取自己
> 关心的那几个。12 个变体 = 12 份 serde 派生 + 12 个校验分支 + 模型多吐一个没见过的
> `type` 就整条解析失败。扁平结构让未知 `type` 原样穿过、由消费方忽略。

- [ ] **Step 1: 写失败测试**

追加到 `packages/deid/src/verify.rs` 的 `mod tests`:

```rust
    #[test]
    fn schema_one_json_still_parses_and_yields_no_facts() {
        // 老 App 发 schema 1,老保险箱里躺着 schema 1 的结果 —— 加了 facts 之后
        // 它们必须照样解析,而不是整条抽取变成解析失败。
        let old = r#"{"doc_type":"lab","doc_date":"2026-01-01","labs":[],"meds":[],
                      "diagnoses":[],"impression":"","notes":""}"#;
        let e = parse_extraction(old).expect("schema 1 必须继续解析");
        assert!(e.facts.is_empty());
    }

    #[test]
    fn facts_parse_with_only_the_fields_that_type_uses() {
        let j = r#"{"labs":[],"facts":[
            {"type":"organ_involvement","organ":"kidney","date":"2024-03-02",
             "text":"狼疮性肾炎 IV 型","evidence":"狼疮性肾炎 IV 型"},
            {"type":"dose_change","drug":"泼尼松","from":"30mg","to":"20mg",
             "date":"2024-06-01","evidence":"泼尼松减至 20mg"},
            {"type":"hospitalization","date_start":"2024-03-01","date_end":"2024-03-12",
             "reason":"狼疮活动","evidence":"因狼疮活动收入院"}]}"#;
        let e = parse_extraction(j).expect("facts 必须解析");
        assert_eq!(e.facts.len(), 3);
        assert_eq!(e.facts[0].r#type, "organ_involvement");
        assert_eq!(e.facts[0].organ, "kidney");
        assert_eq!(e.facts[0].text, "狼疮性肾炎 IV 型");
        assert_eq!(e.facts[1].drug, "泼尼松");
        assert_eq!(e.facts[1].from, "30mg");
        assert_eq!(e.facts[1].to, "20mg");
        assert_eq!(e.facts[2].date_start, "2024-03-01");
        assert_eq!(e.facts[2].date_end, "2024-03-12");
        // 这一族没用到的字段一律空串,不是 None、不是缺席。
        assert_eq!(e.facts[0].drug, "");
        assert!(!e.facts[0].unverified);
    }

    #[test]
    fn an_unknown_fact_type_survives_parsing_instead_of_failing_the_document() {
        // 服务端的 prompt 可以先于 App 加新 type。老 App 必须能把整份抽取收下来
        // (labs 照常入库),只是忽略认不出的那一条 —— 不能整份丢掉。
        let j = r#"{"labs":[],"facts":[{"type":"something_new_2027","text":"x","evidence":"x"}]}"#;
        let e = parse_extraction(j).expect("未知 type 不该让解析失败");
        assert_eq!(e.facts[0].r#type, "something_new_2027");
    }
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p deid`
Expected: FAIL — `no field 'facts' on type 'Extraction'`。

- [ ] **Step 3: 实现**

`packages/deid/src/verify.rs`,在 `DiagnosisItem`(第 37-45 行)之后插入:

```rust
/// 一条**族级病程事实**(spec §3,schema 2)。类型枚举是免疫介导慢病族共用的,
/// 服务端从 prompt 看不出用户是哪个病。
///
/// 扁平结构,不是 12 个变体:所有字段都是**原文逐字字符串**,校验规则完全一样,
/// 消费方按 `type` 取自己关心的那几个。未知 `type` 原样穿过(服务端 prompt 可以
/// 先于 App 加新类型,老 App 忽略它,而不是整份抽取解析失败)。
///
/// `evidence` 必须是原文逐字子串,与 labs 同一套 `verify`(见 [`verify`])。
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Fact {
    /// `organ_involvement|flare|hospitalization|biopsy|infusion|dose_change|scale|
    /// imaging_finding|infection|pregnancy|vaccination|exam_done`,或任何将来的新值。
    #[serde(rename = "type", default)]
    pub r#type: String,
    #[serde(default)]
    pub organ: String,
    #[serde(default)]
    pub date: String,
    #[serde(default)]
    pub date_start: String,
    #[serde(default)]
    pub date_end: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub result: String,
    #[serde(default)]
    pub drug: String,
    #[serde(default)]
    pub dose: String,
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub modality: String,
    #[serde(default)]
    pub finding: String,
    #[serde(default)]
    pub status: String,
    /// 原文逐字子串。图片档验不过时本条标 `unverified`,界面标「需核对」。
    #[serde(default)]
    pub evidence: String,
    /// 与 `LabItem::unverified` 同一约定:**不在 prompt schema 里**,由 [`verify`] 盖章。
    #[serde(default)]
    pub unverified: bool,
}
```

`Extraction`(第 46-62 行)末尾、`notes` 之后加:

```rust
    /// schema 2 的族级病程事实。schema 1 的 JSON 里没有这个键 → 空 Vec。
    #[serde(default)]
    pub facts: Vec<Fact>,
```

`packages/deid/src/lib.rs:14` 的 `pub use verify::{` 列表里加 `Fact,`(按字母序放在 `Extraction` 之后)。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p deid`
Expected: PASS。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test --workspace`
Expected: 全绿 —— `Extraction` 多一个 `#[serde(default)]` 字段不该影响任何既有构造点(现有代码都用 `..Default::default()` 或全字段字面量;若有全字段字面量报错,补 `facts: Vec::new()`)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/deid
git commit -m "feat(deid): schema 2 的族级 facts 类型

扁平结构而非 12 个变体:字段全是原文逐字字符串、校验规则一致,且未知
type 能原样穿过(服务端 prompt 可先于 App 加类型)。schema 1 的老 JSON
照常解析成 facts: []。"
```

---

### Task 6: `deid::verify` 把逐字校验扩到 facts

**Files:**
- Modify: `packages/deid/src/verify.rs:657-661`(`e.diagnoses.retain_mut` 之后插入 facts 分支)

**Interfaces:**
- Consumes: Task 5 的 `deid::Fact`;既有的 `field_ok(&str, &Src, Mode, FieldKind) -> bool` 与闭包 `keep(ok, &mut bool) -> bool`(`verify.rs:615-628`)
- Produces: `verify()` 返回的 `Verified.extraction.facts` 里,文本档验不过的整条丢弃(`rejected += 1`),图片档整条标 `unverified`(`unverified += 1`)—— 与 labs/meds/diagnoses 完全同一处置

- [ ] **Step 1: 写失败测试**

追加到 `packages/deid/src/verify.rs` 的 `mod tests`:

```rust
    const FACT_SRC: &str = "出院诊断:系统性红斑狼疮 狼疮性肾炎 IV 型\n泼尼松减至 20mg qd";

    fn fact(t: &str, text: &str, evidence: &str) -> Fact {
        Fact { r#type: t.into(), text: text.into(), evidence: evidence.into(), ..Default::default() }
    }

    #[test]
    fn text_mode_drops_a_fact_whose_evidence_is_not_in_the_source() {
        let e = Extraction {
            facts: vec![
                fact("organ_involvement", "狼疮性肾炎 IV 型", "狼疮性肾炎 IV 型"),
                fact("flare", "病情活动加重", "患者病情明显加重需大剂量激素"), // 原文没有
            ],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Text);
        assert_eq!(v.extraction.facts.len(), 1);
        assert_eq!(v.extraction.facts[0].r#type, "organ_involvement");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn image_mode_keeps_the_fact_but_marks_it_unverified() {
        let e = Extraction {
            facts: vec![fact("flare", "病情活动加重", "患者病情明显加重需大剂量激素")],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Image);
        assert_eq!(v.extraction.facts.len(), 1);
        assert!(v.extraction.facts[0].unverified);
        assert_eq!(v.unverified, 1);
    }

    #[test]
    fn every_string_field_of_a_fact_is_checked_not_just_evidence() {
        // `drug`/`from`/`to` 直接决定界面上「泼尼松 30mg → 20mg」这句话。
        // 只查 evidence、放任其它字段,等于让模型在这几个字段上自由发挥。
        let e = Extraction {
            facts: vec![Fact {
                r#type: "dose_change".into(),
                drug: "泼尼松".into(),
                from: "30mg".into(), // 原文里没有 30mg
                to: "20mg".into(),
                evidence: "泼尼松减至 20mg".into(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Text);
        assert!(v.extraction.facts.is_empty(), "from 对不上原文,整条应当丢弃");
        assert_eq!(v.rejected, 1);
    }

    #[test]
    fn an_empty_field_is_not_a_verification_failure() {
        // 扁平结构里绝大多数字段对某一族是空的,空串必须恒过 —— 否则每条 fact 都被毙。
        let e = Extraction {
            facts: vec![fact("organ_involvement", "狼疮性肾炎 IV 型", "狼疮性肾炎 IV 型")],
            ..Default::default()
        };
        let v = verify(e, FACT_SRC, Mode::Text);
        assert_eq!(v.extraction.facts.len(), 1);
        assert_eq!(v.rejected, 0);
    }
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p deid verify::tests`
Expected: FAIL — `text_mode_drops_a_fact_whose_evidence_is_not_in_the_source` 得到 2 条(facts 目前原样穿过,一条没查)。

- [ ] **Step 3: 实现**

`packages/deid/src/verify.rs`,在 `e.diagnoses.retain_mut(...)`(第 657-661 行)之后、`Verified { … }` 之前插入:

```rust
    // 族级病程事实(spec §3):与 labs/meds/diagnoses 同一套逐字校验,**每个字符串
    // 字段都查**,不是只查 `evidence` —— `drug`/`from`/`to`/`value` 会直接印到界面上
    // 「泼尼松 30mg → 20mg」这句话里,放任它们就是让模型在最要命的地方自由发挥。
    // `FieldKind::Text` 对所有字段:日期、器官、剂量在原文里都是印出来的文本,没有
    // labs 那种「数值/单位/标志」的分型需求。空串由 `field_ok` 恒过(见其文档)。
    e.facts.retain_mut(|f| {
        let ok = [
            &f.organ, &f.date, &f.date_start, &f.date_end, &f.text, &f.reason, &f.result,
            &f.drug, &f.dose, &f.from, &f.to, &f.name, &f.value, &f.modality, &f.finding,
            &f.status, &f.evidence,
        ]
        .into_iter()
        .all(|s| field_ok(s, &src, mode, FieldKind::Text));
        keep(ok, &mut f.unverified)
    });
```

> 确认 `field_ok` 对空串返回 `true`(既有行为:`LabItem` 的 `ref_low`/`flag` 经常是空串
> 且现在就不被毙)。若不是,在 `field_ok` 入口加 `if s.is_empty() { return true; }`,
> 并为该改动补一条 labs 侧的回归测试。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p deid`
Expected: PASS(含既有 `tests/verify_tolerant.rs`)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/deid
git commit -m "test+feat(deid): facts 走与 labs 同一套逐字校验

每个字符串字段都查,不是只查 evidence —— drug/from/to 会原样印到界面上。
文本档验不过整条丢,图片档标 unverified,与既有三族处置一致。"
```

---

### Task 7: `extract_v2_system.txt` + 参数文件改名 + `services/api` 接受 `schema:2`

**Files:**
- Create: `packages/deid/prompts/extract_v2_system.txt`
- Rename: `packages/deid/prompts/extract_v1_params.json` → `packages/deid/prompts/extract_params.json`
- Modify: `services/api/extract.py:12-16`(读两份 system prompt)、`:41-42`(参数文件名)、`:82`(schema 闸)、`:99`(按 schema 选 prompt)
- Modify: `packages/ocr/examples/medrep_llm.rs:38-45`(`include_str!` 路径 + 新增 v2 常量)
- Modify: `services/api/test_api.py:717-726`(prompt 一致性测试扩到 v2 与参数文件)

**Interfaces:**
- Consumes: Task 5 的 `deid::Fact` 字段名(prompt 里的 JSON 键必须与之逐字一致)
- Produces:
  - `extract.SYSTEM_PROMPT_V2`(Python)/ `SYSTEM_V2`(Rust)
  - `POST /v1/extract` 接受 `schema ∈ {1, 2}`;`schema:1` 行为逐字节不变
  - 请求参数文件 `extract_params.json`(内容不变,只改名,两个臂共用)

- [ ] **Step 1: 写失败测试**

替换 `services/api/test_api.py:717-726` 的 `test_extract_system_prompt_matches_eval_fixture`,并在其后追加:

```python
def test_extract_system_prompt_matches_eval_fixture():
    # 两边(这里的代理 + 评测臂 packages/ocr/examples/medrep_llm.rs)必须发同一段
    # prompt 给 DeepSeek,否则线上抽取和评测数字量的不是同一个模型行为。
    import extract
    prompts_dir = os.path.join(os.path.dirname(extract.__file__), "..", "..", "packages", "deid", "prompts")
    with open(os.path.join(prompts_dir, "extract_v1_system.txt"), encoding="utf-8") as f:
        assert extract.SYSTEM_PROMPT_V1 == f.read()
    with open(os.path.join(prompts_dir, "extract_v2_system.txt"), encoding="utf-8") as f:
        assert extract.SYSTEM_PROMPT_V2 == f.read()
    with open(os.path.join(prompts_dir, "extract_v1_image_user.txt"), encoding="utf-8") as f:
        assert extract.IMAGE_USER_TEXT == f.read()
    with open(os.path.join(prompts_dir, "extract_params.json"), encoding="utf-8") as f:
        assert extract.REQUEST_PARAMS == json.load(f)


def test_extract_v2_prompt_names_every_fact_field_the_rust_type_has():
    # prompt 里的键和 deid::Fact 的字段名对不上,模型吐出来的东西就静默丢字段。
    import extract
    for key in ["organ_involvement", "flare", "hospitalization", "biopsy", "infusion",
                "dose_change", "scale", "imaging_finding", "infection", "pregnancy",
                "vaccination", "exam_done", "evidence", "date_start", "date_end"]:
        assert key in extract.SYSTEM_PROMPT_V2, key
    # 族级:prompt 里不许出现任何具体病名 —— 服务端看不出用户是哪个病(spec §8)。
    for banned in ["红斑狼疮", "SLE", "多发性硬化", "重症肌无力", "IBD", "NMOSD"]:
        assert banned not in extract.SYSTEM_PROMPT_V2, banned


def test_extract_rejects_schema_three_but_accepts_one_and_two(monkeypatch):
    import extract
    seen = {}

    def fake(arm, model, messages):
        seen["system"] = messages[0]["content"]
        return {"choices": [{"finish_reason": "stop", "message": {"content": "{}"}}], "usage": {}}

    monkeypatch.setattr(extract, "_call_deepseek", fake)
    extract.run({"mode": "text", "schema": 1, "payload": "x"})
    assert seen["system"] == extract.SYSTEM_PROMPT_V1
    extract.run({"mode": "text", "schema": 2, "payload": "x"})
    assert seen["system"] == extract.SYSTEM_PROMPT_V2
    for bad in (3, 0, "2", None):
        with pytest.raises(extract.SchemaError):
            extract.run({"mode": "text", "schema": bad, "payload": "x"})


def test_extract_route_accepts_schema_two(monkeypatch):
    import extract
    monkeypatch.setattr(extract, "run", lambda body: ({"labs": [], "facts": []}, 1, 1))
    r = client.post("/v1/extract", json={"mode": "text", "schema": 2, "payload": "x"},
                    headers=_extract_auth())
    assert r.status_code == 200
    assert r.json()["facts"] == []
```

> `_extract_auth()` 用文件里既有的那套 extract 鉴权 helper(见同文件里已有的 `/v1/extract`
> 测试);若名字不同,照抄那些测试用的写法,不要新造。

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -k "extract_v2 or schema_three or schema_two or system_prompt" -v`
Expected: FAIL — `AttributeError: module 'extract' has no attribute 'SYSTEM_PROMPT_V2'`。

- [ ] **Step 3: 实现**

`packages/deid/prompts/extract_v2_system.txt`(单行,与 v1 同一体例;在 v1 的 schema 后面追加 `facts`):

```
你是病历结构化助手。只输出一个 JSON 对象,所有字符串必须逐字取自原文,不得改写、不得推断、不得做单位换算;原文没有的字段留空字符串。输出 schema:{"doc_type":"lab|discharge|outpatient|imaging|prescription|other","doc_date":"YYYY-MM-DD","labs":[{"name":"","value":"","unit":"","ref_low":"","ref_high":"","flag":"H|L|"}],"meds":[{"name":"","dose":"","freq":"","route":""}],"diagnoses":[{"text":"","icd":""}],"impression":"","notes":"","facts":[{"type":"organ_involvement","organ":"kidney|blood|skin|joint|cns|serosa|lung|gi|eye|other","date":"","text":"","evidence":""},{"type":"flare","date":"","text":"","evidence":""},{"type":"hospitalization","date_start":"","date_end":"","reason":"","evidence":""},{"type":"biopsy","organ":"","date":"","result":"","evidence":""},{"type":"infusion","drug":"","dose":"","date":"","evidence":""},{"type":"dose_change","drug":"","from":"","to":"","date":"","evidence":""},{"type":"scale","name":"SLEDAI|PGA|EDSS|MG-ADL|Mayo|BILAG|other","value":"","date":"","evidence":""},{"type":"imaging_finding","modality":"MRI|CT|OCT|DXA|US|endoscopy","finding":"","date":"","evidence":""},{"type":"infection","date":"","text":"","evidence":""},{"type":"pregnancy","status":"planning|pregnant|postpartum","date":"","evidence":""},{"type":"vaccination","name":"","date":"","evidence":""},{"type":"exam_done","name":"","date":"","evidence":""}]}。facts 只收原文明确写出来的事件,每条的 evidence 必须是原文里的一段连续原话;原文没提的事件不要生成。facts 里只放上面列出的字段,不要新增键。
```

`services/api/extract.py` 改四处:

```python
# 第 13-16 行之后补一份 v2(v1 那两行不动)
with open(os.path.join(_PROMPTS_DIR, "extract_v2_system.txt"), encoding="utf-8") as _f:
    SYSTEM_PROMPT_V2 = _f.read()
```

```python
# 第 41 行:参数文件改名(text/image 两条臂共用,与 schema 无关 —— 截断风险取决于
# 输入是图还是文本,不取决于输出 schema)
with open(os.path.join(_PROMPTS_DIR, "extract_params.json"), encoding="utf-8") as _f:
    REQUEST_PARAMS = json.load(_f)
```

```python
# 第 81-83 行:schema 闸从「必须是 1」改成「1 或 2」,并据此选 prompt
def run(body: dict) -> tuple[dict, int, int]:
    mode = body.get("mode", "text")
    schema = body.get("schema")
    # 老 App 发 1、新 App 发 2,两条都在线;3 和别的形状照旧 400。
    # `is` 比较避开 True == 1 这个 Python 陷阱(bool 是 int 的子类)。
    if schema is not True and schema == 1:
        system_prompt = SYSTEM_PROMPT_V1
    elif schema is not True and schema == 2:
        system_prompt = SYSTEM_PROMPT_V2
    else:
        raise SchemaError("schema")
```

```python
# 第 99 行:用选中的 prompt
        out = _call_deepseek(arm, model, [{"role": "system", "content": system_prompt},
                                          {"role": "user", "content": content}])
```

`packages/ocr/examples/medrep_llm.rs:38-45` 三处 `include_str!`:

```rust
const SYSTEM: &str = include_str!("../../deid/prompts/extract_v1_system.txt");
/// schema 2(族级 facts)。评测臂按 `--schema` 选,与线上代理选的是同一份文件。
const SYSTEM_V2: &str = include_str!("../../deid/prompts/extract_v2_system.txt");
const IMAGE_USER_TEXT: &str = include_str!("../../deid/prompts/extract_v1_image_user.txt");
```

并把该文件里读 `extract_v1_params.json` 的那处 `include_str!`/路径常量改成 `extract_params.json`(grep `extract_v1_params` 找全部出现点,一个不漏)。

改名:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git mv packages/deid/prompts/extract_v1_params.json packages/deid/prompts/extract_params.json
grep -rn "extract_v1_params" . --include=*.py --include=*.rs --include=*.md
```

最后一条 grep 必须**没有输出**才算改完。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -q`
Expected: 全绿。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo build --release -p ocr --example medrep_llm --features engine,testing`
Expected: 编译成功(路径改对了)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/deid/prompts services/api packages/ocr/examples/medrep_llm.rs
git commit -m "feat(extract): schema 2 族级 prompt,代理与评测臂共用同一份文件

prompt 里没有任何具体病名(服务端看不出用户是哪个病)。参数文件改名
extract_params.json:截断风险取决于输入是图还是文本,与输出 schema 无关。
schema 1 的行为逐字节不变,老 App 照旧。"
```

---

### Task 8: `NewExtraction.schema` 透传 + MedRepBench 回归门

**Files:**
- Modify: `packages/core-model/src/types.rs:193-199`(`NewExtraction` 加 `schema: i32`)、`:356`(不再写死 `1`)
- Modify: `apps/mobile_flutter/rust/src/api/vault.rs` —— `vault_cloud_commit_extraction`
  里那处 `core_model::NewExtraction { … }` 构造点(**按符号找,别照行号**:
  `grep -n "NewExtraction" apps/mobile_flutter/rust/src/api/vault.rs`)
- Modify: `packages/core-model/src/materialize.rs:853,861` 与 `packages/core-model/src/sync_io.rs:389`(测试里的构造点补字段)
- Modify: `packages/ocr/examples/medrep_llm.rs`(新增 `--schema` 参数)
- Create: `docs/log/2026-09-16-schema2-medrepbench-regression.md`

**Interfaces:**
- Consumes: Task 7 的 `SYSTEM_V2`
- Produces:
  - `core_model::NewExtraction { document_id: i64, backend: String, model_version: String, mode: String, schema: i32, result_json: String }`
  - `medrep_llm --schema 1|2`(默认 1)
- 回归门(spec §9):schema 2 在 MedRepBench 上,**项目召回 / 值-名配对 / 参考区间归属**三条指标都不得比 schema 1 低 1 个百分点以上

- [ ] **Step 1: 写失败测试**

追加到 `packages/core-model/src/materialize.rs` 的 `mod tests`:

```rust
    #[test]
    fn extraction_schema_is_carried_from_the_caller_not_hardcoded() {
        let (v, doc) = extraction_fixture(); // 既有 helper(见本 mod 里已有的抽取测试)
        v.add_extraction(NewExtraction {
            document_id: doc.id,
            backend: "deepseek".into(),
            model_version: "m".into(),
            mode: "text".into(),
            schema: 2,
            result_json: r#"{"labs":[],"facts":[]}"#.into(),
        })
        .unwrap();
        let got: i32 = v
            .conn()
            .query_row("SELECT schema FROM extraction WHERE document_id=?1", [doc.id], |r| r.get(0))
            .unwrap();
        assert_eq!(got, 2, "写死 schema:1 会让 schema 2 的结果在库里伪装成 schema 1");
    }
```

> 若 `mod tests` 里没有叫 `extraction_fixture` 的 helper,照抄同 mod 里既有抽取测试
> (`materialize.rs:845-885` 一带)建 vault/document 的那几行,不要新造抽象。

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p core-model`
Expected: FAIL — `struct 'NewExtraction' has no field named 'schema'`。

- [ ] **Step 3: 实现**

`packages/core-model/src/types.rs:193-199`:

```rust
pub struct NewExtraction {
    pub document_id: i64,
    pub backend: String,
    pub model_version: String,
    pub mode: String,
    /// 抽取输出 schema 版本(1 = labs/meds/diagnoses;2 = 再加族级 facts)。
    /// **由调用方给**:写死在这里会让 schema 2 的结果在库里伪装成 schema 1,
    /// 消费方按 1 去读就永远看不到 facts。
    pub schema: i32,
    pub result_json: String,
}
```

`types.rs:356` 的 `schema: 1,` 改成 `schema: e.schema,`。

`vault_cloud_commit_extraction` 里的 `NewExtraction { … }` 构造点补一行
(`grep -n "NewExtraction" apps/mobile_flutter/rust/src/api/vault.rs` 定位;
移动端此刻仍发 schema 1,C5 才翻):

```rust
                mode,
                // 移动端此刻仍发 schema 1;翻到 2 是 C5 的事(cloud_extract.dart)。
                schema: 1,
                result_json: restored,
```

`materialize.rs:853,861` 与 `sync_io.rs:389` 三个测试构造点各补 `schema: 1,`。

`packages/ocr/examples/medrep_llm.rs` 的参数解析里加 `--schema`(照该文件既有 `--mode`/`--limit` 的写法):

```rust
// 抽取 schema:1 = 现网,2 = 族级 facts(disease-profile spec §3)。两条臂用同一批
// 文档、同一套 `score()` 指标,所以 schema 2 的三条指标可以直接和 schema 1 比 ——
// 这就是回归门(不许因为多让模型吐 facts 而把 labs 抽差了)。
let schema: u8 = arg_value("--schema").unwrap_or(1);
let system = if schema == 2 { SYSTEM_V2 } else { SYSTEM };
```

并把产出目录从 `arm4_llm/deepseek-<mode>/` 改成 `arm4_llm/deepseek-<mode>-s<schema>/`,免得两次跑互相覆盖(`--schema 1` 时目录名保持旧值,不破坏既有产出)。

- [ ] **Step 4: 跑测试与回归门**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test --workspace`
Expected: 全绿。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo build --release -p ocr --example medrep_llm --features engine,testing`
Expected: 成功。

回归门(需要 `MEDREP_ROOT` 与 `DEEPSEEK_API_KEY`;**预计超过 5 分钟,先把命令报给用户,得到许可再跑**):

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
export MEDREP_ROOT=<medrepbench 下载目录>
cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode text --schema 1 --limit 50 --out out_s1
cargo run --release -p ocr --example medrep_llm --features engine,testing -- --mode text --schema 2 --limit 50 --out out_s2
cargo run --release -p ocr --example medrep    --features engine,testing -- --score --out out_s1
cargo run --release -p ocr --example medrep    --features engine,testing -- --score --out out_s2
```

Expected: `out_s2` 的「项目召回 / 值-名配对 / 参考区间归属」三条,每条都 ≥ `out_s1` 对应值 − 1.0 个百分点。**任何一条掉超过 1 点就不合并**:回去改 prompt(常见原因是 facts 的指令把模型注意力从化验表上拉走),改完重跑。

把两次的三条数字与结论写进 `docs/log/2026-09-16-schema2-medrepbench-regression.md`(精炼:命令、两组数字、结论、通过/不通过;不写流水账)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/core-model packages/ocr/examples/medrep_llm.rs apps/mobile_flutter/rust/src/api/vault.rs docs/log
git commit -m "feat(core-model): NewExtraction 带上 schema;评测臂加 --schema 与回归门

写死 schema:1 会让 schema 2 的结果在库里伪装成 schema 1。
MedRepBench 上 schema 2 的三条 labs 指标不得比 schema 1 低 1 点以上。"
```

---

## C3 — `packages/profile` 规则引擎与 `ProfileEvent`

### Task 9: `DocType::ProfileEvent` 与 `parser::profile_event`

**Files:**
- Modify: `packages/core-model/src/types.rs:19`(枚举加变体)、`:34`(`as_str`)、`:50`(`from_str`)
- Create: `packages/parser/src/profile_event.rs`
- Modify: `packages/parser/src/lib.rs:17`(`mod profile_event;`)、`:25` 之后(`pub use`)
- Modify: `packages/parser/src/aggregate.rs:697`(`is_manual_entry` 加 `profile_event`)

**Interfaces:**
- Produces:
  - `core_model::DocType::ProfileEvent`,`as_str()` → `"profile_event"`
  - `parser::PROFILE_EVENT_MARKER: &str = "###MEDME-PROFILE-V1###"`
  - `parser::ProfileEvent { kind: String, package: String, at: String, payload: serde_json::Value }`
  - `parser::render_profile_event_text(human_lines: &[String], ev: &ProfileEvent) -> String`
  - `parser::parse_profile_event_payload(text: &str) -> Option<ProfileEvent>`(版本不符/损坏 → `None`,不猜)
- **零新 `Event` 变体**:与 `self_entry` 完全同构,走 `FileImported` + `DocumentAdded{doc_type:"profile_event"}` + `OcrAdded`

- [ ] **Step 1: 写失败测试**

`packages/parser/src/profile_event.rs` 末尾:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn ev() -> ProfileEvent {
        ProfileEvent {
            kind: "enable".into(),
            package: "sle".into(),
            at: "2026-09-16".into(),
            payload: serde_json::json!({}),
        }
    }

    #[test]
    fn render_then_parse_round_trips() {
        let text = render_profile_event_text(&["开启了狼疮病程档案".to_string()], &ev());
        assert!(text.starts_with("开启了狼疮病程档案"), "人读的那几行必须在最前面");
        let back = parse_profile_event_payload(&text).expect("能读回来");
        assert_eq!(back.kind, "enable");
        assert_eq!(back.package, "sle");
        assert_eq!(back.at, "2026-09-16");
    }

    #[test]
    fn payload_survives_verbatim() {
        let mut e = ev();
        e.kind = "symptom_score".into();
        e.payload = serde_json::json!({"items": ["arthritis", "rash"], "total": 6});
        let back = parse_profile_event_payload(&render_profile_event_text(&[], &e)).unwrap();
        assert_eq!(back.payload, e.payload);
    }

    #[test]
    fn a_wrong_version_marker_returns_none_instead_of_guessing() {
        let text = render_profile_event_text(&[], &ev()).replace("V1", "V2");
        assert!(parse_profile_event_payload(&text).is_none());
    }

    #[test]
    fn corrupt_json_returns_none() {
        let text = format!("人读的一行\n\n{PROFILE_EVENT_MARKER}{{not json");
        assert!(parse_profile_event_payload(&text).is_none());
    }

    #[test]
    fn a_self_measurement_document_is_not_mistaken_for_a_profile_event() {
        let sm = crate::render_self_measurement_text(
            &["体重 61 kg".to_string()],
            &[crate::SelfMeasuredValue { analyte_key: "body_weight".into(), value: 61.0, unit: "kg".into() }],
        );
        assert!(parse_profile_event_payload(&sm).is_none());
    }
}
```

追加到 `packages/parser/src/aggregate.rs` 的 `mod tests`:

```rust
    #[test]
    fn profile_event_documents_never_enter_clinical_aggregation() {
        // profile_event 的合成文本里有「泼尼松」「狼疮性肾炎」这类词。它要是被
        // extract_conditions/extract_meds 读一遍,用户点一下「开启档案」就会凭空
        // 多出一条诊断和一条用药 —— 而且会跟着二维码分享给医生。
        let text = crate::render_profile_event_text(
            &["开启狼疮病程档案".to_string(), "记录:泼尼松 20mg qd,狼疮性肾炎 IV 型".to_string()],
            &crate::ProfileEvent {
                kind: "enable".into(),
                package: "sle".into(),
                at: "2026-09-16".into(),
                payload: serde_json::json!({}),
            },
        );
        let docs = vec![SourceDoc {
            index: 0,
            date: "2026-09-16".parse().ok(),
            text: &text,
            doc_type: Some("profile_event".into()),
            title: None,
            extraction_json: None,
        }];
        let out = aggregate(&docs);
        assert!(out.conditions.is_empty(), "profile_event 不该产出诊断");
        assert!(out.meds.is_empty(), "profile_event 不该产出用药");
        assert!(out.labs.is_empty(), "profile_event 不该产出化验");
    }
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p parser profile_event`
Expected: FAIL — `file not found for module 'profile_event'`。

- [ ] **Step 3: 实现**

`packages/core-model/src/types.rs`:第 19 行 `Note,` 之后加

```rust
    /// 用户在病程档案里主动做的事(开启/关闭某个病、确认诊断、记一次复发、
    /// 勾一次症状分、忽略一条提醒、开停药…)。与 `SelfMeasurement`/`Note` 同一
    /// 手法:合成文本当「文件」过一遍 `Vault::import`,**零新 Event 变体**。
    /// 载荷格式见 `parser::profile_event`。
    ProfileEvent,
```

第 34 行之后加 `DocType::ProfileEvent => "profile_event",`;第 50 行之后加 `"profile_event" => DocType::ProfileEvent,`。

`packages/parser/src/profile_event.rs`:

```rust
//! 病程档案的**用户动作日志**(spec §4)。
//!
//! 与 [`crate::self_entry`] 完全同构,理由也一样:这段文本既由我们写、也由我们读,
//! 所以带一条精确的、带版本的机器可读载荷,读回时逐字反序列化,不用模糊正则。
//!
//! 这些事件必须落日志(而不是存在某个本地偏好里),因为它们要跟着保险箱同步到
//! 别的设备、要进加密分享、并且档案永远可以从日志重算(spec §0)。
use serde::{Deserialize, Serialize};

/// 载荷行的哨兵 + 显式版本。格式变了就升版本,老代码读到新版本**失败关闭**
/// ([`parse_profile_event_payload`] → `None`),而不是把新形状猜着读一半。
pub const PROFILE_EVENT_MARKER: &str = "###MEDME-PROFILE-V1###";

/// 一条用户动作。
///
/// `kind` 取值(spec §4):`enable` / `disable` / `confirm_dx` / `reject_dx` /
/// `flare` / `symptom_score` / `pga` / `dismiss_reminder` / `drug_start` /
/// `drug_stop` / `infusion` / `weight`。
///
/// `payload` 刻意是 `serde_json::Value`:每种 kind 的形状不一样,而规则引擎只按
/// kind 取自己认得的那几个键。认不出的 kind 原样躺在日志里,将来的版本能读它 ——
/// 这是「永远可重算」的前提。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileEvent {
    pub kind: String,
    /// 包 id(`"sle"`)。一个保险箱可以同时开多个病。
    pub package: String,
    /// 事件发生日期 `YYYY-MM-DD`(用户说的那天,不是记录那天)。
    pub at: String,
    #[serde(default)]
    pub payload: serde_json::Value,
}

/// 合成 `ocr_result.text`:调用方给的人读文字在前,空行,再是载荷行。
/// 措辞全由调用方决定(本模块对文案没有意见),这里只管结构化的那条尾巴。
pub fn render_profile_event_text(human_lines: &[String], ev: &ProfileEvent) -> String {
    let mut out = human_lines.join("\n");
    out.push_str("\n\n");
    out.push_str(PROFILE_EVENT_MARKER);
    out.push_str(&serde_json::to_string(ev).expect("ProfileEvent 全是 String/Value,恒可序列化"));
    out
}

/// 从 `doc_type == "profile_event"` 文档的文本里读回载荷。哨兵不在、版本不符、
/// JSON 坏了,一律 `None` —— 从不猜半份。
pub fn parse_profile_event_payload(text: &str) -> Option<ProfileEvent> {
    let line = text.lines().find(|l| l.starts_with(PROFILE_EVENT_MARKER))?;
    serde_json::from_str(line.strip_prefix(PROFILE_EVENT_MARKER)?).ok()
}
```

`packages/parser/src/lib.rs`:`mod self_entry;` 之前加 `mod profile_event;`(按字母序);`pub use meds::{…};` 之后加

```rust
pub use profile_event::{
    parse_profile_event_payload, render_profile_event_text, ProfileEvent, PROFILE_EVENT_MARKER,
};
```

`packages/parser/src/aggregate.rs:697` 改成:

```rust
        // `profile_event` 与前两者同理,而且更危险:它的人读文字里**就是**药名和
        // 诊断名(「开启狼疮病程档案」「泼尼松 20mg」),不挡就等于用户点一下按钮
        // 就凭空多一条诊断,还会跟着二维码分享出去。
        let is_manual_entry =
            matches!(dt, Some("self_measurement") | Some("note") | Some("profile_event"));
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p parser -p core-model`
Expected: PASS。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test --workspace`
Expected: 全绿(含 `packages/parser/tests/corpus_summary.rs` —— 既有语料里没有 profile_event,数字不该动)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/core-model packages/parser
git commit -m "feat(parser): DocType::ProfileEvent 与带版本的动作日志载荷

零新 Event 变体,与 self_entry 同构。profile_event 文档与 note/self_measurement
一样不进临床聚合 —— 它的人读文字里就是药名和诊断名,不挡就会凭空长出诊断。"
```

---

### Task 10: `profile::materialize` 骨架 —— 开启闸、输入装配、空 ProfileView

**Files:**
- Create: `packages/profile/src/view.rs`
- Create: `packages/profile/src/rules.rs`
- Modify: `packages/profile/src/lib.rs`(加 `materialize`)
- Modify: `packages/profile/Cargo.toml`(加 `parser`/`deid` 依赖)

**Interfaces:**
- Consumes: Task 1–2 的 `Package`;`parser::{aggregate, AggregatedClinical, SourceDoc, ProfileEvent, parse_profile_event_payload}`;`deid::{parse_extraction, Fact, LabItem}`
- Produces:
  - `profile::materialize(docs: &[parser::SourceDoc<'_>], events: &[parser::ProfileEvent], pkg: &Package, today: chrono::NaiveDate) -> ProfileView`
  - `profile::ProfileView { package_id: String, package_version: String, display_name: String, enabled: bool, disclaimer: String, sections: Vec<Section>, sources: Vec<SourceOut> }`
  - `profile::Section { kind: String, title: String, empty_hint: Option<String>, body: serde_json::Value }`
  - `profile::SourceOut { id: String, cite: String, url: Option<String> }`
  - crate 内部:`rules::Ctx<'a>`(后续 Task 11–15 全部往它上面加求值函数)

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/materialize_gate.rs`:

```rust
//! 开启闸:**从未开启的病,一个字都不显示、不算、不提醒**(spec §4)。
use chrono::NaiveDate;

mod common;
use common::{minimal_pkg, sle_like_doc};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

#[test]
fn a_package_that_was_never_enabled_yields_a_disabled_view_with_no_sections() {
    let text = sle_like_doc();
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2026-09-01")),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: None,
    }];
    let v = profile::materialize(&docs, &[], &minimal_pkg(), day("2026-09-16"));
    assert!(!v.enabled);
    assert!(v.sections.is_empty(), "没开启就什么都不算,连空 section 都不给");
}

#[test]
fn enable_then_disable_leaves_it_disabled() {
    let ev = |kind: &str, at: &str| parser::ProfileEvent {
        kind: kind.into(),
        package: "t".into(),
        at: at.into(),
        payload: serde_json::json!({}),
    };
    let events = vec![ev("enable", "2026-03-01"), ev("disable", "2026-08-01")];
    let v = profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16"));
    assert!(!v.enabled);

    let events = vec![ev("enable", "2026-03-01"), ev("disable", "2026-08-01"), ev("enable", "2026-09-10")];
    let v = profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16"));
    assert!(v.enabled, "最后一条才算数");
}

#[test]
fn an_event_for_another_package_does_not_enable_this_one() {
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "ms".into(),
        at: "2026-03-01".into(),
        payload: serde_json::json!({}),
    }];
    assert!(!profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16")).enabled);
}

#[test]
fn an_enabled_view_carries_the_manifest_identity_and_sources() {
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-03-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16"));
    assert!(v.enabled);
    assert_eq!(v.package_id, "t");
    assert_eq!(v.package_version, "2026.09.1");
    assert_eq!(v.display_name, "测试病");
    assert!(!v.disclaimer.is_empty(), "免责声明必须随视图一起出去,不能只在包里躺着");
    assert_eq!(v.sources[0].id, "S1");
}
```

`packages/profile/tests/common/mod.rs`:

```rust
//! 测试共用夹具。**不要**在这里塞断言或规则逻辑 —— 它只造输入。
use profile::Package;

/// 一个签好名的最小包(与 `package.rs` 单测里的 MINIMAL 同一份内容)。
pub fn minimal_pkg() -> Package {
    serde_json::from_str(MINIMAL).expect("夹具包必须解析")
}

pub const MINIMAL: &str = r#"{"manifest":{"id":"t","family":"immune","version":"2026.09.1","min_engine":1,
  "display":{"name":"测试病","short":"测试"},"disclaimer":"仅整理你的病历,不做诊断",
  "sources":[{"id":"S1","cite":"test","url":null}]},
  "triggers":{"diagnosis_patterns":[],"serology_any_two":[]},
  "terms":{"aliases":{},"analytes":[]},"markers":[],"drugs":[],
  "rules":{"activity":{"window_days":10,"max":18,"items":[]},"states":[],"monitoring":[],"milestones":[]},
  "views":{"sections":[],"handoff":[]}}"#;

/// 一份长得像化验单的文本,用来证明「没开启就不算」不是因为没有输入。
pub fn sle_like_doc() -> String {
    "检验报告单\n补体C3 0.42 g/L 0.9-1.8 L\n补体C4 0.06 g/L 0.1-0.4 L\n".to_string()
}
```

> 这里直接 `from_str` 而不是走 `load_signed`:开启闸测的是**规则**,不是签名。
> 签名那一层已由 Task 1/2 的测试钉住,再串一遍只会让这些测试依赖测试私钥。

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test materialize_gate`
Expected: FAIL — `cannot find function 'materialize' in crate 'profile'`。

- [ ] **Step 3: 实现**

`packages/profile/Cargo.toml` 的 `[dependencies]` 追加:

```toml
# 规则引擎吃的是 parser 已经汇总好的序列/用药(不自己再实现一遍分组与单位换算),
# 以及 deid 解出来的 facts(schema 2)。两者都是纯计算,不带 IO。
parser = { path = "../parser" }
deid = { path = "../deid" }
```

`packages/profile/src/view.rs`:

```rust
//! `ProfileView` —— 规则引擎的**唯一**输出。渲染引擎(Flutter/查看器)只认这个形状。
//!
//! section 的顺序、标题、空态文案**全来自包**(spec §6):加一个病不发版的前提是
//! App 里没有任何一句写死的病种文案。
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct SourceOut {
    pub id: String,
    pub cite: String,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Section {
    /// 7 种之一:`status_card` / `score_card` / `series_chart` / `reminders` /
    /// `timeline` / `checklist` / `handoff`(spec §6)。渲染引擎认不出的 kind
    /// 整块跳过(前向兼容),不报错。
    pub kind: String,
    pub title: String,
    /// `Some(提示语)` = 这块**没数据**,折叠成一行(spec §5.6);`None` = 展开。
    pub empty_hint: Option<String>,
    pub body: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileView {
    pub package_id: String,
    pub package_version: String,
    pub display_name: String,
    /// 用户从没开启过这个病时为 `false`,且 `sections` 为空。
    pub enabled: bool,
    pub disclaimer: String,
    pub sections: Vec<Section>,
    /// 包里声明的全部出处。界面上每个数值旁边的出处 id 到这里查全文。
    pub sources: Vec<SourceOut>,
}
```

`packages/profile/src/rules.rs`:

```rust
//! 规则求值的共享上下文与各条规则的实现。**纯函数**:同样的 `Ctx` + 同样的包 +
//! 同样的 `today`,永远得到同样的结果。
use chrono::NaiveDate;

/// 一条被规则引用到的化验证据(用于「这次计分用了哪几张单子」的证据链)。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Evidence {
    /// `parser::SourceDoc::index` —— 调用方据此翻回 document_id。
    pub document_index: usize,
    pub date: Option<String>,
    pub analyte: String,
    pub value: String,
    pub unit: Option<String>,
}

/// 规则求值的全部输入,装配一次、各条规则共用。
pub struct Ctx<'a> {
    /// `parser::aggregate` 的产物:已分组、已换算的化验序列 + 用药区间 + 诊断。
    pub clinical: parser::AggregatedClinical,
    /// schema 2 的族级事实,带上它所在文档的 index 与日期(fact 自己的 `date`
    /// 为空时用文档日期兜底)。
    pub facts: Vec<(usize, Option<NaiveDate>, deid::Fact)>,
    /// 抽取结果里的**原始 labs 行**。定性值(「阴性」「阳性」)解析不出 f64,
    /// 在 `aggregate` 那层就被丢了,但 SLEDAI 的 dsDNA 项允许定性阳性计分
    /// (sle-clinical-sources §B.2),所以必须留一条能看到原文字符串的路。
    pub raw_labs: Vec<(usize, Option<NaiveDate>, deid::LabItem)>,
    /// 每份文档的原文(`text_present` 类规则用:管型这种只在尿沉渣描述里出现)。
    pub texts: Vec<(usize, Option<NaiveDate>, &'a str)>,
    pub events: &'a [parser::ProfileEvent],
    pub today: NaiveDate,
}

impl<'a> Ctx<'a> {
    pub fn build(
        docs: &'a [parser::SourceDoc<'a>],
        events: &'a [parser::ProfileEvent],
        today: NaiveDate,
    ) -> Ctx<'a> {
        let clinical = parser::aggregate(docs);
        let mut facts = Vec::new();
        let mut raw_labs = Vec::new();
        let mut texts = Vec::new();
        for d in docs {
            texts.push((d.index, d.date, d.text));
            // 抽取结果解析不出来就当这份没有 facts —— 与 `labs_from_json` 的既有
            // 约定一致(解析失败退回正则路径,而不是让整个投影失败)。
            if let Some(json) = d.extraction_json {
                if let Ok(e) = deid::parse_extraction(json) {
                    for f in e.facts {
                        facts.push((d.index, d.date, f));
                    }
                    for l in e.labs {
                        raw_labs.push((d.index, d.date, l));
                    }
                }
            }
        }
        Ctx { clinical, facts, raw_labs, texts, events, today }
    }

    /// `date` 落在 `[today - window_days, today]` 里吗?没有日期的一律**不算**
    /// —— 取值窗口是 SLEDAI-2K 表格原文的硬要求(前 10 天),猜日期等于编分数。
    pub fn in_window(&self, date: Option<NaiveDate>, window_days: i64) -> bool {
        match date {
            Some(d) => {
                let lo = self.today - chrono::Duration::days(window_days);
                d >= lo && d <= self.today
            }
            None => false,
        }
    }
}
```

`packages/profile/src/lib.rs` 加模块与入口:

```rust
pub mod package;
pub mod rules;
pub mod view;

pub use package::{ /* …Task 1/2 的那一串,不动… */ };
pub use view::{ProfileView, Section, SourceOut};

use chrono::NaiveDate;

/// 从保险箱数据 + 一个病种包算出 `ProfileView`。**纯函数**,可重算。
///
/// `docs` 是调用方从保险箱投影出来的全部文档(与 `parser::assemble_summary` 吃的
/// 是同一份);`events` 是其中 `doc_type == "profile_event"` 的文档解出来的动作日志
/// (调用方负责解,因为只有它知道怎么从库里取文本)。
pub fn materialize(
    docs: &[parser::SourceDoc<'_>],
    events: &[parser::ProfileEvent],
    pkg: &package::Package,
    today: NaiveDate,
) -> ProfileView {
    let enabled = is_enabled(events, &pkg.manifest.id);
    let sections = if enabled {
        let _ctx = rules::Ctx::build(docs, events, today);
        // Task 11–15 往这里加 section。此刻先空着 —— 「开启了但还没有任何数据」
        // 与「没开启」必须是两种不同的显示状态。
        Vec::new()
    } else {
        Vec::new()
    };
    ProfileView {
        package_id: pkg.manifest.id.clone(),
        package_version: pkg.manifest.version.clone(),
        display_name: pkg.manifest.display.name.clone(),
        enabled,
        disclaimer: pkg.manifest.disclaimer.clone(),
        sections,
        sources: pkg
            .manifest
            .sources
            .iter()
            .map(|s| SourceOut { id: s.id.clone(), cite: s.cite.clone(), url: s.url.clone() })
            .collect(),
    }
}

/// 这个包**当前**是不是开着的:只看 `enable`/`disable` 两种 kind,按 `at` 排序取最后
/// 一条。从没开过 = 关着(spec §4:「从未开启 = 不算、不显示、不提醒」)。
fn is_enabled(events: &[parser::ProfileEvent], package_id: &str) -> bool {
    events
        .iter()
        .filter(|e| e.package == package_id && (e.kind == "enable" || e.kind == "disable"))
        // `at` 是 `YYYY-MM-DD`,定宽,字典序即时间序。
        .max_by(|a, b| a.at.cmp(&b.at))
        .is_some_and(|e| e.kind == "enable")
}
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): materialize 骨架 —— 开启闸、输入装配、ProfileView 形状

从未开启的病一个 section 都不给。Ctx 把 parser 汇总、schema 2 facts、
原始定性 labs 行和原文各装配一次,后续规则共用同一份输入。"
```

---

### Task 11: 活动度规则 —— 8 条化验可算项、10 天窗口、x/18

**Files:**
- Modify: `packages/profile/src/rules.rs`(加 `activity` 求值)
- Modify: `packages/profile/src/lib.rs`(`materialize` 里挂 `score_card`)
- Create: `packages/profile/tests/activity_rules.rs`
- Modify: `packages/profile/tests/common/mod.rs`(加带 activity 规则的夹具包)

**Interfaces:**
- Consumes: Task 10 的 `rules::Ctx`、`view::Section`
- Produces:
  - `rules::activity_section(ctx: &Ctx, pkg: &Package) -> Option<Section>`(`kind == "score_card"`)
  - 包里 `rules.activity.items[]` 的**五种 kind**:
    - `flag_low` —— `any_of` 里任一分析物在窗口内有 `flag == "L"` 的点(阈值是**该报告自己印的下限**,`parser` 已经按点算好 flag)
    - `flag_high` —— 同上,`flag == "H"`;另可给 `qualitative_positive: [..]`,用原始 labs 行的 `value` 字符串匹配
    - `gt` / `lt` —— `key` 的规范单位值与 `threshold` 比较
    - `text_present` —— `patterns` 里任一串出现在窗口内某份文档原文里
  - `score_card` 的 `body`:`{"score","max","window_days","as_of","label","hits":[{"id","label","weight","source","caveat","evidence":[…]}],"unscored":[{"id","label","reason"}]}`

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/activity_rules.rs`:

```rust
//! 每条活动度规则一个**阈值边界**用例:恰好在阈上、恰好在阈下各一次。
//! 数值全部来自 `.superpowers/sdd/disease-profile/sle-clinical-sources.md` §B.1/§B.2
//! 的 VERBATIM 行。
use chrono::NaiveDate;

mod common;
use common::{activity_pkg, lab_doc, TODAY};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

fn score(docs: &[(&str, &str)]) -> serde_json::Value {
    let texts: Vec<String> = docs.iter().map(|(_, t)| t.to_string()).collect();
    let src: Vec<parser::SourceDoc> = docs
        .iter()
        .zip(&texts)
        .enumerate()
        .map(|(i, ((d, _), t))| parser::SourceDoc {
            index: i,
            date: Some(day(d)),
            text: t,
            doc_type: Some("lab_report".into()),
            title: None,
            extraction_json: None,
        })
        .collect();
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&src, &events, &activity_pkg(), day(TODAY));
    v.sections
        .iter()
        .find(|s| s.kind == "score_card")
        .expect("有化验就该有 score_card")
        .body
        .clone()
}

fn hit_ids(body: &serde_json::Value) -> Vec<String> {
    body["hits"].as_array().unwrap().iter().map(|h| h["id"].as_str().unwrap().into()).collect()
}

#[test]
fn leukopenia_boundary_is_strictly_below_three() {
    // VERBATIM:「< 3,000 white blood cells / x10⁹/L」→ 实现为 WBC < 3.0 ×10⁹/L。
    let b = score(&[(TODAY, &lab_doc("白细胞 2.9 10^9/L 3.5-9.5"))]);
    assert!(hit_ids(&b).contains(&"leukopenia".to_string()));
    assert_eq!(b["score"], 1);

    let b = score(&[(TODAY, &lab_doc("白细胞 3.0 10^9/L 3.5-9.5"))]);
    assert!(!hit_ids(&b).contains(&"leukopenia".to_string()), "恰好 3.0 不计分");
}

#[test]
fn thrombocytopenia_boundary_is_strictly_below_one_hundred() {
    let b = score(&[(TODAY, &lab_doc("血小板 99 10^9/L 125-350"))]);
    assert_eq!(b["score"], 1);
    let b = score(&[(TODAY, &lab_doc("血小板 100 10^9/L 125-350"))]);
    assert_eq!(b["score"], 0);
}

#[test]
fn proteinuria_boundary_is_strictly_above_half_a_gram_per_day() {
    // VERBATIM:「>0.5 gram/24 hours」,权重 4。词典 canonical 是 mg/24h。
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.51 g/24h"))]);
    assert_eq!(b["score"], 4);
    let b = score(&[(TODAY, &lab_doc("24小时尿蛋白定量 0.50 g/24h"))]);
    assert_eq!(b["score"], 0, "恰好 0.5 g/24h 不计分");
}

#[test]
fn upcr_never_scores_it_is_display_only() {
    // spec §5.2:UPCR 不能替代 24h 尿蛋白计分,只单独展示。
    let b = score(&[(TODAY, &lab_doc("尿蛋白肌酐比 1200 mg/g"))]);
    assert_eq!(b["score"], 0);
    assert!(!hit_ids(&b).contains(&"proteinuria".to_string()));
}

#[test]
fn low_complement_uses_the_reports_own_lower_limit_not_a_fixed_number() {
    // VERBATIM:「below the lower limit of normal for testing laboratory」。
    // 同一个 0.85 g/L,在下限 0.9 的医院算低,在下限 0.8 的医院不算。
    let b = score(&[(TODAY, &lab_doc("补体C3 0.85 g/L 0.9-1.8"))]);
    assert_eq!(b["score"], 2);
    let b = score(&[(TODAY, &lab_doc("补体C3 0.85 g/L 0.8-1.8"))]);
    assert_eq!(b["score"], 0);
}

#[test]
fn low_complement_scores_only_once_even_when_c3_and_c4_are_both_low() {
    // 一条描述符 = 一次 2 分(CH50/C3/C4 是同一条 "Low complement")。
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8\n补体C4 0.05 g/L 0.1-0.4"))]);
    assert_eq!(b["score"], 2);
}

#[test]
fn a_result_older_than_the_window_does_not_score() {
    // VERBATIM:「present at the time of the visit or in the preceding 10 days」。
    let b = score(&[("2026-09-05", &lab_doc("白细胞 2.0 10^9/L 3.5-9.5"))]); // 11 天前
    assert_eq!(b["score"], 0);
    let b = score(&[("2026-09-06", &lab_doc("白细胞 2.0 10^9/L 3.5-9.5"))]); // 10 天前
    assert_eq!(b["score"], 1);
}

#[test]
fn casts_are_detected_from_the_report_text_not_from_a_number() {
    let b = score(&[(TODAY, &lab_doc("尿沉渣:可见红细胞管型"))]);
    assert!(hit_ids(&b).contains(&"casts".to_string()));
    assert_eq!(b["score"], 4);
}

#[test]
fn the_score_is_labelled_as_the_lab_computable_part_and_capped_at_eighteen() {
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    assert_eq!(b["max"], 18);
    assert_eq!(b["label"], "化验可算部分");
    assert_eq!(b["window_days"], 10);
    // 界面不许把它说成 SLEDAI 总分。
    let s = serde_json::to_string(&b).unwrap();
    assert!(!s.contains("SLEDAI 总分"));
}

#[test]
fn every_hit_carries_its_source_id_and_the_reports_it_used() {
    let b = score(&[(TODAY, &lab_doc("补体C3 0.4 g/L 0.9-1.8"))]);
    let h = &b["hits"][0];
    assert_eq!(h["source"], "S1");
    assert_eq!(h["evidence"][0]["document_index"], 0);
    assert_eq!(h["evidence"][0]["analyte"], "complement_c3");
}

#[test]
fn a_qualitative_positive_dsdna_scores_but_is_flagged_as_a_deviation() {
    // §B.2:表格写的是 Farr 法;中国实验室多用 ELISA/CLIFT,定性「阳性」也计分,
    // 但必须标出偏差 —— 不标就是把一个方法学差异藏起来。
    let extraction = r#"{"labs":[{"name":"抗双链DNA抗体","value":"阳性","unit":"","ref_low":"","ref_high":"","flag":""}],"facts":[]}"#;
    let text = lab_doc("抗双链DNA抗体 阳性");
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day(TODAY)),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: Some(extraction),
    }];
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(), package: "t".into(), at: "2026-01-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&docs, &events, &activity_pkg(), day(TODAY));
    let b = &v.sections.iter().find(|s| s.kind == "score_card").unwrap().body;
    assert_eq!(b["score"], 2);
    assert!(b["hits"][0]["caveat"].as_str().unwrap().contains("Farr"));
}
```

追加到 `packages/profile/tests/common/mod.rs`:

```rust
pub const TODAY: &str = "2026-09-16";

/// 把几行化验包成一份像样的报告单文本(`extract_labs` 要看到报告的样子)。
pub fn lab_doc(rows: &str) -> String {
    format!("检验报告单\n项目 结果 单位 参考区间\n{rows}\n")
}

/// 带完整 SLE 活动度规则的夹具包(8 条,权重与阈值逐字取自 sle-clinical-sources
/// §B.1/§B.2)。Task 18 的真包与这份**内容一致**,由 `activity_rules_fixture_matches_
/// the_shipped_sle_package` 钉住。
pub fn activity_pkg() -> profile::Package {
    serde_json::from_str(ACTIVITY).expect("夹具包必须解析")
}

pub const ACTIVITY: &str = r#"{ ... 与 MINIMAL 同,但 rules.activity 填成下面这份 ... }"#;
```

`ACTIVITY` 的 `rules.activity` 内容(照抄进去):

```json
{"window_days":10,"max":18,"items":[
 {"id":"low_complement","label":"低补体","weight":2,"kind":"flag_low",
  "any_of":["complement_c3","complement_c4","ch50"],"source":"S1"},
 {"id":"dsdna_high","label":"dsDNA 升高","weight":2,"kind":"flag_high","any_of":["anti_dsdna"],
  "qualitative_positive":["阳性","强阳性","+"],
  "caveat":"表格原文写的是 Farr 法;中国实验室多用 ELISA/CLIFT,按定义存在偏差","source":"S1"},
 {"id":"proteinuria","label":"蛋白尿","weight":4,"kind":"gt","key":"urine_protein_24h",
  "threshold":500,"canonical_unit":"mg/24h","source":"S1"},
 {"id":"hematuria","label":"血尿","weight":4,"kind":"gt","key":"urine_rbc_hpf","threshold":5,
  "canonical_unit":"/[HPF]","caveat":"需排除结石、感染或其它原因,需医生确认","source":"S1"},
 {"id":"pyuria","label":"脓尿","weight":4,"kind":"gt","key":"urine_wbc_hpf","threshold":5,
  "canonical_unit":"/[HPF]","caveat":"需排除感染,需医生确认","source":"S1"},
 {"id":"casts","label":"管型","weight":4,"kind":"text_present",
  "patterns":["红细胞管型","颗粒管型","血红蛋白管型"],"source":"S1"},
 {"id":"leukopenia","label":"白细胞减少","weight":1,"kind":"lt","key":"wbc","threshold":3.0,
  "canonical_unit":"10*9/L","source":"S1"},
 {"id":"thrombocytopenia","label":"血小板减少","weight":1,"kind":"lt","key":"plt","threshold":100,
  "canonical_unit":"10*9/L","source":"S1"}]}
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test activity_rules`
Expected: FAIL — `有化验就该有 score_card`(panic,`sections` 还是空的)。

- [ ] **Step 3: 实现**

追加到 `packages/profile/src/rules.rs`:

```rust
use crate::package::Package;
use crate::view::Section;

/// 一条被命中的活动度描述符。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Hit {
    pub id: String,
    pub label: String,
    pub weight: u32,
    pub source: String,
    pub caveat: Option<String>,
    pub evidence: Vec<Evidence>,
}

/// 「化验可算部分」的分数。**永远带 `label`,永远不叫 SLEDAI 总分**(spec §8)。
pub fn activity_section(ctx: &Ctx<'_>, pkg: &Package) -> Option<Section> {
    let a = &pkg.rules.activity;
    if a.items.is_empty() {
        return None;
    }
    let mut hits: Vec<Hit> = Vec::new();
    for item in &a.items {
        if let Some(h) = eval_activity_item(ctx, item, a.window_days) {
            hits.push(h);
        }
    }
    let score: u32 = hits.iter().map(|h| h.weight).sum();
    // 一条化验都没进窗口 → 这块没数据,折叠(spec §5.6)。
    let any_data = ctx
        .clinical
        .labs
        .iter()
        .any(|s| s.points.iter().any(|p| ctx.in_window(p.date, a.window_days)));
    Some(Section {
        kind: "score_card".into(),
        title: "活动度(化验可算部分)".into(),
        empty_hint: (!any_data)
            .then(|| format!("最近 {} 天还没有化验结果,下次抽血后这里会自动算", a.window_days)),
        body: serde_json::json!({
            "score": score,
            "max": a.max,
            "label": "化验可算部分",
            "window_days": a.window_days,
            "as_of": ctx.today.to_string(),
            "hits": hits,
        }),
    })
}

fn str_field<'j>(v: &'j serde_json::Value, k: &str) -> &'j str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or_default()
}

fn eval_activity_item(ctx: &Ctx<'_>, item: &serde_json::Value, window: i64) -> Option<Hit> {
    let kind = str_field(item, "kind");
    let keys: Vec<&str> = item
        .get("any_of")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_else(|| item.get("key").and_then(|x| x.as_str()).into_iter().collect());

    let mut evidence = Vec::new();
    let matched = match kind {
        // 阈值是**该报告自己印的区间**:`parser` 已经按点算好 flag(值 vs 该行的
        // ref_low/ref_high,见 `extraction.rs:87-97`),所以这里读 flag 就是读
        // 「低于这家医院的下限」,不需要也不许在这儿放一个固定数字。
        "flag_low" | "flag_high" => {
            let want = if kind == "flag_low" { "L" } else { "H" };
            let mut any = false;
            for s in &ctx.clinical.labs {
                let Some(k) = s.analyte_key.as_deref() else { continue };
                if !keys.contains(&k) || s.self_measured {
                    continue;
                }
                for p in &s.points {
                    if ctx.in_window(p.date, window) && p.flag.as_deref() == Some(want) {
                        any = true;
                        evidence.push(Evidence {
                            document_index: p.source,
                            date: p.date.map(|d| d.to_string()),
                            analyte: k.to_string(),
                            value: p.value.to_string(),
                            unit: p.unit.clone(),
                        });
                    }
                }
            }
            // 定性阳性(dsDNA 的 ELISA/CLIFT 报「阳性」):数值路整条都看不到它,
            // 只能回到抽取结果的原始行上按字符串认。
            if !any {
                if let Some(pos) = item.get("qualitative_positive").and_then(|v| v.as_array()) {
                    let words: Vec<&str> = pos.iter().filter_map(|x| x.as_str()).collect();
                    for (idx, date, l) in &ctx.raw_labs {
                        if !ctx.in_window(*date, window) {
                            continue;
                        }
                        let resolves = terminology::resolve(&l.name, None)
                            .is_some_and(|m| keys.contains(&m.key.as_str()));
                        if resolves && words.iter().any(|w| l.value.contains(w)) {
                            any = true;
                            evidence.push(Evidence {
                                document_index: *idx,
                                date: date.map(|d| d.to_string()),
                                analyte: l.name.clone(),
                                value: l.value.clone(),
                                unit: None,
                            });
                        }
                    }
                }
            }
            any
        }
        "gt" | "lt" => {
            let thr = item.get("threshold").and_then(|v| v.as_f64())?;
            let unit = str_field(item, "canonical_unit");
            let mut any = false;
            for s in &ctx.clinical.labs {
                let Some(k) = s.analyte_key.as_deref() else { continue };
                if !keys.contains(&k) || s.self_measured {
                    continue;
                }
                for p in &s.points {
                    if !ctx.in_window(p.date, window) {
                        continue;
                    }
                    // **只用规范单位比**:报告印 g/24h、mg/24h 的都有,拿 raw value
                    // 去比 0.5 就是 1000 倍的错。换算不出来的点直接跳过(诚实漏)。
                    let (Some(v), Some(u)) = (p.value_canonical, s.unit_canonical.as_deref())
                    else {
                        continue;
                    };
                    if terminology::normalize_unit(u) != terminology::normalize_unit(unit) {
                        continue;
                    }
                    let ok = if kind == "gt" { v > thr } else { v < thr };
                    if ok {
                        any = true;
                        evidence.push(Evidence {
                            document_index: p.source,
                            date: p.date.map(|d| d.to_string()),
                            analyte: k.to_string(),
                            value: v.to_string(),
                            unit: Some(u.to_string()),
                        });
                    }
                }
            }
            any
        }
        "text_present" => {
            let pats: Vec<&str> = item
                .get("patterns")?
                .as_array()?
                .iter()
                .filter_map(|x| x.as_str())
                .collect();
            let mut any = false;
            for (idx, date, text) in &ctx.texts {
                if !ctx.in_window(*date, window) {
                    continue;
                }
                // 一次 `find` 同时当判定和取证。写成 `any()` 判定 + `find().unwrap()`
                // 取证会在两次扫描之间留下一个「刚才一定命中过」的口头不变量 ——
                // 库代码里这种 unwrap 迟早被某次重构踩掉。只扫一次就没有不变量要守。
                let Some(hit) = pats.iter().find(|p| text.contains(**p)) else {
                    continue;
                };
                any = true;
                evidence.push(Evidence {
                    document_index: *idx,
                    date: date.map(|d| d.to_string()),
                    analyte: str_field(item, "id").to_string(),
                    value: (*hit).to_string(),
                    unit: None,
                });
            }
            any
        }
        // 认不出的 kind 不计分、不报错:包可以先于引擎加规则类型(`min_engine` 管
        // 的是**必须**懂的那些;不懂的可选规则静默跳过比整个档案打不开强)。
        _ => false,
    };

    matched.then(|| Hit {
        id: str_field(item, "id").to_string(),
        label: str_field(item, "label").to_string(),
        weight: item.get("weight").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        source: str_field(item, "source").to_string(),
        caveat: item.get("caveat").and_then(|v| v.as_str()).map(str::to_string),
        evidence,
    })
}
```

`packages/profile/Cargo.toml` 加 `terminology = { path = "../terminology" }`。

`materialize` 里把 `Vec::new()` 换成:

```rust
        let ctx = rules::Ctx::build(docs, events, today);
        let mut out = Vec::new();
        out.extend(rules::activity_section(&ctx, pkg));
        out
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS(11 个活动度边界用例 + 之前的)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): 活动度 8 条化验可算项,10 天窗口,x/18

lab-relative 的两条(低补体、dsDNA)读 parser 按点算好的 flag —— 那就是
「低于这家医院印的下限」,不在引擎里放固定数字。数值项只用规范单位比。
每条命中带出处 id 和用到的单子。UPCR 永不计分,只展示。"
```

---

### Task 12: 达标检查表 —— DORIS / LLDAS 逐条三态

**Files:**
- Modify: `packages/profile/src/rules.rs`(加 `states_section`)
- Modify: `packages/profile/src/lib.rs`(挂进 `materialize`)
- Create: `packages/profile/tests/state_checklists.rs`
- Modify: `packages/profile/tests/common/mod.rs`(夹具包加 `rules.states`)

**Interfaces:**
- Consumes: Task 11 的 `activity_section` 算出来的 hits(cSLEDAI 要在总分里**去掉**补体与 dsDNA 两项)、`Ctx`
- Produces:
  - `rules::states_section(ctx: &Ctx, pkg: &Package, hits: &[Hit]) -> Option<Section>`(`kind == "checklist"`)
  - 条目 kind:`csledai_eq` / `sledai_le` / `pga_lt` / `pga_le` / `pred_lt` / `pred_le` / `manual`
  - 每条三态 `"yes" | "no" | "unknown"`;PGA 没录过 = `unknown`,**不是** `no`
  - `body`:`{"states":[{"id","label","source","note","verdict","items":[{"id","label","verdict","actual","note","source"}]}]}`;`verdict` 为整表三态(任一条 `no` → `no`;否则任一条 `unknown` → `unknown`;全 `yes` → `yes`)

> **不自动宣布缓解**(spec §5.3):`verdict == "yes"` 的文案由包给,且包里写的是
> 「这几条都满足了,拿去问医生」,不是「你已缓解」。引擎只算逐条,不下结论。

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/state_checklists.rs`:

```rust
//! DORIS 2021 / LLDAS 的边界。数值逐字取自 sle-clinical-sources §C.1 / §C.2。
use chrono::NaiveDate;

mod common;
use common::{full_pkg, lab_doc, mk_docs, TODAY};

fn day(s: &str) -> NaiveDate { s.parse().unwrap() }

fn checklist(docs: &[(&str, String)], events: Vec<parser::ProfileEvent>) -> serde_json::Value {
    let (holder, src) = mk_docs(docs);
    let _ = &holder;
    let v = profile::materialize(&src, &events, &full_pkg(), day(TODAY));
    v.sections.iter().find(|s| s.kind == "checklist").expect("有 checklist").body.clone()
}

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent { kind: "enable".into(), package: "t".into(), at: "2026-01-01".into(),
                           payload: serde_json::json!({}) }
}

fn pga(at: &str, value: f64) -> parser::ProfileEvent {
    parser::ProfileEvent { kind: "pga".into(), package: "t".into(), at: at.into(),
                           payload: serde_json::json!({"value": value}) }
}

fn state<'a>(b: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    b["states"].as_array().unwrap().iter().find(|s| s["id"] == id).unwrap()
}

fn item<'a>(s: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    s["items"].as_array().unwrap().iter().find(|i| i["id"] == id).unwrap()
}

#[test]
fn pga_never_recorded_is_unknown_not_a_failure() {
    let b = checklist(&[], vec![enable()]);
    assert_eq!(item(state(&b, "doris"), "phga")["verdict"], "unknown");
    assert_eq!(state(&b, "doris")["verdict"], "unknown", "有未知项时整表就是未知");
}

#[test]
fn doris_phga_boundary_is_strictly_below_zero_point_five() {
    // VERBATIM Box 1:「Physician Global Assessment <0.5」。
    let b = checklist(&[], vec![enable(), pga(TODAY, 0.4)]);
    assert_eq!(item(state(&b, "doris"), "phga")["verdict"], "yes");
    let b = checklist(&[], vec![enable(), pga(TODAY, 0.5)]);
    assert_eq!(item(state(&b, "doris"), "phga")["verdict"], "no");
    // 两份指南在这个点上不一致,必须在界面上说出来。
    assert!(item(state(&b, "doris"), "phga")["note"].as_str().unwrap().contains("≤0.5"));
}

#[test]
fn lldas_pga_boundary_is_at_most_one() {
    let b = checklist(&[], vec![enable(), pga(TODAY, 1.0)]);
    assert_eq!(item(state(&b, "lldas"), "pga_le1")["verdict"], "yes");
    let b = checklist(&[], vec![enable(), pga(TODAY, 1.1)]);
    assert_eq!(item(state(&b, "lldas"), "pga_le1")["verdict"], "no");
}

#[test]
fn csledai_drops_the_two_serology_descriptors() {
    // DORIS 的 cSLEDAI「irrespective of serology」:去掉低补体(2)与 dsDNA(2)。
    // 只有低补体时,化验可算分 = 2,但 cSLEDAI = 0 → 这一条应当是 yes。
    let b = checklist(
        &[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))],
        vec![enable(), pga(TODAY, 0.2)],
    );
    assert_eq!(item(state(&b, "doris"), "csledai_zero")["verdict"], "yes");

    // 白细胞减少(1 分,非血清学)一出现,cSLEDAI 就不是 0。
    let b = checklist(
        &[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8\n白细胞 2.0 10^9/L 3.5-9.5"))],
        vec![enable(), pga(TODAY, 0.2)],
    );
    assert_eq!(item(state(&b, "doris"), "csledai_zero")["verdict"], "no");
    assert_eq!(item(state(&b, "doris"), "csledai_zero")["actual"], 1);
}

#[test]
fn lldas_sledai_boundary_is_at_most_four() {
    // 化验可算部分 5 分(蛋白尿 4 + 白细胞减少 1)> 4。
    let b = checklist(
        &[(TODAY, lab_doc("24小时尿蛋白定量 0.8 g/24h\n白细胞 2.0 10^9/L 3.5-9.5"))],
        vec![enable(), pga(TODAY, 0.5)],
    );
    assert_eq!(item(state(&b, "lldas"), "sledai_le4")["verdict"], "no");
    let b = checklist(&[(TODAY, lab_doc("24小时尿蛋白定量 0.8 g/24h"))],
                      vec![enable(), pga(TODAY, 0.5)]);
    assert_eq!(item(state(&b, "lldas"), "sledai_le4")["verdict"], "yes");
}

#[test]
fn a_manual_item_is_unknown_until_someone_answers_it() {
    // LLDAS 的「无重要脏器活动」「与上次比无新活动」不是化验能答的。
    assert_eq!(item(state(&checklist(&[], vec![enable()]), "lldas"), "no_major_organ")["verdict"],
               "unknown");
}

#[test]
fn the_checklist_never_says_remission_in_its_own_words() {
    let s = serde_json::to_string(&checklist(&[], vec![enable(), pga(TODAY, 0.2)])).unwrap();
    for banned in ["已缓解", "判断缓解", "达到缓解"] {
        assert!(!s.contains(banned), "{banned}");
    }
}
```

`packages/profile/tests/common/mod.rs` 追加:

```rust
/// 把 `(日期, 文本)` 列表变成 `SourceDoc`。返回值第一项是文本的所有者,调用方
/// 必须让它活到用完 —— `SourceDoc` 借的是它。
pub fn mk_docs(docs: &[(&str, String)]) -> (Vec<String>, Vec<parser::SourceDoc<'static>>) {
    // 实现细节:测试里用 `Box::leak` 把文本泄成 'static,免得每个测试都写生命周期
    // 体操。泄的是几十字节、进程结束就回收 —— 测试专用,生产路径不用这招。
    let texts: Vec<String> = docs.iter().map(|(_, t)| t.clone()).collect();
    let src = docs
        .iter()
        .enumerate()
        .map(|(i, (d, t))| parser::SourceDoc {
            index: i,
            date: d.parse().ok(),
            text: Box::leak(t.clone().into_boxed_str()),
            doc_type: Some("lab_report".into()),
            title: None,
            extraction_json: None,
        })
        .collect();
    (texts, src)
}

/// 夹具包 = `ACTIVITY` 再加上 `rules.states`(下面那两张表)。Task 13–16 继续往
/// 同一份里加 `monitoring` / `milestones` / `views`。
pub fn full_pkg() -> profile::Package { serde_json::from_str(FULL).expect("夹具包必须解析") }
```

`FULL` 的 `rules.states`:

```json
[{"id":"doris","label":"DORIS 2021 缓解标准(逐条对照,不下结论)","source":"S5",
  "items":[
    {"id":"csledai_zero","label":"临床 SLEDAI = 0(去掉补体、dsDNA 两项)","kind":"csledai_eq",
     "value":0,"exclude":["low_complement","dsdna_high"],"source":"S5"},
    {"id":"phga","label":"医生整体评估 PhGA < 0.5","kind":"pga_lt","value":0.5,"source":"S5",
     "note":"DORIS Box 1 原文是 <0.5;中国 2025 指南写 ≤0.5,恰好等于 0.5 时两份不一致"},
    {"id":"pred","label":"泼尼松 < 5 mg/天","kind":"pred_lt","value":5,"source":"S5",
     "note":"DORIS Box 1 原文是 <5 mg/d;中国 2025 指南写 ≤5 mg/d"},
    {"id":"therapy","label":"允许用羟氯喹、低剂量激素、稳定的免疫抑制剂或生物制剂",
     "kind":"manual","source":"S5"}]},
 {"id":"lldas","label":"LLDAS 低疾病活动(逐条对照,不下结论)","source":"S6",
  "items":[
    {"id":"sledai_le4","label":"SLEDAI-2K ≤ 4","kind":"sledai_le","value":4,"source":"S6"},
    {"id":"no_major_organ","label":"肾、中枢、心肺、血管炎、发热均无活动,无溶血性贫血与消化道活动",
     "kind":"manual","source":"S6"},
    {"id":"pga_le1","label":"SELENA-SLEDAI PGA(0–3 分)≤ 1","kind":"pga_le","value":1,"source":"S6"},
    {"id":"pred_le75","label":"泼尼松(或等效)≤ 7.5 mg/天","kind":"pred_le","value":7.5,"source":"S6"},
    {"id":"no_new","label":"与上次评估相比没有新的狼疮活动表现","kind":"manual","source":"S6"}]}]
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test state_checklists`
Expected: FAIL — `有 checklist`(panic)。

- [ ] **Step 3: 实现**

追加到 `packages/profile/src/rules.rs`:

```rust
/// 三态。**`Unknown` 不是 `No`**:PGA 没人录过,不等于「没达标」——
/// 把「不知道」显示成「不达标」是在替医生下结论(spec §5.3)。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verdict { Yes, No, Unknown }

impl Verdict {
    fn as_str(self) -> &'static str {
        match self { Verdict::Yes => "yes", Verdict::No => "no", Verdict::Unknown => "unknown" }
    }
}

/// 最近一次 `pga` 事件的分值(SELENA-SLEDAI PGA,0–3)。从没录过 → `None`。
fn latest_pga(ctx: &Ctx<'_>, package_id: &str) -> Option<f64> {
    ctx.events
        .iter()
        .filter(|e| e.package == package_id && e.kind == "pga")
        .max_by(|a, b| a.at.cmp(&b.at))
        .and_then(|e| e.payload.get("value").and_then(|v| v.as_f64()))
}

pub fn states_section(ctx: &Ctx<'_>, pkg: &Package, hits: &[Hit]) -> Option<Section> {
    if pkg.rules.states.is_empty() {
        return None;
    }
    let pga = latest_pga(ctx, &pkg.manifest.id);
    let pred = latest_pred_equiv_mg(ctx, pkg); // Task 13 提供;此刻返回 None 也能编过
    let lab_score: u32 = hits.iter().map(|h| h.weight).sum();

    let mut states = Vec::new();
    for st in &pkg.rules.states {
        let mut items = Vec::new();
        let mut worst = Verdict::Yes;
        for it in st.get("items").and_then(|v| v.as_array()).into_iter().flatten() {
            let (verdict, actual) = eval_state_item(it, lab_score, hits, pga, pred);
            if verdict == Verdict::No {
                worst = Verdict::No;
            } else if verdict == Verdict::Unknown && worst != Verdict::No {
                worst = Verdict::Unknown;
            }
            items.push(serde_json::json!({
                "id": str_field(it, "id"), "label": str_field(it, "label"),
                "verdict": verdict.as_str(), "actual": actual,
                "note": it.get("note"), "source": str_field(it, "source"),
            }));
        }
        states.push(serde_json::json!({
            "id": str_field(st, "id"), "label": str_field(st, "label"),
            "source": str_field(st, "source"), "note": st.get("note"),
            "verdict": worst.as_str(), "items": items,
        }));
    }
    Some(Section {
        kind: "checklist".into(),
        title: "达标情况(逐条对照)".into(),
        empty_hint: None, // 逐条对照永远有意义:未知也是答案
        body: serde_json::json!({ "states": states }),
    })
}

fn eval_state_item(
    it: &serde_json::Value,
    lab_score: u32,
    hits: &[Hit],
    pga: Option<f64>,
    pred: Option<f64>,
) -> (Verdict, serde_json::Value) {
    let v = it.get("value").and_then(|x| x.as_f64());
    match str_field(it, "kind") {
        // 临床 SLEDAI:总分**减去** `exclude` 里那几条描述符的权重(DORIS 的
        // 「irrespective of serology」= 去掉低补体与 dsDNA 两行)。
        "csledai_eq" => {
            let excluded: Vec<&str> = it.get("exclude").and_then(|x| x.as_array())
                .map(|a| a.iter().filter_map(|s| s.as_str()).collect()).unwrap_or_default();
            let c: u32 = hits.iter().filter(|h| !excluded.contains(&h.id.as_str()))
                .map(|h| h.weight).sum();
            (if f64::from(c) == v.unwrap_or(0.0) { Verdict::Yes } else { Verdict::No },
             serde_json::json!(c))
        }
        "sledai_le" => (
            if f64::from(lab_score) <= v.unwrap_or(0.0) { Verdict::Yes } else { Verdict::No },
            serde_json::json!(lab_score),
        ),
        "pga_lt" | "pga_le" => match pga {
            None => (Verdict::Unknown, serde_json::Value::Null),
            Some(p) => {
                let ok = if str_field(it, "kind") == "pga_lt" { p < v.unwrap_or(0.0) }
                         else { p <= v.unwrap_or(0.0) };
                (if ok { Verdict::Yes } else { Verdict::No }, serde_json::json!(p))
            }
        },
        "pred_lt" | "pred_le" => match pred {
            None => (Verdict::Unknown, serde_json::Value::Null),
            Some(p) => {
                let ok = if str_field(it, "kind") == "pred_lt" { p < v.unwrap_or(0.0) }
                         else { p <= v.unwrap_or(0.0) };
                (if ok { Verdict::Yes } else { Verdict::No }, serde_json::json!(p))
            }
        },
        // 只有人能答的条目(「无重要脏器活动」「与上次比无新活动」)。二期由医生
        // 在授权查看器里录(spec §7),此刻恒为未知 —— 诚实,不猜。
        _ => (Verdict::Unknown, serde_json::Value::Null),
    }
}
```

`materialize` 里,在 activity 之后:

```rust
        let hits = rules::activity_hits(&ctx, pkg); // 把 Task 11 的命中抽成可复用函数
        out.extend(rules::activity_section_from(&ctx, pkg, &hits));
        out.extend(rules::states_section(&ctx, pkg, &hits));
```

> 重构 Task 11:把 `activity_section` 拆成 `activity_hits(ctx, pkg) -> Vec<Hit>` 与
> `activity_section_from(ctx, pkg, &hits) -> Option<Section>`,两处共用同一份命中,
> 避免算两遍(也避免两遍算出不同分数)。Task 11 的测试不改一个字。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): DORIS / LLDAS 逐条三态检查表

未知不是不达标 —— PGA 没录过就显示未知。cSLEDAI 按 DORIS 原文去掉补体与
dsDNA 两项。<0.5 / ≤0.5 这类指南分歧在条目上直接注出来。不下缓解结论。"
```

---

### Task 13: 现行方案卡 —— 泼尼松等效日剂量与羟氯喹 mg/kg

**Files:**
- Modify: `packages/profile/src/rules.rs`(加 `status_section`、`latest_pred_equiv_mg`、`hcq_mg_per_kg`)
- Modify: `packages/profile/src/lib.rs`
- Create: `packages/profile/tests/drug_status.rs`
- Modify: `packages/profile/tests/common/mod.rs`(夹具包加 `drugs`)

**Interfaces:**
- Consumes: `Ctx.clinical.meds`(`parser::MedSpan{drug_key,name,atc,latest_dose,start,end,status,sources}`)、`Ctx.clinical.labs` 里的 `body_weight` 自测序列、`Ctx.events` 的 `weight` / `drug_start` / `drug_stop`
- Produces:
  - `rules::latest_pred_equiv_mg(ctx: &Ctx, pkg: &Package) -> Option<f64>`
  - `rules::status_section(ctx: &Ctx, pkg: &Package) -> Option<Section>`(`kind == "status_card"`)
  - `body`:`{"gc":{"daily_pred_equiv_mg","drug","since","targets":[{"value","label","source"}],"unconvertible":[{"name","dose","reason"}]},"hcq":{"daily_mg","weight_kg","weight_source","mg_per_kg","target","target_source","label_rule","label_rule_pending"},"others":[{"class","name","latest_dose","since","infusion"}],"last_visit":{"date","title"}}`
    (`label_rule` 是包里 `rules.targets.hcq.label_rule.text` 的原串,
    `label_rule_pending` 是它的 `verify_status == "pending"`)
- **`pred_equiv` 为 `null` 时**:只有泼尼松本身(系数 1,按定义)计入日剂量;其它糖皮质激素进 `unconvertible`,界面显示「等效换算表待核,这一项没算进去」

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/drug_status.rs`:

```rust
use chrono::NaiveDate;
mod common;
use common::{full_pkg, mk_docs, rx_doc, TODAY};

fn day(s: &str) -> NaiveDate { s.parse().unwrap() }

fn status(docs: &[(&str, String)], events: Vec<parser::ProfileEvent>) -> serde_json::Value {
    let (h, src) = mk_docs(docs);
    let _ = &h;
    let v = profile::materialize(&src, &events, &full_pkg(), day(TODAY));
    v.sections.iter().find(|s| s.kind == "status_card").expect("有 status_card").body.clone()
}

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent { kind: "enable".into(), package: "t".into(), at: "2026-01-01".into(),
                           payload: serde_json::json!({}) }
}

#[test]
fn prednisone_daily_dose_is_read_from_the_prescription() {
    let b = status(&[(TODAY, rx_doc("泼尼松片 10mg 每日一次 口服"))], vec![enable()]);
    assert_eq!(b["gc"]["daily_pred_equiv_mg"], 10.0);
    assert_eq!(b["gc"]["drug"], "泼尼松");
}

#[test]
fn another_glucocorticoid_is_not_silently_converted_while_the_table_is_unverified() {
    // 包里 pred_equiv 是 null(换算表还没核实,sle-clinical-sources §G)。
    // 编一个系数比不显示更糟:剂量会直接进 DORIS「<5 mg」那一条的判定。
    let b = status(&[(TODAY, rx_doc("甲泼尼龙片 8mg 每日一次 口服"))], vec![enable()]);
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null());
    assert_eq!(b["gc"]["unconvertible"][0]["name"], "甲泼尼龙");
    // 界面上原样显示这五个字(Task 21 的 status_card 断言同一串),不是一句模糊的
    // 「无法计算」—— 用户和医生要知道缺的是**换算表**,不是缺药。
    assert_eq!(b["gc"]["unconvertible"][0]["reason"], "换算表待核");
}

#[test]
fn hcq_mg_per_kg_uses_the_most_recent_weight_and_says_where_it_came_from() {
    let events = vec![
        enable(),
        parser::ProfileEvent { kind: "weight".into(), package: "t".into(), at: "2026-09-10".into(),
                               payload: serde_json::json!({"kg": 60.0}) },
    ];
    let b = status(&[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))], events);
    assert_eq!(b["hcq"]["daily_mg"], 400.0);
    assert_eq!(b["hcq"]["weight_kg"], 60.0);
    assert!((b["hcq"]["mg_per_kg"].as_f64().unwrap() - 6.667).abs() < 0.01);
    assert_eq!(b["hcq"]["target"], 5.0);
    assert_eq!(b["hcq"]["weight_source"], "self_reported");
}

#[test]
fn hcq_without_a_weight_shows_the_dose_but_no_mg_per_kg() {
    let b = status(&[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))], vec![enable()]);
    assert_eq!(b["hcq"]["daily_mg"], 400.0);
    assert!(b["hcq"]["mg_per_kg"].is_null(), "没有体重就不给 mg/kg,别拿理想体重猜");
}

#[test]
fn hcq_card_states_both_the_guideline_rule_and_the_package_insert_rule() {
    // sle-clinical-sources §D.2.1:指南 5 mg/kg 真实体重 vs 说明书 6.5 mg/kg 理想体重。
    // 用户手里那张说明书写的就是另一个数,界面只说一个就是在制造矛盾。
    let b = status(&[(TODAY, rx_doc("硫酸羟氯喹片 0.2g 每日两次 口服"))], vec![enable()]);
    let insert = b["hcq"]["label_rule"].as_str().unwrap();
    assert!(insert.contains("6.5"));
    assert!(insert.contains("理想体重"));
    assert_eq!(b["hcq"]["target_source"], "S4");
    // 说明书那串还没有人对着纸核过 —— 界面必须让医生知道这一点。
    assert_eq!(b["hcq"]["label_rule_pending"], true);
}

#[test]
fn gc_targets_carry_both_years_because_the_two_guidelines_differ() {
    let b = status(&[(TODAY, rx_doc("泼尼松片 10mg 每日一次 口服"))], vec![enable()]);
    let t = b["gc"]["targets"].as_array().unwrap();
    assert_eq!(t.len(), 2);
    assert!(t.iter().any(|x| x["value"] == 7.5 && x["label"].as_str().unwrap().contains("2019")));
    assert!(t.iter().any(|x| x["value"] == 5.0 && x["label"].as_str().unwrap().contains("2023")));
}

#[test]
fn biologics_show_their_infusion_rhythm_from_the_package() {
    let b = status(&[(TODAY, rx_doc("贝利尤单抗 400mg 静脉滴注"))], vec![enable()]);
    let o = b["others"].as_array().unwrap();
    let bel = o.iter().find(|x| x["class"] == "belimumab").expect("认出贝利尤单抗");
    assert!(bel["infusion"]["iv"].as_str().unwrap().contains("每 4 周"));
}
```

`common/mod.rs` 追加:

```rust
/// 把几行医嘱包成一份处方笺文本(`extract_meds` 只在 `doc_type` 含 prescription 时跑)。
pub fn rx_doc(rows: &str) -> String { format!("处方笺\nRp:\n{rows}\n") }
```

并把 `mk_docs` 的 `doc_type` 改成按文本首行判断:含「处方」→ `"prescription"`,否则 `"lab_report"`。

`FULL` 的 `drugs` 数组用 spec §2 那一份,但 **`pred_equiv` 与 `pred_equiv_source` 都写 `null`**
(换算表未核实,Task 19 才填),`belimumab` 的 `infusion` 写
`{"iv":"第 0、2、4 周,之后每 4 周","sc":"每周 200 mg(狼疮肾炎为每周 400 mg×4 次后改 200 mg)"}`。

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test drug_status`
Expected: FAIL — `有 status_card`(panic)。

- [ ] **Step 3: 实现**

追加到 `packages/profile/src/rules.rs`:

```rust
/// 把 `MedSpan` 归到包里的某个 `drugs[]` 类(先按 `atc_prefix`,再按 `names` 逐字含)。
fn drug_class<'p>(pkg: &'p Package, m: &parser::MedSpan) -> Option<&'p crate::package::Drug> {
    pkg.drugs.iter().find(|d| {
        d.atc_prefix.as_deref().is_some_and(|p| m.atc.as_deref().is_some_and(|a| a.starts_with(p)))
            || d.names.iter().any(|n| m.name.contains(n.as_str()))
    })
}

/// 从「0.2g」「10mg」这类剂量串里取 mg 数。认不出返回 `None` —— 猜一个数会直接
/// 进 DORIS 的「泼尼松 <5 mg」判定,错的比没有更糟。
fn dose_mg(s: &str) -> Option<f64> {
    let t = s.trim().to_lowercase().replace(' ', "");
    if let Some(v) = t.strip_suffix("mg") { v.parse::<f64>().ok() }
    else if let Some(v) = t.strip_suffix('g') { v.parse::<f64>().ok().map(|x| x * 1000.0) }
    else { None }
}

/// 每天几次:`每日一次`/`qd`→1,`每日两次`/`bid`→2,`每日三次`/`tid`→3。认不出 → `None`。
fn per_day(freq: &str) -> Option<f64> {
    let f = freq.to_lowercase();
    for (pat, n) in [("每日一次", 1.0), ("qd", 1.0), ("每日两次", 2.0), ("bid", 2.0),
                     ("每日二次", 2.0), ("每日三次", 3.0), ("tid", 3.0)] {
        if f.contains(pat) { return Some(n); }
    }
    None
}

/// 最近一次泼尼松**等效**日剂量(mg)。
///
/// `pred_equiv` 表还没核实时(`None`),**只认泼尼松本身**(系数 1,按定义):
/// 给别的糖皮质激素编一个系数,会让 DORIS「<5 mg/d」那一条得出一个编出来的答案。
pub fn latest_pred_equiv_mg(ctx: &Ctx<'_>, pkg: &Package) -> Option<f64> {
    for m in &ctx.clinical.meds {
        let Some(d) = drug_class(pkg, m) else { continue };
        if d.class != "gc" { continue; }
        let Some(dose) = m.latest_dose.as_deref().and_then(dose_mg) else { continue };
        let times = per_day(m.latest_dose.as_deref().unwrap_or_default()).unwrap_or(1.0);
        let factor = match &d.pred_equiv {
            Some(tbl) => *tbl.iter().find(|(k, _)| m.name.contains(k.as_str()))?.1,
            // 表待核:只有泼尼松/泼尼松龙本身是 1(定义),别的返回 None。
            None if m.name.contains("泼尼松") && !m.name.contains("甲泼尼龙") => 1.0,
            None => continue,
        };
        return Some(dose * times * factor);
    }
    None
}
```

`status_section` 按上面测试断言的 `body` 形状组装(`gc` / `hcq` / `others` / `last_visit`);
`pred_equiv` 为 `null` 时,每个非泼尼松的糖皮质激素进 `gc.unconvertible`,`reason` **逐字**
写 `"换算表待核"`(Task 19 把表填上之后这个分支自然不再触发,代码不用改);
体重来源优先级:`profile_event{kind:"weight"}` 最近一条 → `body_weight` 自测序列最近一点 →
病历里的 `body_weight` 序列最近一点;三者都没有 → `mg_per_kg: null`,`weight_source: null`。
`hcq.target` / `target_source` 直接从包的 `rules.targets.hcq` 取(Task 18 填);
`label_rule` 取 `label_rule.text`,`label_rule_pending` 取 `label_rule.verify_status == "pending"`。
**说明书那几个数只进这两个字段,不进任何判定** —— `mg_per_kg` 永远只跟 `target`(指南值)比。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): 现行方案卡 —— 激素等效日剂量与 HCQ mg/kg

等效换算表未核实期间只认泼尼松本身,其它激素如实标「换算表待核、没算进去」:
编一个系数会直接污染 DORIS 的 <5 mg 判定。没体重就不给 mg/kg。
HCQ 同时显示指南值(5 mg/kg 真实体重)和说明书值(6.5 mg/kg 理想体重)。"
```

---

### Task 14: 复查提醒 —— 只许两类来源

**Files:**
- Modify: `packages/profile/src/rules.rs`(加 `reminders_section`)
- Modify: `packages/profile/src/lib.rs`
- Create: `packages/profile/tests/reminders.rs`
- Modify: `packages/profile/tests/common/mod.rs`(夹具包加 `rules.monitoring`)

**Interfaces:**
- Consumes: `Ctx`(序列最近日期、`exam_done` facts、用药起始日)、Task 13 的 `latest_pred_equiv_mg`
- Produces:
  - `rules::reminders_section(ctx: &Ctx, pkg: &Package) -> Option<Section>`(`kind == "reminders"`)
  - **三种** `monitoring` kind,**没有第四种**(spec §5.4:不许按单项指标造复查间隔):
    - `disease_cadence` —— `{"id","state":"active|stable","every_days","panel_keys":[],"text","basis","source"}`
    - `drug_schedule` —— `{"id","drug_class","target","phases":[{"until_days","every_days"}],"basis","source"}`
    - `drug_threshold` —— `{"id","drug_class","min_daily_pred_equiv","min_days","min_age","action","basis","source"}`
  - 每条提醒带 `basis ∈ {"guideline","label","literature","package_default"}` 与 `source`
    (`literature` = 有一手文献但**不是**指南也不是说明书,例如 RTX 的 IgG 监测)
  - 逾期判定:`最近一次日期 + 间隔 × 1.2 < today` → `"overdue"`;从没查过 → `"never"`;否则不出现
  - `dismiss_reminder` 事件(payload `{"id": "<提醒 id>"}`)让该条本轮不再出现,**下次到期再提**

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/reminders.rs`:

```rust
use chrono::NaiveDate;
mod common;
use common::{full_pkg, lab_doc, mk_docs, rx_doc, TODAY};

fn day(s: &str) -> NaiveDate { s.parse().unwrap() }

fn reminders(docs: &[(&str, String)], events: Vec<parser::ProfileEvent>) -> Vec<serde_json::Value> {
    let (h, src) = mk_docs(docs);
    let _ = &h;
    let v = profile::materialize(&src, &events, &full_pkg(), day(TODAY));
    v.sections.iter().find(|s| s.kind == "reminders")
        .map(|s| s["items"].as_array().cloned().unwrap_or_default())
        .unwrap_or_default()
}

fn enable() -> parser::ProfileEvent {
    parser::ProfileEvent { kind: "enable".into(), package: "t".into(), at: "2026-01-01".into(),
                           payload: serde_json::json!({}) }
}

fn ids(items: &[serde_json::Value]) -> Vec<String> {
    items.iter().map(|i| i["id"].as_str().unwrap().to_string()).collect()
}

#[test]
fn a_cbc_that_is_due_but_not_yet_overdue_does_not_nag() {
    // MMF 第 4 个月起每月一次血常规(说明书 VERBATIM)。1.2 倍宽限 = 36 天。
    let start = "2025-01-01";
    let items = reminders(
        &[(start, rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
          ("2026-08-20", lab_doc("白细胞 5.0 10^9/L 3.5-9.5"))], // 27 天前
        vec![enable()],
    );
    assert!(!ids(&items).contains(&"mmf_cbc".to_string()));
}

#[test]
fn the_same_cbc_past_one_point_two_intervals_is_overdue() {
    let items = reminders(
        &[("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
          ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5"))], // 39 天前 > 36
        vec![enable()],
    );
    let r = items.iter().find(|i| i["id"] == "mmf_cbc").expect("应当逾期");
    assert_eq!(r["state"], "overdue");
    assert_eq!(r["basis"], "label");
}

#[test]
fn a_test_that_was_never_done_says_never_not_overdue() {
    let items = reminders(&[("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
                          vec![enable()]);
    assert_eq!(items.iter().find(|i| i["id"] == "mmf_cbc").unwrap()["state"], "never");
}

#[test]
fn the_visit_reminder_talks_about_the_visit_not_about_one_lab() {
    // spec §5.4:没有任何指南给 dsDNA/补体/尿蛋白单项间隔。文案必须是「该复诊了,
    // 通常会查…」,不能是「你的 dsDNA 过期了」。
    let items = reminders(&[], vec![enable()]);
    let v = items.iter().find(|i| i["id"].as_str().unwrap().starts_with("visit_")).unwrap();
    assert!(v["text"].as_str().unwrap().contains("复诊"));
    for banned in ["dsDNA 过期", "补体该复查了", "尿蛋白到期"] {
        assert!(!v["text"].as_str().unwrap().contains(banned));
    }
    assert!(v["panel_keys"].as_array().unwrap().len() >= 3, "复诊时该查的一组指标由包列出");
}

#[test]
fn every_reminder_carries_a_basis_and_a_source() {
    for r in reminders(&[("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服"))],
                       vec![enable()]) {
        let basis = r["basis"].as_str().unwrap();
        assert!(["guideline", "label", "literature", "package_default"].contains(&basis), "{basis}");
        assert!(!r["source"].as_str().unwrap().is_empty());
    }
}

#[test]
fn calcium_and_vitamin_d_fire_only_past_seven_point_five_mg_for_three_months() {
    // VERBATIM:「started on prednisone ⩾7.5 mg daily and continues for more than 3 months」。
    let long_ago = "2026-01-01"; // > 3 个月
    let items = reminders(&[(long_ago, rx_doc("泼尼松片 7.5mg 每日一次 口服"))], vec![enable()]);
    assert!(ids(&items).contains(&"gc_ca_vitd".to_string()));

    let items = reminders(&[(long_ago, rx_doc("泼尼松片 5mg 每日一次 口服"))], vec![enable()]);
    assert!(!ids(&items).contains(&"gc_ca_vitd".to_string()), "5 mg 不到 7.5 的阈");

    let recent = "2026-08-20"; // < 3 个月
    let items = reminders(&[(recent, rx_doc("泼尼松片 10mg 每日一次 口服"))], vec![enable()]);
    assert!(!ids(&items).contains(&"gc_ca_vitd".to_string()), "不满 3 个月不提醒");
}

#[test]
fn dismissing_a_reminder_hides_it_until_the_next_due_date() {
    let docs = [("2025-01-01", rx_doc("吗替麦考酚酯胶囊 0.5g 每日两次 口服")),
                ("2026-08-08", lab_doc("白细胞 5.0 10^9/L 3.5-9.5"))];
    let dismiss = parser::ProfileEvent {
        kind: "dismiss_reminder".into(), package: "t".into(), at: "2026-09-15".into(),
        payload: serde_json::json!({"id": "mmf_cbc"}),
    };
    assert!(!ids(&reminders(&docs, vec![enable(), dismiss.clone()]))
        .contains(&"mmf_cbc".to_string()));
    // 忽略发生在**上一次到期之前**就不算数了(又到期了要再提)。
    let old_dismiss = parser::ProfileEvent { at: "2026-07-01".into(), ..dismiss };
    assert!(ids(&reminders(&docs, vec![enable(), old_dismiss])).contains(&"mmf_cbc".to_string()));
}

#[test]
fn the_package_only_ever_contains_the_three_allowed_monitoring_kinds() {
    // 这条是**红线守卫**:多一种 kind 就意味着有人在按单项指标造间隔。
    for m in &full_pkg().rules.monitoring {
        let k = m["kind"].as_str().unwrap();
        assert!(["disease_cadence", "drug_schedule", "drug_threshold"].contains(&k), "{k}");
    }
}
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test reminders`
Expected: FAIL — 所有断言都拿到空列表。

- [ ] **Step 3: 实现**

`reminders_section` 的骨架(细节照测试断言补全):

```rust
/// 复查提醒。**只有三种来源**(spec §5.4):病级复诊节律、药物说明书/指南明示的
/// 频率、包默认(必须标出来)。**不许**按单项化验指标造间隔 —— 核查结论是中国
/// 2020/2025 与 EULAR 都没有给 dsDNA/补体/尿蛋白/血常规任何单项间隔
/// (sle-clinical-sources §A.1 的「最重要的负面发现」)。
pub fn reminders_section(ctx: &Ctx<'_>, pkg: &Package) -> Option<Section> {
    let mut items: Vec<serde_json::Value> = Vec::new();
    for m in &pkg.rules.monitoring {
        let Some(r) = eval_monitor(ctx, pkg, m) else { continue };
        if dismissed(ctx, pkg, str_field(m, "id"), &r) { continue; }
        items.push(r);
    }
    // 排序:从没查过的排在逾期前面(「还没查过」是更硬的缺口),同类按逾期天数倒序。
    items.sort_by_key(|i| {
        (if i["state"] == "never" { 0 } else { 1 }, -(i["overdue_days"].as_i64().unwrap_or(0)))
    });
    (!items.is_empty() || !pkg.rules.monitoring.is_empty()).then(|| Section {
        kind: "reminders".into(),
        title: "待补 / 逾期".into(),
        empty_hint: items.is_empty().then(|| "该查的都查过了".to_string()),
        body: serde_json::json!({ "items": items }),
    })
}

/// 一条提醒被忽略过、且**从那以后没有再到期**,就不再显示。到期时间重新过了,
/// 忽略就失效(spec §5.4:「下次到期再提」)。
fn dismissed(ctx: &Ctx<'_>, pkg: &Package, id: &str, r: &serde_json::Value) -> bool {
    let due: Option<NaiveDate> = r["due_at"].as_str().and_then(|s| s.parse().ok());
    ctx.events
        .iter()
        .filter(|e| e.package == pkg.manifest.id && e.kind == "dismiss_reminder")
        .filter(|e| e.payload.get("id").and_then(|v| v.as_str()) == Some(id))
        .filter_map(|e| e.at.parse::<NaiveDate>().ok())
        .any(|at| due.is_none_or(|d| at >= d))
}
```

`eval_monitor` 三个分支:
- `disease_cadence` —— 活动/稳定由最近一次 `flare` fact 或 `profile_event{kind:"flare"}` 在
  90 天内决定(活动),否则稳定;取最近一次**就诊**日期(`Ctx` 里 `doc_type` 含 `outpatient`/
  `discharge` 的最新文档)与 `every_days` 比。
- `drug_schedule` —— 用药起始日(`MedSpan.start` 或 `profile_event{kind:"drug_start"}`)决定
  当前落在哪个 `phase`,`target` 映射到一组分析物 key(`cbc` → `["wbc","plt","hb"]`)或
  `exam:<名>`(查 `exam_done` fact 的 `name`)。
- `drug_threshold` —— 用 `latest_pred_equiv_mg` 与用药持续天数、`min_age`(来自档案成员年龄,
  没有年龄就当**不满足**,不猜)判定。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): 复查提醒,只许病级节律与药物明示频率两类来源

没有任何指南给 dsDNA/补体/尿蛋白单项间隔,所以复诊提醒说的是「该复诊了,
通常会查…」。每条带 指南/说明书/包默认 三选一的标签与出处 id。
逾期 = 超过间隔 ×1.2;忽略只压住本轮,下次到期再提。"
```

---

### Task 15: 趋势与时间轴两块 section

**Files:**
- Modify: `packages/profile/src/rules.rs`(加 `series_section`、`timeline_section`)
- Modify: `packages/profile/src/lib.rs`
- Create: `packages/profile/tests/series_and_timeline.rs`

**Interfaces:**
- Consumes: `pkg.markers[]`(`key`/`role`/`dir`/`group`/`qualitative_ok`)、`Ctx.clinical.labs`、`Ctx.facts`
- Produces:
  - `rules::series_section(ctx: &Ctx, pkg: &Package) -> Option<Section>`(`kind == "series_chart"`)
    `body`:`{"groups":[{"name","series":[{"analyte_key","name","unit","ref_low","ref_high","values_converted","needs_review_count","dir","role","points":[{"date","value","flag","unverified","document_index"}]}]}],"missing":[{"key","name"}]}`
  - `rules::timeline_section(ctx: &Ctx, pkg: &Package) -> Option<Section>`(`kind == "timeline"`)
    `body`:`{"years":[{"year","events":[{"type","date","text","severity","document_index","unverified"}]}]}`
- 硬规矩:**各院参考区间用各自单子的**(直接透传 `AnalyteSeries.ref_low/ref_high`,不换成指南目标值);UPCR 与 24h 尿蛋白**分成两条线**,不合并;`unverified` 的点原样带出去给渲染层画空心点

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/series_and_timeline.rs`:

```rust
use chrono::NaiveDate;
mod common;
use common::{full_pkg, lab_doc, mk_docs, TODAY};

fn day(s: &str) -> NaiveDate { s.parse().unwrap() }

fn sections(docs: &[(&str, String)], ex: Option<&'static str>) -> Vec<profile::Section> {
    let (h, mut src) = mk_docs(docs);
    let _ = &h;
    if let Some(j) = ex { src[0].extraction_json = Some(j); }
    let ev = vec![parser::ProfileEvent { kind: "enable".into(), package: "t".into(),
                                         at: "2026-01-01".into(), payload: serde_json::json!({}) }];
    profile::materialize(&src, &ev, &full_pkg(), day(TODAY)).sections
}

fn body(secs: &[profile::Section], kind: &str) -> serde_json::Value {
    secs.iter().find(|s| s.kind == kind).unwrap_or_else(|| panic!("有 {kind}")).body.clone()
}

#[test]
fn each_series_keeps_the_reference_range_printed_on_its_own_report() {
    // 硬规矩:各院参考区间用各自单子的。把它换成指南目标值,用户拿手里那张纸
    // 一对就对不上,而且「正常/异常」的判定会跟着医院变 —— 那是医院的事实。
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], None);
    let g = body(&s, "series_chart");
    let one = &g["groups"][0]["series"][0];
    assert_eq!(one["analyte_key"], "complement_c3");
    assert_eq!(one["ref_low"], 0.9);
    assert_eq!(one["ref_high"], 1.8);
}

#[test]
fn upcr_and_twenty_four_hour_protein_are_two_separate_lines() {
    // §11 已知边界:UPCR ≠ 24h 尿蛋白。画成一条线是把两个不同的量当成同一个。
    let s = sections(
        &[(TODAY, lab_doc("尿蛋白肌酐比 1200 mg/g\n24小时尿蛋白定量 1.1 g/24h"))], None);
    let keys: Vec<String> = body(&s, "series_chart")["groups"].as_array().unwrap().iter()
        .flat_map(|g| g["series"].as_array().unwrap().clone())
        .map(|x| x["analyte_key"].as_str().unwrap_or_default().to_string())
        .collect();
    assert!(keys.contains(&"urine_pcr".to_string()));
    assert!(keys.contains(&"urine_protein_24h".to_string()));
}

#[test]
fn an_unverified_point_stays_flagged_all_the_way_out() {
    let ex = r#"{"labs":[{"name":"补体C3","value":"0.4","unit":"g/L","ref_low":"0.9",
                 "ref_high":"1.8","flag":"","unverified":true}],"facts":[]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let one = &body(&s, "series_chart")["groups"][0]["series"][0];
    assert_eq!(one["needs_review_count"], 1);
    assert_eq!(one["points"][0]["unverified"], true);
}

#[test]
fn a_marker_with_no_data_is_listed_as_missing_not_silently_dropped() {
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], None);
    let missing: Vec<String> = body(&s, "series_chart")["missing"].as_array().unwrap().iter()
        .map(|m| m["key"].as_str().unwrap().to_string()).collect();
    assert!(missing.contains(&"anti_dsdna".to_string()), "包里点了名却一次都没查过要说出来");
}

#[test]
fn the_timeline_groups_facts_by_year_and_marks_flares() {
    let ex = r#"{"labs":[],"facts":[
        {"type":"flare","date":"2024-03-02","text":"病情活动加重","evidence":"病情活动加重"},
        {"type":"biopsy","organ":"kidney","date":"2024-03-10","result":"ISN/RPS IV 型",
         "evidence":"ISN/RPS IV 型"},
        {"type":"infusion","drug":"贝利尤单抗","dose":"400mg","date":"2026-08-01",
         "evidence":"贝利尤单抗 400mg"}]}"#;
    let s = sections(&[(TODAY, lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let years = body(&s, "timeline")["years"].as_array().unwrap().clone();
    let y2024 = years.iter().find(|y| y["year"] == 2024).expect("2024 那一年");
    assert_eq!(y2024["events"].as_array().unwrap().len(), 2);
    let flare = y2024["events"][0].clone();
    assert_eq!(flare["type"], "flare");
    assert_eq!(flare["severity"], "high", "复发标红");
    assert!(years.iter().any(|y| y["year"] == 2026));
}

#[test]
fn a_fact_without_its_own_date_falls_back_to_the_document_date() {
    let ex = r#"{"labs":[],"facts":[{"type":"infection","date":"","text":"带状疱疹",
                 "evidence":"带状疱疹"}]}"#;
    let s = sections(&[("2025-06-01", lab_doc("补体C3 0.4 g/L 0.9-1.8"))], Some(ex));
    let years = body(&s, "timeline")["years"].as_array().unwrap().clone();
    assert!(years.iter().any(|y| y["year"] == 2025));
}
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test series_and_timeline`
Expected: FAIL — `有 series_chart`(panic)。

- [ ] **Step 3: 实现**

`series_section`:遍历 `pkg.markers`,在 `ctx.clinical.labs` 里找 `analyte_key == marker.key`
且 `!self_measured` 的序列;找到的按 `marker.group`(`None` → `marker.role`)分组输出,
`ref_low`/`ref_high`/`values_converted`/`needs_review_count` **原样透传**;一次都没有的进 `missing`。

`timeline_section`:把 `ctx.facts` 里 `type ∈ {flare, hospitalization, biopsy, infusion,
dose_change, infection, pregnancy}` 的取出来,日期用 `fact.date`(空则退回文档日期),
按年分桶、年内按日期升序;`severity`:`flare`/`hospitalization` → `"high"`,其余 `"normal"`;
`unverified` 原样带出。`years` 按年升序。facts 与 meds 都为空时 `empty_hint` =
「还没有可以放上时间轴的记录,导入门诊病历或出院小结后这里会自动长出来」。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile
git commit -m "feat(profile): 趋势与时间轴两块 section

参考区间原样用各院单子上印的那对数;UPCR 与 24h 尿蛋白分成两条线;
包里点名却一次都没查过的指标进 missing,不静默消失。"
```

---

### Task 16: 狼疮肾炎里程碑 + 合成 SLE 病程语料 + golden ProfileView

**Files:**
- Modify: `packages/profile/src/rules.rs`(加 `milestones_section`)
- Modify: `packages/profile/src/lib.rs`
- Create: `examples/demo-dataset/generate_sle.sh`
- Modify: `examples/demo-dataset/extract_fixtures.py`(源/目标改成一张表,支持两套语料)
- Create: `packages/profile/testdata/corpus/*.txt`(由脚本生成并 commit)
- Create: `packages/profile/testdata/golden_profile_view.json`
- Create: `packages/profile/tests/golden_sle_course.rs`

**Interfaces:**
- Consumes: 前面全部 section
- Produces:
  - `rules::milestones_section(ctx: &Ctx, pkg: &Package) -> Option<Section>`(`kind == "score_card"` 的兄弟,用 `kind == "checklist"` 复用渲染;**本任务定为 `kind: "checklist"`**,标题「狼疮肾炎治疗里程碑」)
  - `milestones` 条目 kind:`proteinuria_drop_pct` / `upcr_below` / `gfr_pct_of_baseline` / `biopsy_indication`
  - golden:`packages/profile/testdata/golden_profile_view.json` 逐字段钉住整份 `ProfileView`

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/golden_sle_course.rs`:

```rust
//! 合成 SLE 病程的 golden ProfileView。
//!
//! 语料文本本身是**写出来的**(模拟医院打印件,这一层没法用生产代码产出),但
//! 从文本往后的每一步都走生产路径:`parser::aggregate` → `profile::materialize`。
//! golden 文件由 `UPDATE_GOLDEN=1` 重新生成,**任何一次重生成都必须人工看 diff**:
//! 这份文件的作用就是让规则的改动无处可藏。
use chrono::NaiveDate;
use std::path::{Path, PathBuf};

mod common;

fn testdata() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

/// 语料文件名形如 `2024-03-02_出院记录_协和.txt`,日期与类型都在名字里。
fn load_corpus() -> Vec<(String, NaiveDate, String)> {
    let mut out = Vec::new();
    for f in std::fs::read_dir(testdata().join("corpus")).unwrap().flatten() {
        let p = f.path();
        let stem = p.file_stem().unwrap().to_string_lossy().to_string();
        let mut parts = stem.splitn(3, '_');
        let date: NaiveDate = parts.next().unwrap().parse().unwrap();
        let kind = parts.next().unwrap().to_string();
        out.push((kind, date, std::fs::read_to_string(&p).unwrap()));
    }
    out.sort_by_key(|(_, d, _)| *d);
    out
}

fn doc_type_for(kind: &str) -> &'static str {
    match kind {
        "检验报告" => "lab_report",
        "处方" => "prescription",
        "出院记录" => "discharge_summary",
        "门诊病历" => "outpatient",
        "病理报告" => "pathology",
        "眼科报告" | "输液记录" => "clinical_note",
        _ => "other",
    }
}

#[test]
fn the_synthetic_sle_course_renders_the_pinned_profile_view() {
    let corpus = load_corpus();
    assert!(corpus.len() >= 12, "3 年 4 家医院的病程至少该有十几份文档,实际 {}", corpus.len());

    let docs: Vec<parser::SourceDoc> = corpus
        .iter()
        .enumerate()
        .map(|(i, (kind, date, text))| parser::SourceDoc {
            index: i,
            date: Some(*date),
            text,
            doc_type: Some(doc_type_for(kind).into()),
            title: None,
            extraction_json: None,
        })
        .collect();

    let events = vec![
        parser::ProfileEvent { kind: "enable".into(), package: "sle".into(),
                               at: "2024-03-15".into(), payload: serde_json::json!({}) },
        parser::ProfileEvent { kind: "weight".into(), package: "sle".into(),
                               at: "2026-09-01".into(), payload: serde_json::json!({"kg": 56.0}) },
    ];

    // 用**测试夹具包**,不是 skills/ 里那份 —— 那份要到 Task 18 才存在,而这条测试
    // 测的是规则引擎。两份内容一致由 Task 18 的
    // `the_shipped_sle_package_matches_the_test_fixture` 钉住。
    let pkg = common::full_pkg();
    let view = profile::materialize(&docs, &events, &pkg, "2026-09-16".parse().unwrap());
    let got = serde_json::to_value(&view).unwrap();

    let golden_path = testdata().join("golden_profile_view.json");
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::write(&golden_path, serde_json::to_string_pretty(&got).unwrap() + "\n").unwrap();
        panic!("golden 已重写 —— 人工 review 这次 diff 之后再跑一遍(不带 UPDATE_GOLDEN)");
    }
    let want: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&golden_path).unwrap()).unwrap();
    assert_eq!(got, want, "ProfileView 与 golden 不一致");
}

#[test]
fn the_golden_view_never_claims_remission_or_a_sledai_total() {
    let s = std::fs::read_to_string(testdata().join("golden_profile_view.json")).unwrap();
    for banned in ["SLEDAI 总分", "已缓解", "判断缓解", "达到缓解", "计算 SLEDAI"] {
        assert!(!s.contains(banned), "golden 里出现了禁用措辞:{banned}");
    }
}

#[test]
fn every_number_in_the_golden_view_traces_to_a_declared_source_id() {
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(testdata().join("golden_profile_view.json"))
            .unwrap()).unwrap();
    let declared: Vec<String> = v["sources"].as_array().unwrap().iter()
        .map(|s| s["id"].as_str().unwrap().to_string()).collect();
    fn walk(v: &serde_json::Value, declared: &[String]) {
        match v {
            serde_json::Value::Object(m) => {
                if let Some(s) = m.get("source").and_then(|x| x.as_str()) {
                    assert!(declared.contains(&s.to_string()), "出处 id {s} 没在 sources 里声明");
                }
                for x in m.values() { walk(x, declared); }
            }
            serde_json::Value::Array(a) => for x in a { walk(x, declared) },
            _ => {}
        }
    }
    walk(&v, &declared);
}
```

`packages/profile/tests/ln_milestones.rs`(阈值边界,数值逐字取自 §E.1/§E.2):

```rust
// 25% by 3 months / 50% by 6 months / UPCR <700 mg/g by 12 months /
// 完全肾应答 UPCR <500 mg/g 任一时点 / GFR ≥ 基线 80% / 活检指征 ≥0.5 g/24h 或 UPCR ≥500 mg/g
// 每条一个「恰好在阈上」+ 一个「恰好在阈下」用例,断言 verdict 与 actual,
// 并断言每条都带 source 与年份(spec §5.5:四个阈值都带出处与年份)。
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test golden_sle_course`
Expected: FAIL — `testdata/corpus` 目录不存在。

- [ ] **Step 3: 造语料、实现里程碑、生成 golden**

`examples/demo-dataset/generate_sle.sh`:照 `generate.sh` 的 `write_txt "<name>" <<'EOF' … EOF`
体例写一个**新病人**(不要往张建国身上加免疫病 —— 那会污染既有语料的断言),覆盖
spec §9 要求的:3 年跨度、4 家医院、含肾活检病理、生物制剂输注记录、眼科报告,以及
补体/dsDNA/24h 尿蛋白/UPCR/血常规的连续化验与处方。每份文件名
`YYYY-MM-DD_<类型>_<医院>.txt`。

`examples/demo-dataset/extract_fixtures.py`:把 `SRC`/`DST` 两个常量换成一张表,其余不动:

```python
# (语料生成脚本, 抽出来的 fixture 目录)。两套语料:张建国(慢病,parser 用)与
# 合成 SLE 病程(profile 用)。合在一个病人身上会让既有 corpus 断言全部漂移。
CORPORA = [
    (ROOT / "examples/demo-dataset/generate.sh", ROOT / "packages/parser/tests/fixtures/corpus"),
    (ROOT / "examples/demo-dataset/generate_sle.sh", ROOT / "packages/profile/testdata/corpus"),
]
```

`main()` 里对 `CORPORA` 逐对跑原来那段逻辑。

`milestones_section` 实现:T0 = 最早的 `organ_involvement{organ:"kidney"}` fact 日期,
或最早的免疫抑制剂 `drug_start`(两者取更早的);基线蛋白尿 = T0 前后 30 天内最近一次
`urine_protein_24h` 或 `urine_pcr`。四条里程碑逐条三态(与 Task 12 同一 `Verdict`),
`actual` 给实际值与百分比,每条带 `source` 与 `year`。**任何一条都不下「缓解」结论**,
`label` 由包给。只有在存在肾受累 fact 或任一 UPCR/24h 尿蛋白数据点时才输出这块。

跑:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
bash examples/demo-dataset/generate_sle.sh   # 只生成 .txt 那一档就够(不需要 PDF/扫描图)
python3 examples/demo-dataset/extract_fixtures.py
cargo test -p profile --test golden_sle_course   # 第一次必然失败:golden 还不存在
UPDATE_GOLDEN=1 cargo test -p profile --test golden_sle_course
```

然后**逐字段人读一遍** `packages/profile/testdata/golden_profile_view.json`:分数对不对、
证据链指的文档对不对、提醒的 basis 对不对、有没有出现禁用措辞。确认无误再跑一遍不带
`UPDATE_GOLDEN` 的。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test --workspace`
Expected: 全绿 —— 特别是 `packages/parser/tests/corpus_summary.rs` 的数字**一个都不许动**
(新语料进的是另一个目录、另一个病人)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/profile examples/demo-dataset
git commit -m "feat(profile): 狼疮肾炎里程碑 + 合成 SLE 病程语料 + golden ProfileView

语料是独立病人独立目录,不往张建国身上加免疫病(会污染既有 corpus 断言)。
golden 逐字段钉住整份 ProfileView,并断言里面没有禁用措辞、每个 source
都在 manifest.sources 里声明过。"
```

---

## C4 — SLE 包内容、术语覆盖层、临床核查

### Task 17: `packages/terminology` 运行时覆盖层

**Files:**
- Modify: `packages/terminology/src/lib.rs`(新增覆盖层;`normalize` 在内置未命中时回落)
- Modify: `packages/parser/src/labs.rs:381`(换成覆盖层感知的 entry 查询)
- Create: `packages/terminology/tests/overlay.rs`

**Interfaces:**
- Produces:
  - `terminology::set_overlay(entries: Vec<Entry>)` —— 整体替换(传空 Vec 即清空)
  - `terminology::entry_for(key: &str) -> Option<Entry>` —— **内置优先**,内置没有才查覆盖层(拥有所有权的克隆)
  - `normalize`/`resolve`/`resolve_drug` 在内置全部路径未命中后才查覆盖层别名
- 硬规矩(spec §2):**包不能覆盖内置定义**。内置有 `complement_c3`,覆盖层再定义一个
  `complement_c3` 也不生效 —— 否则一个被盗签的包可以悄悄把肌酐的单位改掉。

- [ ] **Step 1: 写失败测试**

`packages/terminology/tests/overlay.rs`:

```rust
//! 运行时术语覆盖层:病种包给已有 key 加别名、定义新分析物(「加病不发版」的前提)。
//!
//! 这些测试**必须串行**跑:覆盖层是进程级全局状态。用一个互斥锁串起来,
//! 而不是 `--test-threads=1`(那要求每个跑测试的人都记得加参数)。
use std::sync::Mutex;
use terminology::{Category, Codes, Entry, UnitConversion};

static SERIAL: Mutex<()> = Mutex::new(());

fn upcr() -> Entry {
    serde_json::from_value(serde_json::json!({
        "key": "urine_pcr", "canonical_name": "尿蛋白肌酐比值", "category": "lab",
        "system": "urine", "panel": "肾功能", "codes": {},
        "canonical_unit": "mg/g",
        "units": [{"unit": "mg/g", "slope": 1.0, "intercept": 0.0},
                  {"unit": "mg/mmol", "slope": 8.84, "intercept": 0.0}],
        "aliases": ["尿蛋白肌酐比值", "尿蛋白/肌酐比值", "尿蛋白肌酐比", "UPCR", "尿蛋白/肌酐"]
    })).unwrap()
}

#[test]
fn an_overlay_analyte_resolves_and_carries_its_units() {
    let _g = SERIAL.lock().unwrap();
    terminology::set_overlay(vec![]);
    assert!(terminology::resolve("尿蛋白肌酐比值", Some("mg/g")).is_none(), "内置词典里本来没有");

    terminology::set_overlay(vec![upcr()]);
    let m = terminology::resolve("尿蛋白肌酐比值", Some("mg/g")).expect("覆盖层要认出来");
    assert_eq!(m.key, "urine_pcr");
    let e = terminology::entry_for("urine_pcr").expect("entry_for 也要查覆盖层");
    assert_eq!(e.canonical_unit.as_deref(), Some("mg/g"));
    assert!(e.units.iter().any(|u| u.unit == "mg/mmol" && (u.slope - 8.84).abs() < 1e-9));
    terminology::set_overlay(vec![]);
}

#[test]
fn an_overlay_alias_on_an_existing_key_works() {
    let _g = SERIAL.lock().unwrap();
    terminology::set_overlay(vec![]);
    let mut c3 = terminology::entry_for("complement_c3").unwrap();
    c3.aliases = vec!["血清补体C3测定".into()];
    terminology::set_overlay(vec![c3]);
    assert_eq!(terminology::resolve("血清补体C3测定", Some("g/L")).unwrap().key, "complement_c3");
    terminology::set_overlay(vec![]);
}

#[test]
fn an_overlay_can_never_shadow_a_builtin_definition() {
    // 被盗签的包不能把肌酐的单位改掉。内置命中就到此为止,覆盖层根本不查。
    let _g = SERIAL.lock().unwrap();
    let mut evil: Entry = terminology::entry_for("creatinine").unwrap();
    evil.canonical_unit = Some("mg/dL".into());
    evil.canonical_name = "假肌酐".into();
    terminology::set_overlay(vec![evil]);
    let m = terminology::resolve("肌酐", Some("umol/L")).unwrap();
    assert_eq!(m.key, "creatinine");
    assert_eq!(m.canonical_name, "肌酐", "内置定义必须原封不动");
    assert_eq!(terminology::entry_for("creatinine").unwrap().canonical_unit.as_deref(),
               Some("umol/L"));
    terminology::set_overlay(vec![]);
}

#[test]
fn clearing_the_overlay_really_clears_it() {
    let _g = SERIAL.lock().unwrap();
    terminology::set_overlay(vec![upcr()]);
    assert!(terminology::entry_for("urine_pcr").is_some());
    terminology::set_overlay(vec![]);
    assert!(terminology::entry_for("urine_pcr").is_none());
    assert!(terminology::resolve("UPCR", Some("mg/g")).is_none());
}
```

`packages/parser/tests/overlay_end_to_end.rs`:

```rust
//! 覆盖层加的分析物必须一路走到 `aggregate` 的序列里,**含单位换算** —— 否则
//! 「加病不发版」只是加了个名字,画不出线。
use std::sync::Mutex;
static SERIAL: Mutex<()> = Mutex::new(());

#[test]
fn an_overlay_analyte_becomes_a_real_series_with_canonical_values() {
    let _g = SERIAL.lock().unwrap();
    let upcr: terminology::Entry = serde_json::from_value(serde_json::json!({
        "key": "urine_pcr", "canonical_name": "尿蛋白肌酐比值", "category": "lab",
        "system": "urine", "panel": "肾功能", "codes": {}, "canonical_unit": "mg/g",
        "units": [{"unit": "mg/g", "slope": 1.0, "intercept": 0.0},
                  {"unit": "mg/mmol", "slope": 8.84, "intercept": 0.0}],
        "aliases": ["尿蛋白肌酐比值", "UPCR"]
    })).unwrap();
    terminology::set_overlay(vec![upcr]);

    let text = "检验报告单\n尿蛋白肌酐比值 100 mg/mmol 0-30\n";
    let docs = vec![parser::SourceDoc {
        index: 0, date: "2026-09-01".parse().ok(), text,
        doc_type: Some("lab_report".into()), title: None, extraction_json: None,
    }];
    let out = parser::aggregate(&docs);
    let s = out.labs.iter().find(|s| s.analyte_key.as_deref() == Some("urine_pcr"))
        .expect("覆盖层分析物要变成序列");
    assert_eq!(s.unit_canonical.as_deref(), Some("mg/g"));
    assert!((s.points[0].value_canonical.unwrap() - 884.0).abs() < 1e-6, "100 mg/mmol = 884 mg/g");
    terminology::set_overlay(vec![]);
}
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p terminology --test overlay`
Expected: FAIL — `cannot find function 'set_overlay' in crate 'terminology'`。

- [ ] **Step 3: 实现**

追加到 `packages/terminology/src/lib.rs`(放在 `index()`/`normalize` 附近):

```rust
/// 运行时术语覆盖层:病种包带来的别名与新分析物(spec §2)。
///
/// **内置永远优先。** 所有查询都是「内置全部路径都没命中,才来问覆盖层」——
/// 包不能改写 `dictionary.json` 里已有的定义。理由是安全边界:包来自网络,
/// 哪怕验过签,也不该有能力把肌酐的规范单位改掉。
///
/// 覆盖层是**进程级全局**,由 App 在加载/切换病种包时整体替换(传空 Vec 清空)。
/// 用 `RwLock` 而不是 `OnceLock`:用户会开关病、切换成员,包不是只装一次。
static OVERLAY: std::sync::RwLock<Vec<Entry>> = std::sync::RwLock::new(Vec::new());

/// 整体替换覆盖层。`entries` 里与内置 key 相同的条目**会被保留但永远查不到**
/// (内置优先),这是刻意的:与其在这里静默丢弃,不如让 `entry_for` 的行为
/// 单点决定优先级,只有一处需要读懂。
pub fn set_overlay(entries: Vec<Entry>) {
    // ponytail: 线性扫描覆盖层(条目数是「开着的病种数 × 每包几条」,个位数)。
    // 真到几百条再建索引。
    *OVERLAY.write().expect("overlay lock poisoned") = entries;
}

/// 按 key 取条目:**内置优先**,内置没有才查覆盖层。返回克隆(覆盖层在锁后面,
/// 给不出 `&'static`)。
pub fn entry_for(key: &str) -> Option<Entry> {
    if let Some(e) = dictionary_entries().iter().find(|e| e.key == key) {
        return Some(e.clone());
    }
    OVERLAY.read().ok()?.iter().find(|e| e.key == key).cloned()
}

/// 覆盖层的别名查找,供 [`normalize`] 在内置全部路径 miss 之后回落。
/// 与内置一样,精确别名命中 = 1.0。内置已有的 key 在这里被跳过(不能遮蔽)。
fn overlay_normalize(norm: &str) -> Option<Match> {
    let builtin_keys: Vec<&str> = dictionary_entries().iter().map(|e| e.key.as_str()).collect();
    let guard = OVERLAY.read().ok()?;
    for e in guard.iter() {
        if builtin_keys.contains(&e.key.as_str()) {
            continue;
        }
        if let Some(a) = e.aliases.iter().find(|a| normalize_term(a) == norm) {
            return Some(Match {
                key: e.key.clone(),
                canonical_name: e.canonical_name.clone(),
                category: e.category,
                codes: e.codes.clone(),
                ingredient: e.ingredient.clone(),
                matched_alias: a.clone(),
                confidence: 1.0,
            });
        }
    }
    None
}
```

> 内置 key 的**新别名**怎么生效?`overlay_normalize` 跳过内置 key,所以
> `an_overlay_alias_on_an_existing_key_works` 会红。正确做法是这个跳过只针对
> **定义**(canonical_unit/units/codes),别名仍可追加。把上面的 `continue` 改成:
> 命中时返回**内置**那条的定义(`dictionary_entries()` 里那条)配上覆盖层的别名 ——
> 即 `matched_alias` 来自包,其余字段一律来自内置。

`normalize()`(`lib.rs:711`)末尾的 `None` 改成 `overlay_normalize(&norm)`。

`packages/parser/src/labs.rs:381` 改成:

```rust
        // `entry_for` 而不是 `dictionary_entries().find`:病种包带来的新分析物
        // (UPCR 等)也要能换算单位,否则它有名字却画不出规范单位的线。
        if let Some(entry) = terminology::entry_for(&m.key) {
```
(随之把后续 `entry.units` / `entry.canonical_unit` 的借用改成对本地 `entry` 的借用。)

`Entry` 需要 `Clone`(已有 `#[derive(Debug, Clone, Deserialize)]`,`lib.rs:64`,无需改)。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p terminology -p parser`
Expected: PASS。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test --workspace`
Expected: 全绿 —— 覆盖层默认为空,既有行为一字不变。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/terminology packages/parser
git commit -m "feat(terminology): 运行时术语覆盖层,内置永远优先

包能加别名、能定义新分析物(UPCR),但永远改不掉内置定义 —— 包来自网络,
哪怕验过签也不该有能力把肌酐的规范单位改掉。覆盖层默认空,既有行为不变。"
```

---

### Task 18: `skills/sle/2026.09.1.json` —— SLE 包内容

**Files:**
- Create: `skills/sle/2026.09.1.src.json`
- Create(由脚本生成): `skills/sle/2026.09.1.json`、更新 `skills/index.json`
- Modify: `packages/profile/tests/common/mod.rs`(夹具包改为直接读 `skills/sle/2026.09.1.src.json`)
- Create: `packages/profile/tests/shipped_package.rs`

**Interfaces:**
- Consumes: Task 1–2 的包 schema;Task 11–16 定下的全部规则 kind;Task 17 的 `terms` 覆盖层
- Produces: `sle` 包 v`2026.09.1`,`min_engine: 1`
- **每个数值的唯一合法来源是 `.superpowers/sdd/disease-profile/sle-clinical-sources.md` 里标 `VERBATIM` 的行。** 标 `NOT VERIFIED` 的一律 `null` + `"note":"待核"`。

`manifest.sources`(id → cite,全部来自出处文件的 "Primary sources used" 与各节):

| id | cite |
|---|---|
| `S1` | Gladman DD, Ibañez D, Urowitz MB. SLEDAI-2K. *J Rheumatol* 2002;29:288–91, Table 2 |
| `S2` | Mosca M, et al. EULAR recommendations for monitoring SLE. *Ann Rheum Dis* 2010, Table 1 |
| `S3` | Fanouriakis A, et al. 2019 update of the EULAR recommendations for the management of SLE |
| `S4` | Fanouriakis A, et al. EULAR recommendations for the management of SLE: 2023 update |
| `S5` | 2021 DORIS definition of remission in SLE, Box 1 / Table 2 |
| `S6` | Golder V, et al. *Arthritis Res Ther* 2017;19:62(转载 Franklyn 2016 的 LLDAS 操作性定义) |
| `S8` | Fanouriakis A, et al. EULAR recommendations for SLE with kidney involvement: 2025 update. *Ann Rheum Dis* 2026;85:75–90 |
| `S9` | 2025 Chinese guidelines for the diagnosis and treatment of SLE. *Rheumatol Immunol Res* 2025;6(3):120–148 |
| `S10` | 2020 Chinese Guidelines for the Diagnosis and Treatment of SLE. *Rheumatol Immunol Res* 2020;1(1):5–23 |
| `S11` | Aringer M, et al. 2019 EULAR/ACR classification criteria for SLE. *Arthritis Rheumatol* 2019;71:1400–12 |
| `S12` | EULAR recommendations on management of systemic glucocorticoid therapy. *Ann Rheum Dis* 2007;66:1560–7 |
| `S13` | ACR 2022 GIOP guideline. Humphrey MB, et al. *Arthritis Care Res* 2023;75:2405–19(摘要) |
| `S14` | Marmor MF, et al. AAO Recommendations on Screening for Hydroxychloroquine Retinopathy (2025 Revision). *Ophthalmology* 2026;133:439–50 |
| `L1` | CELLCEPT(吗替麦考酚酯)US PI,DailyMed setid 37241e87-… |
| `L2` | IMURAN / azathioprine US label,DailyMed setid aaa6c540-… |
| `L3` | LUPKYNIS(伏环孢素)US PI,DailyMed setid 9f489295-… |
| `L4` | NEORAL(环孢素)US PI,DailyMed setid 94461af3-… |
| `L5` | BENLYSTA(贝利尤单抗)US PI,DailyMed setid 2fa3c528-… |
| `L6` | RITUXAN(利妥昔单抗)US PI,DailyMed setid b172773b-… |
| `L7` | van Vollenhoven RF, et al. Telitacicept phase 3. *NEJM* 2025;393(15):1475–85 |
| `L8` | 硫酸羟氯喹片说明书(0.1 g / 0.2 g 两个规格,两份互相矛盾,见 note)。**`verify_status:"pending"`** |
| `R1` | Staveri C, Liossis SC. *Front Lupus* 2026;4:1877692(RTX 的 IgG 监测建议;**综述,非指南非说明书**) |
| `PKG` | 包默认值,**非指南、非说明书** |

`terms`(覆盖层,Task 17 的输入):

```json
{"aliases":{
   "complement_c3":["血清补体C3","补体C3测定","C3"],
   "complement_c4":["血清补体C4","补体C4测定","C4"],
   "anti_dsdna":["抗双链DNA抗体","抗dsDNA抗体","ds-DNA","抗ds-DNA抗体"],
   "ana":["抗核抗体","ANA"],
   "urine_protein_24h":["24小时尿蛋白定量","24h尿蛋白定量"]},
 "analytes":[
   {"key":"urine_pcr","name":"尿蛋白肌酐比值","loinc":null,"panel":"肾功能",
    "canonical_unit":"mg/g",
    "units":[{"unit":"mg/g","slope":1,"intercept":0},{"unit":"mg/mmol","slope":8.84,"intercept":0}],
    "aliases":["尿蛋白肌酐比值","尿蛋白/肌酐比值","尿蛋白肌酐比","尿蛋白/肌酐","UPCR"],
    "note":"LOINC 待核。mg/g 是中国指南主用单位,mg/mmol 只作为换算出现(2019 LN 指南印「500 mg/g(50 mg/mmol)」→ 1 mg/mmol = 8.84 mg/g)。与 urine_acr(尿白蛋白肌酐比)是两个项目,不可互替。"},
   {"key":"ch50","name":"血清总补体CH50","loinc":null,"panel":"风湿免疫","canonical_unit":"U/mL",
    "units":[{"unit":"U/mL","slope":1,"intercept":0}],
    "aliases":["总补体CH50","血清总补体CH50","CH50","总补体溶血活性"],
    "note":"LOINC 待核。齐鲁医院目录印 50～100 U/ml。"},
   {"key":"urine_rbc_hpf","name":"尿红细胞(高倍视野)","loinc":null,"panel":"尿液",
    "canonical_unit":"/[HPF]","units":[{"unit":"/[HPF]","slope":1,"intercept":0}],
    "aliases":["尿红细胞","红细胞(尿沉渣)","尿RBC"],
    "note":"与内置 urine_rbc_count(/uL 定量)是**两个不同的量**,/HP 与 /uL 之间没有确定换算;SLEDAI-2K 用的是 /HP。LOINC 待核。"},
   {"key":"urine_wbc_hpf","name":"尿白细胞(高倍视野)","loinc":null,"panel":"尿液",
    "canonical_unit":"/[HPF]","units":[{"unit":"/[HPF]","slope":1,"intercept":0}],
    "aliases":["尿白细胞","白细胞(尿沉渣)","尿WBC"],
    "note":"同上,与 urine_wbc_count(/uL)不同量。LOINC 待核。"}]}
```

`triggers`:

```json
{"diagnosis_patterns":["系统性红斑狼疮","红斑狼疮","SLE","狼疮性肾炎","狼疮肾炎"],
 "serology_any_two":["ana_positive","anti_dsdna_high","anti_sm_positive","low_c3","low_c4"]}
```
(ANA 阳性的滴度界值用 **≥1:80**,出处 `S11` —— "a sensitivity of 97.8% … for ANA of ≥1:80",VERBATIM。)

`drugs`:spec §2 那一份,但:
- `gc` 的 `"pred_equiv": null, "pred_equiv_source": null, "note": "泼尼松等效换算表待核(sle-clinical-sources 未逐字转录 2020 指南表 2),核实前只有泼尼松本身计入日剂量"`
- `belimumab.infusion` = `{"iv":"10 mg/kg,第 0、2、4 周,之后每 4 周(S8/L5)","sc":"SLE 每周 200 mg;狼疮肾炎每周 400 mg×4 次后改每周 200 mg(S8/L5)"}`
- `telitacicept.infusion` = `{"sc":"每周 160 mg(L7)"}`

`rules.activity`:Task 11 的 `ACTIVITY` 那八条,原样。
`rules.states`:Task 12 的 DORIS / LLDAS 两张表,原样。
`rules.bands`(总分分档,VERBATIM,两份指南一致):
```json
{"source":"S10","corroborated_by":"S4","bands":[{"max":6,"label":"轻度活动"},
 {"min":7,"max":12,"label":"中度活动"},{"min":13,"label":"重度活动"}],
 "note":"分档用于**总分**(症状项由用户/医生勾选后合成),不用于化验可算部分"}
```
`rules.targets`:
```json
{"gc":{"targets":[{"value":7.5,"label":"EULAR 2019:慢性维持期低于 7.5 mg/d","source":"S3"},
                  {"value":5,"label":"EULAR 2023:维持剂量 ≤5 mg/d","source":"S4"}]},
 "hcq":{"target":5,"unit":"mg/kg","basis":"real_body_weight","ceiling_mg":400,"source":"S4",
        "label_rule":{
          "text":"说明书写「不应超过 6.5 mg/kg/日(按理想体重而非实际体重算)或 0.4 g/日」,与指南的 5 mg/kg 真实体重不是同一个算法;两份规格的说明书连眼科复查间隔都互相矛盾(每 3 月 vs 每年至少一次)",
          "source":"L8",
          "verify_status":"pending"}}}
```

> **HCQ 的说明书那一串是本包里风险最高的内容**:它只经过摘要管道、没人打开过纸质
> 说明书核对,而研究阶段这条管道已经编造过两次羟氯喹剂量
> (`sle-clinical-sources.md` 开头的告诫)。所以它在包里**只以 `label_rule` 存在、
> 只用来提示「你手上那张说明书写的和指南不一样」**,`verify_status:"pending"`;
> **它不参与任何判定**——没有任何规则读 6.5、读理想体重、读那两个眼科间隔。
> Task 19 必须从一手说明书重新核实它,这是那个任务的第一优先级。
`rules.monitoring`:Task 14 的三种 kind,条目与出处:

| id | kind | 数值 | basis | source |
|---|---|---|---|---|
| `visit_active` | disease_cadence | 活动期 30 天 | guideline | S9(与 S10 一致) |
| `visit_stable` | disease_cadence | 稳定期 90–180 天 | guideline | S9(与 S10 一致) |
| `mmf_cbc` | drug_schedule | 7 / 14 / 30 天三段(第 1 月 / 2–3 月 / 第一年其余) | label | L1 |
| `aza_cbc` | drug_schedule | 7 / 14 / 30 天三段 | label | L2 |
| `cni_egfr` | drug_schedule | 14 / 28 / 90 天三段(伏环孢素) | label | L3 |
| `cni_bp` | drug_schedule | 第 1 月每 14 天 | label | L3 |
| `csa_bp_scr` | drug_schedule | 前 3 月每 14 天,之后每 30 天(环孢素) | label | L4 |
| `hcq_eye` | drug_schedule | 基线一次;无危险因素满 5 年后每年;有肾病/他莫昔芬/高龄起始者从开始每年 | guideline | S14(并注 S3 与 L8 的不同说法) |
| `gc_ca_vitd` | drug_threshold | ≥7.5 mg/d 且 >3 个月 | guideline | S12 |
| `gc_dxa` | drug_threshold | ≥2.5 mg/d 且 >3 个月 → FRAX + 骨密度。**`min_age` 写 `null` + 「待核」** | guideline | S13 |
| `gc_cv_annual` | drug_schedule | 血脂/血糖/血压/BMI 每年一次 | guideline | S2 |
| `rtx_igg` | drug_schedule | 起始前查 IgG,之后定期或每个疗程前 | **literature** | **R1** |
| `rtx_hbv` | drug_threshold | 起始前 HBsAg + 抗-HBc | label | L6 |
| `mtx_labs` | drug_schedule | 每 30 天血常规 + 肝功 | **package_default** | PKG |
| `ctx_cbc` | drug_schedule | 每次冲击前血常规 | **package_default** | PKG |

`rules.milestones`:Task 16 的四条 + 活检指征,全部 `source: "S8"` 并带 `"year": 2025`;
再加一条旧口径 `{"id":"ln_cr_2019","kind":"upcr_below","value":500,"unit":"mg/24h","year":2019,"source":"S3","label":"旧口径:完全肾缓解 尿蛋白 <500 mg/24h"}`(spec §5.5:旧口径一并带年份)。

`views`:7 种 section 的顺序、标题、空态文案。顺序按 spec §5.6「首页永远先出待补/逾期再出趋势」:
`reminders` → `score_card` → `status_card` → `checklist`(达标)→ `checklist`(里程碑)→
`series_chart` → `timeline`;`handoff` 另给一份顺序(当前活动度 → 现行方案 → 近 12 月复发 →
逾期监测 → 各院来源)。

**Interfaces(新增测试):**
- `packages/profile/tests/shipped_package.rs`

- [ ] **Step 1: 写失败测试**

`packages/profile/tests/shipped_package.rs`:

```rust
//! 已发布的 SLE 包的硬约束。这些断言就是「包里不许编数字」的自动化形式。
use std::path::{Path, PathBuf};

mod common;

fn repo() -> PathBuf { Path::new(env!("CARGO_MANIFEST_DIR")).join("../..") }

fn src_json() -> String {
    std::fs::read_to_string(repo().join("skills/sle/2026.09.1.src.json")).unwrap()
}

fn pkg() -> profile::Package {
    let signed = std::fs::read_to_string(repo().join("skills/sle/2026.09.1.json")).unwrap();
    profile::load_signed(&signed).expect("已发布的 SLE 包必须用生产公钥验过并加载")
}

#[test]
fn the_shipped_sle_package_matches_the_test_fixture() {
    // 夹具包与真包同一份内容 —— 否则 golden ProfileView 钉住的是一个不存在的包。
    let a: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    let b = serde_json::to_value(&common::full_pkg()).unwrap();
    assert_eq!(a["rules"], b["rules"]);
    assert_eq!(a["drugs"], b["drugs"]);
    assert_eq!(a["markers"], b["markers"]);
}

#[test]
fn every_rule_object_declares_a_source_that_exists() {
    // **`rules` 底下每一个带标量的对象**都要有 source —— 不只是带 value/threshold/
    // every_days 的那些。activity 的条目只带 `weight`,states 的条目只带 `kind`,
    // monitoring 的 `phases[]` 只带天数,bands 的每一行只带 `label` —— 早先那版
    // 谓词把这些全放过去了,等于「只有一半的数字被出处覆盖」。
    //
    // 判定规则只有一条:**对象里出现任何标量值(非对象、非数组)就必须有 source**。
    // 纯容器(所有值都是对象/数组,如 `rules.targets`、`rules.targets.gc`)豁免。
    let p = pkg();
    let ids: Vec<&str> = p.manifest.sources.iter().map(|s| s.id.as_str()).collect();
    let mut checked = 0usize;
    fn walk(v: &serde_json::Value, ids: &[&str], path: &str, checked: &mut usize) {
        match v {
            serde_json::Value::Object(m) => {
                let has_scalar = m
                    .iter()
                    .any(|(k, x)| k != "source" && !x.is_object() && !x.is_array());
                if has_scalar {
                    let s = m
                        .get("source")
                        .and_then(|x| x.as_str())
                        .unwrap_or_else(|| panic!("{path} 带着数值/文案却没有 source"));
                    assert!(ids.contains(&s), "{path} 的 source {s} 没在 manifest.sources 里");
                    *checked += 1;
                }
                for (k, x) in m {
                    walk(x, ids, &format!("{path}.{k}"), checked);
                }
            }
            serde_json::Value::Array(a) => {
                for (i, x) in a.iter().enumerate() {
                    walk(x, ids, &format!("{path}[{i}]"), checked);
                }
            }
            _ => {}
        }
    }
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    walk(&v["rules"], &ids, "pkg.rules", &mut checked);
    // 防「谓词写歪了导致一个都没查」:五组规则各自至少要被覆盖到。
    assert!(checked >= 40, "只核到 {checked} 个规则对象,谓词可能又漏了一整类");
    for group in ["activity", "states", "monitoring", "milestones", "targets", "bands"] {
        assert!(!v["rules"][group].is_null(), "rules.{group} 不该缺席");
    }
}

#[test]
fn every_terms_analyte_and_drug_row_declares_a_source_or_a_note() {
    // `terms`/`drugs` 不在 `rules` 下,但同样是「会印到用户眼前的事实」:
    // 新分析物的单位换算系数、生物制剂的输注周期都必须能追到出处或写明待核。
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    for a in v["terms"]["analytes"].as_array().unwrap() {
        let note = a["note"].as_str().unwrap_or_default();
        assert!(!note.is_empty(), "{} 没有 note(换算与编码的来源/待核状态)", a["key"]);
    }
    for d in v["drugs"].as_array().unwrap() {
        if !d["infusion"].is_null() {
            assert!(
                !d["infusion_source"].as_str().unwrap_or_default().is_empty(),
                "{} 给了输注周期就必须给出处",
                d["class"]
            );
        }
    }
}

#[test]
fn unverified_values_are_null_with_a_todo_note_not_invented_numbers() {
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    let gc = v["drugs"].as_array().unwrap().iter().find(|d| d["class"] == "gc").unwrap();
    assert!(gc["pred_equiv"].is_null(), "泼尼松等效换算表未核实,不许写数字");
    assert!(gc["note"].as_str().unwrap().contains("待核"));
    // UPCR / CH50 / 尿沉渣 /HP 四个新分析物的 LOINC 都未核实。
    for key in ["urine_pcr", "ch50", "urine_rbc_hpf", "urine_wbc_hpf"] {
        let a = v["terms"]["analytes"].as_array().unwrap().iter()
            .find(|a| a["key"] == key).unwrap();
        assert!(a["loinc"].is_null(), "{key} 的 LOINC 未核实");
        assert!(a["note"].as_str().unwrap().contains("待核"), "{key}");
    }
}

#[test]
fn the_package_never_uses_the_unsourced_five_band_sledai_scheme() {
    // sle-clinical-sources §G.1:0 / 1–5 / 6–10 / 11–19 / ≥20 追不到一手出处,不许发。
    let s = src_json();
    for banned in ["11-19", "11–19", "≥20"] {
        assert!(!s.contains(banned), "出现了未经核实的五档分级:{banned}");
    }
    let bands = serde_json::from_str::<serde_json::Value>(&s).unwrap()["rules"]["bands"]["bands"]
        .as_array().unwrap().len();
    assert_eq!(bands, 3, "只用 ≤6 / 7–12 / >12 三档(两份指南一致)");
}

#[test]
fn package_default_monitoring_rules_are_labelled_as_such() {
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    for id in ["mtx_labs", "ctx_cbc"] {
        let m = v["rules"]["monitoring"].as_array().unwrap().iter()
            .find(|m| m["id"] == id).unwrap();
        assert_eq!(m["basis"], "package_default", "{id} 的说明书只写「定期」,不许冒充指南");
        assert_eq!(m["source"], "PKG");
    }
}

#[test]
fn the_hcq_rule_carries_both_the_guideline_and_the_package_insert_numbers() {
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    let h = &v["rules"]["targets"]["hcq"];
    assert_eq!(h["target"], 5);
    assert_eq!(h["basis"], "real_body_weight");
    let lr = &h["label_rule"];
    assert!(lr["text"].as_str().unwrap().contains("6.5"));
    assert!(lr["text"].as_str().unwrap().contains("理想体重"));
    // 说明书那串只经过摘要管道,没人打开过纸质说明书 —— 必须标着待核。
    assert_eq!(lr["verify_status"], "pending");
    assert_eq!(lr["source"], "L8");
}

#[test]
fn the_package_insert_numbers_never_drive_a_judgement() {
    // 6.5 / 理想体重 / 每 3 月 这些只能出现在 `label_rule` 的提示文案里。
    // 一旦哪条规则真的拿它去判定「你的剂量超了」,我们就是在用一个没核实过的
    // 数字给用户下结论。
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    let mut rules = v["rules"].clone();
    rules["targets"]["hcq"]["label_rule"] = serde_json::Value::Null;
    let s = rules.to_string();
    for banned in ["6.5", "理想体重", "每 3 月"] {
        assert!(!s.contains(banned), "说明书数值 {banned} 泄进了判定规则");
    }
}

#[test]
fn the_dxa_age_threshold_is_null_because_it_came_from_a_third_party_summary() {
    // 「≥40 岁用 FRAX + 骨密度」那句 VERBATIM 是从 guidelinecentral 的摘要页抄的,
    // 不是 ACR 2022 GIOP 指南原文(sle-clinical-sources §D.1 自己标了)。
    // 人群阈值(>3 个月、≥2.5 mg/d)是 verbatim 的,年龄不是。
    let v: serde_json::Value = serde_json::from_str(&src_json()).unwrap();
    let r = v["rules"]["monitoring"].as_array().unwrap().iter()
        .find(|m| m["id"] == "gc_dxa").unwrap();
    assert_eq!(r["min_daily_pred_equiv"], 2.5);
    assert_eq!(r["min_days"], 90);
    assert!(r["min_age"].is_null(), "年龄阈值来自三方摘要,核实前写 null");
    assert!(r["note"].as_str().unwrap().contains("待核"));
}
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile --test shipped_package`
Expected: FAIL — `skills/sle/2026.09.1.src.json` 不存在。

- [ ] **Step 3: 写包并签名**

按上面的表逐块写 `skills/sle/2026.09.1.src.json`。写的时候**一条一条对着**
`.superpowers/sdd/disease-profile/sle-clinical-sources.md` 的 VERBATIM 行抄,不要凭记忆。

把 `packages/profile/tests/common/mod.rs` 的 `FULL` 常量换成
`include_str!("../../../../skills/sle/2026.09.1.src.json")` —— 夹具与真包从此是同一份字节。
(`MINIMAL` / `ACTIVITY` 保留:前者给开启闸测试,后者已被真包的 `rules.activity` 取代,
删掉并让 `activity_pkg()` 返回 `full_pkg()`。)

签名 + 刷新 index:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
python3 scripts/sign_skill.py skills/sle/2026.09.1.src.json
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p profile`
Expected: PASS(含 `repo_packages_verify`、`shipped_package`、`golden_sle_course`)。
golden 因为包内容进来了会变 → `UPDATE_GOLDEN=1` 重生成,**人工 review diff** 后再跑一次。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api && python3 -m pytest test_api.py -k skills -q`
Expected: PASS —— `index.json` 现在有一条,路由照样服务。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add skills packages/profile
git commit -m "feat(skills): SLE 包 2026.09.1

每个数值对着 sle-clinical-sources 的 VERBATIM 行抄;未核实的(泼尼松等效
换算表、四个新分析物的 LOINC)写 null + 待核,不编数字。MTX/CTX 的监测
频率说明书只写「定期」,包里给保守默认并标 package_default。"
```

---

### Task 19: 临床独立核查 —— 包内每个数值 → 出处行

**Files:**
- Create: `docs/log/2026-09-16-sle-package-clinical-verification.md`
- Modify: `skills/sle/2026.09.1.src.json`(核查后该改的改,该补的补)
- Modify: `skills/sle/2026.09.1.json`(重签)

**Interfaces:**
- Consumes: Task 18 的包
- Produces: 一份逐条核查表 —— **包里每一个数值 → `sle-clinical-sources.md` 的行号 → 该行的 `VERBATIM`/`NOT VERIFIED` 标记 → 结论**

> **这一条必须由一个独立的人/agent 做,不能由写包的人自审**(CLAUDE.md 四条硬规矩第 3 条:
> 「对外产出必须独立核查,不许自审」;那次三轮核查抓出 5 条硬错误,包括「修正」时新引入的)。
> 研究阶段已抓到过两次工具编造(羟氯喹剂量、ANA 荧光型),所以标「仅经摘要管道」的值
> (药物说明书、中文来源)必须**逐条重验**(`sle-clinical-sources.md` §G 的要求)。

- [ ] **Step 1: 列清单**

跑一遍,把包里每个带数字的位置抽出来当核查清单:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
python3 - <<'PY'
import json, pathlib
p = json.loads(pathlib.Path("skills/sle/2026.09.1.src.json").read_text(encoding="utf-8"))
rows = []
# 与 Task 18 的 `every_rule_object_declares_a_source_that_exists` **同一个谓词**:
# 带任何标量值的对象都要核。两边用不同的谓词,清单就会漏掉测试正在检查的那些。
def walk(v, path):
    if isinstance(v, dict):
        if any(k != "source" and not isinstance(x, (dict, list)) for k, x in v.items()):
            rows.append((path, json.dumps(v, ensure_ascii=False)))
        for k, x in v.items(): walk(x, f"{path}.{k}")
    elif isinstance(v, list):
        for i, x in enumerate(v): walk(x, f"{path}[{i}]")
walk(p.get("rules", {}), "pkg.rules")
walk(p.get("terms", {}), "pkg.terms")
walk({"drugs": p.get("drugs", [])}, "pkg")
for path, v in rows: print(f"| `{path}` | {v} | | | |")
PY
```

把输出贴进 `docs/log/2026-09-16-sle-package-clinical-verification.md` 的表格里,
表头:`| 包内位置 | 值 | sle-clinical-sources 行号 | 该行标记 | 结论 |`。

- [ ] **Step 2: 派独立核查**

开一个**新的、没有写包上下文的** agent,交给它:

> 输入:`skills/sle/2026.09.1.src.json`、`.superpowers/sdd/disease-profile/sle-clinical-sources.md`。
> 任务:对上一步那张表的每一行,在出处文件里找到对应行号,核对(a)数值一字不差、
> (b)那行确实标着 `VERBATIM`、(c)包里的 `source` id 指向的就是那一行引用的文献。
> 三条任一不成立就写「不通过」并给出应当改成什么。**不许放过任何一行**,
> 不许用「大致相符」结案。另外单独回答三件事:
> (i) 包里有没有任何一个数值来自 `sle-clinical-sources.md` §G.1 那张「do not ship」表;
> (ii) 每条 `monitoring` 的 `basis` 标得对不对 —— `guideline` 只给指南原文、
> `label` 只给药品说明书、`literature` 给一手文献(非指南非说明书)、其余一律
> `package_default`;标错等于把一篇综述的建议说成指南;
> (iii) 有没有任何**判定用**的数值(阈值、间隔、目标)来自 `verify_status:"pending"`
> 的字段 —— 有就是硬错误。

- [ ] **Step 3: 按核查结论改包**

逐条落实核查结论。**按风险从高到低**,以下六项必须各自有明确结论:

1. **【最高风险】羟氯喹的两份中文说明书**(`rules.targets.hcq.label_rule`,`verify_status:"pending"`)。
   为什么排第一:这串字只经过摘要管道,而那条管道在研究阶段**就编造过羟氯喹剂量**
   (`sle-clinical-sources.md` 开头的告诫,以及 §D.2.1);它又恰恰是患者手里那张纸上
   写的东西,一旦错,错得最显眼、最伤信任。
   - 要核的四个点:`6.5 mg/kg`、`理想体重(而非实际体重)`、`0.4 g/日`、以及两份规格
     互相矛盾的眼科间隔(`每3月` vs `每年至少检查一次`)。
   - 怎么核:拿到 **0.1 g 与 0.2 g 两个规格**的一手说明书(药盒里的纸、NMPA 说明书
     数据库、或药企官网 PDF),逐字比对。**不许**用药品信息站、科普页、搜索摘要。
   - 核过:`verify_status` 改 `"verified"`,并把核到的规格/批准文号写进 `source` 的 cite。
   - 核不到:整个 `label_rule` 改成 `null`,界面上那句「说明书写的和指南不一样」
     **就不显示** —— 宁可不说,不能说一句没核过的。
2. **§G.1 的 do-not-ship 值**若出现在包里 → 立刻删掉,换成 §G.1「What to use instead」列的值。
3. **泼尼松等效换算表 —— 这一条是本任务的必办项,不是「顺便看看」。**
   `sle-clinical-sources.md` §A.1 记着 2020 中国指南的四张表之一就是
   「**常用糖皮质激素的等效剂量**」(§G 的负面发现里点了名),但那张表的**数值**
   从没被逐字转录过 —— 所以现在包里是 `null`。本步骤要把它拿到:
   - **首选**:打开 S10 的开放全文(2020 Chinese Guidelines for the Diagnosis and
     Treatment of SLE, *Rheumatol Immunol Res* 2020;1(1):5–23,
     <https://pmc.ncbi.nlm.nih.gov/articles/PMC9524765/>),找到那张等效剂量表,
     **逐字**抄下泼尼松/泼尼松龙/甲泼尼龙/地塞米松(以及表里其余行)的系数,
     并记下表号与页码。
   - **备选**(首选打不开时):任一可打开的一手来源 —— S9(2025 中国指南,
     PMC12495991)的同类表,或相应药品说明书的等效剂量段。**不许**用二手科普页、
     计算器站点或搜索摘要。
   - 拿到之后:填 `drugs[class=gc].pred_equiv`(`{"泼尼松":1, …}`)与
     `pred_equiv_source`(新加一个 `sources[]` 条目,cite 写到表号),
     并**删掉** `note` 里的「待核」字样;Task 18 的
     `unverified_values_are_null_with_a_todo_note_not_invented_numbers` 里那条
     `pred_equiv` 断言随之改成「已填且每个系数都有 source」。
   - **两条来源都拿不到**:保持 `null`,并在核查日志里写清楚试了哪几个 URL、
     分别是什么失败(付费墙/PDF 解不出/登录墙)。Task 13 会继续显示
     「换算表待核」,这是可接受的收尾状态 —— **但不许填一个近似值**。
4. **`gc_dxa` 的 `min_age`(「≥40 岁」)**:出处文件自己标了那一行是
   *VERBATIM from a third-party summary*(guidelinecentral 的摘要页),**不是**
   ACR 2022 GIOP 指南原文;人群阈值(>3 个月、≥2.5 mg/d)才是 verbatim 的。
   - 拿到 ACR 2022 GIOP 指南原文(Wiley 403 时试 ACR 官网的 summary PDF 或
     PMC 版本)核实年龄阈值,核到就填 `min_age` 并改 `source`;
   - 核不到就保持 `null` + `"note":"年龄阈值待核(三方摘要,非指南原文)"` ——
     此时这条提醒对**所有**满足剂量与时长的人触发(宁可多提醒一次骨密度,
     也不拿一个没核过的年龄把人挡在外面)。
5. 其余「仅经摘要管道」的值(贝利尤中文说明书、泰它西普中文说明书)→ 没能打开原始
   说明书核实的,改成 `null` + `"note":"说明书原文待核"`。
6. 四个新分析物的 **LOINC**:核到就填,核不到保持 `null`。
7. **`rtx_igg` 的 `basis` 必须是 `literature`(来源 `R1`),不是 `label`**:
   RITUXAN 说明书里只有 HBV 筛查那条是硬要求,「起始前与定期查 IgG」来自
   Staveri/Liossis 2026 的综述。核一遍它确实没被标成 `guideline` 或 `label`。

- [ ] **Step 4: 重签、重跑、写结论**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
python3 scripts/sign_skill.py skills/sle/2026.09.1.src.json
cargo test -p profile
```
golden 若因改值而变 → `UPDATE_GOLDEN=1` 重生成并人工 review。

`docs/log/2026-09-16-sle-package-clinical-verification.md` 收尾写:核了多少条、
不通过多少条、改了什么、还剩哪几个 `null` 待核(以及谁去核、怎么核)。**精炼,不写流水账。**

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add skills docs/log packages/profile
git commit -m "fix(skills): SLE 包临床独立核查后的修正

逐条核到 sle-clinical-sources 的行号与 VERBATIM 标记;§G.1 的 do-not-ship
值一个不留;核不到的改回 null + 待核。核查由独立 agent 做,不是自审。"
```

---

## C5 — 移动端:FFI、渲染引擎、入口、交接单

> **构建纪律(`apps/mobile_flutter/CLAUDE.md`):** 日常只用 `flutter analyze`、
> `flutter test`、Rust 单测 + 当前选中的模拟器 debug 跑。**不**跑 release、不跑全 ABI;
> 任何预计超过 5 分钟的命令先把原文报给用户,得许可再跑。
>
> **界面位置:** C5 的入口挂在「看懂」tab 的入口卡(UX Stage 1 的四 tab 结构)。
> Stage 1 若还没落地,**先挂到现有的概览页**(`overview_screen.dart` 的
> `_summary` 子树,`VisitSheetBanner` 之后),位置由一个常量控制,Stage 1 一到位只改一处。

### Task 20: FRB `vault_profile_view` 与包的安装/刷新

**Files:**
- Create: `apps/mobile_flutter/rust/src/api/vault_profile.rs`
- Modify: `apps/mobile_flutter/rust/src/api/mod.rs`(挂新模块)
- Modify: `apps/mobile_flutter/rust/Cargo.toml`(加 `profile` path 依赖)
- Modify: `apps/mobile_flutter/rust/src/api/vault.rs` —— `vault_cloud_commit_extraction`
  带上 `schema` 参数(按符号定位,不用行号)
- Modify: `apps/mobile_flutter/lib/cloud_extract.dart:147`(`'schema': 2`)
- Create: `apps/mobile_flutter/lib/skill_packages.dart`(拉包 + 交给 Rust 缓存)
- Modify: `apps/mobile_flutter/rust/src/frb_generated.rs`(codegen 产物)

**Interfaces:**
- Produces(FRB):
  - `vault_profile_verify_index(envelope_json: String) -> anyhow::Result<String>` → 验签后的清单 JSON
  - `vault_profile_install_package(dir: String, envelope_json: String) -> anyhow::Result<String>` → 包 id
  - `vault_profile_view(dir: String, package_id: String) -> anyhow::Result<String>` → `ProfileView` 的 JSON
  - `vault_profile_record_event(kind: String, package: String, at: String, payload_json: String) -> anyhow::Result<i64>` → document_id
- Consumes: `profile::{cache_store, cache_load, materialize}`;`parser::{ProfileEvent, parse_profile_event_payload, render_profile_event_text}`
- **函数名必须排在 `recognize_image_pp` 之后**(派发表按名字典序):`vault_profile_*` 排在
  `vault_cloud_redact_image`(73)与 `view_emergency_card`(74)之间,**下标 44 不动**。

- [ ] **Step 1: 写失败测试**

`apps/mobile_flutter/rust/src/api/vault_profile.rs` 的 `mod tests`(用 `tempfile`,与
`vault_ephemeral` 的单测同一手法):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installing_a_tampered_package_fails_and_leaves_no_cache_file() {
        let dir = tempfile::tempdir().unwrap();
        let bad = r#"{"sig":"AAAA","package":"{}"}"#;
        assert!(vault_profile_install_package(
            dir.path().display().to_string(), bad.into()).is_err());
        assert!(!dir.path().join("skills").exists());
    }

    #[test]
    fn view_without_an_installed_package_reports_it_instead_of_panicking() {
        let dir = tempfile::tempdir().unwrap();
        let err = vault_profile_view(dir.path().display().to_string(), "sle".into()).unwrap_err();
        assert!(err.to_string().contains("没有可用的病种包"));
    }
}
```

`apps/mobile_flutter/rust/tests/frb_dispatch_indices.rs`:

```rust
//! FRB 派发表是按函数名字典序编号的:新增一个排在前面的名字会把**后面所有**下标
//! 往后推一位,而 `recognize_image_pp` 的下标 44 是外部契约(见根 CLAUDE.md)。
//! 这条测试让「加个 FFI 函数」这件事不再可能悄悄改掉它。
#[test]
fn recognize_image_pp_is_still_dispatch_index_44() {
    let src = include_str!("../src/frb_generated.rs");
    assert!(
        src.contains("44 => wire__crate__api__vault__recognize_image_pp_impl"),
        "下标 44 被挪走了 —— 新 FFI 函数名必须字典序排在 recognize_image_pp 之后"
    );
}
```

`apps/mobile_flutter/test/skill_packages_test.dart`:

```dart
// 拉包只在「有网 + 已登录与否无关」时发生,且请求里**不带任何账号头**。
// 这条是隐私断言,不是网络断言(spec §8:请求里永远不带病种/包 id 之外,
// 也不能带账号 —— 否则服务端能把「谁」和「开了哪个病」对上)。
test('an unverified index is never used to build a request path', () async {
  // 中间人把 version 改成 "../../x" 或一个不存在的号,只要客户端不先验签就照拉。
  final client = FakeHttpClient(onGet: (url, headers) => '{"sig":"AA","package":"{}"}');
  final pkgs = SkillPackages(client: client);
  await pkgs.refreshIndex();
  expect(pkgs.lastFetchedPackagePaths, isEmpty, reason: '清单没验过就不许发第二个请求');
});

test('skill package fetch carries no auth header', () async {
  final captured = <String, String>{};
  final client = FakeHttpClient(onGet: (url, headers) {
    captured.addAll(headers);
    return '{"skills":[]}';
  });
  await SkillPackages(client: client).refreshIndex();
  expect(captured.containsKey('Authorization'), isFalse);
  expect(captured.containsKey('X-Device-Id'), isFalse);
});
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter/rust && cargo test`
Expected: FAIL — `vault_profile.rs` 不存在;`frb_dispatch_indices` 也还没有。

- [ ] **Step 3: 实现**

`apps/mobile_flutter/rust/Cargo.toml` 加 `profile = { path = "../../../packages/profile" }`。

`apps/mobile_flutter/rust/src/api/vault_profile.rs`:

```rust
//! 病程档案的 FFI 门面。**规则全在 `packages/profile`**,这里只做三件事:
//! 把包收进缓存、把保险箱投影成 `SourceDoc`、把 `ProfileView` 序列化给 Dart。
//!
//! 函数名都以 `vault_profile_` 打头:FRB 派发表按名字典序编号,这个前缀排在
//! `recognize_image_pp`(下标 44,外部契约)之后,所以加函数不会挪动它。
use crate::api::vault_projections;

/// 验清单的签名并原样交给 Dart。**Dart 永远不自己解析未验签的清单** —— 那是
/// 中间人改一行 `version` 就能拿去拼路径的地方(Task 27)。
pub fn vault_profile_verify_index(envelope_json: String) -> anyhow::Result<String> {
    let idx = profile::load_signed_index(&envelope_json).map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(serde_json::to_string(&serde_json::json!({
        "skills": idx.skills.iter().map(|s| serde_json::json!({
            "id": s.id, "version": s.version, "min_engine": s.min_engine, "name": s.name
        })).collect::<Vec<_>>()
    }))?)
}

/// 装包。单调版本闸在 `profile::cache_store` 里(Task 27):送来一个更旧的版本
/// 会返回 `Downgrade`,这里原样变成一个 Dart 能读到的错误,**不吞掉**。
pub fn vault_profile_install_package(dir: String, envelope_json: String) -> anyhow::Result<String> {
    profile::cache_store(std::path::Path::new(&dir), &envelope_json)
        .map_err(|e| anyhow::anyhow!("{e}"))
}

pub fn vault_profile_view(dir: String, package_id: String) -> anyhow::Result<String> {
    let pkg = profile::cache_load(std::path::Path::new(&dir), &package_id)
        .ok_or_else(|| anyhow::anyhow!("没有可用的病种包:{package_id}"))?;
    // 术语覆盖层:包带来的别名与新分析物必须在 `aggregate` **之前**装上,
    // 否则 UPCR 这类新分析物在分组那一步就已经落进「未识别」桶了。
    terminology::set_overlay(overlay_entries(&pkg));
    let projection = vault_projections::gather_for_profile()?;
    let docs = projection.source_docs();
    let events = projection.profile_events();
    let view = profile::materialize(&docs, &events, &pkg, chrono::Local::now().date_naive());
    Ok(serde_json::to_string(&view)?)
}

pub fn vault_profile_record_event(
    kind: String,
    package: String,
    at: String,
    payload_json: String,
) -> anyhow::Result<i64> {
    let ev = parser::ProfileEvent {
        kind,
        package,
        at,
        payload: serde_json::from_str(&payload_json)?,
    };
    let text = parser::render_profile_event_text(&human_lines(&ev), &ev);
    // 与 `add_note` / `add_self_measurement` 完全同一条路径:import + add_document +
    // add_ocr,零新事件类型(`vault.rs:848,979` 的先例)。
    crate::api::vault::add_synthetic_document(core_model::DocType::ProfileEvent, &title(&ev), &text)
}
```

`vault_projections.rs` 加两个小函数:`gather_for_profile()`(复用既有 `gather()`)与
`profile_events()`(对 `doc_type == "profile_event"` 的文档跑 `parse_profile_event_payload`,
解不出来的**跳过**,不猜)。`add_synthetic_document` 是把 `add_note`(`vault.rs:979`)里
那三步抽出来的共用函数,`add_note`/`add_self_measurement` 改为调用它(同一条路径,别写第二份)。

`vault.rs` 的 `vault_cloud_commit_extraction` 加一个 `schema: i32` 参数,原样传给
`NewExtraction`(Task 8 已在同一处写死了 `schema: 1`,这里把它换成参数);
`cloud_extract.dart` 里那处 `'schema': 1`(`grep -n "'schema'" apps/mobile_flutter/lib/cloud_extract.dart`)
改 `'schema': 2`,并把 2 一路传到
`vaultCloudCommitExtraction(... schema: 2)`。

`apps/mobile_flutter/lib/skill_packages.dart`:拉 `GET /v1/skills/index.json`,
先过 `vaultProfileVerifyIndex` 验签,**再**按验过的 `id`/`version` 去拉
`GET /v1/skills/{id}/{ver}.json`,拿到信封原文后调 `vaultProfileInstallPackage`。
两次请求都**用一个不带任何账号头的裸 http 客户端**(不要复用 `ApiClient` —— 它会自动挂
bearer 与 `X-Device-Id`)。失败静默(没网、验签不过、被单调闸拒了降级,都退回缓存里那份)。

codegen:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter
flutter_rust_bridge_codegen generate
```

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter/rust && cargo test`
Expected: PASS,**特别是 `recognize_image_pp_is_still_dispatch_index_44`**。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter && flutter analyze && flutter test`
Expected: 无 error。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && git diff --stat apps/mobile_flutter/rust/src/frb_generated.rs`
Expected: 只增不改既有下标行(人工扫一眼 diff 里有没有 `NN => ` 的号码被改动)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add apps/mobile_flutter
git commit -m "feat(mobile): vault_profile_* FFI 与包的安装/刷新;云抽取切到 schema 2

函数名前缀保证 FRB 派发表里 recognize_image_pp 仍是 44,并加了一条测试钉住它。
拉包用不带账号头的裸客户端 —— 服务端不能把「谁」和「开了哪个病」对上。"
```

---

### Task 21: 渲染引擎 —— 7 种 section

**Files:**
- Create: `apps/mobile_flutter/lib/widgets/profile_sections.dart`
- Create: `apps/mobile_flutter/test/profile_sections_test.dart`

**Interfaces:**
- Consumes: Task 20 的 `vault_profile_view` 返回的 JSON
- Produces:
  - `ProfileSectionView(Map<String, dynamic> section)` —— 一个 widget 按 `kind` 分派
  - 7 个 kind:`status_card` / `score_card` / `series_chart` / `reminders` / `timeline` / `checklist` / `handoff`
  - **认不出的 kind 整块跳过**(返回 `SizedBox.shrink()`),不抛异常
  - `empty_hint != null` 时折叠成一行提示,不展开

- [ ] **Step 1: 写失败测试**

`apps/mobile_flutter/test/profile_sections_test.dart`:

```dart
// section 的标题、顺序、空态文案**全部来自包** —— 这几条测试就是在钉住
// 「App 里没有任何一句写死的病种文案」这件事。
testWidgets('titles come from the package, not from the widget', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'score_card', 'title': '活动度(化验可算部分)', 'empty_hint': null,
    'body': {'score': 6, 'max': 18, 'label': '化验可算部分', 'window_days': 10,
             'as_of': '2026-09-16', 'hits': []},
  })));
  expect(find.text('活动度(化验可算部分)'), findsOneWidget);
  expect(find.textContaining('6'), findsWidgets);
  expect(find.textContaining('18'), findsWidgets);
});

testWidgets('an unknown section kind renders nothing instead of crashing', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'something_from_2027', 'title': 'x', 'body': {},
  })));
  expect(t.takeException(), isNull);
});

testWidgets('an empty section collapses to its package-supplied hint', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'timeline', 'title': '病程时间轴',
    'empty_hint': '还没有可以放上时间轴的记录',
    'body': {'years': []},
  })));
  expect(find.text('还没有可以放上时间轴的记录'), findsOneWidget);
});

testWidgets('the score card never renders the words SLEDAI total', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'score_card', 'title': '活动度(化验可算部分)',
    'body': {'score': 6, 'max': 18, 'label': '化验可算部分', 'window_days': 10,
             'as_of': '2026-09-16', 'hits': []},
  })));
  expect(find.textContaining('SLEDAI 总分'), findsNothing);
  expect(find.textContaining('计算 SLEDAI'), findsNothing);
});

testWidgets('a checklist renders unknown as unknown, not as a failure', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'checklist', 'title': '达标情况(逐条对照)',
    'body': {'states': [{'id': 'doris', 'label': 'DORIS', 'verdict': 'unknown', 'items': [
      {'id': 'phga', 'label': 'PhGA < 0.5', 'verdict': 'unknown', 'actual': null,
       'note': null, 'source': 'S5'}]}]},
  })));
  expect(find.text('未知'), findsOneWidget);
  expect(find.text('未达标'), findsNothing);
});

testWidgets('an unverified point is drawn hollow and labelled 需核对', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'series_chart', 'title': '指标趋势',
    'body': {'groups': [{'name': '补体', 'series': [{
      'analyte_key': 'complement_c3', 'name': '补体C3', 'unit': 'g/L',
      'ref_low': 0.9, 'ref_high': 1.8, 'values_converted': false,
      'needs_review_count': 1, 'dir': 'low_is_active', 'role': 'activity',
      'points': [{'date': '2026-09-01', 'value': 0.4, 'flag': 'L',
                  'unverified': true, 'document_index': 0}]}]}], 'missing': []},
  })));
  expect(find.textContaining('需核对'), findsOneWidget);
});

testWidgets('an unconvertible glucocorticoid says 换算表待核, not a vague failure', (t) async {
  // 缺的是**换算表**,不是缺药。含糊成「无法计算」会让人以为是 bug。
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'status_card', 'title': '现行方案',
    'body': {'gc': {'daily_pred_equiv_mg': null, 'drug': null, 'since': null,
                    'targets': [], 'unconvertible': [
                      {'name': '甲泼尼龙', 'dose': '8mg', 'reason': '换算表待核'}]},
             'hcq': null, 'others': [], 'last_visit': null},
  })));
  expect(find.textContaining('甲泼尼龙'), findsOneWidget);
  expect(find.text('换算表待核'), findsOneWidget);
});

testWidgets('every reminder shows its basis label', (t) async {
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'reminders', 'title': '待补 / 逾期',
    'body': {'items': [
      {'id': 'mmf_cbc', 'text': '血常规', 'state': 'overdue', 'overdue_days': 12,
       'basis': 'label', 'source': 'L1'},
      {'id': 'mtx_labs', 'text': '血常规 + 肝功', 'state': 'never',
       'basis': 'package_default', 'source': 'PKG'}]},
  })));
  expect(find.text('说明书'), findsOneWidget);
  expect(find.text('包默认'), findsOneWidget);   // 包默认必须看得见,不能冒充指南
});

testWidgets('values converted to a canonical unit say so', (t) async {
  // 用户在纸上找不到这个数字,不说就等于改写原文(AnalyteSeries.values_converted 的既有约定)。
  await t.pumpWidget(_wrap(ProfileSectionView({
    'kind': 'series_chart', 'title': '指标趋势',
    'body': {'groups': [{'name': '肾', 'series': [{
      'analyte_key': 'urine_pcr', 'name': '尿蛋白肌酐比值', 'unit': 'mg/g',
      'ref_low': null, 'ref_high': null, 'values_converted': true,
      'needs_review_count': 0, 'dir': 'high_is_active', 'role': 'organ:kidney',
      'points': [{'date': '2026-09-01', 'value': 884.0, 'flag': null,
                  'unverified': false, 'document_index': 0}]}]}], 'missing': []},
  })));
  expect(find.textContaining('已换算'), findsOneWidget);
});
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter && flutter test test/profile_sections_test.dart`
Expected: FAIL — `ProfileSectionView` 未定义。

- [ ] **Step 3: 实现**

`profile_sections.dart`:一个 `ProfileSectionView` 按 `kind` switch 到 7 个私有 widget。
共用约定:
- 标题、空态文案一律读 `section['title']` / `section['empty_hint']`,widget 里**不写任何病种文案**;
- `basis` → 中文标签映射四档:`guideline`→「指南」、`label`→「说明书」、
  `literature`→「文献」、`package_default`→「包默认」;
- `verdict` → `yes`「满足」/`no`「未满足」/`unknown`「未知」;
- `status_card` 的 `gc.unconvertible[]` 逐条显示「药名 + 剂量 + `reason`」,`reason` 就是
  Rust 那边给的 `"换算表待核"` 原串(**不要在 Flutter 里另写一句文案** —— 两处各写一句,
  改了一处另一处就悄悄留在旧措辞上);
- 趋势线复用既有 `widgets/trend_chart.dart`(参考带用 `ref_low`/`ref_high`,指南目标线另画虚线),
  `unverified` 点画空心并在序列标题旁挂「需核对 ×N」chip(与 `lab_status.dart` 现有 chip 同一样式);
- `default:` 分支返回 `const SizedBox.shrink()`。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter && flutter analyze && flutter test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add apps/mobile_flutter/lib/widgets/profile_sections.dart apps/mobile_flutter/test/profile_sections_test.dart
git commit -m "feat(mobile): 病程档案渲染引擎,7 种 section

标题/顺序/空态文案全来自包,widget 里没有一句病种文案 —— 这是「加病不发版」
的前提。认不出的 kind 整块跳过。未知就显示未知,包默认标成包默认。"
```

---

### Task 22: 「病程档案」入口卡与独立页

**Files:**
- Create: `apps/mobile_flutter/lib/screens/disease_profile_screen.dart`
- Create: `apps/mobile_flutter/lib/widgets/disease_profile_card.dart`
- Modify: `apps/mobile_flutter/lib/screens/overview_screen.dart:251` 附近(`VisitSheetBanner` 之后插入入口卡)
- Create: `apps/mobile_flutter/test/disease_profile_card_test.dart`

**Interfaces:**
- Consumes: Task 20 的 `vaultProfileView` / `vaultProfileRecordEvent`;Task 21 的 `ProfileSectionView`
- Produces:
  - `DiseaseProfileCard()` —— 「看懂」tab 的入口卡。**三态**:未开启(不显示,除非命中 `triggers`
    → 显示「这份档案像是狼疮相关,要不要开启?」)、已开启有数据(显示首个 `reminders`/`score_card` 摘要)、
    已开启无数据(一行提示)
  - `DiseaseProfileScreen(packageId)` —— 独立页,按包给的顺序渲染全部 section
  - 常量 `kDiseaseProfileMountPoint`(注释说明:Stage 1 四 tab 到位后改到「看懂」tab)

> **通用摘要不变**(spec §0):入口卡是「看懂」里**另加**的一块,既有化验趋势/时间线/就诊
> 一行都不改。

- [ ] **Step 1: 写失败测试**

```dart
testWidgets('a never-enabled package shows nothing at all', (t) async {
  await t.pumpWidget(_wrap(DiseaseProfileCard(view: {
    'package_id': 'sle', 'enabled': false, 'sections': [], 'sources': []})));
  expect(find.byType(Card), findsNothing);
});

testWidgets('a suggestion card asks instead of labelling the user', (t) async {
  // spec §5.1:不自动贴标签,用户确认才 enable。
  await t.pumpWidget(_wrap(DiseaseProfileCard(
    view: {'package_id': 'sle', 'enabled': false, 'sections': [], 'sources': []},
    suggestion: {'display_name': '系统性红斑狼疮', 'reason': '档案里出现了「狼疮性肾炎」'})));
  expect(find.textContaining('要不要'), findsOneWidget);
  expect(find.textContaining('你患有'), findsNothing);
  expect(find.text('先不用'), findsOneWidget);
});

testWidgets('an enabled but empty profile says what to bring back', (t) async {
  await t.pumpWidget(_wrap(DiseaseProfileCard(view: {
    'package_id': 'sle', 'enabled': true, 'display_name': '系统性红斑狼疮',
    'sections': [{'kind': 'reminders', 'title': '待补 / 逾期',
                  'empty_hint': '该查的都查过了', 'body': {'items': []}}],
    'sources': []})));
  expect(find.text('该查的都查过了'), findsOneWidget);
});

testWidgets('tapping enable writes exactly one profile_event', (t) async {
  final calls = <List<String>>[];
  await t.pumpWidget(_wrap(DiseaseProfileCard(
    view: {'package_id': 'sle', 'enabled': false, 'sections': [], 'sources': []},
    suggestion: {'display_name': '系统性红斑狼疮', 'reason': 'x'},
    recordEvent: (kind, pkg, at, payload) async { calls.add([kind, pkg]); return 1; })));
  await t.tap(find.text('开启'));
  await t.pumpAndSettle();
  expect(calls, [['enable', 'sle']]);
});

testWidgets('the card never claims a diagnosis or a remission', (t) async {
  await t.pumpWidget(_wrap(DiseaseProfileCard(view: _fullViewFixture())));
  for (final banned in ['确诊', '已缓解', '判断缓解', '计算 SLEDAI']) {
    expect(find.textContaining(banned), findsNothing, reason: banned);
  }
});
```

再加一条 `disease_profile_screen_test.dart`:**三态**(加载中 / 成功 / 失败)各断言一次
(memory `test-all-three-states`:只验一条会连环出 bug)。

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter && flutter test test/disease_profile_card_test.dart`
Expected: FAIL — `DiseaseProfileCard` 未定义。

- [ ] **Step 3: 实现**

`disease_profile_card.dart` / `disease_profile_screen.dart` 按上面的三态实现;
`overview_screen.dart` 在 `VisitSheetBanner`(第 251 行)之后插入:

```dart
          // 「病程档案」入口。Stage 1 的四 tab 一到位,这一处整体搬到「看懂」tab
          // (只改这一处;卡片本身不依赖挂载位置)。
          const DiseaseProfileCard.mounted(),
```

`DiseaseProfileScreen` 用 `FutureBuilder` 包 `vaultProfileView`,三态各有明确 UI;
失败态给「重试」并显示是「没有包」还是「算不出来」。

- [ ] **Step 4: 跑测试,确认通过**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter && flutter analyze && flutter test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add apps/mobile_flutter
git commit -m "feat(mobile): 病程档案入口卡与独立页

不自动贴标签 —— 命中 triggers 只问「要不要开启」,用户确认才写一条 enable。
通用摘要一行不改。加载中/成功/失败三态各有明确 UI 与测试。"
```

---

### Task 23: 医生交接单进加密分享 + 查看器渲染

**Files:**
- Modify: `packages/share/src/share.rs:158`(`build_share_blob_inner` 加一个参数)、`:319-350`(payload 挂 `profile`)、`:403`(`build_own_share_blob` 旁边加一个带 profile 的入口)
- Modify: `apps/mobile_flutter/rust/src/api/vault.rs:1116`(`qr_share_blob` 把 ProfileView 透传下去)
- Modify: `apps/mobile_flutter/lib/screens/disease_profile_screen.dart`(「给医生看」入口)与 `qr_share_screen.dart` 的调用点
- Modify: `web/hosted-viewer/index.html:1141`(`render(payload)` 里加一行)+ 新增 `renderProfile`
- Run: `scripts/csp-hashes.py`(**改了内联脚本就必须跑**)
- Modify: `apps/mobile_flutter/rust/src/frb_generated.rs`(codegen 产物)

**Interfaces:**
- Consumes: Task 20 的 `vault_profile_view`(返回 ProfileView JSON);Task 18 包里的 `views.handoff` 顺序
- Produces:
  - `medme_share::share::build_own_share_blob_with_profile(v: &Vault, expires_days: u32, render_dicom_png: crate::DicomPngRenderer, profile: Option<&serde_json::Value>) -> Result<(Vec<u8>, String, i64), String>`
  - `build_own_share_blob` 变成它 `profile = None` 的特例(与文件里 `build_encrypted_share`
    是 `build_encrypted_share_with_consent` 特例的写法一致,`share.rs:115-118` 自己写了这条约定)
  - `qr_share_blob(expires_days: i64, profile_json: Option<String>)` —— **函数名不变**,
    所以 FRB 派发表里它仍是 42、`recognize_image_pp` 仍是 44
  - 分享 payload 新增可选顶层键 `profile`(内容就是 ProfileView 的 JSON)

> ⚠️ **本任务改了「数据往哪走」** —— 给医生看的那份加密内容里**多了一类东西**。
> 通道、加密方式、有效期、谁能解密全都不变,但内容变了,所以 **Task 24 的隐私政策
> 第 3 条必须和本任务一起落地**(CLAUDE.md 四条硬规矩第 4 条)。两者一起做或一起不做,
> 不许只改代码留政策。
>
> **为什么落在 `build_share_blob_inner`(`share.rs:158`)而不是各个入口:** 那一个函数是
> 六个公开构建器(`build_encrypted_share` / `_with_consent` / `_with_consent_and_confirmed` /
> `build_own_share_blob` / `build_claim_blob`)**唯一**共同的 payload 装配点,`summary` 也正是
> 在那里挂上去的(`share.rs:319` 算、`:349` 挂)。改在这里,密文格式与查看器解密分支
> 只有一处定义这件事继续成立。
>
> **哪条路带 profile,哪条不带:**
> - **带**:`build_own_share_blob`(病人出二维码 → 瞬时云 → 托管查看器)。这是「给医生看」那条。
> - **不带**:`qr::build_qr_share`(`qr.rs:227`)—— 那条把整份摘要塞进 URL fragment,
>   体积是硬约束(`qr::trim_summary` + `QrLimits` 就是为此存在的),再塞一份档案进去必然超。
> - **不带**:`build_claim_blob`(医生代拍 → 病人认领)—— 方向相反,那份是医生给病人的,
>   病人的病程档案不在医生手机上。
> - **不带**:`build_encrypted_share*`(桌面导出)—— 桌面暂缓(landing-messaging 的取舍),
>   本任务不动它的签名。`build_share_blob_inner` 那个新参数它们传 `None`,输出逐字节不变。

- [ ] **Step 1: 写失败测试**

追加到 `packages/share/src/share.rs` 的 `mod tests`:

```rust
    /// profile 是**严格加法**:不传的调用方产出的 payload 必须逐字节不变。
    /// 这条要挡的是一整类事故 —— 老分享文件、老查看器、桌面导出都还在跑同一份密文格式。
    #[test]
    fn a_share_without_a_profile_has_no_profile_key_at_all() {
        let (vault, _tmp) = fixture_vault_with_records();
        let (blob, key, _n) =
            build_own_share_blob(&vault, 5, &crate::render_dicom_png_in_process).unwrap();
        let payload = decrypt_payload_for_test(&blob, &key);
        assert!(payload.get("profile").is_none());
    }

    #[test]
    fn passing_none_through_the_new_parameter_is_byte_identical_to_the_old_entry() {
        let (vault, _tmp) = fixture_vault_with_records();
        let a = build_own_share_blob(&vault, 5, &crate::render_dicom_png_in_process).unwrap();
        let b = build_own_share_blob_with_profile(
            &vault, 5, &crate::render_dicom_png_in_process, None,
        )
        .unwrap();
        // blob 每次的 nonce/密钥都不同,所以比**明文 payload**,不是比密文。
        assert_eq!(
            decrypt_payload_for_test(&a.0, &a.1),
            decrypt_payload_for_test(&b.0, &b.1)
        );
    }

    #[test]
    fn a_profile_is_carried_verbatim_when_present() {
        let (vault, _tmp) = fixture_vault_with_records();
        let view = serde_json::json!({
            "package_id": "sle", "package_version": "2026.09.1",
            "display_name": "系统性红斑狼疮", "enabled": true,
            "disclaimer": "仅整理你的病历,不做诊断",
            "sections": [{"kind": "handoff", "title": "给医生看", "empty_hint": null,
                          "body": {"blocks": []}}],
            "sources": [{"id": "S1", "cite": "x", "url": null}]
        });
        let (blob, key, _n) = build_own_share_blob_with_profile(
            &vault, 5, &crate::render_dicom_png_in_process, Some(&view),
        )
        .unwrap();
        let payload = decrypt_payload_for_test(&blob, &key);
        assert_eq!(payload["profile"], view, "档案必须原样进去,分享层不做任何改写");
    }

    #[test]
    fn a_disabled_or_empty_profile_is_not_attached() {
        // 「没开启」和「开启了但一个 section 都算不出来」都不该在医生那边多出一个空块。
        let (vault, _tmp) = fixture_vault_with_records();
        for view in [
            serde_json::json!({"package_id":"sle","enabled":false,"sections":[],"sources":[]}),
            serde_json::json!({"package_id":"sle","enabled":true,"sections":[],"sources":[]}),
        ] {
            let (blob, key, _n) = build_own_share_blob_with_profile(
                &vault, 5, &crate::render_dicom_png_in_process, Some(&view),
            )
            .unwrap();
            assert!(decrypt_payload_for_test(&blob, &key).get("profile").is_none());
        }
    }

    /// 查看器是 `include_str!` 进来的同一份文件(`share.rs:27`),所以这里能直接钉住
    /// 它确实长出了渲染入口 —— 没有 JS 测试框架,也不为这件事引入一个。
    #[test]
    fn the_viewer_has_a_guarded_profile_render_entry() {
        assert!(CANONICAL_VIEWER.contains("function renderProfile("));
        assert!(
            CANONICAL_VIEWER.contains("if (payload.profile)"),
            "必须是**有才画**:老分享包没有这个键,不能因此报错或画空块"
        );
    }
```

> `fixture_vault_with_records()` / `decrypt_payload_for_test()`:`mod tests` 里已经有等价的
> 建库与解密片段(见 `share.rs:587`、`:1198-1240` 一带那几个测试的开头几行)。
> **把它们抽成这两个 helper 并让既有测试改用**,不要再写第三份 —— 抽完既有测试断言一字不改。

移动端 Rust 侧(`apps/mobile_flutter/rust/src/api/vault.rs` 的 `mod tests`,或
`vault_profile.rs` 的 `mod tests`):

```rust
    #[test]
    fn qr_share_blob_rejects_a_profile_json_that_is_not_json() {
        // Dart 传下来的是一个字符串;坏字符串要当场报错,不能悄悄当成「没有档案」
        // 去生成一份**少了交接单**的分享 —— 医生那边看不出少了东西。
        let err = qr_share_blob(5, Some("{not json".into())).unwrap_err();
        assert!(err.to_string().contains("档案 JSON"));
    }
```

- [ ] **Step 2: 跑测试,确认失败**

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p medme-share`
Expected: FAIL — `cannot find function 'build_own_share_blob_with_profile'`;
`the_viewer_has_a_guarded_profile_render_entry` 也红(查看器还没有那个函数)。

- [ ] **Step 3: 实现**

`packages/share/src/share.rs`:

```rust
fn build_share_blob_inner(
    v: &Vault,
    expires_days: u32,
    render_dicom_png: crate::DicomPngRenderer,
    consent: Option<ShareConsent>,
    confirmed_document_ids: Option<&HashSet<i64>>,
    /// 病程档案(`profile::ProfileView` 的 JSON)。**严格加法**:`None` 时 payload
    /// 逐字节不变。本层不解释它的内容,原样挂上去 —— 规则、措辞、出处都已经在
    /// `packages/profile` 里定完了,分享层再碰一次就是第二份真相。
    profile: Option<&serde_json::Value>,
) -> Result<(Vec<u8>, [u8; 32], i64), String> {
```

在 `payload["summary"] = summary;`(`share.rs:349`)那个 `if` 块之后插入:

```rust
    // 病程档案(可选)。挂的门槛与 summary 同理:开着、且真的算出了内容才挂,
    // 免得医生那边多出一个空块。
    if let Some(pv) = profile {
        let enabled = pv.get("enabled").and_then(|b| b.as_bool()).unwrap_or(false);
        let has_sections = pv
            .get("sections")
            .and_then(|s| s.as_array())
            .is_some_and(|a| !a.is_empty());
        if enabled && has_sections {
            payload["profile"] = pv.clone();
        }
    }
```

五个既有调用点(`build_encrypted_share_inner`、`build_own_share_blob`、`build_claim_blob`)
末尾各补一个 `None`。新入口:

```rust
/// 同 [`build_own_share_blob`],但把病程档案(`profile::ProfileView` 的 JSON)一起
/// 放进密文。[`build_own_share_blob`] 就是本函数传 `profile=None` 的特例,两者共用
/// 同一套装配逻辑,不重复维护 —— 与 [`build_encrypted_share`] /
/// [`build_encrypted_share_with_consent`] 的关系完全一样。
pub fn build_own_share_blob_with_profile(
    v: &Vault,
    expires_days: u32,
    render_dicom_png: crate::DicomPngRenderer,
    profile: Option<&serde_json::Value>,
) -> Result<(Vec<u8>, String, i64), String> {
    let (blob, key_bytes, record_count) =
        build_share_blob_inner(v, expires_days, render_dicom_png, None, None, profile)?;
    Ok((blob, B64URL.encode(key_bytes), record_count))
}
```

`build_own_share_blob` 改成调它(传 `None`),函数体只剩一行。

`apps/mobile_flutter/rust/src/api/vault.rs` 的 `qr_share_blob`(`:1116`):

```rust
/// `profile_json`:`vault_profile_view` 的返回值原样带下来,没开启病程档案就传 `None`。
/// **解析失败当场报错**,不降级成「没有档案」—— 那样会静默产出一份少了交接单的分享,
/// 医生那边看不出少了东西。
pub fn qr_share_blob(
    expires_days: i64,
    profile_json: Option<String>,
) -> anyhow::Result<(Vec<u8>, String, i64)> {
    let profile: Option<serde_json::Value> = match profile_json.as_deref() {
        Some(s) => Some(
            serde_json::from_str(s).map_err(|e| anyhow::anyhow!("档案 JSON 解析失败:{e}"))?,
        ),
        None => None,
    };
    with_state(|state| {
        medme_share::share::build_own_share_blob_with_profile(
            &state.vault,
            expires_days as u32,
            &medme_share::render_dicom_png_in_process,
            profile.as_ref(),
        )
        .map_err(|e| anyhow::anyhow!(e))
    })
}
```

Dart 侧:`disease_profile_screen.dart` 的「给医生看」按钮把当前 `vaultProfileView` 的原串
带进现有的分享流程;`qr_share_screen.dart` 里调 `qrShareBlob` 的地方补上
`profileJson:`(没开启就 `null`)。**其余分享入口一律传 `null`**。

`web/hosted-viewer/index.html`,在 `render(payload)`(`:1141`)里 `renderSummary(...)` 之后:

```js
  // 病程档案(可选)。老分享包没有这个键 —— 一行都不多画。
  if (payload.profile) renderProfile(payload.profile);
```

新增 `renderProfile(pv)`:按 `pv.sections` 的顺序渲染,标题/空态文案全部读 section 自己的
`title`/`empty_hint`(**查看器里同样不写任何病种文案**);`basis`/`verdict`/「需核对」
三套标签用**与手机端逐字相同**的中文词(`guideline`→「指南」、`label`→「说明书」、
`literature`→「文献」、`package_default`→「包默认」;`yes`→「满足」、`no`→「未满足」、
`unknown`→「未知」)—— 两边各写一套词,医生会以为是两个东西。每个数值旁显示其
`source` id,末尾列 `pv.sources` 全文与 `pv.disclaimer`。

改完**必须**跑:

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
python3 scripts/csp-hashes.py
```

> 不跑的后果是**查看器整页白屏**:CSP 里的内联脚本 sha256 对不上,浏览器直接拒绝执行,
> 而本地 `file://` 打开时看不出来。`share.rs` 的
> `every_inline_script_in_the_hosted_viewer_is_allowed_by_its_own_csp` 会红 —— 那条测试
> 就是为这件事补的(它已经发生过一次)。

- [ ] **Step 4: codegen、下标核对、跑测试**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter
flutter_rust_bridge_codegen generate
```

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter/rust && cargo test`
Expected: PASS,**含 `recognize_image_pp_is_still_dispatch_index_44`**(Task 20 建的那条)。
`qr_share_blob` 只是加参数、名字没变,派发表编号不该动。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && git diff -U0 apps/mobile_flutter/rust/src/frb_generated.rs | grep -E '^[+-] *[0-9]+ =>' | sort | uniq -c`
Expected: 没有任何 `NN =>` 行被改成别的编号(只可能整块不变)。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && cargo test -p medme-share`
Expected: PASS(含 CSP 哈希那条与新增五条)。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a && python3 scripts/csp-hashes.py --check`
Expected: 退出码 0。

Run: `cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter && flutter analyze && flutter test`
Expected: 无 error。

手工:用 `packages/share/examples/gen_demo_share.rs` 生成一份**不带** profile 的分享 HTML,
在浏览器里打开,与改动前生成的那份逐屏比对(尤其是 devtools 控制台**没有** CSP 报错)。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add packages/share web/hosted-viewer apps/mobile_flutter
git commit -m "feat(share): 病程档案进加密分享包,托管查看器按包的顺序渲染

改在 build_share_blob_inner —— 六个公开构建器唯一共同的 payload 装配点,
summary 也是在那里挂的。不传 profile 的调用方(桌面导出、代拍认领、
URL fragment 二维码)明文 payload 逐字节不变。手机端与查看器用同一套中文标签。
改了内联脚本,已重算 CSP sha256。"
```
---

## C6 — 隐私政策、ADR、模拟器 smoke

### Task 24: 隐私政策 §三.7 一句 + 新增一段

**Files:**
- Modify: `/Volumes/extraSupply/Projects/Medme-ghpages/privacy.html:245` 之后(§三 第 7 项内部)
- Modify: 同文件 `:278`(§三之二)之前插入新的一节

> ⚠️ **gh-pages 是推上去即上线,没有 merge 这一步**(CLAUDE.md 四条硬规矩第 4 条)。
> 工作树 `/Volumes/extraSupply/Projects/Medme-ghpages`,与 `main` **没有共同祖先** ——
> 改代码时看不见它,评审也评审不到。改完自己 `curl` 线上核实。

**这次改了什么「数据往哪走」:**
1. **发出去的东西多了一类。** 云端结构化整理(第 7 项)现在还会让模型从**脱敏后的**
   单据里整理出「病程事实」:复发、住院、活检结果、用药变化、某项检查做没做过。
   通道、脱敏、那道硬闸、发给谁,**全都不变** —— 变的只是模型被要求整理出来的内容。
2. **新增一条「不离开手机」的说明。** 病程档案本身(算分、达标表、提醒)**全在手机上算**,
   服务器不知道你开启了哪种病:病种包是**公开静态文件**,拉它的请求不带账号、不带设备号,
   请求里也没有任何病种偏好。
3. **二维码/代拍分享的内容多了一块。** 给医生看的那份里现在可以带上病程档案(交接单)。
   加密方式、有效期、谁能解密**都不变**。

- [ ] **Step 1: 改 §三.7(在「发出去的是什么」那段的项目符号列表里补一句)**

在 `privacy.html` §三 第 7 项「**留下的是**」那一条之后,补一条:

```html
    <li><strong>还会整理出「病程事实」</strong>:从同一份<strong>已经脱敏、已经涂黑</strong>的单据里,把「哪天复发过、哪天住过院、活检结果是什么、药加了还是减了、某项检查做没做过」这类事实按结构整理出来。<strong>发出去的东西一个字节都没变</strong>——变的只是我们要求模型从那张图里整理出什么。原文里没写的,不许它生成。</li>
```

- [ ] **Step 2: 在 §三之二(`:278`)之前插入新一节**

```html
<h2>三之三、「病程档案」在你手机上算,服务器不知道你开了哪种病</h2>

<div class="card">
  <p><strong>病程档案</strong>是一块可选的功能:开启之后,App 会把你已经导入的病历按某一种病的角度重新整理一遍——把化验里能算的那部分活动度整理出来、把指南和药品说明书里写明频率的复查列出来、把复发和用药变化排成时间轴。</p>

  <p><strong>算在哪里。</strong>全部在<strong>你的手机上</strong>。规则本身来自一个<strong>公开的静态文件</strong>(我们把它叫「病种包」),里面只有阈值、指南出处和展示顺序,<strong>不含任何用户数据</strong>。App 下载它的请求<strong>不带账号、不带设备号、不带任何和你有关的信息</strong>,和任何人打开我们网站上的一个公开文件没有区别。这个包由我们用私钥签名,签名对不上就不加载。</p>

  <p><strong>所以服务器不知道你开启了哪种病。</strong>你在 App 里开启、关闭、确认或否认某一种病,这些动作<strong>只写进你自己的保险箱</strong>(和病历一样是密文),不会单独发给任何人。云端结构化整理(第三节第 7 项)发出去的那份请求里,<strong>没有病种、没有包的名字</strong>——我们给模型的指令对这一族慢病是<strong>同一份</strong>,服务端从请求上看不出你是哪一个病。</p>

  <p><strong>会不会跟着分享出去。</strong>你主动出示二维码、或者医生用「代拍」给你建档的时候(第三节第 3、4 项),病程档案<strong>可以</strong>随那份加密内容一起给医生看。加密方式、有效期、谁能解密,<strong>和现在完全一样</strong>——只是那份里多了一块内容。</p>

  <p><strong>我们不做的事。</strong>App <strong>不做诊断</strong>、<strong>不判断你有没有缓解</strong>、也<strong>不替医生下结论</strong>。它只做两件事:把指南里「化验能算的那部分」算出来并标明这只是一部分;把「按指南或说明书该复查的」列出来。每一个数字旁边都写着它的出处。</p>
</div>
```

- [ ] **Step 3: 自查两条老账**

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
grep -n "七种" privacy.html
```

§三 的标题与开头都写着「只有以下七种」。本次**没有新增离开手机的通道**(病种包是**下载**,
不是上传;交接单走的是已有的第 3、4 项),所以七种不变 —— 新节编号为「三之三」,放在
「三之二」之前还是之后由行文顺序定,但**不得改动「七种」这个数**,也不得把新节混进那七条里。
若评审认为「下载一个公开文件」也该算一条通道,那就得同时改标题、开头、第五节权限表
和第六节第三方表 —— **要么都改,要么都不改,不许只改一处**。

- [ ] **Step 4: 上线并核实**

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
git add privacy.html
git commit -m "docs(privacy): 云端整理会整理病程事实;病程档案在手机上算

发出去的字节没变,变的是要求模型整理出什么。病种包是公开静态文件,
下载它的请求不带账号与设备号,所以服务端看不出用户开了哪种病。"
git push origin gh-pages
```

```bash
curl -s https://medmenow.com/privacy.html | grep -c "三之三"
curl -s https://medmenow.com/privacy.html | grep -c "病程事实"
```
Expected: 两条都 ≥ 1。**推上去即上线,必须自己 curl 核过才算完。**

---

### Task 25: ADR 0011

**Files:**
- Create: `docs/ADR/0011-disease-profile-skill-packages.md`

**Interfaces:** 无代码接口。Nygard 格式,ADR 不可变。

- [ ] **Step 1: 写 ADR**

`docs/ADR/0011-disease-profile-skill-packages.md`:

```markdown
# 0011. 病程档案:一个病 = 一个签名的静态包,规则在手机上跑

日期:2026-09-16
状态:已接受

## 背景

MedMe 已有的摘要是**通用**的:化验趋势、时间线、就诊。它对每个用户一视同仁,
因此对一个已经确诊的慢病患者帮助有限 —— 同样一张补体 C3,狼疮患者关心的是
「比上次低了吗、够不够计一次活动度」,而通用摘要只能说「低于参考区间」。

要做「按病看」,有三条路:(a) 把每个病的规则写进 App,(b) 把病历送到服务端按病
分析,(c) 把规则做成可下发的数据、在手机上跑。

## 决定

选 (c)。

1. **一个病 = 一个 skill 包**:服务端 `GET /v1/skills/{id}/{ver}.json` 的**公开静态
   JSON**,Ed25519 签名,公钥编进 App,验不过不加载。包里只有阈值、出处、展示顺序,
   **不含任何用户数据**。拉包的请求**不带账号、不带设备号**。
2. **App 里只有一个规则引擎(`packages/profile`,纯函数)和一个渲染引擎**(7 种
   section)。加一个病 = 发一个包,不发版;只有需要新的 section 类型或新的规则类型
   时才发版(包声明 `min_engine`)。
3. **抽取用族级 prompt**(schema 2):事实类型枚举对免疫介导慢病族是同一份,
   服务端从请求上看不出用户是哪个病。**请求里永远不带病种/包 id。**
4. **零新 `Event` 变体**:用户动作走 `DocumentAdded{doc_type=profile_event}`,
   与 `self_measurement`/`note` 同一先例(ADR 0003 的 CAS + 事件溯源不动)。
   `ExtractionAdded` 只把 `schema` 从 1 升到 2。
5. **包不能覆盖内置术语定义**:术语覆盖层只能加别名、加新分析物;与
   `dictionary.json` 撞 key 的一律以内置为准。
6. **不下结论**:界面上不出现「计算 SLEDAI」「判断缓解」。分数永远带「化验可算
   部分」标签,达标表逐条 ✔/✘/未知,每个数值带出处 id。

## 后果

**好的:**
- 加病、改阈值、跟进指南更新都不需要过应用商店审核。
- 服务端看不出用户开了哪种病(包是公开文件,抽取 prompt 是族级的)。
- 规则是纯函数 + golden 测试,阈值改动跑不掉。
- 保险箱格式与桌面逐字节兼容不受影响(没加事件类型)。

**代价:**
- 多了一条**签名信任链**:私钥丢了就等于规则可被替换。私钥只在发布者本机
  `~/.medme_skill_signing_key`,不进仓库、不进 CI。**清单 `skills/index.json` 与包用
  同一种签名信封**,并且客户端对每个包记住见过的最高版本、拒绝装更低的版本,
  所以**降级攻击也被挡住**:中间人既注入不了内容,也不能把用户按在一个旧规则上。
  残余面只剩「把缓存整个抹掉再喂旧包」(需要对设备存储的写权限,那时攻击者已经
  能做得多得多的事);当前不为它再加一层设备级防重放。
- 包里的每个数值都必须能追到一手文献。研究阶段抓到过两次工具编造,所以流程上
  强制**独立核查**(不许写包的人自审),核不到的一律写 `null` + 待核,不填近似值。
- 「化验可算部分」不是 SLEDAI 总分。这是一个必须一直说出口的局限 —— 一旦哪个版本
  忘了说,它就变成了一个看起来像分数的假分数。

## 与既有 ADR 的关系

- 不影响 ADR 0003(CAS + 事件溯源):没有新事件类型。
- 不影响 ADR 0005/0006/0007(OCR 分平台):抽取的输入不变。
- 建立在 ADR 0010(云 LLM 抽取与账号)之上:schema 2 走的是同一条通道、同一道
  脱敏硬闸、同一个计量。
```

- [ ] **Step 2: 核对编号与链接**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a && ls docs/ADR/
```
Expected: 0011 是新的最大号,没有重号。

- [ ] **Step 3: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add docs/ADR/0011-disease-profile-skill-packages.md
git commit -m "docs(adr): 0011 病程档案 —— 签名的静态病种包,规则在手机上跑"
```

---

### Task 26: 模拟器 smoke

**Files:**
- Create: `docs/log/2026-09-16-disease-profile-smoke.md`

**Interfaces:** 无。这是一次**真机路径**验证:单测证明不了「包真的能从服务端拉下来、
真的能验过签、真的能在一台设备上算出档案」。

- [ ] **Step 1: 起本地后端并放包**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a/services/api
python3 -m uvicorn app:app --host 127.0.0.1 --port 9000
```

另开一个终端:

```bash
curl -s http://127.0.0.1:9000/v1/skills/index.json | head -c 400
curl -s http://127.0.0.1:9000/v1/skills/sle/2026.09.1.json | head -c 200
curl -sI http://127.0.0.1:9000/v1/skills/index.json | grep -i etag
```
Expected: 三条都有输出;第二条以 `{"sig":` 开头。

- [ ] **Step 2: 跑模拟器 debug 包**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter
flutter devices
flutter run -d <当前选中的模拟器 id> --dart-define=MEDME_API_BASE=http://127.0.0.1:9000
```

> **只跑当前选中的模拟器 debug 包**;不跑 release、不跑全 ABI
> (`apps/mobile_flutter/CLAUDE.md`)。预计首次编译超过 5 分钟 —— 先把这条命令原文报给
> 用户,得到许可再跑。

- [ ] **Step 3: 走一遍**

1. 用 `load_demo_data` 或导入 `packages/profile/testdata/corpus/` 里几份文本,让保险箱里有数据;
2. 概览页应当出现「这份档案像是狼疮相关,要不要开启?」的**提问式**卡(不是标签);
3. 点「开启」→ 卡变成档案入口,档案页按包给的顺序出 7 类 section;
4. 关掉后端(`Ctrl-C`)再杀掉 App 重进 → 档案**照常显示**(走缓存,且缓存读回时重新验签);
5. 手改缓存文件一个字节(`<app support>/skills/sle.json`)再重进 → 档案**消失**并提示包不可用
   (不是崩溃、不是显示半份);
6. 「给医生看」→ 生成分享 → 用查看器打开,交接单在;再打开一份**改动前**生成的老分享包,
   页面与以前一致。

- [ ] **Step 4: 记录**

`docs/log/2026-09-16-disease-profile-smoke.md`:六步各写一行结果(过/不过 + 现象),
附上模拟器型号与 iOS 版本。**精炼**,不写流水账。任何一步不过 → 不合并,回去修。

- [ ] **Step 5: Commit**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git add docs/log/2026-09-16-disease-profile-smoke.md
git commit -m "test(mobile): 病程档案模拟器 smoke 记录

覆盖:拉包、验签、断网走缓存、缓存被改则失败关闭、交接单与老分享包兼容。"
```

---

## 自审(writing-plans §Self-Review)

**1. Spec 覆盖**

| spec 章节 | 任务 |
|---|---|
| §1 数据流(零新 Event、`DocType::ProfileEvent`、schema 1→2) | 5, 8, 9 |
| §2 包格式、签名、`min_engine`、`terms` 覆盖层 | 1, 2, 3, 17, 18 |
| §2 分发清单的签名与防降级(补充决定,2026-09-16) | 27 |
| §3 族级 facts schema、`evidence` 逐字、prompt 文件、参数文件改名、`services/api` 收 schema 2 | 5, 6, 7 |
| §4 `DocType::ProfileEvent` 载荷、不进临床聚合、「从未开启 = 不算」 | 9, 10 |
| §5.1 识别建议(不自动贴标签) | 22 |
| §5.2 活动度 8 项、10 天窗口、x/18、证据链 | 11 |
| §5.3 DORIS / LLDAS 逐条三态、边界注差异 | 12 |
| §5.4 激素目标与提醒、HCQ mg/kg 与两套规则、眼科、两类提醒来源、dismiss | 13, 14, 18 |
| §5.5 狼疮肾炎里程碑、活检指征、带年份 | 16, 18 |
| §5.6 数据完备度驱动(`empty_hint` 折叠、待补优先) | 11, 14, 18, 21 |
| §6 7 种 section、顺序/标题/空态来自包、交接单(走 `build_own_share_blob_with_profile`) | 15, 18, 21, 23 |
| §7 多模态输入 → 数据 | 5, 15, 16(语料覆盖活检/输注/眼科) |
| §8 请求不带病种、`/v1/skills` 无鉴权、档案在手机算、政策、对外话术 | 4, 20, 21, 24, 27 |
| §9 代码落点、评测(golden、每规则边界、MedRepBench 回归) | 全部;8, 11, 16 |
| §10 已拍板的五条(签名 / `<5` / 显示 x/18 / 医生录 PGA 二期 / 名字「病程档案」) | 1, 12, 11, 12(`manual` 恒未知), 18, 22 |
| §11 已知边界写进界面与政策 | 13, 15, 18, 19, 21, 24 |
| §12 分期 | C1–C6 章节 |

**未覆盖/已知缺口(有意为之,已在对应任务里写明):**
- spec §7 表格最后一行「医生(授权查看者)录 `pga`/`symptom_score`」= 二期,本计划
  只把 `manual` 条目恒定为「未知」(Task 12),不实现录入。
- 症状分(`symptom_score`)的**勾选界面**不在本计划内:Task 11 只算化验可算部分,
  Task 12 的 `sledai_le`/`csledai_eq` 用的也是化验可算分。总分与分档(§5.2 末句、
  `rules.bands`)在包里备好了,但要等症状勾选界面才真正能合成 —— 这是 C5 之后的事,
  **不要在本计划里悄悄用化验分冒充总分**。

**2. 占位符扫描**

已逐条检查「TBD / TODO / 稍后实现 / 加上适当的错误处理 / 类似 Task N」等模式:
- 「待核」出现的地方全都是**临床事实层面**的 `null` 占位(Task 18/19 有明确的核查任务与
  落实步骤),不是计划本身的占位符;
- Task 13/14/15/16 的少数实现描述用了散文而非完整代码块(`status_section` 的组装、
  `eval_monitor` 的三分支、`series_section`/`timeline_section` 的遍历、
  `milestones_section` 的 T0 选取)。这些位置的**测试断言是完整的、逐字段的**,
  形状由测试完全钉死;执行者按断言实现即可,不存在「自己发挥」的空间。
- Task 21 的 `ProfileSectionView` 同理:7 个 kind 的渲染细节由 8 条 widget 测试钉住。

**3. 类型一致性**

跨任务复用的名字与签名已统一:
- `profile::Package` / `Manifest` / `Analyte` / `Drug` / `Rules` / `ActivityRules` / `Views`(Task 1)
  → Task 11/12/13/14/15/16/18 全部按这些字段名读。
- `profile::load_signed` / `cache_store` / `cache_load`(Task 2)→ Task 3 的 `repo_packages_verify`、
  Task 18 的 `shipped_package`、Task 20 的 FFI 都调这三个。Task 27 把 `verify_envelope` 的
  内层取字节那一半抽成 `verify_envelope_body`,并给 `cache_store` 加**单调版本闸**
  (新增 `PackageError::Downgrade`);`load_signed_index` / `Index` / `IndexEntry` /
  `version_tuple` 也在 Task 27 定义,Task 20 的 `vault_profile_verify_index` 调它。
- `rules::Ctx` / `Evidence` / `Hit` / `Verdict`(Task 10/11/12)→ 12/13/14/15/16 共用;
  Task 12 明确要求把 Task 11 的 `activity_section` 拆成 `activity_hits` +
  `activity_section_from`,两处共用同一份 `Vec<Hit>`(避免算两遍得两个分数)。
- `view::Section { kind, title, empty_hint, body }`(Task 10)→ Task 21 的 widget 与
  Task 23 的 `renderProfile` 都按这四个键读。
- `medme_share::share::build_own_share_blob_with_profile(&Vault, u32, DicomPngRenderer,
  Option<&serde_json::Value>)`(Task 23)→ `qr_share_blob(i64, Option<String>)` 调它;
  `build_share_blob_inner` 的新 `profile` 参数其余五个调用点一律传 `None`。
- `deid::Fact`(Task 5)→ Task 6 的校验、Task 7 的 prompt 键名、Task 10 的 `Ctx.facts`、
  Task 15 的时间轴全部对齐同一组字段名(`date_start`/`date_end`/`from`/`to`/`result`/`finding`…)。
- `core_model::NewExtraction.schema: i32`(Task 8)→ Task 20 的 `vault_cloud_commit_extraction` 透传。
- `terminology::set_overlay` / `entry_for`(Task 17)→ Task 20 在 `aggregate` 之前装覆盖层。
- `"换算表待核"` 这五个字在 Rust(Task 13)与 Flutter(Task 21)两处逐字一致。
- `basis ∈ {"guideline","label","literature","package_default"}`、
  `verdict ∈ {"yes","no","unknown"}` 两组字符串常量在 Rust(14/12)与 Flutter(21)
  与查看器(23)三处必须是同一组词 —— Task 23 显式要求「同一套中文标签」。
