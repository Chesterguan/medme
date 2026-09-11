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
