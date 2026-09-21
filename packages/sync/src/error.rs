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
