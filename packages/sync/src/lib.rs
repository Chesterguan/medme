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
