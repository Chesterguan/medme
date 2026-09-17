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
        ActivityRules {
            window_days: 10,
            max: 0,
            items: Vec::new(),
        }
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

/// 仅测试用(把生成的测试公钥转成 `verify_envelope_with_key` 要的 hex 形式)。
/// 生产路径只解不编:`SIGNING_PUBLIC_KEY_HEX` 是常量源码,不需要反向编码。
#[cfg(test)]
fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_decode_32(s: &str) -> Option<[u8; 32]> {
    // `u8::from_str_radix` 悄悄接受前导 `+`(`"+9"` 和 `"09"` 解出同一个字节),
    // 逐字符先挡掉非 `0-9a-fA-F`,不然两个不同的 hex 字符串能被当成同一把公钥。
    if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks(2).enumerate() {
        out[i] = u8::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?;
    }
    Some(out)
}

/// 用生产公钥验签并解析。**不检查 `min_engine`** —— 版本闸在 Task 2 的
/// `load_signed`(加载路径)里做,这里只管「是不是我们签的、体裁对不对」。
pub fn verify_envelope(envelope_json: &str) -> Result<Package, PackageError> {
    verify_envelope_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

/// 同上,但公钥可注入 —— 只给测试用(生产路径固定走上面那个)。
/// `pub(crate)`:公钥 pin 不能从 crate 外部绕过,Task 2/27 的调用点都在本 crate 内。
pub(crate) fn verify_envelope_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<Package, PackageError> {
    use base64::Engine as _;
    use ed25519_dalek::{Signature, VerifyingKey};

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
    // `verify_strict` 而不是 `verify`:拒掉小阶公钥/可延展签名,别在验签这道闸上省。
    vk.verify_strict(env.package.as_bytes(), &Signature::from_bytes(&sig_arr))
        .map_err(|_| PackageError::BadSignature)?;

    serde_json::from_str(&env.package)
        .map_err(|e| PackageError::Malformed(format!("包体解析失败:{e}")))
}

/// 验签 + 引擎版本闸。**生产路径唯一的包入口**。
pub fn load_signed(envelope_json: &str) -> Result<Package, PackageError> {
    load_signed_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

pub(crate) fn load_signed_with_key(
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
///
/// TODO(Task 27): 这里还没做单调版本号检查(同 id 的旧包不应覆盖新包);
/// 届时在验签通过之后、写盘之前加。
pub fn cache_store(dir: &std::path::Path, envelope_json: &str) -> Result<String, PackageError> {
    cache_store_with_key(dir, envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

pub(crate) fn cache_store_with_key(
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

pub(crate) fn cache_load_with_key(
    dir: &std::path::Path,
    id: &str,
    pubkey_hex: &str,
) -> Option<Package> {
    let raw = std::fs::read_to_string(cache_file(dir, id)).ok()?;
    load_signed_with_key(&raw, pubkey_hex).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 固定测试密钥(仅测试用,不是生产签名密钥)。seed 全 1。
    const TEST_SEED: [u8; 32] = [1u8; 32];

    fn sign_with_test_key(body: &str) -> String {
        use base64::Engine as _;
        use ed25519_dalek::{Signer, SigningKey};
        let sk = SigningKey::from_bytes(&TEST_SEED);
        let sig =
            base64::engine::general_purpose::STANDARD.encode(sk.sign(body.as_bytes()).to_bytes());
        serde_json::json!({ "sig": sig, "package": body }).to_string()
    }

    fn test_pubkey_hex() -> String {
        use ed25519_dalek::SigningKey;
        hex_encode(
            SigningKey::from_bytes(&TEST_SEED)
                .verifying_key()
                .as_bytes(),
        )
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
            ed25519_dalek::SigningKey::from_bytes(&[2u8; 32])
                .verifying_key()
                .as_bytes(),
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

    #[test]
    fn signature_wrong_length_is_malformed() {
        use base64::Engine as _;
        let sig_63 = base64::engine::general_purpose::STANDARD.encode([0u8; 63]);
        let env = serde_json::json!({ "sig": sig_63, "package": MINIMAL }).to_string();
        assert!(matches!(
            verify_envelope_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));

        let sig_65 = base64::engine::general_purpose::STANDARD.encode([0u8; 65]);
        let env = serde_json::json!({ "sig": sig_65, "package": MINIMAL }).to_string();
        assert!(matches!(
            verify_envelope_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
    }

    #[test]
    fn invalid_base64_signature_is_malformed() {
        let env =
            serde_json::json!({ "sig": "not-valid-base64!!", "package": MINIMAL }).to_string();
        assert!(matches!(
            verify_envelope_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
    }

    #[test]
    fn bad_and_non_canonical_pubkey_hex_is_malformed() {
        let env = sign_with_test_key(MINIMAL);

        // 普通非法字符,压根不是 hex。
        let non_hex = "zz".repeat(32);
        assert!(matches!(
            verify_envelope_with_key(&env, &non_hex),
            Err(PackageError::Malformed(_))
        ));

        // 非规范:`u8::from_str_radix` 把前导 `+` 当符号位默默吃掉,"+0" 和 "00"
        // 解出来是同一个字节 —— 两个不同的十六进制字符串却被当成同一把公钥接受。
        // 必须在解码这一步就拒,不能让非规范写法蒙混过关。
        let non_canonical = format!("+0{}", "0".repeat(62));
        assert!(matches!(
            verify_envelope_with_key(&env, &non_canonical),
            Err(PackageError::Malformed(_))
        ));
    }

    #[test]
    fn valid_signature_over_non_json_body_is_malformed() {
        let env = sign_with_test_key("this is not json");
        assert!(matches!(
            verify_envelope_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
    }

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
        let body = MINIMAL.replace(
            "\"min_engine\":1",
            &format!("\"min_engine\":{ENGINE_VERSION}"),
        );
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
        let poisoned = std::fs::read_to_string(&path)
            .unwrap()
            .replace("测试病", "别的病");
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
}
