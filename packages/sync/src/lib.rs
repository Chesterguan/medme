//! 纯密码学层(子项目 B §2)。所有函数无 IO、可在任何平台单测。
pub mod blob;
pub mod error;
pub mod keys;

pub use blob::{
    date_shift_days, decrypt_blob, encrypt_blob, event_id_for_wire, object_id, profile_key_new,
};
pub use error::SyncError;
pub use keys::{
    account_keys_new, kek_from_password, kek_from_recovery, kek_from_token, open_sealed,
    recovery_code_new, seal_to, unwrap, wrap, AccountKeys, KdfParams, KDF_DEFAULT,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_kek_round_trips_private_key() {
        let keys = account_keys_new();
        let salt = [7u8; 16];
        let kek = kek_from_password(
            "正确的口令",
            &salt,
            &KdfParams {
                m_kib: 8192,
                t: 1,
                p: 1,
            },
        )
        .unwrap();
        let blob = wrap(&kek, &keys.secret, b"account-priv-v1").unwrap();
        assert_eq!(
            unwrap(&kek, &blob, b"account-priv-v1").unwrap(),
            keys.secret
        );
        let wrong = kek_from_password(
            "错的",
            &salt,
            &KdfParams {
                m_kib: 8192,
                t: 1,
                p: 1,
            },
        )
        .unwrap();
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

    /// 低阶/全零公钥会让 X25519 共享密钥可预测(=0),必须在两端都拒绝,
    /// 否则一个恶意服务端可以喂假公钥、自己算出 box key。
    #[test]
    fn seal_to_rejects_low_order_public_key() {
        let pk = profile_key_new();
        assert!(seal_to(&[0u8; 32], &pk).is_err());
    }

    #[test]
    fn open_sealed_rejects_low_order_ephemeral_public_key() {
        let bob = account_keys_new();
        // eph_pub 全零 + 任意长度足够的 nonce/ct/tag:合法性检查应在解密之前就失败。
        let forged = vec![0u8; 32 + 12 + 16];
        assert!(open_sealed(&bob.secret, &forged).is_err());
    }

    #[test]
    fn blob_encrypt_is_bound_to_id_and_object_id_hides_plaintext_hash() {
        let pk = profile_key_new();
        let id = object_id(&pk, "ab".repeat(32).as_str()).unwrap();
        assert_eq!(id.len(), 64);
        assert_ne!(id, "ab".repeat(32));
        let ct = encrypt_blob(&pk, &id, b"hello").unwrap();
        assert_eq!(decrypt_blob(&pk, &id, &ct).unwrap(), b"hello");
        assert!(decrypt_blob(&pk, "other-id", &ct).is_err());
    }

    #[test]
    fn object_id_rejects_non_lowercase_hex() {
        let pk = profile_key_new();
        assert!(object_id(&pk, &"AB".repeat(32)).is_err());
    }

    #[test]
    fn tampered_wrap_ciphertext_fails_to_unwrap() {
        let kek = profile_key_new();
        let mut blob = wrap(&kek, b"hello world", b"aad").unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0x01; // 翻转密文体(nonce 之后)里的一个字节
        assert!(unwrap(&kek, &blob, b"aad").is_err());
    }

    #[test]
    fn tampered_blob_ciphertext_fails_to_decrypt() {
        let pk = profile_key_new();
        let id = object_id(&pk, "cd".repeat(32).as_str()).unwrap();
        let mut ct = encrypt_blob(&pk, &id, b"hello").unwrap();
        let last = ct.len() - 1;
        ct[last] ^= 0x01;
        assert!(decrypt_blob(&pk, &id, &ct).is_err());
    }

    #[test]
    fn token_kek_is_deterministic_and_differs_from_recovery_derivation() {
        let a = kek_from_token("invite-tok-abc123").unwrap();
        let b = kek_from_token("invite-tok-abc123").unwrap();
        assert_eq!(a, b);
        assert_ne!(a, kek_from_token("invite-tok-xyz789").unwrap());
        // 同一串当"恢复码"跑会因长度/字符集校验直接出错,派生链互不相通。
        assert!(kek_from_recovery("invite-tok-abc123").is_err());
    }

    /// 恢复码字母表只有 30 个符号(index 0..29),拒绝采样之后不该有任何越界字符,
    /// 且分布大致均匀(宽松的界:200 个码 * 20 符号 = 4000 个抽样,期望每个符号
    /// 出现 ~133 次,允许到 60..240 这么宽的区间,只为抓"整段没走拒绝采样"这类
    /// 回归,不是严谨的统计检验)。
    #[test]
    fn recovery_code_alphabet_is_uniform_and_never_out_of_range() {
        const ALPHABET: &str = "ABCDEFGHJKMNPQRSTVWXYZ23456789";
        let mut counts = [0u32; 30];
        for _ in 0..200 {
            let code = recovery_code_new();
            for c in code.chars().filter(|c| *c != '-') {
                let idx = ALPHABET
                    .find(c)
                    .expect("symbol must be in the 30-char alphabet");
                counts[idx] += 1;
            }
        }
        let total: u32 = counts.iter().sum();
        assert_eq!(total, 200 * 20);
        for (i, &n) in counts.iter().enumerate() {
            assert!(
                (60..240).contains(&n),
                "symbol {i} count {n} looks non-uniform"
            );
        }
    }

    #[test]
    fn date_shift_is_deterministic_and_within_90_days() {
        let pk = profile_key_new();
        let d = date_shift_days(&pk);
        assert_eq!(d, date_shift_days(&pk));
        assert!((-90..=90).contains(&d));
    }
}
