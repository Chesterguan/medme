# 子项目 B · 账号 + 密钥 + 加密同步 + 授权 + LLM 代理 · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给保险箱一个账号身份:换机可恢复、可授权家属/医生/机构、云抽取可计费,而服务器永远只见密文;不登录时现有纯本地行为一字不变。

**Architecture:** 三层。① `packages/sync`(Rust,纯密码学:账号密钥对、口令/恢复码 KEK、档案密钥封装、对象/事件 AES-GCM、object_id、日期偏移秘密);② `services/api`(Python FastAPI on 阿里云 FC 自定义运行时 + RDS PostgreSQL + OSS 私有桶 `medme-vault`,只存密文与账号业务数据);③ Flutter 侧 `ApiClient` + `SyncEngine` + 账号/授权屏,复用现有 `Net`、`ProfileManager`、`vault_boot` 的 FIFO 开箱队列与 `ClaimLink` 深链路径。主人/家属/医生/机构统一为 `grants` 表的一行。

**Tech Stack:** Rust(aes-gcm 0.11 / x25519-dalek 2 / argon2 0.5 / hkdf 0.13 / hmac 0.13 / sha2 0.11 / getrandom 0.4,均与仓库现有版本线一致)· flutter_rust_bridge 2.12.0 · Dart(`flutter_secure_storage`、`sign_in_with_apple` 两个新依赖)· Python 3.11(fastapi、uvicorn、psycopg[binary]、PyJWT、cryptography)· 阿里云 FC / RDS PG Serverless / OSS / PNVS 短信认证。

**Spec:** `docs/superpowers/specs/2026-09-11-account-keys-sync-design.md`(总纲 `docs/superpowers/specs/2026-09-11-advanced-edition-overview-design.md`)

## Global Constraints

- **不登录 = 现状。** 未登录时 `openCurrentProfileVault` 的路径、`profiles.json` 格式、本地 vault 布局一律不变;所有新行为都在「该档案有 `cloudId`」这个条件之后。
- **服务器只见密文。** 明文、档案密钥、账号私钥、口令、恢复码永不出手机;服务端代码里不得出现任何解密调用。
- **不做:密钥代管、微信/支付宝真登录(路由留 501)、机构 UI、撤销时密钥轮换、安卓钥匙串同步、桌面端接入。**
- **医生授权 = viewer,15 天**(`GRANT_DOCTOR_DAYS = 15`);家属 = editor,永久。
- **移动端构建纪律**(`apps/mobile_flutter/CLAUDE.md`):只用 `flutter analyze`、`flutter test`、Rust 单测验证;不跑 release / 全 ABI;>5 分钟的命令先报告。
- **FRB 序号纪律**(`apps/mobile_flutter/rust/src/api/mod.rs`):新模块 `vault_sync`,函数一律 `sync_` 前缀,`recognize_image_pp` 的 wire 序号不得变(`git diff main -- apps/mobile_flutter/rust/src/frb_generated.rs | grep recognize_image_pp` 必须为空)。
- **Rust 风格**:`thiserror` 错误类型,生产代码无 `unwrap()`;`expect()` 只用于文档化的不变量。
- **Python 风格**:与 `services/claim-signer/` 一致,密钥只从环境变量读,测试是可直接 `python3 test_x.py` 跑的脚本或 `pytest`(两者都要能跑)。
- **埋点**:新增 `AnalyticsEvent` 必须同步 `docs/analytics-catalog.md` 第四节(标题条数 + 属性列),否则 `test/analytics_catalog_test.dart` 红。
- **提交**:每个任务结束一次 commit,只 `git add` 本任务的文件;不 push。commit message 末尾附会话给定的 Co-Authored-By / Claude-Session 两行。

---

## 文件结构

| 路径 | 职责 |
|---|---|
| `packages/sync/Cargo.toml`, `src/lib.rs`, `src/keys.rs`, `src/blob.rs`, `src/error.rs` | 纯密码学;不碰文件系统、不碰网络 |
| `packages/core-model/src/lib.rs`, `src/log.rs`, `src/sync_io.rs` | keyed resilient open、日志条目导出/导入(去重)、缺失对象清单 |
| `packages/pipeline/src/photo.rs` | 导入时压图(长边 2000px,JPEG q85) |
| `services/api/app.py` | FastAPI 路由(一个文件,按路径分节) |
| `services/api/db.py` | 建表 SQL + 全部查询函数(接收 `psycopg.Connection`) |
| `services/api/auth.py` | OTP、JWT、Apple 校验、`LoginProvider` + WeChat 501 |
| `services/api/oss.py` | 预签名(从 claim-signer 复制的 3 个函数)|
| `services/api/extract.py` | DeepSeek 转发 + usage 记账 |
| `services/api/test_api.py` | 全部后端测试(对本机 PG 跑) |
| `services/api/requirements.txt`, `README.md` | 部署 |
| `apps/mobile_flutter/rust/src/api/vault_sync.rs` | FRB 暴露 `sync_*` |
| `apps/mobile_flutter/lib/account.dart` | 会话 + 密钥的本机存储(secure storage) |
| `apps/mobile_flutter/lib/api_client.dart` | 所有 HTTP 调用(注入式,可 fake) |
| `apps/mobile_flutter/lib/sync_engine.dart` | 事件推拉、对象按需取 |
| `apps/mobile_flutter/lib/grant_link.dart` | `g1.` 深链解析(与 `ClaimLink` 并列) |
| `apps/mobile_flutter/lib/screens/account_screen.dart` | 登录/注册/恢复码/设备/授权 |
| `apps/mobile_flutter/test/account_screen_test.dart`, `test/sync_engine_test.dart`, `test/api_client_test.dart` | 三态 + 引擎测试 |

---

### Task 1: `packages/sync` 密码学原语

**Files:**
- Create: `packages/sync/Cargo.toml`, `packages/sync/src/lib.rs`, `packages/sync/src/error.rs`, `packages/sync/src/keys.rs`, `packages/sync/src/blob.rs`
- Modify: `Cargo.toml`(workspace members 加 `"packages/sync"`)

**Interfaces:**
- Produces:
  - `pub struct AccountKeys { pub public: [u8;32], pub secret: [u8;32] }`;`pub fn account_keys_new() -> AccountKeys`
  - `pub struct KdfParams { pub m_kib: u32, pub t: u32, pub p: u32 }`;`pub const KDF_DEFAULT: KdfParams = KdfParams { m_kib: 65536, t: 3, p: 1 }`
  - `pub fn kek_from_password(pw: &str, salt: &[u8; 16], params: &KdfParams) -> Result<[u8;32], SyncError>`
  - `pub fn recovery_code_new() -> String`(`XXXX-XXXX-XXXX-XXXX-XXXX`)、`pub fn kek_from_recovery(code: &str) -> Result<[u8;32], SyncError>`
  - `pub fn wrap(kek: &[u8;32], plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>, SyncError>`、`pub fn unwrap(kek: &[u8;32], blob: &[u8], aad: &[u8]) -> Result<Vec<u8>, SyncError>`
  - `pub fn seal_to(public: &[u8;32], plaintext: &[u8]) -> Result<Vec<u8>, SyncError>`、`pub fn open_sealed(secret: &[u8;32], blob: &[u8]) -> Result<Vec<u8>, SyncError>`
  - `pub fn profile_key_new() -> [u8;32]`
  - `pub fn object_id(profile_key: &[u8;32], plaintext_sha256_hex: &str) -> String`
  - `pub fn encrypt_blob(profile_key: &[u8;32], id: &str, plaintext: &[u8]) -> Result<Vec<u8>, SyncError>`、`pub fn decrypt_blob(profile_key: &[u8;32], id: &str, blob: &[u8]) -> Result<Vec<u8>, SyncError>`
  - `pub fn date_shift_days(profile_key: &[u8;32]) -> i32`(−90..=90)
  - `pub enum SyncError { Crypto, Kdf(String), Format(String) }`

- [ ] **Step 1: 写 Cargo.toml 与失败测试**

`packages/sync/Cargo.toml`:
```toml
[package]
name = "sync"
version = "0.1.0"
edition = "2021"
description = "账号密钥对、口令/恢复码 KEK、档案密钥封装、对象/事件加密。纯密码学,不碰 IO。"

[dependencies]
aes-gcm = "0.11"
x25519-dalek = { version = "2", features = ["static_secrets"] }
argon2 = "0.5"
hkdf = "0.13"
sha2 = { workspace = true }
hmac = { workspace = true }
getrandom = "0.4"
thiserror = { workspace = true }
```

根 `Cargo.toml` members 加 `"packages/sync"`。

`packages/sync/src/lib.rs`:
```rust
//! 纯密码学层(子项目 B §2)。所有函数无 IO、可在任何平台单测。
pub mod blob;
pub mod error;
pub mod keys;

pub use blob::{date_shift_days, decrypt_blob, encrypt_blob, object_id, profile_key_new};
pub use error::SyncError;
pub use keys::{
    account_keys_new, kek_from_password, kek_from_recovery, open_sealed, recovery_code_new,
    seal_to, unwrap, wrap, AccountKeys, KdfParams, KDF_DEFAULT,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_kek_round_trips_private_key() {
        let keys = account_keys_new();
        let salt = [7u8; 16];
        let kek = kek_from_password("正确的口令", &salt, &KdfParams { m_kib: 8192, t: 1, p: 1 }).unwrap();
        let blob = wrap(&kek, &keys.secret, b"account-priv-v1").unwrap();
        assert_eq!(unwrap(&kek, &blob, b"account-priv-v1").unwrap(), keys.secret);
        let wrong = kek_from_password("错的", &salt, &KdfParams { m_kib: 8192, t: 1, p: 1 }).unwrap();
        assert!(unwrap(&wrong, &blob, b"account-priv-v1").is_err());
        assert!(unwrap(&kek, &blob, b"other-aad").is_err());
    }

    #[test]
    fn recovery_code_is_20_groups_of_4_and_derives_stable_kek() {
        let code = recovery_code_new();
        assert_eq!(code.len(), 24);
        assert_eq!(code.matches('-').count(), 4);
        let a = kek_from_recovery(&code).unwrap();
        let b = kek_from_recovery(&code.to_lowercase().replace('-', " ")).unwrap();
        assert_eq!(a, b, "大小写与分隔符不影响派生");
        assert!(kek_from_recovery("ABCD").is_err());
    }

    #[test]
    fn sealed_box_only_opens_with_matching_secret() {
        let alice = account_keys_new();
        let bob = account_keys_new();
        let pk = profile_key_new();
        let sealed = seal_to(&alice.public, &pk).unwrap();
        assert_eq!(open_sealed(&alice.secret, &sealed).unwrap(), pk);
        assert!(open_sealed(&bob.secret, &sealed).is_err());
    }

    #[test]
    fn blob_encrypt_is_bound_to_id_and_object_id_hides_plaintext_hash() {
        let pk = profile_key_new();
        let id = object_id(&pk, "ab".repeat(32).as_str());
        assert_eq!(id.len(), 64);
        assert_ne!(id, "ab".repeat(32));
        let ct = encrypt_blob(&pk, &id, b"hello").unwrap();
        assert_eq!(decrypt_blob(&pk, &id, &ct).unwrap(), b"hello");
        assert!(decrypt_blob(&pk, "other-id", &ct).is_err());
    }

    #[test]
    fn date_shift_is_deterministic_and_within_90_days() {
        let pk = profile_key_new();
        let d = date_shift_days(&pk);
        assert_eq!(d, date_shift_days(&pk));
        assert!((-90..=90).contains(&d));
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p sync`
Expected: 编译失败(模块不存在)。

- [ ] **Step 3: 实现**

`packages/sync/src/error.rs`:
```rust
#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    /// 解密/认证失败。刻意不带细节:区分「密钥错」与「密文被改」会泄漏预言。
    #[error("crypto failure")]
    Crypto,
    #[error("kdf: {0}")]
    Kdf(String),
    #[error("format: {0}")]
    Format(String),
}
```

`packages/sync/src/keys.rs`:
```rust
use crate::SyncError;
use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

pub struct AccountKeys {
    pub public: [u8; 32],
    pub secret: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KdfParams {
    pub m_kib: u32,
    pub t: u32,
    pub p: u32,
}

/// 起始参数(Task 14 按 Mate 9 实测后可能下调)。参数随包好的私钥一起存服务端
/// (`accounts.kdf_params`),所以改默认值不影响老账号。
pub const KDF_DEFAULT: KdfParams = KdfParams { m_kib: 65536, t: 3, p: 1 };

fn random32() -> [u8; 32] {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).expect("OS entropy source is always available on supported targets");
    b
}

pub fn account_keys_new() -> AccountKeys {
    let secret = StaticSecret::from(random32());
    let public = PublicKey::from(&secret);
    AccountKeys { public: public.to_bytes(), secret: secret.to_bytes() }
}

pub fn kek_from_password(pw: &str, salt: &[u8; 16], p: &KdfParams) -> Result<[u8; 32], SyncError> {
    let params = Params::new(p.m_kib, p.t, p.p, Some(32)).map_err(|e| SyncError::Kdf(e.to_string()))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = [0u8; 32];
    argon
        .hash_password_into(pw.as_bytes(), salt, &mut out)
        .map_err(|e| SyncError::Kdf(e.to_string()))?;
    Ok(out)
}

/// 20 字符 base32(去掉易混的 0/O/1/I/L/U),100 bit 熵,4 字符一组。
const ALPHABET: &[u8; 32] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789ZZ"; // 末两位不会被 index 到(见 recovery_code_new)

pub fn recovery_code_new() -> String {
    let mut raw = [0u8; 20];
    getrandom::fill(&mut raw).expect("OS entropy source is always available on supported targets");
    let mut s = String::with_capacity(24);
    for (i, b) in raw.iter().enumerate() {
        if i > 0 && i % 4 == 0 {
            s.push('-');
        }
        s.push(ALPHABET[(b % 30) as usize] as char);
    }
    s
}

fn normalize_recovery(code: &str) -> Result<String, SyncError> {
    let s: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    if s.len() != 20 {
        return Err(SyncError::Format("恢复码应为 20 个字符".into()));
    }
    Ok(s)
}

/// 恢复码本身已是 100 bit 随机,用 HKDF 拉伸即可,不需要 Argon2 的抗暴力代价。
pub fn kek_from_recovery(code: &str) -> Result<[u8; 32], SyncError> {
    let s = normalize_recovery(code)?;
    let hk = Hkdf::<Sha256>::new(Some(b"medme-recovery-v1"), s.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(b"kek", &mut out).map_err(|_| SyncError::Crypto)?;
    Ok(out)
}

fn gcm(key: &[u8; 32]) -> Aes256Gcm {
    Aes256Gcm::new_from_slice(key).expect("32-byte key is always a valid AES-256 key")
}

/// `nonce(12) || ciphertext+tag`。
pub fn wrap(kek: &[u8; 32], plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>, SyncError> {
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).expect("OS entropy source is always available on supported targets");
    let ct = gcm(kek)
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext, aad })
        .map_err(|_| SyncError::Crypto)?;
    let mut out = nonce.to_vec();
    out.extend_from_slice(&ct);
    Ok(out)
}

pub fn unwrap(kek: &[u8; 32], blob: &[u8], aad: &[u8]) -> Result<Vec<u8>, SyncError> {
    if blob.len() < 12 + 16 {
        return Err(SyncError::Format("blob too short".into()));
    }
    let (nonce, ct) = blob.split_at(12);
    gcm(kek)
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad })
        .map_err(|_| SyncError::Crypto)
}

/// Sealed box:临时 X25519 → HKDF → AES-GCM。布局 `eph_pub(32) || nonce(12) || ct`。
pub fn seal_to(public: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, SyncError> {
    let eph = StaticSecret::from(random32());
    let eph_pub = PublicKey::from(&eph);
    let shared = eph.diffie_hellman(&PublicKey::from(*public));
    let key = derive_box_key(shared.as_bytes(), eph_pub.as_bytes(), public)?;
    let mut out = eph_pub.to_bytes().to_vec();
    out.extend(wrap(&key, plaintext, b"medme-sealed-v1")?);
    Ok(out)
}

pub fn open_sealed(secret: &[u8; 32], blob: &[u8]) -> Result<Vec<u8>, SyncError> {
    if blob.len() < 32 + 12 + 16 {
        return Err(SyncError::Format("sealed blob too short".into()));
    }
    let mut eph_pub = [0u8; 32];
    eph_pub.copy_from_slice(&blob[..32]);
    let me = StaticSecret::from(*secret);
    let my_pub = PublicKey::from(&me);
    let shared = me.diffie_hellman(&PublicKey::from(eph_pub));
    let key = derive_box_key(shared.as_bytes(), &eph_pub, my_pub.as_bytes())?;
    unwrap(&key, &blob[32..], b"medme-sealed-v1")
}

fn derive_box_key(shared: &[u8], eph: &[u8], recipient: &[u8]) -> Result<[u8; 32], SyncError> {
    let mut salt = eph.to_vec();
    salt.extend_from_slice(recipient);
    let hk = Hkdf::<Sha256>::new(Some(&salt), shared);
    let mut out = [0u8; 32];
    hk.expand(b"medme-sealed-v1", &mut out).map_err(|_| SyncError::Crypto)?;
    Ok(out)
}
```

`packages/sync/src/blob.rs`:
```rust
use crate::keys::{unwrap, wrap};
use crate::SyncError;
use hkdf::Hkdf;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

pub fn profile_key_new() -> [u8; 32] {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).expect("OS entropy source is always available on supported targets");
    b
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// 服务端看到的对象名。明文哈希经档案密钥 HMAC:同一份文件在两个档案里名字不同,
/// 服务端无法跨用户比对内容。
pub fn object_id(profile_key: &[u8; 32], plaintext_sha256_hex: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(profile_key)
        .expect("HMAC-SHA256 accepts a key of any length");
    mac.update(b"object:");
    mac.update(plaintext_sha256_hex.as_bytes());
    hex(&mac.finalize().into_bytes())
}

pub fn encrypt_blob(profile_key: &[u8; 32], id: &str, plaintext: &[u8]) -> Result<Vec<u8>, SyncError> {
    wrap(profile_key, plaintext, id.as_bytes())
}

pub fn decrypt_blob(profile_key: &[u8; 32], id: &str, blob: &[u8]) -> Result<Vec<u8>, SyncError> {
    unwrap(profile_key, blob, id.as_bytes())
}

/// 子项目 A 的日期偏移秘密:−90..=90,由档案密钥确定,随档案同步、无需存储。
pub fn date_shift_days(profile_key: &[u8; 32]) -> i32 {
    let hk = Hkdf::<Sha256>::new(None, profile_key);
    let mut out = [0u8; 2];
    hk.expand(b"date-shift", &mut out)
        .expect("2-byte HKDF output is always within the SHA-256 limit");
    (u16::from_be_bytes(out) % 181) as i32 - 90
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test -p sync`
Expected: 5 passed。

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml packages/sync
git commit -m "feat(sync): 账号密钥对/口令与恢复码 KEK/档案密钥封装/对象加密原语"
```

---

### Task 2: core-model 同步接口(keyed resilient open、日志导出/导入、缺失对象)

**Files:**
- Create: `packages/core-model/src/sync_io.rs`
- Modify: `packages/core-model/src/lib.rs`(`pub mod sync_io; pub use event::LogEntry;` + `open_split_resilient_with_key`)、`packages/core-model/src/log.rs`(`pub fn tail_seq_of_device`)

**Interfaces:**
- Consumes: `Vault::open_split_resilient`、`EventLog::append/read_all`、`LogEntry`、`cas::object_relpath`
- Produces:
  - `Vault::open_split_resilient_with_key(truth_root, db_path, device_id, key: &[u8]) -> Result<Vault, MedmeError>`
  - `Vault::log_entries(&self) -> Result<Vec<LogEntry>, MedmeError>`
  - `Vault::append_peer_entries(&self, entries: &[LogEntry]) -> Result<usize, MedmeError>`(跳过已有的 `(device_id, seq)`,返回实际追加数,最后 `materialize`)
  - `Vault::missing_object_hashes(&self) -> Result<Vec<String>, MedmeError>`(事件引用而 `objects/` 里没有的哈希)
  - `Vault::device_seq_map(&self) -> Result<HashMap<String, i64>, MedmeError>`(每个 device 当前最大 seq,即推送水位)

- [ ] **Step 1: 写失败测试**

在 `packages/core-model/src/sync_io.rs` 底部:
```rust
#[cfg(test)]
mod tests {
    use crate::Vault;
    use tempfile::tempdir;

    fn keyed(dir: &std::path::Path, dev: &str) -> Vault {
        Vault::open_split_resilient_with_key(dir, &dir.join(format!("{dev}.db")), dev, &[9u8; 32]).unwrap()
    }

    #[test]
    fn peer_entries_apply_once_and_materialize() {
        let a = tempdir().unwrap();
        let b = tempdir().unwrap();
        let va = keyed(a.path(), "dev-a");
        va.import("r.txt", "text/plain", b"血红蛋白 130 g/L").unwrap();
        let entries = va.log_entries().unwrap();
        assert!(!entries.is_empty());

        let vb = keyed(b.path(), "dev-b");
        // 对象还没同步:先只推事件,materialize 必须容忍缺对象
        assert_eq!(vb.append_peer_entries(&entries).unwrap(), entries.len());
        assert_eq!(vb.append_peer_entries(&entries).unwrap(), 0, "重复推送不重复追加");
        let missing = vb.missing_object_hashes().unwrap();
        assert_eq!(missing.len(), 1);
        // 把对象搬过去后再 materialize 一次,文档出现
        let bytes = va.read_object(&missing[0]).unwrap();
        vb.store_object(&bytes).unwrap();
        vb.materialize().unwrap();
        assert!(vb.missing_object_hashes().unwrap().is_empty());
        assert_eq!(vb.device_seq_map().unwrap().get("dev-a").copied().unwrap_or(0), entries.len() as i64);
    }

    #[test]
    fn wrong_key_peer_entries_are_quarantined() {
        let a = tempdir().unwrap();
        let b = tempdir().unwrap();
        let va = keyed(a.path(), "dev-a");
        va.import("r.txt", "text/plain", b"x").unwrap();
        let entries = va.log_entries().unwrap();
        let vb = Vault::open_split_resilient_with_key(b.path(), &b.path().join("b.db"), "dev-b", &[1u8; 32]).unwrap();
        vb.append_peer_entries(&entries).unwrap();
        // MAC 用的是 a 的 key,b 用另一把 key 验证不过 → read_all 隔离 → 看不到
        assert!(vb.log_entries().unwrap().iter().all(|e| e.device_id != "dev-a"));
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p core-model sync_io`
Expected: 编译失败(方法不存在)。

- [ ] **Step 3: 实现**

`packages/core-model/src/lib.rs` 加(紧接 `open_split_resilient` 之后):
```rust
    /// [`Vault::open_split_resilient`] + MAC key:云同步档案的开法。所有设备用同一把
    /// 档案密钥当 MAC key,于是拉回来的 peer 事件能通过 `verify_segment`。
    pub fn open_split_resilient_with_key(
        truth_root: &Path,
        db_path: &Path,
        device_id: &str,
        key: &[u8],
    ) -> Result<Vault, MedmeError> {
        match Self::open_split_with_key(truth_root, db_path, device_id, key) {
            Ok(v) => Ok(v),
            Err(first) => {
                let truth_present =
                    truth_root.join("log").is_dir() || truth_root.join("objects").is_dir();
                if !truth_present {
                    return Err(first);
                }
                for sidecar in db_sidecar_paths(db_path) {
                    let _ = std::fs::remove_file(&sidecar);
                }
                Self::open_split_with_key(truth_root, db_path, device_id, key).map_err(|second| {
                    MedmeError::Other(format!(
                        "vault open failed and rebuilding the db from the log also failed: {second}"
                    ))
                })
            }
        }
    }
```
并加 `pub mod sync_io;`、`pub use event::LogEntry;`。

`packages/core-model/src/log.rs` 加:
```rust
    /// 某设备段当前最大 seq(无段 = 0)。推送水位用。
    pub fn tail_seq_of_device(&self, device_id: &str) -> Result<i64, MedmeError> {
        let path = self.device_segment(device_id);
        if !path.exists() {
            return Ok(0);
        }
        Ok(read_segment_entries(&path)?.iter().map(|e| e.seq).max().unwrap_or(0))
    }
```

`packages/core-model/src/sync_io.rs`:
```rust
//! 云同步的日志/对象接口(子项目 B §3)。只做本地读写,不联网。
use crate::event::{Event, LogEntry};
use crate::{cas, MedmeError, Vault};
use std::collections::HashMap;

impl Vault {
    pub fn log_entries(&self) -> Result<Vec<LogEntry>, MedmeError> {
        self.log.read_all()
    }

    /// 每个 device 段的当前最大 seq。推送时把 `seq > 服务端水位` 的条目发出去;
    /// 拉取时把 `seq > 本机水位` 的条目要回来。
    pub fn device_seq_map(&self) -> Result<HashMap<String, i64>, MedmeError> {
        let mut m = HashMap::new();
        for e in self.log.read_all()? {
            let cur = m.entry(e.device_id.clone()).or_insert(0);
            if e.seq > *cur {
                *cur = e.seq;
            }
        }
        Ok(m)
    }

    /// 追加别的设备的条目(按 device 段落盘,`append` 会重新封链与 MAC)。
    /// 已有的 `(device_id, seq)` 跳过。**必须按 seq 升序传入**,否则链会断。
    pub fn append_peer_entries(&self, entries: &[LogEntry]) -> Result<usize, MedmeError> {
        let mut sorted: Vec<&LogEntry> = entries.iter().collect();
        sorted.sort_by(|a, b| (a.device_id.as_str(), a.seq).cmp(&(b.device_id.as_str(), b.seq)));
        let mut tails: HashMap<String, i64> = HashMap::new();
        let mut n = 0;
        for e in sorted {
            let tail = match tails.get(&e.device_id) {
                Some(t) => *t,
                None => {
                    let t = self.log.tail_seq_of_device(&e.device_id)?;
                    tails.insert(e.device_id.clone(), t);
                    t
                }
            };
            if e.seq <= tail {
                continue;
            }
            self.log.append(e)?;
            tails.insert(e.device_id.clone(), e.seq);
            n += 1;
        }
        if n > 0 {
            self.materialize()?;
        }
        Ok(n)
    }

    /// 事件引用了、但 `objects/` 里还没有的对象哈希(拉对象的清单)。
    pub fn missing_object_hashes(&self) -> Result<Vec<String>, MedmeError> {
        let mut out = Vec::new();
        for e in self.log.read_all()? {
            let h = match &e.event {
                Event::FileImported { content_hash, .. } => content_hash,
                Event::OcrAdded { text_hash, .. } => text_hash,
                _ => continue,
            };
            if cas::is_object_hash(h) && !self.root().join(cas::object_relpath(h)).exists() && !out.contains(h) {
                out.push(h.clone());
            }
        }
        Ok(out)
    }
}
```

- [ ] **Step 4: 跑测试**

Run: `cargo test -p core-model`
Expected: 全绿(含既有 `materialize` 测试)。

- [ ] **Step 5: Commit**

```bash
git add packages/core-model
git commit -m "feat(core-model): 云同步接口——keyed resilient open、peer 条目追加去重、缺失对象清单"
```

---

### Task 3: 导入时压图(长边 2000px,JPEG q85)

**Files:**
- Create: `packages/pipeline/src/photo.rs`
- Modify: `packages/pipeline/src/lib.rs`(`pub mod photo; pub use photo::compress_photo;`)、`apps/mobile_flutter/rust/src/api/vault.rs`(`ingest_image_with_text` 与 `ingest_bytes` 在 `v.import` 之前调用)

**Interfaces:**
- Produces: `pub fn compress_photo(bytes: &[u8]) -> Vec<u8>`(不是图片/解不开/多页/已经够小 → 原样返回;否则返回 JPEG)

- [ ] **Step 1: 写失败测试**(`packages/pipeline/src/photo.rs` 底部)
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};

    fn big_jpeg() -> Vec<u8> {
        let img = ImageBuffer::from_fn(4000, 3000, |x, y| Rgb([(x % 256) as u8, (y % 256) as u8, 7]));
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut out, image::ImageFormat::Jpeg).unwrap();
        out.into_inner()
    }

    #[test]
    fn large_photo_is_downscaled_to_2000_long_edge() {
        let out = compress_photo(&big_jpeg());
        let img = image::load_from_memory(&out).unwrap();
        assert_eq!(img.width().max(img.height()), 2000);
        assert_eq!(image::guess_format(&out).unwrap(), image::ImageFormat::Jpeg);
    }

    #[test]
    fn small_or_non_image_passes_through() {
        assert_eq!(compress_photo(b"not an image"), b"not an image");
        let img = ImageBuffer::from_fn(800, 600, |_, _| Rgb([1u8, 2, 3]));
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
        let small = out.into_inner();
        assert_eq!(compress_photo(&small), small);
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test -p pipeline photo`
Expected: 编译失败。

- [ ] **Step 3: 实现**
```rust
//! 导入时压图(总纲横切 4):长边 2000px、JPEG q85。手机直拍 2~5 MB → ~400 KB,
//! OCR/LLM 识别不受影响,上云存储与流量降一个数量级。
//! 不留未压缩原图(创始人决定,2026-09-11)。HEIC/TIFF 多页/解不开的一律原样返回。
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::GenericImageView;

pub const PHOTO_LONG_EDGE: u32 = 2000;
pub const PHOTO_JPEG_QUALITY: u8 = 85;

pub fn compress_photo(bytes: &[u8]) -> Vec<u8> {
    let Ok(fmt) = image::guess_format(bytes) else { return bytes.to_vec() };
    if !matches!(fmt, image::ImageFormat::Jpeg | image::ImageFormat::Png) {
        return bytes.to_vec();
    }
    let Ok(img) = image::load_from_memory(bytes) else { return bytes.to_vec() };
    let (w, h) = img.dimensions();
    if w.max(h) <= PHOTO_LONG_EDGE {
        return bytes.to_vec();
    }
    let img = img.resize(PHOTO_LONG_EDGE, PHOTO_LONG_EDGE, FilterType::Triangle);
    let mut out = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut out, PHOTO_JPEG_QUALITY);
    match enc.encode_image(&img.to_rgb8()) {
        Ok(()) => out,
        Err(_) => bytes.to_vec(),
    }
}
```
`vault.rs` 两处 ingest:在 `if bytes.is_empty()` 检查之后、`v.import(...)` 之前加
```rust
    let bytes = pipeline::compress_photo(&bytes);
```
(`ingest_bytes` 里只对 `pipeline::mime_for(...)` 以 `image/` 开头的走这一行。)

- [ ] **Step 4: 跑测试**

Run: `cargo test -p pipeline && cd apps/mobile_flutter/rust && cargo check`
Expected: 全绿。

- [ ] **Step 5: Commit**

```bash
git add packages/pipeline apps/mobile_flutter/rust/src/api/vault.rs
git commit -m "feat(pipeline): 导入时压图——长边 2000px JPEG q85,不留未压缩原图"
```

---

### Task 4: `services/api` 骨架 + 建表 + 认证(OTP / JWT / Apple / WeChat 501)

**Files:**
- Create: `services/api/requirements.txt`, `services/api/db.py`, `services/api/auth.py`, `services/api/app.py`, `services/api/test_api.py`, `services/api/README.md`

**Interfaces:**
- Produces:
  - `db.connect() -> psycopg.Connection`(读 `DATABASE_URL`)、`db.ensure_schema(conn)`、`db.account_by_phone_hash(conn, h)`, `db.account_create(conn, *, phone_hash=None, apple_sub=None) -> str`
  - `auth.phone_hash(phone: str) -> str`(HMAC-SHA256 with `PHONE_HMAC_KEY`,hex)
  - `auth.otp_send(conn, phone) -> None`(限频)、`auth.otp_check(conn, phone, code) -> bool`
  - `auth.issue_tokens(account_id) -> dict(access, refresh)`、`auth.verify_access(token) -> str`(返回 account_id,失败抛 `AuthError`)
  - `auth.apple_verify(identity_token) -> str`(返回 `sub`)
  - `class LoginProvider(Protocol): def login(self, conn, payload: dict) -> str`;`PhoneOtpProvider`、`AppleProvider`、`WeChatProvider`(`raise NotImplementedError`)
  - HTTP:`POST /v1/auth/otp {phone}`、`POST /v1/auth/login {phone, code, device_id, device_name}`、`POST /v1/auth/apple {identity_token, device_id, device_name}`、`POST /v1/auth/wechat` → 501、`POST /v1/auth/refresh {refresh}`、`GET /health`

- [ ] **Step 1: 写失败测试**

`services/api/test_api.py`(顶部):
```python
"""后端测试。对本机 PostgreSQL 跑:
    DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest services/api -q
库不存在先 `createdb -p 5435 medme_api_test`。没有 DATABASE_URL 时整文件跳过。
"""
import base64, hashlib, json, os, time
import pytest

DB = os.environ.get("DATABASE_URL")
pytestmark = pytest.mark.skipif(not DB, reason="需要 DATABASE_URL")

os.environ.setdefault("API_JWT_SECRET", "test-secret")
os.environ.setdefault("PHONE_HMAC_KEY", "test-phone-key")
os.environ.setdefault("OTP_DRY_RUN", "1")  # 不真发短信,验证码固定 000000

from fastapi.testclient import TestClient  # noqa: E402
import db as dbm  # noqa: E402
import auth  # noqa: E402
from app import app  # noqa: E402


@pytest.fixture(autouse=True)
def clean():
    with dbm.connect() as conn:
        dbm.ensure_schema(conn)
        conn.execute("TRUNCATE accounts, devices, profiles, grants, invites, events, objects, usage, otp CASCADE")
        conn.commit()


client = TestClient(app)


def login(phone="13800000001", device="dev-1"):
    assert client.post("/v1/auth/otp", json={"phone": phone}).status_code == 200
    r = client.post("/v1/auth/login", json={"phone": phone, "code": "000000", "device_id": device, "device_name": "test"})
    assert r.status_code == 200, r.text
    return r.json()


def test_otp_login_issues_tokens_and_creates_account_once():
    a = login()
    b = login()
    assert a["account_id"] == b["account_id"]
    assert auth.verify_access(a["access"]) == a["account_id"]
    r = client.post("/v1/auth/refresh", json={"refresh": a["refresh"]})
    assert r.status_code == 200 and "access" in r.json()


def test_otp_wrong_code_and_rate_limit():
    client.post("/v1/auth/otp", json={"phone": "13800000002"})
    r = client.post("/v1/auth/login", json={"phone": "13800000002", "code": "999999", "device_id": "d", "device_name": "d"})
    assert r.status_code == 401
    for _ in range(5):
        client.post("/v1/auth/otp", json={"phone": "13800000003"})
    assert client.post("/v1/auth/otp", json={"phone": "13800000003"}).status_code == 429


def test_wechat_is_501_and_apple_rejects_garbage():
    assert client.post("/v1/auth/wechat", json={}).status_code == 501
    r = client.post("/v1/auth/apple", json={"identity_token": "nope", "device_id": "d", "device_name": "d"})
    assert r.status_code == 401
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd services/api && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q`
Expected: ImportError(模块不存在)。

- [ ] **Step 3: 实现**

`services/api/requirements.txt`:
```
fastapi==0.115.*
uvicorn==0.30.*
psycopg[binary]==3.2.*
PyJWT[crypto]==2.9.*
httpx==0.27.*
pytest==8.*
```

`services/api/db.py`:
```python
"""建表 + 全部查询。所有函数接收 psycopg.Connection;没有 ORM。
服务端只存密文与账号业务数据:任何列都不该出现明文病历、档案密钥、私钥、口令。"""
import os
import secrets
import psycopg

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  phone_hash TEXT UNIQUE,
  apple_sub TEXT UNIQUE,
  wechat_openid TEXT UNIQUE,            -- 预留,v1 永远 NULL
  public_key BYTEA,                     -- X25519 公钥 32B
  wrapped_priv_pw BYTEA,                -- 口令 KEK 包的私钥
  wrapped_priv_rc BYTEA,                -- 恢复码 KEK 包的私钥
  kdf_salt BYTEA,
  kdf_params JSONB,                     -- {"m_kib":..,"t":..,"p":..}
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS devices (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  eph_public BYTEA,                     -- 等待批准时的临时公钥
  approved_priv BYTEA,                  -- 旧设备封给它的私钥(取走即删)
  last_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, device_id)
);
CREATE TABLE IF NOT EXISTS profiles (
  id TEXT PRIMARY KEY,
  owner_account_id TEXT NOT NULL REFERENCES accounts(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS grants (
  id TEXT PRIMARY KEY,
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  grantee_kind TEXT NOT NULL CHECK (grantee_kind IN ('account','org')),
  grantee_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner','editor','viewer')),
  expires_at TIMESTAMPTZ,
  wrapped_profile_key BYTEA,            -- 用 grantee 公钥封的档案密钥(邀请兑换后由 grantee 回填)
  created_by TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (profile_id, grantee_kind, grantee_id)
);
CREATE TABLE IF NOT EXISTS invites (
  id TEXT PRIMARY KEY,
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner','editor','viewer')),
  grant_days INT,                       -- NULL = 永久
  token_hash TEXT NOT NULL,
  wrapped_key_by_token BYTEA NOT NULL,  -- 用 token 派生 KEK 包的档案密钥
  expires_at TIMESTAMPTZ NOT NULL,      -- 邀请本身的有效期
  created_by TEXT NOT NULL,
  redeemed_by TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS events (
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  seq BIGINT NOT NULL,
  event_id TEXT NOT NULL,
  ts TEXT NOT NULL,
  ciphertext BYTEA NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, device_id, seq)
);
CREATE TABLE IF NOT EXISTS objects (
  profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  object_id TEXT NOT NULL,
  size BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_id, object_id)
);
CREATE TABLE IF NOT EXISTS usage (
  account_id TEXT NOT NULL,
  month TEXT NOT NULL,                  -- 'YYYY-MM'
  llm_tokens_in BIGINT NOT NULL DEFAULT 0,
  llm_tokens_out BIGINT NOT NULL DEFAULT 0,
  storage_bytes BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, month)
);
CREATE TABLE IF NOT EXISTS otp (
  phone_hash TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  sends_in_window INT NOT NULL DEFAULT 0,
  window_started TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def connect():
    return psycopg.connect(os.environ["DATABASE_URL"])


def ensure_schema(conn):
    conn.execute(SCHEMA)
    conn.commit()


def new_id(prefix):
    return f"{prefix}_{secrets.token_urlsafe(12)}"


def account_by_phone_hash(conn, h):
    return conn.execute("SELECT id FROM accounts WHERE phone_hash=%s", (h,)).fetchone()


def account_by_apple_sub(conn, sub):
    return conn.execute("SELECT id FROM accounts WHERE apple_sub=%s", (sub,)).fetchone()


def account_create(conn, *, phone_hash=None, apple_sub=None):
    aid = new_id("acc")
    conn.execute("INSERT INTO accounts(id, phone_hash, apple_sub) VALUES (%s,%s,%s)", (aid, phone_hash, apple_sub))
    return aid


def device_touch(conn, account_id, device_id, name):
    conn.execute(
        """INSERT INTO devices(account_id, device_id, name) VALUES (%s,%s,%s)
           ON CONFLICT (account_id, device_id) DO UPDATE SET last_seen=now(), name=EXCLUDED.name""",
        (account_id, device_id, name),
    )
```

`services/api/auth.py`:
```python
"""OTP(阿里云 PNVS 短信认证)、JWT、Apple 登录校验、LoginProvider。密钥只从环境变量读。"""
import base64, hashlib, hmac, json, os, secrets, time, urllib.parse, urllib.request, uuid
from typing import Protocol
import jwt

OTP_TTL = 300
OTP_MAX_SENDS_PER_HOUR = 5
OTP_MAX_ATTEMPTS = 5
ACCESS_TTL = 3600
REFRESH_TTL = 30 * 86400


class AuthError(Exception):
    pass


def _secret():
    return os.environ["API_JWT_SECRET"]


def phone_hash(phone: str) -> str:
    return hmac.new(os.environ["PHONE_HMAC_KEY"].encode(), phone.strip().encode(), hashlib.sha256).hexdigest()


def _code_hash(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


# ---- 阿里云 PNVS「短信认证」:RPC 风格签名(与 OSS V1 签名同族,stdlib 即可) ----
def _pnvs_call(action: str, params: dict) -> dict:
    ak, sk = os.environ["ALIYUN_ACCESS_KEY_ID"], os.environ["ALIYUN_ACCESS_KEY_SECRET"]
    q = {
        "Action": action, "Version": "2017-05-25", "Format": "JSON",
        "AccessKeyId": ak, "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
        "SignatureNonce": str(uuid.uuid4()), "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **params,
    }
    def enc(s):
        return urllib.parse.quote(str(s), safe="~")
    canon = "&".join(f"{enc(k)}={enc(v)}" for k, v in sorted(q.items()))
    sts = "POST&%2F&" + enc(canon)
    sig = base64.b64encode(hmac.new((sk + "&").encode(), sts.encode(), hashlib.sha1).digest()).decode()
    body = urllib.parse.urlencode({**q, "Signature": sig}).encode()
    req = urllib.request.Request("https://dypnsapi.aliyuncs.com/", data=body, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def otp_send(conn, phone: str):
    h = phone_hash(phone)
    row = conn.execute("SELECT sends_in_window, window_started FROM otp WHERE phone_hash=%s", (h,)).fetchone()
    sends = 0
    if row:
        sends, started = row
        if (time.time() - started.timestamp()) > 3600:
            sends = 0
    if sends >= OTP_MAX_SENDS_PER_HOUR:
        raise AuthError("rate_limited")
    code = "000000" if os.environ.get("OTP_DRY_RUN") else f"{secrets.randbelow(10**6):06d}"
    conn.execute(
        """INSERT INTO otp(phone_hash, code_hash, expires_at, attempts, sends_in_window, window_started)
           VALUES (%s,%s, now() + interval '%s seconds', 0, 1, now())
           ON CONFLICT (phone_hash) DO UPDATE SET code_hash=EXCLUDED.code_hash, expires_at=EXCLUDED.expires_at,
             attempts=0,
             sends_in_window = CASE WHEN now() - otp.window_started > interval '1 hour' THEN 1 ELSE otp.sends_in_window + 1 END,
             window_started = CASE WHEN now() - otp.window_started > interval '1 hour' THEN now() ELSE otp.window_started END""",
        (h, _code_hash(code), OTP_TTL),
    )
    if not os.environ.get("OTP_DRY_RUN"):
        _pnvs_call("SendSmsVerifyCode", {
            "PhoneNumber": phone, "SignName": os.environ["PNVS_SIGN_NAME"],
            "TemplateCode": os.environ["PNVS_TEMPLATE_CODE"],
            "TemplateParam": json.dumps({"code": code}), "ValidTime": str(OTP_TTL),
        })


def otp_check(conn, phone: str, code: str) -> bool:
    h = phone_hash(phone)
    row = conn.execute("SELECT code_hash, expires_at, attempts FROM otp WHERE phone_hash=%s", (h,)).fetchone()
    if not row:
        return False
    code_hash, expires_at, attempts = row
    if attempts >= OTP_MAX_ATTEMPTS or expires_at.timestamp() < time.time():
        return False
    ok = hmac.compare_digest(code_hash, _code_hash(code))
    conn.execute("UPDATE otp SET attempts = attempts + 1 WHERE phone_hash=%s", (h,))
    if ok:
        conn.execute("DELETE FROM otp WHERE phone_hash=%s", (h,))
    return ok


def issue_tokens(account_id: str) -> dict:
    now = int(time.time())
    return {
        "access": jwt.encode({"sub": account_id, "typ": "access", "exp": now + ACCESS_TTL}, _secret(), algorithm="HS256"),
        "refresh": jwt.encode({"sub": account_id, "typ": "refresh", "exp": now + REFRESH_TTL}, _secret(), algorithm="HS256"),
    }


def _verify(token: str, typ: str) -> str:
    try:
        p = jwt.decode(token, _secret(), algorithms=["HS256"])
    except jwt.PyJWTError as e:
        raise AuthError(str(e))
    if p.get("typ") != typ:
        raise AuthError("wrong token type")
    return p["sub"]


def verify_access(token: str) -> str:
    return _verify(token, "access")


def verify_refresh(token: str) -> str:
    return _verify(token, "refresh")


# ---- Apple ----
_APPLE_JWKS = {"at": 0, "client": None}


def apple_verify(identity_token: str) -> str:
    if time.time() - _APPLE_JWKS["at"] > 3600:
        with urllib.request.urlopen("https://appleid.apple.com/auth/keys", timeout=10) as r:
            _APPLE_JWKS["client"] = jwt.PyJWKSet.from_dict(json.loads(r.read()))
            _APPLE_JWKS["at"] = time.time()
    try:
        header = jwt.get_unverified_header(identity_token)
        key = _APPLE_JWKS["client"][header["kid"]]
        p = jwt.decode(identity_token, key.key, algorithms=["RS256"],
                       audience=os.environ["APPLE_BUNDLE_ID"], issuer="https://appleid.apple.com")
    except Exception as e:  # 任何一步失败都是 401,不区分
        raise AuthError(f"apple: {e}")
    return p["sub"]


# ---- LoginProvider:一个接口,三个实现(微信只留位) ----
class LoginProvider(Protocol):
    def login(self, conn, payload: dict) -> str: ...


class PhoneOtpProvider:
    def login(self, conn, payload):
        import db
        phone, code = payload.get("phone", ""), payload.get("code", "")
        if not otp_check(conn, phone, code):
            raise AuthError("bad code")
        h = phone_hash(phone)
        row = db.account_by_phone_hash(conn, h)
        return row[0] if row else db.account_create(conn, phone_hash=h)


class AppleProvider:
    def login(self, conn, payload):
        import db
        sub = apple_verify(payload.get("identity_token", ""))
        row = db.account_by_apple_sub(conn, sub)
        return row[0] if row else db.account_create(conn, apple_sub=sub)


class WeChatProvider:
    """预留。拿到营业执照、开放平台认证后在这里接 code2session;账号表已有 wechat_openid 列。"""
    def login(self, conn, payload):
        raise NotImplementedError("wechat login not available yet")


PROVIDERS = {"otp": PhoneOtpProvider(), "apple": AppleProvider(), "wechat": WeChatProvider()}
```

`services/api/app.py`(本任务只写认证与健康检查;后续任务往同一文件追加路由):
```python
"""MedMe 账号/同步/授权/LLM 代理 API。阿里云 FC 自定义运行时:`python3 -m uvicorn app:app --host 0.0.0.0 --port 9000`。
服务端只见密文:此文件里不得出现任何解密调用。"""
import os
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
import auth, db

app = FastAPI(title="medme-api")


@app.on_event("startup")
def _startup():
    with db.connect() as conn:
        db.ensure_schema(conn)


def conn_dep():
    conn = db.connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def account_dep(authorization: str = Header(default="")) -> str:
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer")
    token = authorization[7:]
    # 子项目 A 评测期的静态 token(与 claim-signer 的 MEDME_UPLOAD_TOKEN 同一模式)
    dev = os.environ.get("MEDME_EXTRACT_TOKEN", "")
    if dev and token == dev:
        return "dev"
    try:
        return auth.verify_access(token)
    except auth.AuthError as e:
        raise HTTPException(401, str(e))


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/v1/auth/otp")
def auth_otp(body: dict, conn=Depends(conn_dep)):
    try:
        auth.otp_send(conn, body.get("phone", ""))
    except auth.AuthError:
        raise HTTPException(429, "rate_limited")
    return {"ok": True}


def _login_with(provider: str, body: dict, conn):
    try:
        aid = auth.PROVIDERS[provider].login(conn, body)
    except NotImplementedError:
        raise HTTPException(501, "not implemented")
    except auth.AuthError as e:
        raise HTTPException(401, str(e))
    db.device_touch(conn, aid, body.get("device_id", ""), body.get("device_name", ""))
    return {"account_id": aid, **auth.issue_tokens(aid)}


@app.post("/v1/auth/login")
def auth_login(body: dict, conn=Depends(conn_dep)):
    return _login_with("otp", body, conn)


@app.post("/v1/auth/apple")
def auth_apple(body: dict, conn=Depends(conn_dep)):
    return _login_with("apple", body, conn)


@app.post("/v1/auth/wechat")
def auth_wechat(body: dict, conn=Depends(conn_dep)):
    return _login_with("wechat", body, conn)


@app.post("/v1/auth/refresh")
def auth_refresh(body: dict):
    try:
        aid = auth.verify_refresh(body.get("refresh", ""))
    except auth.AuthError as e:
        raise HTTPException(401, str(e))
    return auth.issue_tokens(aid)
```

`services/api/README.md`:写部署三步(与 claim-signer README 同格式):FC Web 函数 · 自定义运行时 · 启动命令 `python3 -m uvicorn app:app --host 0.0.0.0 --port 9000` · `pip install -r requirements.txt -t .` 打包 · 环境变量表:`DATABASE_URL`, `API_JWT_SECRET`, `PHONE_HMAC_KEY`, `ALIYUN_ACCESS_KEY_ID/SECRET`, `PNVS_SIGN_NAME`, `PNVS_TEMPLATE_CODE`, `APPLE_BUNDLE_ID=com.medme.mobile`, `OSS_BUCKET=medme-vault`, `OSS_ENDPOINT`, `DEEPSEEK_API_KEY`, `MEDME_EXTRACT_TOKEN`(可选,A 评测期)。RDS 用 Serverless PG 杭州,开 RDS Proxy 解决 FC 冷启动连接风暴。

- [ ] **Step 4: 跑测试**

Run: `createdb -p 5435 medme_api_test 2>/dev/null; cd services/api && pip install -r requirements.txt -q && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q`
Expected: 3 passed。

- [ ] **Step 5: Commit**

```bash
git add services/api
git commit -m "feat(api): 账号服务骨架——建表、手机验证码/Apple/JWT,微信登录留 501"
```

---

### Task 5: 密钥、档案、授权、邀请、转移、设备批准

**Files:**
- Modify: `services/api/db.py`, `services/api/app.py`, `services/api/test_api.py`

**Interfaces:**
- Produces(HTTP,均需 Bearer):
  - `PUT /v1/account/keys {public_key, wrapped_priv_pw, wrapped_priv_rc, kdf_salt, kdf_params}`(base64)、`GET /v1/account/keys`
  - `GET /v1/accounts/lookup?phone=` → `{account_id, public_key}`(家属按手机号授权用;找不到 404)
  - `POST /v1/profiles {wrapped_profile_key}` → `{profile_id}`(同时写 owner grant)
  - `GET /v1/profiles` → `[{profile_id, role, expires_at, wrapped_profile_key}]`(我拥有 + 被授权给我,过期的不返回)
  - `POST /v1/profiles/{id}/grants {grantee_account_id, role, days, wrapped_profile_key}`(owner 才能;role ∈ editor/viewer)
  - `DELETE /v1/profiles/{id}/grants/{gid}`(owner)
  - `POST /v1/profiles/{id}/invites {role, days, token_hash, wrapped_key_by_token, invite_ttl_s}` → `{invite_id}`(owner;role=owner 表示转移)
  - `POST /v1/invites/redeem {invite_id, token}` → `{profile_id, role, expires_at, wrapped_key_by_token, grant_id}`(创建 grant;role=owner 时旧 owner 降 editor、profiles.owner 改)
  - `PUT /v1/profiles/{id}/grants/{gid}/key {wrapped_profile_key}`(grantee 兑换后回填自己公钥封的密钥)
  - `POST /v1/devices/request {eph_public}`(新设备)、`GET /v1/devices` 、`POST /v1/devices/approve {device_id, approved_priv}`(旧设备)、`GET /v1/devices/approval?device_id=` → `{approved_priv}`(取走即删)
  - `db.role_for(conn, profile_id, account_id) -> str|None`(过期视为 None)

- [ ] **Step 1: 追加失败测试**(`test_api.py`)
```python
def _h(c, tok):
    return {"Authorization": f"Bearer {tok}"}


def b64(b):
    return base64.b64encode(b).decode()


def test_keys_profile_family_grant_and_doctor_invite_flow():
    alice = login("13800000010", "a-1")
    bob = login("13800000011", "b-1")
    doc = login("13800000012", "d-1")
    ha, hb, hd = _h(client, alice["access"]), _h(client, bob["access"]), _h(client, doc["access"])
    keys = {"public_key": b64(b"A" * 32), "wrapped_priv_pw": b64(b"pw"), "wrapped_priv_rc": b64(b"rc"),
            "kdf_salt": b64(b"s" * 16), "kdf_params": {"m_kib": 65536, "t": 3, "p": 1}}
    assert client.put("/v1/account/keys", json=keys, headers=ha).status_code == 200
    assert client.get("/v1/account/keys", headers=ha).json()["public_key"] == keys["public_key"]
    assert client.put("/v1/account/keys", json={**keys, "public_key": b64(b"B" * 32)}, headers=hb).status_code == 200

    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk-alice")}, headers=ha).json()["profile_id"]
    mine = client.get("/v1/profiles", headers=ha).json()
    assert mine[0]["role"] == "owner"

    # 家属:按手机号查公钥 → 直接授权 editor 永久
    lk = client.get("/v1/accounts/lookup", params={"phone": "13800000011"}, headers=ha).json()
    assert lk["public_key"] == b64(b"B" * 32)
    g = client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": lk["account_id"], "role": "editor",
                                                      "days": None, "wrapped_profile_key": b64(b"wk-bob")}, headers=ha)
    assert g.status_code == 200
    assert [p for p in client.get("/v1/profiles", headers=hb).json() if p["profile_id"] == pid][0]["role"] == "editor"
    # bob 不是 owner,不能再授权别人
    assert client.post(f"/v1/profiles/{pid}/grants", json={"grantee_account_id": doc["account_id"], "role": "viewer",
                                                         "days": 15, "wrapped_profile_key": b64(b"x")}, headers=hb).status_code == 403

    # 医生:患者出示邀请(15 天 viewer),医生兑换
    token = "T" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"wk-token"), "invite_ttl_s": 600}, headers=ha).json()
    r = client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": "wrong"}, headers=hd)
    assert r.status_code == 404
    r = client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd)
    assert r.status_code == 200 and r.json()["role"] == "viewer"
    exp = r.json()["expires_at"]
    assert 14 * 86400 < (time.mktime(time.strptime(exp[:19], "%Y-%m-%dT%H:%M:%S")) - time.time()) < 16 * 86400
    assert client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hd).status_code == 410
    gid = r.json()["grant_id"]
    assert client.put(f"/v1/profiles/{pid}/grants/{gid}/key", json={"wrapped_profile_key": b64(b"wk-doc")}, headers=hd).status_code == 200
    # owner 撤销
    assert client.delete(f"/v1/profiles/{pid}/grants/{gid}", headers=ha).status_code == 200
    assert all(p["profile_id"] != pid for p in client.get("/v1/profiles", headers=hd).json())


def test_transfer_makes_new_owner_and_demotes_old():
    doc = login("13800000020", "d-1")
    pat = login("13800000021", "p-1")
    hd, hp = _h(client, doc["access"]), _h(client, pat["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=hd).json()["profile_id"]
    token = "X" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "owner", "days": None, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"wk-t"), "invite_ttl_s": 86400 * 15}, headers=hd).json()
    assert client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hp).status_code == 200
    roles = {p["profile_id"]: p["role"] for p in client.get("/v1/profiles", headers=hp).json()}
    assert roles[pid] == "owner"
    roles = {p["profile_id"]: p["role"] for p in client.get("/v1/profiles", headers=hd).json()}
    assert roles[pid] == "editor"


def test_device_approval_handoff():
    a = login("13800000030", "old")
    ha = _h(client, a["access"])
    b = login("13800000030", "new")
    hb = _h(client, b["access"])
    assert client.post("/v1/devices/request", json={"eph_public": b64(b"E" * 32)}, headers=hb).status_code == 200
    devs = client.get("/v1/devices", headers=ha).json()
    pending = [d for d in devs if d["device_id"] == "new"][0]
    assert pending["eph_public"] == b64(b"E" * 32)
    assert client.post("/v1/devices/approve", json={"device_id": "new", "approved_priv": b64(b"sealed")}, headers=ha).status_code == 200
    r = client.get("/v1/devices/approval", params={"device_id": "new"}, headers=hb)
    assert r.json()["approved_priv"] == b64(b"sealed")
    assert client.get("/v1/devices/approval", params={"device_id": "new"}, headers=hb).json()["approved_priv"] is None
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd services/api && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q -k "keys or transfer or device"`
Expected: 404(路由不存在)。

- [ ] **Step 3: 实现**

`db.py` 追加:
```python
import base64, datetime, hashlib


def b64d(s):
    return base64.b64decode(s) if s is not None else None


def b64e(b):
    return base64.b64encode(bytes(b)).decode() if b is not None else None


def keys_put(conn, aid, body):
    conn.execute(
        """UPDATE accounts SET public_key=%s, wrapped_priv_pw=%s, wrapped_priv_rc=%s, kdf_salt=%s, kdf_params=%s WHERE id=%s""",
        (b64d(body["public_key"]), b64d(body["wrapped_priv_pw"]), b64d(body["wrapped_priv_rc"]),
         b64d(body["kdf_salt"]), psycopg.types.json.Jsonb(body["kdf_params"]), aid),
    )


def keys_get(conn, aid):
    r = conn.execute("SELECT public_key, wrapped_priv_pw, wrapped_priv_rc, kdf_salt, kdf_params FROM accounts WHERE id=%s", (aid,)).fetchone()
    if not r or r[0] is None:
        return None
    return {"public_key": b64e(r[0]), "wrapped_priv_pw": b64e(r[1]), "wrapped_priv_rc": b64e(r[2]), "kdf_salt": b64e(r[3]), "kdf_params": r[4]}


def account_lookup_by_phone_hash(conn, h):
    r = conn.execute("SELECT id, public_key FROM accounts WHERE phone_hash=%s AND public_key IS NOT NULL", (h,)).fetchone()
    return {"account_id": r[0], "public_key": b64e(r[1])} if r else None


def profile_create(conn, aid, wrapped_key):
    pid = new_id("prf")
    conn.execute("INSERT INTO profiles(id, owner_account_id) VALUES (%s,%s)", (pid, aid))
    grant_upsert(conn, pid, aid, "owner", None, b64d(wrapped_key), aid)
    return pid


def grant_upsert(conn, pid, grantee_account_id, role, expires_at, wrapped_key, created_by):
    gid = new_id("grt")
    conn.execute(
        """INSERT INTO grants(id, profile_id, grantee_kind, grantee_id, role, expires_at, wrapped_profile_key, created_by)
           VALUES (%s,%s,'account',%s,%s,%s,%s,%s)
           ON CONFLICT (profile_id, grantee_kind, grantee_id) DO UPDATE
             SET role=EXCLUDED.role, expires_at=EXCLUDED.expires_at,
                 wrapped_profile_key=COALESCE(EXCLUDED.wrapped_profile_key, grants.wrapped_profile_key)
           RETURNING id""",
        (gid, pid, grantee_account_id, role, expires_at, wrapped_key, created_by),
    )
    return conn.execute("SELECT id FROM grants WHERE profile_id=%s AND grantee_kind='account' AND grantee_id=%s", (pid, grantee_account_id)).fetchone()[0]


def role_for(conn, pid, aid):
    r = conn.execute(
        "SELECT role FROM grants WHERE profile_id=%s AND grantee_kind='account' AND grantee_id=%s AND (expires_at IS NULL OR expires_at > now())",
        (pid, aid)).fetchone()
    return r[0] if r else None


def profiles_for(conn, aid):
    rows = conn.execute(
        """SELECT profile_id, role, expires_at, wrapped_profile_key, id FROM grants
           WHERE grantee_kind='account' AND grantee_id=%s AND (expires_at IS NULL OR expires_at > now())
           ORDER BY created_at""", (aid,)).fetchall()
    return [{"profile_id": r[0], "role": r[1], "expires_at": r[2].isoformat() if r[2] else None,
             "wrapped_profile_key": b64e(r[3]), "grant_id": r[4]} for r in rows]


def grant_delete(conn, pid, gid):
    conn.execute("DELETE FROM grants WHERE profile_id=%s AND id=%s AND role<>'owner'", (pid, gid))


def grant_set_key(conn, pid, gid, aid, wrapped_key):
    conn.execute("UPDATE grants SET wrapped_profile_key=%s WHERE profile_id=%s AND id=%s AND grantee_id=%s", (b64d(wrapped_key), pid, gid, aid))


def invite_create(conn, pid, aid, body):
    iid = new_id("inv")
    ttl = int(body.get("invite_ttl_s", 600))
    conn.execute(
        """INSERT INTO invites(id, profile_id, role, grant_days, token_hash, wrapped_key_by_token, expires_at, created_by)
           VALUES (%s,%s,%s,%s,%s,%s, now() + make_interval(secs => %s), %s)""",
        (iid, pid, body["role"], body.get("days"), body["token_hash"], b64d(body["wrapped_key_by_token"]), ttl, aid))
    return iid


def invite_redeem(conn, iid, token, aid):
    """返回 (status, payload)。status ∈ ok / notfound / gone。"""
    r = conn.execute("SELECT profile_id, role, grant_days, token_hash, wrapped_key_by_token, expires_at, redeemed_by, created_by FROM invites WHERE id=%s", (iid,)).fetchone()
    if not r or not hmac.compare_digest(r[3], hashlib.sha256(token.encode()).hexdigest()):
        return "notfound", None
    pid, role, days, _, wrapped, exp, redeemed_by, created_by = r
    if redeemed_by is not None or exp.timestamp() < time.time():
        return "gone", None
    expires_at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)) if days else None
    if role == "owner":
        # 转移:旧 owner 降 editor,新 owner 上位
        conn.execute("UPDATE grants SET role='editor' WHERE profile_id=%s AND role='owner'", (pid,))
        conn.execute("UPDATE profiles SET owner_account_id=%s WHERE id=%s", (aid, pid))
    gid = grant_upsert(conn, pid, aid, role, expires_at, None, created_by)
    conn.execute("UPDATE invites SET redeemed_by=%s WHERE id=%s", (aid, iid))
    return "ok", {"profile_id": pid, "role": role, "expires_at": expires_at.isoformat() if expires_at else None,
                  "wrapped_key_by_token": b64e(wrapped), "grant_id": gid}


def device_request(conn, aid, did, eph_public):
    conn.execute("UPDATE devices SET eph_public=%s WHERE account_id=%s AND device_id=%s", (b64d(eph_public), aid, did))


def devices_list(conn, aid):
    rows = conn.execute("SELECT device_id, name, last_seen, eph_public, approved_priv IS NOT NULL FROM devices WHERE account_id=%s", (aid,)).fetchall()
    return [{"device_id": r[0], "name": r[1], "last_seen": r[2].isoformat(), "eph_public": b64e(r[3]), "approved": r[4]} for r in rows]


def device_approve(conn, aid, did, approved_priv):
    conn.execute("UPDATE devices SET approved_priv=%s, eph_public=NULL WHERE account_id=%s AND device_id=%s", (b64d(approved_priv), aid, did))


def device_take_approval(conn, aid, did):
    r = conn.execute("UPDATE devices SET approved_priv=NULL WHERE account_id=%s AND device_id=%s AND approved_priv IS NOT NULL RETURNING approved_priv", (aid, did)).fetchone()
    return b64e(r[0]) if r else None
```
(`db.py` 顶部补 `import hmac, time`。)

`app.py` 追加:
```python
def _require_role(conn, pid, aid, allowed):
    role = db.role_for(conn, pid, aid)
    if role not in allowed:
        raise HTTPException(403, "forbidden")
    return role


@app.put("/v1/account/keys")
def keys_put(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    db.keys_put(conn, aid, body)
    return {"ok": True}


@app.get("/v1/account/keys")
def keys_get(aid=Depends(account_dep), conn=Depends(conn_dep)):
    k = db.keys_get(conn, aid)
    if not k:
        raise HTTPException(404, "no keys")
    return k


@app.get("/v1/accounts/lookup")
def account_lookup(phone: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    r = db.account_lookup_by_phone_hash(conn, auth.phone_hash(phone))
    if not r:
        raise HTTPException(404, "not found")
    return r


@app.post("/v1/profiles")
def profile_create(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    return {"profile_id": db.profile_create(conn, aid, body["wrapped_profile_key"])}


@app.get("/v1/profiles")
def profiles_list(aid=Depends(account_dep), conn=Depends(conn_dep)):
    return db.profiles_for(conn, aid)


@app.post("/v1/profiles/{pid}/grants")
def grant_create(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    if body["role"] not in ("editor", "viewer"):
        raise HTTPException(400, "role")
    days = body.get("days")
    exp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)) if days else None
    gid = db.grant_upsert(conn, pid, body["grantee_account_id"], body["role"], exp, db.b64d(body["wrapped_profile_key"]), aid)
    return {"grant_id": gid}


@app.delete("/v1/profiles/{pid}/grants/{gid}")
def grant_delete(pid: str, gid: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    db.grant_delete(conn, pid, gid)
    return {"ok": True}


@app.put("/v1/profiles/{pid}/grants/{gid}/key")
def grant_set_key(pid: str, gid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    db.grant_set_key(conn, pid, gid, aid, body["wrapped_profile_key"])
    return {"ok": True}


@app.post("/v1/profiles/{pid}/invites")
def invite_create(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner"})
    return {"invite_id": db.invite_create(conn, pid, aid, body)}


@app.post("/v1/invites/redeem")
def invite_redeem(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    status, payload = db.invite_redeem(conn, body.get("invite_id", ""), body.get("token", ""), aid)
    if status == "notfound":
        raise HTTPException(404, "not found")
    if status == "gone":
        raise HTTPException(410, "used or expired")
    return payload


@app.post("/v1/devices/request")
def device_request(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep), x_device_id: str = Header(default="")):
    db.device_request(conn, aid, body.get("device_id") or x_device_id, body["eph_public"])
    return {"ok": True}


@app.get("/v1/devices")
def devices_list(aid=Depends(account_dep), conn=Depends(conn_dep)):
    return db.devices_list(conn, aid)


@app.post("/v1/devices/approve")
def device_approve(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    db.device_approve(conn, aid, body["device_id"], body["approved_priv"])
    return {"ok": True}


@app.get("/v1/devices/approval")
def device_approval(device_id: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    return {"approved_priv": db.device_take_approval(conn, aid, device_id)}
```
(`app.py` 顶部补 `import datetime`;`/v1/devices/request` 测试里 device_id 从登录时的 `device_touch` 已存在,body 里没有 `device_id` 就用 `X-Device-Id` 头——测试 `login(..., "new")` 后请求头需加 `"X-Device-Id": "new"`,在测试的 `_h` 里顺带带上:`{"Authorization": ..., "X-Device-Id": device}`;把 `_h(c, tok)` 改成 `_h(tok, device="")`。)

- [ ] **Step 4: 跑测试**

Run: `cd services/api && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q`
Expected: 6 passed。

- [ ] **Step 5: Commit**

```bash
git add services/api
git commit -m "feat(api): 密钥托管密文、档案/授权/邀请/转移/设备批准——一套 grants 管主人家属医生"
```

---

### Task 6: 事件推拉、对象预签名、LLM 代理 + usage

**Files:**
- Create: `services/api/oss.py`, `services/api/extract.py`
- Modify: `services/api/db.py`, `services/api/app.py`, `services/api/test_api.py`

**Interfaces:**
- Produces(HTTP):
  - `GET /v1/profiles/{id}/events?since=<json {device_id: seq}>` → `[{device_id, seq, event_id, ts, ciphertext}]`(任何有效 role)
  - `POST /v1/profiles/{id}/events [{device_id, seq, event_id, ts, ciphertext}]`(owner/editor;`(profile, device, seq)` 冲突时忽略)
  - `POST /v1/profiles/{id}/objects/sign {object_id, verb: PUT|GET, size?}` → `{url, content_type, expires_in}`(PUT 需 owner/editor 并登记 objects 行与 storage_bytes)
  - `GET /v1/profiles/{id}/objects` → `[object_id]`
  - `POST /v1/extract {mode, schema, payload, hints}` → DeepSeek 的 JSON(不落盘 payload;usage 记 tokens)
  - `oss.presign(verb, key, content_type, ttl) -> str`

- [ ] **Step 1: 追加失败测试**
```python
def test_events_push_pull_role_enforced_and_since_filter():
    a = login("13800000040", "a")
    v = login("13800000041", "v")
    ha, hv = _h(a["access"]), _h(v["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    token = "V" * 32
    inv = client.post(f"/v1/profiles/{pid}/invites", json={"role": "viewer", "days": 15, "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                                                            "wrapped_key_by_token": b64(b"w"), "invite_ttl_s": 600}, headers=ha).json()
    client.post("/v1/invites/redeem", json={"invite_id": inv["invite_id"], "token": token}, headers=hv)
    evs = [{"device_id": "a", "seq": i, "event_id": f"e{i}", "ts": "2026-09-11T00:00:00Z", "ciphertext": b64(b"c%d" % i)} for i in (1, 2, 3)]
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=ha).status_code == 200
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=ha).status_code == 200  # 幂等
    assert client.post(f"/v1/profiles/{pid}/events", json=evs, headers=hv).status_code == 403   # viewer 不能写
    got = client.get(f"/v1/profiles/{pid}/events", params={"since": json.dumps({"a": 1})}, headers=hv).json()
    assert [e["seq"] for e in got] == [2, 3]
    assert got[0]["ciphertext"] == b64(b"c2")


def test_object_sign_registers_and_counts_storage():
    os.environ.update({"OSS_ACCESS_KEY_ID": "AK", "OSS_ACCESS_KEY_SECRET": "SK", "OSS_BUCKET": "medme-vault", "OSS_ENDPOINT": "oss-cn-hangzhou.aliyuncs.com"})
    a = login("13800000050", "a")
    ha = _h(a["access"])
    pid = client.post("/v1/profiles", json={"wrapped_profile_key": b64(b"wk")}, headers=ha).json()["profile_id"]
    r = client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": "ab" * 32, "verb": "PUT", "size": 1234}, headers=ha).json()
    assert r["url"].startswith("https://medme-vault.oss-cn-hangzhou.aliyuncs.com/v/") and "Signature=" in r["url"]
    assert client.get(f"/v1/profiles/{pid}/objects", headers=ha).json() == ["ab" * 32]
    with dbm.connect() as conn:
        assert conn.execute("SELECT storage_bytes FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone()[0] == 1234
    assert client.post(f"/v1/profiles/{pid}/objects/sign", json={"object_id": "zz", "verb": "PUT", "size": 1}, headers=ha).status_code == 400


def test_extract_proxies_and_counts_tokens(monkeypatch):
    import extract
    monkeypatch.setattr(extract, "_call_deepseek", lambda model, messages: {"choices": [{"message": {"content": '{"doc_type":"lab","labs":[]}'}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
    a = login("13800000060", "a")
    r = client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "血红蛋白 130 g/L", "hints": {}}, headers=_h(a["access"]))
    assert r.status_code == 200 and r.json()["doc_type"] == "lab"
    with dbm.connect() as conn:
        assert conn.execute("SELECT llm_tokens_in, llm_tokens_out FROM usage WHERE account_id=%s", (a["account_id"],)).fetchone() == (10, 5)
    os.environ["MEDME_EXTRACT_TOKEN"] = "dev-token"
    assert client.post("/v1/extract", json={"mode": "text", "schema": 1, "payload": "x"}, headers={"Authorization": "Bearer dev-token"}).status_code == 200
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd services/api && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q -k "events or object or extract"`
Expected: 404 / AttributeError。

- [ ] **Step 3: 实现**

`services/api/oss.py`(从 `services/claim-signer/handler.py` 复制 `_sign` / `canonical_resource` / `build_presigned` 三个函数,一字不改,顶部注明来源),再加:
```python
import os, time

PRESIGN_TTL = 600
CONTENT_TYPE = "application/octet-stream"


def presign(verb: str, key: str, content_type: str = CONTENT_TYPE, ttl: int = PRESIGN_TTL) -> str:
    return build_presigned(
        verb=verb, access_key_id=os.environ["OSS_ACCESS_KEY_ID"].strip(), access_key_secret=os.environ["OSS_ACCESS_KEY_SECRET"].strip(),
        bucket=os.environ["OSS_BUCKET"].strip(), endpoint=os.environ["OSS_ENDPOINT"].strip(), key=key,
        expires_at=int(time.time()) + ttl, content_type=content_type if verb == "PUT" else "",
    )
```

`services/api/extract.py`:
```python
"""LLM 代理(子项目 A §2)。payload 已在手机上脱敏;这里**不落盘**,只记 token。"""
import json, os, urllib.request

DEEPSEEK_BASE = os.environ.get("DEEPSEEK_BASE", "https://api.deepseek.com")
MODEL_TEXT = "deepseek-v4-flash"
MODEL_VISION = "deepseek-v4-flash-vision-exp"

# 输出 schema v1 逐字来自 spec A §3;子项目 A 负责调 prompt 措辞,schema 字段不改。
SYSTEM_PROMPT_V1 = """你是医疗单据结构化助手。只输出一个 JSON 对象,不要任何解释。所有字符串必须是输入原文的逐字子串;不确定的留空字符串,绝不推断或补全。
{"doc_type":"lab|discharge|outpatient|imaging|prescription|other","doc_date":"YYYY-MM-DD","labs":[{"name":"","value":"","unit":"","ref_low":"","ref_high":"","flag":"H|L|"}],"meds":[{"name":"","dose":"","freq":"","route":""}],"diagnoses":[{"text":"","icd":""}],"impression":"","notes":""}"""


def _call_deepseek(model: str, messages: list) -> dict:
    req = urllib.request.Request(
        f"{DEEPSEEK_BASE}/chat/completions",
        data=json.dumps({"model": model, "messages": messages, "response_format": {"type": "json_object"}, "temperature": 0}).encode(),
        headers={"Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def run(body: dict) -> tuple[dict, int, int]:
    mode = body.get("mode", "text")
    if body.get("schema") != 1:
        raise ValueError("schema")
    if mode == "image":
        content = [{"type": "text", "text": "请按 schema 输出这份单据的内容。"},
                   {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{body['payload']}"}}]
        model = MODEL_VISION
    else:
        content = body["payload"]
        model = MODEL_TEXT
    out = _call_deepseek(model, [{"role": "system", "content": SYSTEM_PROMPT_V1}, {"role": "user", "content": content}])
    text = out["choices"][0]["message"]["content"]
    usage = out.get("usage", {})
    return json.loads(text), int(usage.get("prompt_tokens", 0)), int(usage.get("completion_tokens", 0))
```

`db.py` 追加:
```python
def events_push(conn, pid, events):
    for e in events:
        conn.execute(
            """INSERT INTO events(profile_id, device_id, seq, event_id, ts, ciphertext) VALUES (%s,%s,%s,%s,%s,%s)
               ON CONFLICT (profile_id, device_id, seq) DO NOTHING""",
            (pid, e["device_id"], int(e["seq"]), e["event_id"], e["ts"], b64d(e["ciphertext"])))


def events_pull(conn, pid, since: dict):
    rows = conn.execute("SELECT device_id, seq, event_id, ts, ciphertext FROM events WHERE profile_id=%s ORDER BY device_id, seq", (pid,)).fetchall()
    return [{"device_id": r[0], "seq": r[1], "event_id": r[2], "ts": r[3], "ciphertext": b64e(r[4])}
            for r in rows if r[1] > int(since.get(r[0], 0))]


def object_register(conn, pid, aid, oid, size):
    conn.execute("INSERT INTO objects(profile_id, object_id, size) VALUES (%s,%s,%s) ON CONFLICT DO NOTHING", (pid, oid, size))
    usage_add(conn, aid, storage_bytes=size)


def objects_list(conn, pid):
    return [r[0] for r in conn.execute("SELECT object_id FROM objects WHERE profile_id=%s ORDER BY created_at", (pid,)).fetchall()]


def usage_add(conn, aid, *, tokens_in=0, tokens_out=0, storage_bytes=0):
    month = time.strftime("%Y-%m")
    conn.execute(
        """INSERT INTO usage(account_id, month, llm_tokens_in, llm_tokens_out, storage_bytes) VALUES (%s,%s,%s,%s,%s)
           ON CONFLICT (account_id, month) DO UPDATE SET llm_tokens_in=usage.llm_tokens_in+EXCLUDED.llm_tokens_in,
             llm_tokens_out=usage.llm_tokens_out+EXCLUDED.llm_tokens_out, storage_bytes=usage.storage_bytes+EXCLUDED.storage_bytes""",
        (aid, month, tokens_in, tokens_out, storage_bytes))
```

`app.py` 追加:
```python
import json, re
import extract, oss

_OID = re.compile(r"^[0-9a-f]{64}$")


@app.get("/v1/profiles/{pid}/events")
def events_pull(pid: str, since: str = "{}", aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    return db.events_pull(conn, pid, json.loads(since))


@app.post("/v1/profiles/{pid}/events")
def events_push(pid: str, body: list, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor"})
    db.events_push(conn, pid, body)
    return {"ok": True}


@app.post("/v1/profiles/{pid}/objects/sign")
def object_sign(pid: str, body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    verb = body.get("verb", "GET")
    oid = body.get("object_id", "")
    if not _OID.match(oid):
        raise HTTPException(400, "object_id")
    _require_role(conn, pid, aid, {"owner", "editor"} if verb == "PUT" else {"owner", "editor", "viewer"})
    if verb == "PUT":
        db.object_register(conn, pid, aid, oid, int(body.get("size", 0)))
    return {"url": oss.presign(verb, f"v/{pid}/{oid}"), "content_type": oss.CONTENT_TYPE, "expires_in": oss.PRESIGN_TTL}


@app.get("/v1/profiles/{pid}/objects")
def objects_list(pid: str, aid=Depends(account_dep), conn=Depends(conn_dep)):
    _require_role(conn, pid, aid, {"owner", "editor", "viewer"})
    return db.objects_list(conn, pid)


@app.post("/v1/extract")
def extract_route(body: dict, aid=Depends(account_dep), conn=Depends(conn_dep)):
    try:
        result, tin, tout = extract.run(body)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception as e:  # 上游失败如实报 502,payload 不进日志
        raise HTTPException(502, "upstream")
    db.usage_add(conn, aid, tokens_in=tin, tokens_out=tout)
    return result
```

- [ ] **Step 4: 跑测试**

Run: `cd services/api && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q`
Expected: 9 passed。

- [ ] **Step 5: Commit**

```bash
git add services/api
git commit -m "feat(api): 事件推拉按 role 拒写、对象预签名登记用量、DeepSeek 代理不落盘只记 token"
```

---

### Task 7: FRB 暴露 `sync_*`(密钥、封装、事件/对象加解密、keyed 开箱、KDF 基准)

**Files:**
- Create: `apps/mobile_flutter/rust/src/api/vault_sync.rs`
- Modify: `apps/mobile_flutter/rust/src/api/mod.rs`(末尾 `pub mod vault_sync;`)、`apps/mobile_flutter/rust/Cargo.toml`(`sync = { path = "../../../packages/sync" }`)、`apps/mobile_flutter/rust/src/api/vault.rs`(`VaultState` 增 `profile_key: Option<[u8;32]>`;`open_vault` 增可选参数版本见下)

**Interfaces:**
- Consumes: Task 1 全部、Task 2 的 `open_split_resilient_with_key / log_entries / append_peer_entries / missing_object_hashes / device_seq_map`
- Produces(Dart 侧生成为同名 camelCase):
  - `sync_account_keys_new() -> (Vec<u8> public, Vec<u8> secret)`
  - `sync_wrap_private(secret, password, salt16, m_kib, t, p) -> Vec<u8>`、`sync_unwrap_private_pw(blob, password, salt16, m_kib, t, p) -> Vec<u8>`
  - `sync_recovery_code_new() -> String`、`sync_wrap_private_rc(secret, code) -> Vec<u8>`、`sync_unwrap_private_rc(blob, code) -> Vec<u8>`
  - `sync_profile_key_new() -> Vec<u8>`、`sync_seal_to(public, plaintext) -> Vec<u8>`、`sync_open_sealed(secret, blob) -> Vec<u8>`
  - `sync_wrap_with_token(plaintext, token) -> Vec<u8>`、`sync_unwrap_with_token(blob, token) -> Vec<u8>`(邀请用:`kek = HKDF(token)`,复用 `kek_from_recovery` 的做法但 salt 为 `medme-invite-v1`;实现放在 `packages/sync/keys.rs` 加 `kek_from_token(token: &str)`)
  - `sync_open_profile_vault(docs_dir, data_dir, profile_key) -> ()`(与 `open_vault` 同布局但 keyed;不走 iCloud)
  - `sync_local_seq_map() -> Vec<(String, i64)>`、`sync_export_events(profile_key, after: Vec<(String,i64)>) -> Vec<SyncEventDto>`、`sync_import_events(profile_key, Vec<SyncEventDto>) -> u32`
  - `sync_missing_objects(profile_key) -> Vec<(String hash, String object_id)>`、`sync_encrypt_object(profile_key, hash) -> (String object_id, Vec<u8> ciphertext)`、`sync_store_object(profile_key, object_id, ciphertext) -> String hash`
  - `sync_all_object_ids(profile_key) -> Vec<(String hash, String object_id)>`(推送清单)
  - `sync_date_shift_days(profile_key) -> i32`
  - `sync_kdf_bench_ms(m_kib, t, p) -> u64`
  - `SyncEventDto { device_id, seq: i64, event_id, ts, ciphertext: Vec<u8> }`(放 `dto.rs`)

- [ ] **Step 1: 写失败测试**(`vault_sync.rs` 底部,不依赖 FRB 运行时)
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn export_import_round_trip_between_two_devices() {
        let pk = sync_profile_key_new();
        let a = tempdir().unwrap();
        sync_open_profile_vault(a.path().to_string_lossy().into(), a.path().join("data").to_string_lossy().into(), pk.clone()).unwrap();
        crate::api::vault::ingest_bytes("r.txt".into(), b"WBC 5.0".to_vec()).unwrap();
        let events = sync_export_events(pk.clone(), vec![]).unwrap();
        let objs = sync_all_object_ids(pk.clone()).unwrap();
        let (oid, ct) = sync_encrypt_object(pk.clone(), objs[0].0.clone()).unwrap();

        let b = tempdir().unwrap();
        sync_open_profile_vault(b.path().to_string_lossy().into(), b.path().join("data").to_string_lossy().into(), pk.clone()).unwrap();
        assert_eq!(sync_import_events(pk.clone(), events).unwrap(), 2);
        assert_eq!(sync_missing_objects(pk.clone()).unwrap()[0].1, oid);
        let h = sync_store_object(pk.clone(), oid, ct).unwrap();
        assert_eq!(h, objs[0].0);
        assert!(sync_missing_objects(pk).unwrap().is_empty());
    }

    #[test]
    fn kdf_bench_runs() {
        assert!(sync_kdf_bench_ms(8192, 1, 1) < 5_000);
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/mobile_flutter/rust && cargo test vault_sync`
Expected: 编译失败。

- [ ] **Step 3: 实现**

`vault_sync.rs` 要点(全部函数 `sync_` 前缀;`with_state` 与 `vault_cell` 复用 `vault.rs` 的,改成 `pub(crate)`):
```rust
//! 云同步 FRB 面。Rust 只做密码学与本地读写;HTTP 在 Dart(`sync_engine.dart`)。
use crate::api::dto::SyncEventDto;
use crate::api::vault::{machine_device_id, vault_cell, with_state, VaultState};
use core_model::{LogEntry, Vault};
use std::path::PathBuf;

fn key32(v: &[u8]) -> anyhow::Result<[u8; 32]> {
    v.try_into().map_err(|_| anyhow::anyhow!("密钥必须是 32 字节"))
}

pub fn sync_account_keys_new() -> (Vec<u8>, Vec<u8>) {
    let k = sync::account_keys_new();
    (k.public.to_vec(), k.secret.to_vec())
}

pub fn sync_wrap_private(secret: Vec<u8>, password: String, salt: Vec<u8>, m_kib: u32, t: u32, p: u32) -> anyhow::Result<Vec<u8>> {
    let salt: [u8; 16] = salt.try_into().map_err(|_| anyhow::anyhow!("salt 必须 16 字节"))?;
    let kek = sync::kek_from_password(&password, &salt, &sync::KdfParams { m_kib, t, p })?;
    Ok(sync::wrap(&kek, &secret, b"account-priv-v1")?)
}
// sync_unwrap_private_pw / sync_wrap_private_rc / sync_unwrap_private_rc / sync_wrap_with_token /
// sync_unwrap_with_token / sync_seal_to / sync_open_sealed / sync_profile_key_new / sync_recovery_code_new
// 一一映射到 packages/sync,同一 AAD `account-priv-v1`;token 版 AAD `invite-v1`。

pub fn sync_open_profile_vault(docs_dir: String, data_dir: String, profile_key: Vec<u8>) -> anyhow::Result<()> {
    let pk = key32(&profile_key)?;
    let docs = PathBuf::from(docs_dir);
    let data = PathBuf::from(data_dir);
    std::fs::create_dir_all(&docs)?;
    std::fs::create_dir_all(&data)?;
    let device_id = machine_device_id(&data)?;
    let truth = docs.join("vault");
    let db = truth.join("medme.db");
    let vault = Vault::open_split_resilient_with_key(&truth, &db, &device_id, &pk)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let mut guard = vault_cell().lock().unwrap_or_else(|p| p.into_inner());
    *guard = Some(VaultState { vault, truth_root: truth, db_path: db, device_id, docs_dir: docs, data_dir: data, profile_key: Some(pk) });
    Ok(())
}

pub fn sync_local_seq_map() -> anyhow::Result<Vec<(String, i64)>> {
    with_state(|s| Ok(s.vault.device_seq_map().map_err(|e| anyhow::anyhow!(e.to_string()))?.into_iter().collect()))
}

pub fn sync_export_events(profile_key: Vec<u8>, after: Vec<(String, i64)>) -> anyhow::Result<Vec<SyncEventDto>> {
    let pk = key32(&profile_key)?;
    let after: std::collections::HashMap<String, i64> = after.into_iter().collect();
    with_state(|s| {
        let mut out = Vec::new();
        for e in s.vault.log_entries().map_err(|e| anyhow::anyhow!(e.to_string()))? {
            if e.seq <= after.get(&e.device_id).copied().unwrap_or(0) { continue; }
            let plain = serde_json::to_vec(&e)?;
            let ct = sync::encrypt_blob(&pk, &e.event_id, &plain)?;
            out.push(SyncEventDto { device_id: e.device_id.clone(), seq: e.seq, event_id: e.event_id.clone(), ts: e.ts.clone(), ciphertext: ct });
        }
        Ok(out)
    })
}

pub fn sync_import_events(profile_key: Vec<u8>, events: Vec<SyncEventDto>) -> anyhow::Result<u32> {
    let pk = key32(&profile_key)?;
    let mut entries = Vec::with_capacity(events.len());
    for ev in events {
        let plain = sync::decrypt_blob(&pk, &ev.event_id, &ev.ciphertext)?;
        let entry: LogEntry = serde_json::from_slice(&plain)?;
        if entry.event_id != ev.event_id || entry.device_id != ev.device_id || entry.seq != ev.seq {
            anyhow::bail!("事件信封与内容不一致,拒收");
        }
        entries.push(entry);
    }
    with_state(|s| Ok(s.vault.append_peer_entries(&entries).map_err(|e| anyhow::anyhow!(e.to_string()))? as u32))
}

pub fn sync_missing_objects(profile_key: Vec<u8>) -> anyhow::Result<Vec<(String, String)>> {
    let pk = key32(&profile_key)?;
    with_state(|s| Ok(s.vault.missing_object_hashes().map_err(|e| anyhow::anyhow!(e.to_string()))?
        .into_iter().map(|h| { let id = sync::object_id(&pk, &h); (h, id) }).collect()))
}

pub fn sync_all_object_ids(profile_key: Vec<u8>) -> anyhow::Result<Vec<(String, String)>> {
    // 遍历 log 里引用的哈希(与 missing_object_hashes 同源),只留本地存在的
    let pk = key32(&profile_key)?;
    with_state(|s| {
        let mut out = Vec::new();
        for e in s.vault.log_entries().map_err(|e| anyhow::anyhow!(e.to_string()))? {
            let h = match &e.event { core_model::Event::FileImported { content_hash, .. } => content_hash.clone(), core_model::Event::OcrAdded { text_hash, .. } => text_hash.clone(), _ => continue };
            if s.vault.root_join(&core_model::cas::object_relpath(&h)).exists() && !out.iter().any(|(x, _)| x == &h) {
                let id = sync::object_id(&pk, &h);
                out.push((h, id));
            }
        }
        Ok(out)
    })
}

pub fn sync_encrypt_object(profile_key: Vec<u8>, hash: String) -> anyhow::Result<(String, Vec<u8>)> {
    let pk = key32(&profile_key)?;
    with_state(|s| {
        let bytes = s.vault.read_object(&hash).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let id = sync::object_id(&pk, &hash);
        let ct = sync::encrypt_blob(&pk, &id, &bytes)?;
        Ok((id, ct))
    })
}

pub fn sync_store_object(profile_key: Vec<u8>, object_id: String, ciphertext: Vec<u8>) -> anyhow::Result<String> {
    let pk = key32(&profile_key)?;
    let plain = sync::decrypt_blob(&pk, &object_id, &ciphertext)?;
    with_state(|s| {
        let (h, _, _) = s.vault.store_object(&plain).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        if sync::object_id(&pk, &h) != object_id { anyhow::bail!("对象内容与 object_id 不符,已丢弃"); }
        s.vault.materialize().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(h)
    })
}

pub fn sync_date_shift_days(profile_key: Vec<u8>) -> anyhow::Result<i32> {
    Ok(sync::date_shift_days(&key32(&profile_key)?))
}

pub fn sync_kdf_bench_ms(m_kib: u32, t: u32, p: u32) -> u64 {
    let t0 = std::time::Instant::now();
    let _ = sync::kek_from_password("bench", &[0u8; 16], &sync::KdfParams { m_kib, t, p });
    t0.elapsed().as_millis() as u64
}
```
`sync_store_object` 里若 `store_object` 已存在则不重写(它自己会跳过),但 object_id 校验仍执行。

- [ ] **Step 4: 生成绑定并跑测试**

Run: `cd apps/mobile_flutter && flutter_rust_bridge_codegen generate && cd rust && cargo test && cd .. && flutter analyze`
Expected: Rust 测试全绿;`git diff main -- rust/src/frb_generated.rs | grep recognize_image_pp` 为空。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/rust apps/mobile_flutter/lib/src/rust
git commit -m "feat(mobile-rust): sync_* FRB 面——keyed 开箱、事件/对象加解密、密钥封装、KDF 基准"
```

---

### Task 8: Dart `AccountSession` + `ApiClient`(可注入、可 fake)

**Files:**
- Create: `apps/mobile_flutter/lib/account.dart`, `apps/mobile_flutter/lib/api_client.dart`, `apps/mobile_flutter/test/api_client_test.dart`
- Modify: `apps/mobile_flutter/pubspec.yaml`(`flutter_secure_storage: ^9.2.2`, `sign_in_with_apple: ^6.1.3`)

**Interfaces:**
- Produces:
  - `class ApiClient { ApiClient({String? base, Future<String?> Function()? bearer}); Future<Map<String,dynamic>> postJson(String path, Object body); Future<dynamic> getJson(String path, {Map<String,String>? query}); Future<void> putBytes(String url, Uint8List bytes); Future<Uint8List> getBytes(String url); }`(走 `Net`;401 时抛 `ApiUnauthorized`;其它非 2xx 抛 `ApiFailed(status, message)`;基址 `String.fromEnvironment('MEDME_API_BASE', defaultValue: 'https://api.medmenow.com')`)
  - `class AccountSession`(单例 `instance`):`Future<void> ensureLoaded()`、`String? accountId`、`String? access`、`String? refresh`、`Uint8List? privateKey`、`Uint8List? publicKey`、`Future<void> save({...})`、`Future<void> clear()`、`Future<Uint8List?> profileKey(String cloudId)`、`Future<void> putProfileKey(String cloudId, Uint8List key)`、`ValueNotifier<bool> loggedIn`
  - 存储:token/id 在 `shared_preferences`;私钥与档案密钥在 `flutter_secure_storage`(iOS `synchronizable: true` 让 iCloud 钥匙串同步,安卓 `encryptedSharedPreferences: true`)

- [ ] **Step 1: 写失败测试**(`test/api_client_test.dart`,用本地 `HttpServer`,与 `claim_upload_test.dart` 同套路)
```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/api_client.dart';

void main() {
  late HttpServer server;
  late ApiClient api;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = ApiClient(base: 'http://127.0.0.1:${server.port}', bearer: () async => 'tok');
    server.listen((req) async {
      final auth = req.headers.value('authorization');
      if (req.uri.path == '/v1/echo') {
        final body = await utf8.decodeStream(req);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'auth': auth, 'got': jsonDecode(body)}));
      } else if (req.uri.path == '/v1/nope') {
        req.response.statusCode = 401;
        req.response.write('{"detail":"expired"}');
      } else {
        req.response.statusCode = 500;
        req.response.write('{"detail":"boom"}');
      }
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('带 Bearer、发 JSON、解 JSON', () async {
    final r = await api.postJson('/v1/echo', {'a': 1});
    expect(r['auth'], 'Bearer tok');
    expect(r['got'], {'a': 1});
  });

  test('401 抛 ApiUnauthorized,其它抛 ApiFailed 带 detail', () async {
    expect(() => api.getJson('/v1/nope'), throwsA(isA<ApiUnauthorized>()));
    expect(() => api.getJson('/v1/other'), throwsA(predicate((e) => e is ApiFailed && e.status == 500 && e.message == 'boom')));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/mobile_flutter && flutter test test/api_client_test.dart`
Expected: 编译错误(文件不存在)。

- [ ] **Step 3: 实现**

`lib/api_client.dart`:
```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:mobile_flutter/net.dart';

class ApiUnauthorized implements Exception {
  const ApiUnauthorized();
}

class ApiFailed implements Exception {
  const ApiFailed(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => '服务器返回 $status:$message';
}

/// 账号 API 的唯一出口。所有请求走 [Net](有读超时);token 由 [bearer] 回调提供,
/// 于是测试里注入假服务器 + 假 token 即可,不碰 secure storage。
class ApiClient {
  ApiClient({String? base, Future<String?> Function()? bearer})
      : base = base ?? defaultBase,
        _bearer = bearer;

  static const defaultBase = String.fromEnvironment('MEDME_API_BASE', defaultValue: 'https://api.medmenow.com');
  final String base;
  final Future<String?> Function()? _bearer;

  Future<dynamic> _json(String method, String path, {Object? body, Map<String, String>? query}) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    return Net.run((client) async {
      final req = await client.openUrl(method, uri);
      final tok = await _bearer?.call();
      if (tok != null) req.headers.set('authorization', 'Bearer $tok');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        await Net.flush(req);
      }
      final res = await Net.send(req);
      final text = await Net.text(res);
      if (res.statusCode == 401) throw const ApiUnauthorized();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = text;
        try { msg = (jsonDecode(text) as Map)['detail']?.toString() ?? text; } catch (_) {}
        throw ApiFailed(res.statusCode, msg);
      }
      return text.isEmpty ? null : jsonDecode(text);
    });
  }

  Future<Map<String, dynamic>> postJson(String path, Object body) async => (await _json('POST', path, body: body)) as Map<String, dynamic>;
  Future<dynamic> getJson(String path, {Map<String, String>? query}) => _json('GET', path, query: query);
  Future<Map<String, dynamic>> putJson(String path, Object body) async => (await _json('PUT', path, body: body)) as Map<String, dynamic>;
  Future<void> delete(String path) => _json('DELETE', path);

  /// 直传 OSS 预签名地址(不带 Bearer)。Content-Type 必须与签名一致。
  Future<void> putBytes(String url, Uint8List bytes) => Net.run((client) async {
        final req = await client.putUrl(Uri.parse(url));
        req.headers.set('content-type', 'application/octet-stream');
        req.contentLength = bytes.length;
        req.add(bytes);
        await Net.flush(req, timeout: const Duration(seconds: 90));
        final res = await Net.send(req, timeout: const Duration(seconds: 90));
        await Net.drain(res);
        if (res.statusCode != 200) throw ApiFailed(res.statusCode, 'upload');
      });

  Future<Uint8List> getBytes(String url) => Net.run((client) async {
        final res = await Net.send(await client.getUrl(Uri.parse(url)));
        if (res.statusCode != 200) { await Net.drain(res); throw ApiFailed(res.statusCode, 'download'); }
        return Net.bytes(res);
      });
}
```

`lib/account.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 账号会话 + 密钥的本机存储。**私钥与档案密钥只进 secure storage**(iOS Keychain
/// 开 synchronizable = 同一 Apple ID 新机自动拿回,这就是「系统钥匙串」那条换机路;
/// 安卓用 EncryptedSharedPreferences,不跨机)。token 与 id 在 shared_preferences。
class AccountSession {
  AccountSession._();
  static final AccountSession instance = AccountSession._();

  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(synchronizable: true, accessibility: KeychainAccessibility.first_unlock),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final ValueNotifier<bool> loggedIn = ValueNotifier<bool>(false);
  String? accountId;
  String? access;
  String? refresh;
  Uint8List? publicKey;
  Uint8List? privateKey;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    accountId = p.getString('acct_id');
    access = p.getString('acct_access');
    refresh = p.getString('acct_refresh');
    final pk = await _secure.read(key: 'acct_priv');
    privateKey = pk == null ? null : base64Decode(pk);
    final pub = p.getString('acct_pub');
    publicKey = pub == null ? null : base64Decode(pub);
    _loaded = true;
    loggedIn.value = accountId != null && access != null;
  }

  Future<void> save({required String accountId, required String access, required String refresh, Uint8List? publicKey, Uint8List? privateKey}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('acct_id', accountId);
    await p.setString('acct_access', access);
    await p.setString('acct_refresh', refresh);
    if (publicKey != null) await p.setString('acct_pub', base64Encode(publicKey));
    if (privateKey != null) await _secure.write(key: 'acct_priv', value: base64Encode(privateKey));
    this.accountId = accountId; this.access = access; this.refresh = refresh;
    if (publicKey != null) this.publicKey = publicKey;
    if (privateKey != null) this.privateKey = privateKey;
    loggedIn.value = true;
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in ['acct_id', 'acct_access', 'acct_refresh', 'acct_pub']) { await p.remove(k); }
    await _secure.delete(key: 'acct_priv');
    accountId = access = refresh = null; publicKey = privateKey = null;
    loggedIn.value = false;
  }

  Future<Uint8List?> profileKey(String cloudId) async {
    final v = await _secure.read(key: 'pk_$cloudId');
    return v == null ? null : base64Decode(v);
  }

  Future<void> putProfileKey(String cloudId, Uint8List key) => _secure.write(key: 'pk_$cloudId', value: base64Encode(key));
}
```

- [ ] **Step 4: 跑测试**

Run: `cd apps/mobile_flutter && flutter pub get && flutter test test/api_client_test.dart && flutter analyze`
Expected: 2 passed,analyze 无 error。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/pubspec.yaml apps/mobile_flutter/pubspec.lock apps/mobile_flutter/lib/account.dart apps/mobile_flutter/lib/api_client.dart apps/mobile_flutter/test/api_client_test.dart
git commit -m "feat(mobile): ApiClient(可注入)+ AccountSession(私钥进钥匙串,iOS 同步)"
```

---

### Task 9: 账号屏:登录 / 注册(口令 + 恢复码确认)/ 设备 / 授权列表,三态

**Files:**
- Create: `apps/mobile_flutter/lib/account_flow.dart`(纯逻辑:注册/登录/恢复的编排,不含 UI)、`apps/mobile_flutter/lib/screens/account_screen.dart`、`apps/mobile_flutter/test/account_screen_test.dart`
- Modify: `apps/mobile_flutter/lib/screens/settings_screen.dart`(「保险箱」节之前加 `_SectionLabel('账号')` + 一行进入 `AccountScreen`)

**Interfaces:**
- Consumes: Task 7 `sync*` 绑定、Task 8 `ApiClient/AccountSession`
- Produces:
  - `class AccountFlow { AccountFlow(this.api, this.session, {this.crypto = const RustCrypto()}); Future<void> sendOtp(String phone); Future<LoginOutcome> loginOtp(String phone, String code); Future<String> registerKeys(String password) /* 返回恢复码 */; Future<void> unlockWithPassword(String password); Future<void> unlockWithRecovery(String code); Future<void> loginApple(); }`
  - `enum LoginOutcome { needsKeySetup, needsUnlock, ready }`(服务端 `GET /v1/account/keys` 404 → needsKeySetup;有 keys 且本机无私钥 → needsUnlock)
  - `abstract class SyncCrypto`(包一层 `sync*` FRB 调用,测试可 fake):`accountKeysNew()`, `wrapPrivate(...)`, `unwrapPrivatePw(...)`, `recoveryCodeNew()`, `wrapPrivateRc(...)`, `unwrapPrivateRc(...)`;`RustCrypto` 是真实实现
  - `AccountScreen`:四个区块(状态、登录、设备、授权),每个异步动作都有加载中/成功/失败三态

- [ ] **Step 1: 写失败测试**(`test/account_screen_test.dart`:fake `ApiClient` 子类 + fake `SyncCrypto`)
```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/account_flow.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/screens/account_screen.dart';

class FakeApi extends ApiClient {
  FakeApi({this.failLogin = false, this.hasKeys = false}) : super(base: 'http://x');
  final bool failLogin;
  final bool hasKeys;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> postJson(String path, Object body) async {
    calls.add('POST $path');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (path == '/v1/auth/login' && failLogin) throw const ApiFailed(401, 'bad code');
    if (path == '/v1/auth/login') return {'account_id': 'acc_1', 'access': 'a', 'refresh': 'r'};
    return {'ok': true};
  }
  @override
  Future<dynamic> getJson(String path, {Map<String, String>? query}) async {
    calls.add('GET $path');
    if (path == '/v1/account/keys') { if (!hasKeys) throw const ApiFailed(404, 'no keys'); return {'public_key': 'AA==', 'wrapped_priv_pw': 'AA==', 'wrapped_priv_rc': 'AA==', 'kdf_salt': 'AA==', 'kdf_params': {'m_kib': 8, 't': 1, 'p': 1}}; }
    return [];
  }
  @override
  Future<Map<String, dynamic>> putJson(String path, Object body) async { calls.add('PUT $path'); return {'ok': true}; }
}

class FakeCrypto implements SyncCrypto {
  @override Future<(Uint8List, Uint8List)> accountKeysNew() async => (Uint8List(32), Uint8List(32));
  @override Future<Uint8List> wrapPrivate(Uint8List s, String pw, Uint8List salt, int m, int t, int p) async => Uint8List(40);
  @override Future<Uint8List> unwrapPrivatePw(Uint8List b, String pw, Uint8List salt, int m, int t, int p) async { if (pw != 'right') throw Exception('crypto'); return Uint8List(32); }
  @override Future<String> recoveryCodeNew() async => 'ABCD-EFGH-JKMN-PQRS-TVWX';
  @override Future<Uint8List> wrapPrivateRc(Uint8List s, String code) async => Uint8List(40);
  @override Future<Uint8List> unwrapPrivateRc(Uint8List b, String code) async => Uint8List(32);
}

Widget _app(FakeApi api) => MaterialApp(home: AccountScreen(flow: AccountFlow(api, AccountSession.instance, crypto: FakeCrypto())));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('登录:加载中 → 进入设口令 → 展示恢复码并要求确认', (t) async {
    final api = FakeApi();
    await t.pumpWidget(_app(api));
    await t.enterText(find.byKey(const Key('phone')), '13800000001');
    await t.tap(find.text('发送验证码'));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);   // 加载中
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('code')), '000000');
    await t.tap(find.text('登录'));
    await t.pumpAndSettle();
    expect(find.text('设置口令'), findsOneWidget);                         // needsKeySetup
    await t.enterText(find.byKey(const Key('password')), 'right');
    await t.tap(find.text('生成密钥'));
    await t.pumpAndSettle();
    expect(find.text('ABCD-EFGH-JKMN-PQRS-TVWX'), findsOneWidget);       // 恢复码
    expect(find.text('我已抄下恢复码'), findsOneWidget);
    expect(api.calls, contains('PUT /v1/account/keys'));
  });

  testWidgets('登录失败显示错误且可重试', (t) async {
    final api = FakeApi(failLogin: true);
    await t.pumpWidget(_app(api));
    await t.enterText(find.byKey(const Key('phone')), '13800000001');
    await t.tap(find.text('发送验证码'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('code')), '111111');
    await t.tap(find.text('登录'));
    await t.pumpAndSettle();
    expect(find.textContaining('bad code'), findsOneWidget);              // 失败态
    expect(find.text('登录'), findsOneWidget);                              // 可重试
  });

  testWidgets('已有密钥、本机无私钥 → 解锁;口令错报错', (t) async {
    final api = FakeApi(hasKeys: true);
    await t.pumpWidget(_app(api));
    await t.enterText(find.byKey(const Key('phone')), '13800000001');
    await t.tap(find.text('发送验证码'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('code')), '000000');
    await t.tap(find.text('登录'));
    await t.pumpAndSettle();
    expect(find.text('输入口令解锁'), findsOneWidget);
    await t.enterText(find.byKey(const Key('password')), 'wrong');
    await t.tap(find.text('解锁'));
    await t.pumpAndSettle();
    expect(find.textContaining('口令不对'), findsOneWidget);
  });
}
```
(测试里 `AccountSession` 用 `SharedPreferences.setMockInitialValues({})` + `FlutterSecureStorage.setMockInitialValues({})` 在 `setUp` 里初始化。)

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/mobile_flutter && flutter test test/account_screen_test.dart`
Expected: 编译错误。

- [ ] **Step 3: 实现**

`lib/account_flow.dart` 核心(其余 wrapper 一一对应):
```dart
enum LoginOutcome { needsKeySetup, needsUnlock, ready }

abstract class SyncCrypto { /* 见 Interfaces */ }

class RustCrypto implements SyncCrypto {
  const RustCrypto();
  @override Future<(Uint8List, Uint8List)> accountKeysNew() async { final (p, s) = await rust.syncAccountKeysNew(); return (Uint8List.fromList(p), Uint8List.fromList(s)); }
  // …其余直接转调 rust.syncWrapPrivate / syncUnwrapPrivatePw / syncRecoveryCodeNew / syncWrapPrivateRc / syncUnwrapPrivateRc
}

class AccountFlow {
  AccountFlow(this.api, this.session, {this.crypto = const RustCrypto()});
  final ApiClient api; final AccountSession session; final SyncCrypto crypto;
  static const kdf = (mKib: 65536, t: 3, p: 1);   // Task 14 实测后改这里一处

  Future<void> sendOtp(String phone) => api.postJson('/v1/auth/otp', {'phone': phone});

  Future<LoginOutcome> loginOtp(String phone, String code) async {
    final r = await api.postJson('/v1/auth/login', {'phone': phone, 'code': code, 'device_id': await deviceId(), 'device_name': Platform.operatingSystem});
    await session.save(accountId: r['account_id'] as String, access: r['access'] as String, refresh: r['refresh'] as String);
    return _afterLogin();
  }

  Future<LoginOutcome> _afterLogin() async {
    try {
      final k = await api.getJson('/v1/account/keys') as Map<String, dynamic>;
      _serverKeys = k;
      return session.privateKey == null ? LoginOutcome.needsUnlock : LoginOutcome.ready;
    } on ApiFailed catch (e) {
      if (e.status == 404) return LoginOutcome.needsKeySetup;
      rethrow;
    }
  }

  /// 首次:生成密钥对、口令包一份、恢复码包一份,上传;返回恢复码给 UI 展示。
  Future<String> registerKeys(String password) async {
    final (pub, sec) = await crypto.accountKeysNew();
    final salt = Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)));
    final pw = await crypto.wrapPrivate(sec, password, salt, kdf.mKib, kdf.t, kdf.p);
    final code = await crypto.recoveryCodeNew();
    final rc = await crypto.wrapPrivateRc(sec, code);
    await api.putJson('/v1/account/keys', {'public_key': base64Encode(pub), 'wrapped_priv_pw': base64Encode(pw), 'wrapped_priv_rc': base64Encode(rc),
        'kdf_salt': base64Encode(salt), 'kdf_params': {'m_kib': kdf.mKib, 't': kdf.t, 'p': kdf.p}});
    await session.save(accountId: session.accountId!, access: session.access!, refresh: session.refresh!, publicKey: pub, privateKey: sec);
    return code;
  }

  Future<void> unlockWithPassword(String password) async {
    final k = _serverKeys!; final p = k['kdf_params'] as Map;
    try {
      final sec = await crypto.unwrapPrivatePw(base64Decode(k['wrapped_priv_pw']), password, base64Decode(k['kdf_salt']), p['m_kib'], p['t'], p['p']);
      await session.save(accountId: session.accountId!, access: session.access!, refresh: session.refresh!, publicKey: base64Decode(k['public_key']), privateKey: sec);
    } catch (_) { throw const UnlockFailed('口令不对'); }
  }
  // unlockWithRecovery 同上换 unwrapPrivateRc;loginApple 用 sign_in_with_apple 拿 identityToken → POST /v1/auth/apple → _afterLogin。
}
```
`screens/account_screen.dart`:`StatefulWidget`,内部 `_Phase { idle, otpSent, keySetup, showRecovery, unlock, ready }` + `_busy` + `_error`;每个按钮 `onPressed: _busy ? null : …`,`_busy` 时按钮位置放 `CircularProgressIndicator`;`_error != null` 时红字 + 原按钮保留。ready 态展示 `GET /v1/devices` 列表(待批准设备有「批准」按钮 → `sync_seal_to(eph_public, privateKey)` → `POST /v1/devices/approve`)与 `GET /v1/profiles` 的授权列表(owner 行可「撤销」)。「恢复码」页必须点「我已抄下恢复码」才能离开。

设置页:在 `_SectionLabel('保险箱')` 之前插入 `_SectionLabel('账号')` + `_SettingsRow(icon: Icons.person_outline, title: loggedIn ? '已登录' : '登录 / 注册', subtitle: '换机恢复、家人共享、云端识别', onTap: → AccountScreen())`。

- [ ] **Step 4: 跑测试**

Run: `cd apps/mobile_flutter && flutter test test/account_screen_test.dart && flutter analyze`
Expected: 3 passed。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/lib/account_flow.dart apps/mobile_flutter/lib/screens/account_screen.dart apps/mobile_flutter/lib/screens/settings_screen.dart apps/mobile_flutter/test/account_screen_test.dart
git commit -m "feat(mobile): 账号屏——手机号登录、口令+恢复码建密钥、解锁、设备批准、授权列表(三态)"
```

---

### Task 10: 档案上云 + `SyncEngine`(推拉事件、按需对象、keyed 开箱)

**Files:**
- Create: `apps/mobile_flutter/lib/sync_engine.dart`, `apps/mobile_flutter/test/sync_engine_test.dart`
- Modify: `apps/mobile_flutter/lib/profile_manager.dart`(`Profile` 增 `cloudId`, `role`, `expiresAt`;`toJson/fromJson`;`markCloud(id, cloudId, role, expiresAt)`)、`apps/mobile_flutter/lib/vault_boot.dart`(`openCurrentProfileVault`:档案有 `cloudId` 且能取到档案密钥 → `syncOpenProfileVault`,否则原路径不变)

**Interfaces:**
- Consumes: Task 7、8
- Produces:
  - `class SyncEngine { SyncEngine(this.api, this.session, {this.rust = const RustSync()}); Future<String> enableCloud(Profile p) /* 建档案密钥、封给自己公钥、POST /v1/profiles、存密钥、markCloud、返回 cloudId */; Future<SyncReport> syncProfile(Profile p) /* push events since server watermark, pull events since local watermark, push local objects not on server, pull missing objects */; Future<void> fetchObject(Profile p, String hash) }`
  - `class SyncReport { int pushed, pulled, objectsUp, objectsDown; }`
  - `abstract class RustSyncApi`(包 `sync*` FRB;测试 fake)
  - 触发点:`vaultRevision` 变化后 debounce 2 s 推一次;App 回前台拉一次;账号屏「立即同步」

- [ ] **Step 1: 写失败测试**(fake api 记录请求;fake rust 返回固定事件)
```dart
test('首次同步:推本地事件与对象,拉回缺的', () async {
  final api = RecordingApi(server: {'events': [], 'objects': []});
  final rust = FakeRust(localEvents: [SyncEventDto(deviceId: 'd1', seq: 1, eventId: 'e1', ts: 't', ciphertext: Uint8List(3))], localObjects: [('h1', 'o1')], missing: []);
  final engine = SyncEngine(api, session, rust: rust);
  final rep = await engine.syncProfile(Profile(id: 'p-1', name: 'x', cloudId: 'prf_1', role: 'owner'));
  expect(rep.pushed, 1); expect(rep.objectsUp, 1);
  expect(api.calls, containsAll(['GET /v1/profiles/prf_1/events', 'POST /v1/profiles/prf_1/events', 'POST /v1/profiles/prf_1/objects/sign', 'PUT <presigned>']));
});

test('viewer 不推只拉', () async { /* role: 'viewer' → 无 POST events / sign PUT */ });

test('服务端已有的对象不重传;缺的对象拉回并 store', () async { /* server objects ['o1'] → objectsUp 0; missing [('h2','o2')] → GET sign + getBytes + syncStoreObject 调用 */ });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/mobile_flutter && flutter test test/sync_engine_test.dart`
Expected: 编译错误。

- [ ] **Step 3: 实现**

`sync_engine.dart` 核心:
```dart
Future<SyncReport> syncProfile(Profile p) async {
  final cloudId = p.cloudId!;
  final key = await session.profileKey(cloudId);
  if (key == null) throw StateError('没有这个档案的密钥');
  final rep = SyncReport();
  final canWrite = p.role == 'owner' || p.role == 'editor';

  // 1. 拉:本机水位 → 服务端只给新的
  final local = Map<String, int>.fromEntries((await rust.localSeqMap()).map((e) => MapEntry(e.$1, e.$2.toInt())));
  final pulled = (await api.getJson('/v1/profiles/$cloudId/events', query: {'since': jsonEncode(local)}) as List)
      .map((e) => SyncEventDto(deviceId: e['device_id'], seq: e['seq'], eventId: e['event_id'], ts: e['ts'], ciphertext: base64Decode(e['ciphertext']))).toList();
  if (pulled.isNotEmpty) rep.pulled = (await rust.importEvents(key, pulled)).toInt();

  // 2. 推:服务端水位 = 拉回来之后服务端已有的最大 seq(用同一份 since 反推:凡本机有而服务端没给的就是要推的)
  if (canWrite) {
    final serverHas = <String, int>{...local};
    for (final e in pulled) { serverHas[e.deviceId] = max(serverHas[e.deviceId] ?? 0, e.seq.toInt()); }
    // 本机自己设备段的条目服务端可能还没有:用 server 返回的 objects/events 清单无法逐条知道,所以推「本机水位之上」的做法不成立——
    // 改为:服务端提供本 profile 各 device 的最大 seq(GET /v1/profiles/{id}/events 响应头 X-Seq-Map),推 seq 大于它的。
    final toPush = await rust.exportEvents(key, serverHas.entries.map((e) => (e.key, e.value)).toList());
    if (toPush.isNotEmpty) {
      await api.postJson('/v1/profiles/$cloudId/events', toPush.map((e) => {'device_id': e.deviceId, 'seq': e.seq, 'event_id': e.eventId, 'ts': e.ts, 'ciphertext': base64Encode(e.ciphertext)}).toList());
      rep.pushed = toPush.length;
    }
    // 3. 对象上行:服务端没有的
    final serverObjs = ((await api.getJson('/v1/profiles/$cloudId/objects')) as List).cast<String>().toSet();
    for (final (hash, oid) in await rust.allObjectIds(key)) {
      if (serverObjs.contains(oid)) continue;
      final (_, ct) = await rust.encryptObject(key, hash);
      final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {'object_id': oid, 'verb': 'PUT', 'size': ct.length});
      await api.putBytes(s['url'] as String, ct);
      rep.objectsUp++;
    }
  }
  // 4. 对象下行:事件引用了、本机没有的
  for (final (_, oid) in await rust.missingObjects(key)) {
    final s = await api.postJson('/v1/profiles/$cloudId/objects/sign', {'object_id': oid, 'verb': 'GET'});
    await rust.storeObject(key, oid, await api.getBytes(s['url'] as String));
    rep.objectsDown++;
  }
  bumpVaultRevision();
  return rep;
}
```
**注意上面第 2 步的注释暴露的一个坑:** 推送水位不能从 `since` 反推。修正为:服务端 `GET /v1/profiles/{id}/events` 额外返回 `X-Seq-Map: {"dev":seq,…}`(该 profile 每个 device 当前最大 seq,`db.events_pull` 顺带算);客户端用它作为 `exportEvents(after)`。**Task 6 的 `events_pull` 路由要补这个响应头,本任务一并改并在 `test_api.py` 断言。** `ApiClient.getJson` 需要能拿到响应头 → 加 `Future<(dynamic, Map<String,String>)> getJsonWithHeaders(...)`。

`enableCloud(p)`:`key = syncProfileKeyNew()` → `wrapped = syncSealTo(session.publicKey, key)` → `POST /v1/profiles` → `session.putProfileKey(cloudId, key)` → `ProfileManager.markCloud(p.id, cloudId, 'owner', null)` → 重开箱(keyed)→ `syncProfile`。

`vault_boot.dart`:
```dart
Future<void> openCurrentProfileVault() => _serializedOpen(() async {
  await ProfileManager.instance.ensureLoaded();
  final p = ProfileManager.instance.current;
  final docsRoot = (await getApplicationDocumentsDirectory()).path;
  final support = (await getApplicationSupportDirectory()).path;
  final key = p.cloudId == null ? null : await AccountSession.instance.profileKey(p.cloudId!);
  if (key != null) {
    // 云档案:keyed 开箱,不走 iCloud 容器(两套同步不叠加)
    await syncOpenProfileVault(docsDir: ProfileManager.instance.localBase(docsRoot), dataDir: support, profileKey: key);
    return;
  }
  final containerRoot = await IcloudBridge.containerPath();   // ← 原路径,一字不改
  await openVault(docsDir: ProfileManager.instance.localBase(docsRoot), dataDir: support, icloudContainerDir: ProfileManager.instance.containerBase(containerRoot));
});
```

- [ ] **Step 4: 跑测试**

Run: `cd apps/mobile_flutter && flutter test && flutter analyze && cd ../../services/api && DATABASE_URL=postgresql://postgres@localhost:5435/medme_api_test python3 -m pytest -q`
Expected: 全绿(含 `X-Seq-Map` 新断言)。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/lib/sync_engine.dart apps/mobile_flutter/lib/profile_manager.dart apps/mobile_flutter/lib/vault_boot.dart apps/mobile_flutter/lib/api_client.dart apps/mobile_flutter/test/sync_engine_test.dart services/api
git commit -m "feat(mobile): SyncEngine——事件推拉按水位、对象按需上下行、云档案 keyed 开箱;本地档案路径不变"
```

---

### Task 11: 授权落地:家属(手机号)、医生(15 天邀请二维码 + 深链兑换)、切换器合并、过期清理、代拍转移

**Files:**
- Create: `apps/mobile_flutter/lib/grant_link.dart`, `apps/mobile_flutter/lib/grants.dart`, `apps/mobile_flutter/test/grant_link_test.dart`, `apps/mobile_flutter/test/grants_test.dart`
- Modify: `apps/mobile_flutter/lib/main.dart`(`_dispatch` 先试 `GrantLink.tryParse`)、`apps/mobile_flutter/lib/widgets/member_switcher.dart`(列表 = 本机档案 + 被授权档案;viewer 行显示「至 M 月 D 日」)、`apps/mobile_flutter/lib/screens/qr_share_screen.dart`(登录且档案上云时,二维码内容 = 授权链接而不是密文上传)、`apps/mobile_flutter/lib/screens/doctor/doctor_claim_link_dialog.dart`(登录时交付 = `role=owner` 邀请链接,即转移)

**Interfaces:**
- Produces:
  - `class GrantLink { final String inviteId; final String token; static GrantLink? tryParse(Uri); String toUrl() /* https://medmenow.com/claim/#g1.<inviteId>.<token> */ }`(与 `ClaimLink` 同一 `pageUrl`、同一 id 正则;`g1.` 前缀)
  - `class Grants { Grants(this.api, this.session, this.rust); Future<GrantLink> inviteDoctor(Profile p) /* role viewer, days 15, invite_ttl_s 600 */; Future<GrantLink> inviteTransfer(Profile p) /* role owner, ttl 15 天 */; Future<Profile> redeem(GrantLink l) /* POST redeem → unwrap_with_token → seal_to 自己公钥 → PUT grants/{gid}/key → putProfileKey → ProfileManager.markCloud(new local profile) */; Future<void> grantFamilyByPhone(Profile p, String phone) /* lookup → seal_to 对方公钥 → POST grants editor 永久 */; Future<void> revoke(Profile p, String grantId); Future<int> purgeExpired() /* 本机被授权档案 expiresAt < now → 删本地目录 + ProfileManager.remove */ }`
  - `static const grantDoctorDays = 15;`

- [ ] **Step 1: 写失败测试**
```dart
// grant_link_test.dart:与 claim_link_test 同形,g1 前缀;非法 token 字符返回 null;toUrl 回环。
// grants_test.dart(fake api / fake rust):
test('inviteDoctor 发 viewer/15 天/600 秒 的邀请,链接含 inviteId 与 token', () async { … expect(api.lastBody['role'], 'viewer'); expect(api.lastBody['days'], 15); … });
test('redeem 解 token 包、封给自己公钥回填、建本地档案并存密钥', () async { … expect(api.calls, contains('PUT /v1/profiles/prf_9/grants/grt_1/key')); expect(await session.profileKey('prf_9'), isNotNull); expect(ProfileManager.instance.profiles.any((p) => p.cloudId == 'prf_9' && p.role == 'viewer'), isTrue); });
test('purgeExpired 删过期的被授权档案', () async { … });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/mobile_flutter && flutter test test/grant_link_test.dart test/grants_test.dart`
Expected: 编译错误。

- [ ] **Step 3: 实现**

`grants.dart` 关键路径:
```dart
Future<GrantLink> _invite(Profile p, {required String role, int? days, required int ttlS}) async {
  final key = (await session.profileKey(p.cloudId!))!;
  final token = base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
  final wrapped = await rust.wrapWithToken(key, token);
  final r = await api.postJson('/v1/profiles/${p.cloudId}/invites', {
    'role': role, 'days': days, 'token_hash': sha256Hex(token), 'wrapped_key_by_token': base64Encode(wrapped), 'invite_ttl_s': ttlS,
  });
  return GrantLink(inviteId: r['invite_id'] as String, token: token);
}
Future<GrantLink> inviteDoctor(Profile p) => _invite(p, role: 'viewer', days: grantDoctorDays, ttlS: 600);
Future<GrantLink> inviteTransfer(Profile p) => _invite(p, role: 'owner', days: null, ttlS: 15 * 86400);

Future<Profile> redeem(GrantLink l) async {
  final r = await api.postJson('/v1/invites/redeem', {'invite_id': l.inviteId, 'token': l.token});
  final key = await rust.unwrapWithToken(base64Decode(r['wrapped_key_by_token']), l.token);
  final mine = await rust.sealTo(session.publicKey!, key);
  await api.putJson('/v1/profiles/${r['profile_id']}/grants/${r['grant_id']}/key', {'wrapped_profile_key': base64Encode(mine)});
  await session.putProfileKey(r['profile_id'], key);
  final localId = await ProfileManager.instance.create('(同步中)', userManaged: false);
  await ProfileManager.instance.markCloud(localId!, r['profile_id'], r['role'], r['expires_at'] == null ? null : DateTime.parse(r['expires_at']));
  await openCurrentProfileVault();
  await SyncEngine(api, session).syncProfile(ProfileManager.instance.current);
  await autoNameCurrentProfileFrom((await patientProfile()).name);   // 拉完事件后用识别到的姓名命名
  return ProfileManager.instance.current;
}
```
`sha256Hex` 用 `package:crypto`(Flutter SDK 自带传递依赖;若 `flutter pub deps` 没有,加 `crypto: ^3.0.3`)。

`main.dart._dispatch`:
```dart
final g = GrantLink.tryParse(uri);
if (g != null) { WidgetsBinding.instance.addPostFrameCallback((_) async { if (!await FirstRunConsent.hasAgreed()) { _pendingGrant = (g, cold); return; } pushGrantRedeem(g); }); return true; }
```
`pushGrantRedeem` 推一个简单确认屏:「要把 X 的病历加进你的 MedMe 吗?(只读,15 天)」→ 未登录先进 `AccountScreen` → `Grants.redeem` 三态。

`qr_share_screen.dart`:`initState` 里若 `AccountSession.instance.loggedIn.value && profile.cloudId != null` → `_url = (await Grants(...).inviteDoctor(profile)).toUrl()`,跳过密文上传;否则原路径。二维码下方文案改「医生扫码后 15 天内可在自己的 MedMe 里查看」。

`doctor_claim_link_dialog.dart`:登录且代拍档案已 `enableCloud` 时,认领链接 = `inviteTransfer(...)`.toUrl();否则原瞬时云路径。

`member_switcher.dart`:`members` 不变(被授权档案 `redeem` 时已 `create` 进 `ProfileManager`),只在 `ListTile.subtitle` 对 `role == 'viewer'` 显示 `'只读 · 至 ${expiresAt.month}月${expiresAt.day}日'`;`showMemberSwitcherSheet` 开头 `await Grants(...).purgeExpired()`。

- [ ] **Step 4: 跑测试**

Run: `cd apps/mobile_flutter && flutter test && flutter analyze`
Expected: 全绿。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/lib apps/mobile_flutter/test
git commit -m "feat(mobile): 授权落地——家属按手机号、医生 15 天邀请二维码经深链兑换、代拍即转移、过期自动消失"
```

---

### Task 12: 埋点:四个新事件 + 目录

**Files:**
- Modify: `apps/mobile_flutter/lib/analytics.dart`(枚举)、`docs/analytics-catalog.md`(第四节标题条数 27 → 31,新表「账号与同步」)、埋点调用点:`account_flow.dart`、`sync_engine.dart`、`grants.dart`

**Interfaces:**
- Produces:`accountLogin('account_login', {'method','ok'})`、`syncRun('sync_run', {'ok','pushed_bucket','pulled_bucket'})`、`grantCreated('grant_created', {'role'})`、`grantRedeemed('grant_redeemed', {'role','ok'})`。`method ∈ otp/apple`;bucket 用 `Bucket.count`。**不带任何 id、手机号、档案名。**

- [ ] **Step 1: 先改目录,跑 `flutter test test/analytics_catalog_test.dart` 看它红**(缺枚举)
- [ ] **Step 2: 加枚举 + 调用点(登录成功/失败、每次 `syncProfile` 结束、`_invite`、`redeem`)**
- [ ] **Step 3: `flutter test test/analytics_catalog_test.dart test/analytics_test.dart`** → 绿
- [ ] **Step 4: Commit**

```bash
git add apps/mobile_flutter/lib docs/analytics-catalog.md
git commit -m "feat(analytics): 账号登录/同步/授权四个行为事件,目录同步"
```

---

### Task 13: 隐私政策 + 官网话术(gh-pages worktree)

**Files:**
- Modify: `../Medme-ghpages/privacy.html`(第一节「没有账号」段、第二节 OCR 段、第 3 项云同步、第四节第三方表)、`../Medme-ghpages/index.html`(「零服务器」相关句)

**Interfaces:** 无代码接口;**对外文案须由独立 subagent 逐条核到 `file:line`(CLAUDE.md 硬规矩 3)后再 push。**

- [ ] **Step 1: 改 `privacy.html`**
  - 首段 `<meta description>` 与「MedMe 没有账号、没有注册」改为:「MedMe 默认不需要账号。**登录是可选的**:登录后你的病历会以你手机上加密后的形式备份到我们的云端,用于换机恢复与家人共享;**解密密钥只从你的口令或恢复码派生,我们没有,忘了口令且丢了恢复码,数据无法找回。**」
  - 新增一节「三、云端识别(可选)」:「开启云端识别后,手机会先抹去姓名、证件号、病历号、条码、医生姓名、医院名等身份信息,再把脱敏后的内容发送到位于中国境内的大模型服务(DeepSeek)进行结构化识别;结果回到手机后同样加密保存。**脱敏不可能做到 100%**;不开启时识别完全在手机上完成。」
  - 「账号与授权」一节:存的字段(手机号哈希、公钥、两份包好的私钥、设备名、用量);授权的真实语义:「撤销授权后对方**不再能获取新内容**;撤销前已下载到对方设备的内容我们无法收回。」医生授权 15 天到期。
  - 第三方表加两行:阿里云(RDS/OSS,杭州,只存密文与账号业务数据)、DeepSeek(脱敏后的识别请求,不存储)。
- [ ] **Step 2: 改 `index.html`**:含「零服务器」「不经过服务器」的句子改为「密文后端:我们的服务器只保管你打不开就谁也打不开的密文」(逐句 grep:`grep -n "零服务器\|不经过我们的服务器\|没有账号" ../Medme-ghpages/*.html`)。
- [ ] **Step 3: 派独立 subagent 逐条核对**:每一句新文案对应到本计划的具体任务/代码位置(`services/api/db.py` 表结构、`account.dart` 钥匙串、`extract.py` 不落盘、`db.grant_delete`),不符的改文案不改代码。
- [ ] **Step 4: 在 gh-pages worktree 提交并 push(gh-pages 推上去即上线),`curl -s https://medmenow.com/privacy.html | grep -c "云端识别"` ≥ 1。**

---

### Task 14: Argon2 参数按真机定

**Files:**
- Modify: `apps/mobile_flutter/lib/screens/account_screen.dart`(`kDebugMode` 下多一行「KDF 基准」)、`packages/sync/src/keys.rs`(`KDF_DEFAULT`)、`apps/mobile_flutter/lib/account_flow.dart`(`kdf` 常量)

- [ ] **Step 1:** 账号屏 debug 行调用 `syncKdfBenchMs(mKib: 65536, t: 3, p: 1)` 与 `(32768, 3, 1)`、`(16384, 4, 1)` 三组,SnackBar 显示毫秒。
- [ ] **Step 2:** 在华为 Mate 9 与一台 iPhone 上各跑一次(`flutter run -d <device>` debug 即可;**不跑 release**),把三组数字记进 `docs/log/2026-09-XX-argon2-on-device.md`。
- [ ] **Step 3:** 取「Mate 9 上 ≤ 1.5 s」的最大内存档作为 `KDF_DEFAULT` 与 `AccountFlow.kdf`,两处改成同一组数。
- [ ] **Step 4:** `cargo test -p sync && flutter analyze`,Commit:

```bash
git add packages/sync/src/keys.rs apps/mobile_flutter/lib/account_flow.dart apps/mobile_flutter/lib/screens/account_screen.dart docs/log
git commit -m "chore(sync): Argon2id 参数按 Mate 9 实测定"
```

---

## 自查(写完后对着 spec 过一遍)

| Spec 段 | 任务 |
|---|---|
| §1 后端运行时/DB/OSS/短信 | 4(部署 README、PNVS)、6(OSS 私有桶) |
| §1 八张表(+ invites) | 4 建表;`invites` 是 spec 未列但邀请兑换必需的第九张,已在 Task 5 说明 |
| §1 接口 v1 全部 | 4(auth 5 条)、5(keys/lookup/profiles/grants/invites/transfer=redeem owner/devices)、6(events/objects/extract) |
| §2 密钥体系 | 1(原语)、7(FRB)、9(注册/解锁流程)、14(参数) |
| §2 换机三条路 | 设备批准(5+9)、iOS 钥匙串同步(8 `synchronizable`)、口令/恢复码(9);安卓钥匙串不做(§6) |
| §3 同步 | 2(core-model)、7、10;压图 3 |
| §4 授权语义 | 5(表与 role)、11(家属/医生 15 天/转移/过期消失);撤销=删行(5),轮换不做 |
| §5 客户端 | 9(账号屏)、10(切换器数据源)、11(医生扫码进 app)、三态测试(9) |
| §6 不做 | 微信 501(4)、其余未建任务 |
| §7 风险 | Argon2(14)、RDS Proxy(4 README)、短信限次(4) |
| 横切:隐私政策/官网/埋点 | 13、12 |

**类型一致性核对:** `SyncEventDto` 字段(device_id/seq/event_id/ts/ciphertext)在 Task 6 HTTP、Task 7 Rust、Task 10 Dart 三处一致;`wrapped_profile_key` 在 grants 里由 grantee 用**自己公钥**封,邀请路径先用 token 包(`wrapped_key_by_token`)再由 grantee 回填(Task 5 `grant_set_key` ↔ Task 11 `redeem`);`role_for` 过期即 None ↔ `profiles_for` 过滤 ↔ 客户端 `purgeExpired` 三处口径一致(15 天)。

**已知简化(ponytail):** `events_pull` 全表扫后在 Python 里按 since 过滤(每档案事件数千级,够用;上万再改 SQL);FC 上 FastAPI 冷启动约 1–2 s;对象上行逐个签名(每对象一次往返,几百份报告可接受,再多改批量签名)。
