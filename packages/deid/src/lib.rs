//! 本地脱敏(spec: docs/superpowers/specs/2026-09-11-deid-cloud-extraction-design.md §1/§4)。
//! 三层 + 一道闸:K 已知值 → A 锚点 → P 模式 → gate。全部纯函数,不做网络、不读盘。
pub mod anchors;
pub mod dates;
pub mod gate;
pub mod known;
pub mod patterns;
pub mod redact;
pub use gate::assert_clean;
pub use redact::{redact_text, restore, KnownIdentity, Redacted, RestoreMap};

#[derive(Debug, thiserror::Error)]
pub enum DeidError {
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("payload 含已知身份信息,拒发:{0}")]
    IdentityLeak(String),
}
