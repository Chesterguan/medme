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

/// 档案密钥本身从不直接当 AES/HMAC 密钥用:每个用途(加密对象、算对象 id、日期偏移)
/// 都用 HKDF-SHA256(无 salt,IKM=档案密钥)按 `info` 派生独立子密钥,互不可推导。
fn derive_subkey(profile_key: &[u8; 32], info: &[u8]) -> Result<[u8; 32], SyncError> {
    let hk = Hkdf::<Sha256>::new(None, profile_key);
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).map_err(|_| SyncError::Crypto)?;
    Ok(out)
}

fn is_lowercase_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// 服务端看到的对象名。明文哈希(须为 64 位小写 hex)经档案密钥派生的 `object-id`
/// 子密钥 HMAC:同一份文件在两个档案里名字不同,服务端无法跨用户比对内容。
pub fn object_id(profile_key: &[u8; 32], plaintext_sha256_hex: &str) -> Result<String, SyncError> {
    if !is_lowercase_sha256_hex(plaintext_sha256_hex) {
        return Err(SyncError::Format("plaintext_sha256_hex 应为 64 位小写 hex".into()));
    }
    let key = derive_subkey(profile_key, b"object-id")?;
    let mut mac =
        Hmac::<Sha256>::new_from_slice(&key).expect("HMAC-SHA256 accepts a key of any length");
    mac.update(b"object:");
    mac.update(plaintext_sha256_hex.as_bytes());
    Ok(hex(&mac.finalize().into_bytes()))
}

/// 密文/HMAC 密钥经 `object-enc` 子密钥派生,与 `object_id` 用的 `object-id` 子密钥
/// 互相独立(见 `derive_subkey`)。
pub fn encrypt_blob(profile_key: &[u8; 32], id: &str, plaintext: &[u8]) -> Result<Vec<u8>, SyncError> {
    let key = derive_subkey(profile_key, b"object-enc")?;
    wrap(&key, plaintext, id.as_bytes())
}

pub fn decrypt_blob(profile_key: &[u8; 32], id: &str, blob: &[u8]) -> Result<Vec<u8>, SyncError> {
    let key = derive_subkey(profile_key, b"object-enc")?;
    unwrap(&key, blob, id.as_bytes())
}

/// 子项目 A 的日期偏移秘密:−90..=90,由档案密钥派生的 `date-shift` 子密钥确定,
/// 随档案同步、无需存储。
pub fn date_shift_days(profile_key: &[u8; 32]) -> i32 {
    let hk = Hkdf::<Sha256>::new(None, profile_key);
    let mut out = [0u8; 2];
    hk.expand(b"date-shift", &mut out)
        .expect("2-byte HKDF output is always within the SHA-256 limit");
    (u16::from_be_bytes(out) % 181) as i32 - 90
}

#[cfg(test)]
mod tests {
    use super::*;

    /// object_id、encrypt_blob 各自用的子密钥,以及 date_shift_days 的派生输出,
    /// 三者互不相同 —— 确认没有共用同一段原始档案密钥当密钥用。
    #[test]
    fn per_purpose_subkeys_differ() {
        let pk = profile_key_new();
        let enc_key = derive_subkey(&pk, b"object-enc").unwrap();
        let id_key = derive_subkey(&pk, b"object-id").unwrap();
        let mut date_shift = [0u8; 2];
        Hkdf::<Sha256>::new(None, &pk)
            .expand(b"date-shift", &mut date_shift)
            .unwrap();
        assert_ne!(enc_key, id_key);
        assert_ne!(&enc_key[..2], &date_shift[..]);
        assert_ne!(&id_key[..2], &date_shift[..]);
    }
}
