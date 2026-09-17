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
pub const SIGNING_PUBLIC_KEY_HEX: &str =
    "70718ff1ff2cce86c6d06c8666a48882b8c65fdc0fc1894889a2a09fa32b7a2a";

#[derive(Debug)]
pub enum PackageError {
    /// 信封或包体不是我们认得的形状(缺字段、不是 JSON、签名不是 64 字节…)。
    Malformed(String),
    /// 签名验不过 —— 包被改过,或不是我们签的。**不加载,不降级,不「只用一部分」**。
    BadSignature,
    /// 包要求的引擎版本比本二进制新。老 App 装不上新包是正常的,如实告诉用户去升级。
    EngineTooOld { needs: u32, have: u32 },
    /// 待装的版本比已经装过的**低**。签名是合法的(确实是我们签的),但这是
    /// 降级 —— 中间人重放一个旧包就能把用户按在过时的规则上。不装。
    Downgrade { have: String, offered: String },
}

impl std::fmt::Display for PackageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PackageError::Malformed(m) => write!(f, "包格式不对:{m}"),
            PackageError::BadSignature => write!(f, "包签名验证不通过"),
            PackageError::EngineTooOld { needs, have } => {
                write!(f, "这个病种包需要 App 引擎 v{needs},当前是 v{have}")
            }
            PackageError::Downgrade { have, offered } => {
                write!(f, "拒绝降级:已有 {have},送来的是更旧的 {offered}")
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
    /// 治疗目标值,按药物类别分组(`targets.gc` 是激素的两条维持线,`targets.hcq`
    /// 是羟氯喹的 mg/kg 目标 + 说明书原文)。和 `states`/`monitoring` 一样是**裸
    /// JSON**:形状由包作者和读它的那条规则约定,引擎不在这里定死字段名 —— 定死
    /// 一次,以后加一个病就多一次发版。
    #[serde(default)]
    pub targets: serde_json::Value,
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

/// 验签,返回**内层原文字符串**。包和清单共用这一半 —— 两者是同一种信封,
/// 区别只在内层解析成什么(`Package` 还是 `Index`)。用生产公钥固定验(不接受调用方
/// 指定别的公钥 —— 那样公钥 pin 就成了摆设,谁传个别的公钥进来都能"验过")。
pub fn verify_envelope_body(envelope_json: &str) -> Result<String, PackageError> {
    verify_envelope_body_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

/// 同上,但公钥可注入 —— 只给测试用(生产路径固定走上面那个)。
/// `pub(crate)`:公钥 pin 不能从 crate 外部绕过,调用点都在本 crate 内。
pub(crate) fn verify_envelope_body_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<String, PackageError> {
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
    Ok(env.package)
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
    let body = verify_envelope_body_with_key(envelope_json, pubkey_hex)?;
    serde_json::from_str(&body).map_err(|e| PackageError::Malformed(format!("包体解析失败:{e}")))
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

/// 用生产公钥验签并解析清单。清单和包同一种信封,只是内层解析成 `Index`。
pub fn load_signed_index(envelope_json: &str) -> Result<Index, PackageError> {
    load_signed_index_with_key(envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

/// 同上,但公钥可注入 —— 只给测试用(生产路径固定走上面那个)。
///
/// 验完签只是保证「这份清单是我们发的」,不保证里面每一条的 `id`/`version` 形状
/// 本身没问题——下游(C2+ 的 fetcher)会拿这两个字段拼 URL/路径。签名只有我们能出,
/// 不是被攻击面,但校验一次是免费的,总比这道闸被忘在某个还没写的任务里强。
/// 任何一条形状不对,整份清单**都**不要(fail closed),不是挑好的挑走坏的扔掉——
/// 一份"部分能用"的清单会让不同客户端因为过滤逻辑不一致而看到不同的包集合。
pub(crate) fn load_signed_index_with_key(
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<Index, PackageError> {
    let body = verify_envelope_body_with_key(envelope_json, pubkey_hex)?;
    let idx: Index = serde_json::from_str(&body)
        .map_err(|e| PackageError::Malformed(format!("清单解析失败:{e}")))?;
    for entry in &idx.skills {
        if !valid_id(&entry.id) {
            return Err(PackageError::Malformed(format!(
                "清单条目 id 不合法:{:?}",
                entry.id
            )));
        }
        if version_tuple(&entry.version).is_none() {
            return Err(PackageError::Malformed(format!(
                "清单条目 version 形状不对:{:?}",
                entry.version
            )));
        }
    }
    Ok(idx)
}

/// `YYYY.MM.N` → 可比较的元组。**必须按数字比**:字典序会把 `2026.09.10` 排在
/// `2026.09.9` 前面,单调闸就成了反向的。形状不对返回 `None`(调用方按 `Malformed` 处理)。
pub fn version_tuple(v: &str) -> Option<(u32, u32, u32)> {
    // 每一段必须**只含数字**:Rust 的 `u32::from_str` 会悄悄接受前导 `+`
    // (同 `hex_decode_32` 那个坑),不先挡字符集,"2026.+9.1" 会被当成
    // "2026.09.1" 解出来。
    let is_digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let mut it = v.split('.');
    let (y, m, n) = (it.next()?, it.next()?, it.next()?);
    if it.next().is_some()
        || y.len() != 4
        || m.len() != 2
        || n.is_empty()
        || n.len() > 3
        || !is_digits(y)
        || !is_digits(m)
        || !is_digits(n)
    {
        return None;
    }
    Some((y.parse().ok()?, m.parse().ok()?, n.parse().ok()?))
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

/// id 的合法字符集:非空,只含小写字母/数字/下划线。id 会拼进缓存路径
/// (`cache_file`),写(`cache_store`)和读(`cache_load`)**都**要过这一闸——
/// 只挡写不挡读,`id="../x"` 就能让 `cache_load` 读到 `<dir>/skills/` 之外的文件
/// (哪怕那份文件本身验签通过,也不该是这个 id 该读到的东西)。
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// 把**信封原文**写进缓存,文件名取包自己声明的 `manifest.id`。写之前先验签:
/// 缓存里只放验得过的东西,免得下次开机拿一份坏包去试。单调版本闸同样在写盘前:
/// 装包只会往前走,见过的最高版本就是缓存里那份自己的 `manifest.version`,不另开
/// 状态文件。返回写进去的 id。
pub fn cache_store(dir: &std::path::Path, envelope_json: &str) -> Result<String, PackageError> {
    cache_store_with_key(dir, envelope_json, SIGNING_PUBLIC_KEY_HEX)
}

pub(crate) fn cache_store_with_key(
    dir: &std::path::Path,
    envelope_json: &str,
    pubkey_hex: &str,
) -> Result<String, PackageError> {
    let pkg = load_signed_with_key(envelope_json, pubkey_hex)?;
    // id 来自包体,包体来自网络,所以按路径分量校验一次。验签已经证明包是我们签的,
    // 这道闸是给「我们自己签了一个带斜杠/空的 id」兜底。
    if !valid_id(&pkg.manifest.id) {
        return Err(PackageError::Malformed(format!(
            "包 id 只允许小写字母/数字/下划线,实际 {:?}",
            pkg.manifest.id
        )));
    }
    let offered = version_tuple(&pkg.manifest.version).ok_or_else(|| {
        PackageError::Malformed(format!("版本号形状不对:{}", pkg.manifest.version))
    })?;
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
    let path = cache_file(dir, &pkg.manifest.id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| PackageError::Malformed(format!("建缓存目录失败:{e}")))?;
    }
    // 同目录临时文件 + rename:rename 在同一文件系统内是原子的,写到一半被打断
    // (掉电/进程被杀)不会留下半份 `<id>.json`——落盘的要么是整份新内容,要么还是旧的。
    let tmp_path = path.with_extension("json.tmp");
    std::fs::write(&tmp_path, envelope_json)
        .map_err(|e| PackageError::Malformed(format!("写缓存失败:{e}")))?;
    std::fs::rename(&tmp_path, &path)
        .map_err(|e| PackageError::Malformed(format!("落盘缓存失败:{e}")))?;
    Ok(pkg.manifest.id)
}

/// 从缓存读回。**每次都重新验签** —— 缓存文件在用户可写的目录里,是不可信输入。
/// id 也要过 `valid_id`:形状不对(含 `/`、空、大写……)直接 `None`,不拼路径去碰
/// 文件系统,免得读到 `<dir>/skills/` 之外的地方。
/// 任何失败(id 不合法、文件不在、验不过、引擎太老)一律 `None`:调用方的处置都一样
/// (没有包 = 不显示病程档案),不需要区分。
pub fn cache_load(dir: &std::path::Path, id: &str) -> Option<Package> {
    cache_load_with_key(dir, id, SIGNING_PUBLIC_KEY_HEX)
}

pub(crate) fn cache_load_with_key(
    dir: &std::path::Path,
    id: &str,
    pubkey_hex: &str,
) -> Option<Package> {
    if !valid_id(id) {
        return None;
    }
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

    #[test]
    fn cache_load_rejects_ids_that_are_not_a_single_path_component() {
        // 每个 id 按「不做校验时会拼出的路径」真放一份验得过签名的信封在那儿 ——
        // 这样断言 None 是因为 id 被 valid_id 挡了,不是碰巧那个位置没文件。
        // "../x" 这一条就是 review 探针复现的路径穿越:不校验时会逃出 <dir>/skills/。
        let dir = tempfile::tempdir().unwrap();
        let env = sign_with_test_key(MINIMAL);
        // `skills/` 先建好,不然 "../x" 那一条在 OS 层面连中间目录都解析不到,
        // 会"碰巧"返回 None——跟真实场景(缓存已有别的包,skills/ 早就存在)不符,
        // 也验证不到 id 校验本身。
        std::fs::create_dir_all(dir.path().join("skills")).unwrap();
        for (bad_id, planted_at) in [
            ("../x", dir.path().join("x.json")),
            ("a/b", dir.path().join("skills").join("a").join("b.json")),
            ("", dir.path().join("skills").join(".json")),
            ("T", dir.path().join("skills").join("T.json")),
        ] {
            if let Some(parent) = planted_at.parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::write(&planted_at, &env).unwrap();
            assert!(
                cache_load_with_key(dir.path(), bad_id, &test_pubkey_hex()).is_none(),
                "id {bad_id:?} 不该读到 {planted_at:?}"
            );
        }
    }

    #[test]
    fn cache_store_rejects_ids_that_are_not_a_single_path_component() {
        let dir = tempfile::tempdir().unwrap();
        for bad_id in ["../x", "a/b", "", "T"] {
            let body = MINIMAL.replace("\"id\":\"t\"", &format!("\"id\":\"{bad_id}\""));
            let env = sign_with_test_key(&body);
            assert!(
                cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).is_err(),
                "id {bad_id:?} 应被拒绝"
            );
        }
    }

    #[test]
    fn cache_store_leaves_only_the_final_file_no_tmp_litter() {
        let dir = tempfile::tempdir().unwrap();
        let env = sign_with_test_key(MINIMAL);
        cache_store_with_key(dir.path(), &env, &test_pubkey_hex()).unwrap();
        let names: Vec<_> = std::fs::read_dir(dir.path().join("skills"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["t.json".to_string()]);
    }

    const INDEX_BODY: &str =
        r#"{"skills":[{"id":"t","version":"2026.09.2","min_engine":1,"name":"测试病"}]}"#;

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
    fn an_index_entry_with_a_path_traversal_id_is_refused() {
        // 签名合法(确实是我们签的),但条目内容本身形状不对——服务端已经拿 id/version
        // 拼路径白名单挡过一轮,客户端这边不能假设「验过签 = 每个字段都能直接拼路径」。
        let body = INDEX_BODY.replace("\"id\":\"t\"", "\"id\":\"../../etc\"");
        let env = sign_with_test_key(&body);
        assert!(matches!(
            load_signed_index_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
    }

    #[test]
    fn an_index_entry_with_a_malformed_version_is_refused() {
        let body = INDEX_BODY.replace("2026.09.2", "2026.+9.1");
        let env = sign_with_test_key(&body);
        assert!(matches!(
            load_signed_index_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
    }

    #[test]
    fn one_bad_entry_rejects_the_whole_index_not_just_that_entry() {
        // fail closed:不是「挑出能用的几条」,一条不合法整份清单都不要——不然不同
        // 客户端会因为各自的过滤逻辑不一致,看到不同的包集合。
        let body = INDEX_BODY.replace(
            "\"skills\":[",
            "\"skills\":[{\"id\":\"ok\",\"version\":\"2026.09.1\",\"min_engine\":1,\"name\":\"好包\"},",
        );
        let body = body.replace("\"id\":\"t\"", "\"id\":\"../bad\"");
        let env = sign_with_test_key(&body);
        assert!(matches!(
            load_signed_index_with_key(&env, &test_pubkey_hex()),
            Err(PackageError::Malformed(_))
        ));
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
    fn version_tuple_rejects_non_digit_characters() {
        // `u32::from_str` 会悄悄接受前导 `+`(同 `hex_decode_32` 挡过的坑):不先挡
        // 字符集,"2026.+9.1" 就会被当成 "2026.09.1" 解出来,单调闸能被这条绕过。
        assert!(version_tuple("2026.+9.1").is_none());
        assert!(version_tuple("+026.09.1").is_none());
        assert!(version_tuple("2026.-9.1").is_none());
        assert!(version_tuple("2026.09.-1").is_none());
        assert!(version_tuple("2026. 9.1").is_none());
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
            cache_load_with_key(dir.path(), "t", &test_pubkey_hex())
                .unwrap()
                .manifest
                .version,
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
            cache_load_with_key(dir.path(), "t", &test_pubkey_hex())
                .unwrap()
                .manifest
                .version,
            "2026.10.1"
        );
    }
}
