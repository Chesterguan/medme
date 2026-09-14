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
pub const KDF_DEFAULT: KdfParams = KdfParams {
    m_kib: 65536,
    t: 3,
    p: 1,
};

fn random32() -> [u8; 32] {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).expect("OS entropy source is always available on supported targets");
    b
}

pub fn account_keys_new() -> AccountKeys {
    let secret = StaticSecret::from(random32());
    let public = PublicKey::from(&secret);
    AccountKeys {
        public: public.to_bytes(),
        secret: secret.to_bytes(),
    }
}

pub fn kek_from_password(pw: &str, salt: &[u8; 16], p: &KdfParams) -> Result<[u8; 32], SyncError> {
    let params =
        Params::new(p.m_kib, p.t, p.p, Some(32)).map_err(|e| SyncError::Kdf(e.to_string()))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = [0u8; 32];
    argon
        .hash_password_into(pw.as_bytes(), salt, &mut out)
        .map_err(|e| SyncError::Kdf(e.to_string()))?;
    Ok(out)
}

/// 20 字符 base32(去掉易混的 0/O/1/I/L/U),约 98 bit 熵(log2(30^20)),4 字符一组。
const ALPHABET: &[u8; 30] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789";

pub fn recovery_code_new() -> String {
    let mut s = String::with_capacity(24);
    let mut i = 0usize;
    while i < 20 {
        let mut b = [0u8; 1];
        getrandom::fill(&mut b)
            .expect("OS entropy source is always available on supported targets");
        // 拒绝采样:256 不是 30 的整数倍(256 = 8*30 + 16),直接 `% 30` 会让
        // 0..15 比 16..29 多被选中一次——舍弃 >= 240 的字节,剩下的 0..239 按
        // 30 均分,字母表才是真均匀的。
        if b[0] >= 240 {
            continue;
        }
        if i > 0 && i % 4 == 0 {
            s.push('-');
        }
        s.push(ALPHABET[(b[0] % 30) as usize] as char);
        i += 1;
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

/// 恢复码本身已是约 98 bit 随机,用 HKDF 拉伸即可,不需要 Argon2 的抗暴力代价。
pub fn kek_from_recovery(code: &str) -> Result<[u8; 32], SyncError> {
    let s = normalize_recovery(code)?;
    let hk = Hkdf::<Sha256>::new(Some(b"medme-recovery-v1"), s.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(b"kek", &mut out).map_err(|_| SyncError::Crypto)?;
    Ok(out)
}

/// 邀请令牌派生 KEK(邀请医生/家属加入档案时,用于封装/开封临时共享的密钥材料)。
/// 令牌由后端签发、一次性、本身已足够随机(不是人手打的恢复码),同
/// `kek_from_recovery` 一样直接 HKDF 拉伸即可、不需要 Argon2 的抗暴力代价;
/// salt 换成 `medme-invite-v1`(与恢复码的 `medme-recovery-v1` 区分),两条派生
/// 链互不可推导。不做 `normalize_recovery` 那样的大小写/分隔符折叠——令牌是
/// 程序生成、经 URL 传递的不透明串,不是人手输入的东西。
pub fn kek_from_token(token: &str) -> Result<[u8; 32], SyncError> {
    let hk = Hkdf::<Sha256>::new(Some(b"medme-invite-v1"), token.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(b"kek", &mut out).map_err(|_| SyncError::Crypto)?;
    Ok(out)
}

fn gcm(key: &[u8; 32]) -> Aes256Gcm {
    Aes256Gcm::new_from_slice(key).expect("32-byte key is always a valid AES-256 key")
}

/// `nonce(12) || ciphertext+tag`。
pub fn wrap(kek: &[u8; 32], plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>, SyncError> {
    let mut nonce_bytes = [0u8; 12];
    getrandom::fill(&mut nonce_bytes)
        .expect("OS entropy source is always available on supported targets");
    let nonce: &Nonce<_> = (&nonce_bytes).into();
    let ct = gcm(kek)
        .encrypt(
            nonce,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| SyncError::Crypto)?;
    let mut out = nonce_bytes.to_vec();
    out.extend_from_slice(&ct);
    Ok(out)
}

pub fn unwrap(kek: &[u8; 32], blob: &[u8], aad: &[u8]) -> Result<Vec<u8>, SyncError> {
    if blob.len() < 12 + 16 {
        return Err(SyncError::Format("blob too short".into()));
    }
    let (nonce_bytes, ct) = blob.split_at(12);
    let nonce: &Nonce<_> = nonce_bytes.try_into().expect("已按 12 字节切片");
    gcm(kek)
        .decrypt(nonce, Payload { msg: ct, aad })
        .map_err(|_| SyncError::Crypto)
}

/// Sealed box:临时 X25519 → HKDF → AES-GCM。布局 `eph_pub(32) || nonce(12) || ct`。
pub fn seal_to(public: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, SyncError> {
    let eph = StaticSecret::from(random32());
    let eph_pub = PublicKey::from(&eph);
    let shared = eph.diffie_hellman(&PublicKey::from(*public));
    // 拒绝低阶/全零公钥:否则对方(比如服务端)可以喂一个低阶点,让共享密钥可预测,
    // 自己算出 box key。`was_contributory` 是 x25519-dalek 对这类点的标准检测。
    if !shared.was_contributory() {
        return Err(SyncError::Crypto);
    }
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
    // 同上:拒绝发件方(比如被篡改的服务端存储)塞进来的低阶/全零临时公钥。
    if !shared.was_contributory() {
        return Err(SyncError::Crypto);
    }
    let key = derive_box_key(shared.as_bytes(), &eph_pub, my_pub.as_bytes())?;
    unwrap(&key, &blob[32..], b"medme-sealed-v1")
}

fn derive_box_key(shared: &[u8], eph: &[u8], recipient: &[u8]) -> Result<[u8; 32], SyncError> {
    let mut salt = eph.to_vec();
    salt.extend_from_slice(recipient);
    let hk = Hkdf::<Sha256>::new(Some(&salt), shared);
    let mut out = [0u8; 32];
    hk.expand(b"medme-sealed-v1", &mut out)
        .map_err(|_| SyncError::Crypto)?;
    Ok(out)
}
