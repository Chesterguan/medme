//! 出厂内置的病种包(2026-10-22 通用病程档案 spec §5):`skills/<id>/<ver>.json` 的签名信封
//! 逐字节编进二进制,首启先装内置、再联网更新(`lib/skill_packages.dart`)。
//!
//! **内置 ≠ 免检**:走的是同一个 `profile::cache_store` —— 同一把公钥、同一个 `min_engine`
//! 闸、同一个单调版本闸;线上更高版本能覆盖内置、更低的被拒。
//! `skills/index.src.json` 加包 = 这里加一行;`vault_profile.rs` 的
//! `builtin_list_matches_repo_index` 守着两边 (id, version) 逐一相等。
use std::path::Path;

use crate::diagnostics::warn as log_warn;

/// `(id, version, 签名信封)`。
pub(crate) const BUILTIN: &[(&str, &str, &str)] = &[(
    "sle",
    "2026.10.1",
    include_str!("../../../../../skills/sle/2026.10.1.json"),
)];

/// 把内置清单逐个装进缓存,返回**装上(或缓存里已有同版/更新版)**的 id。
/// `Ok` 与 `Err(Downgrade)` 都算成功;别的错误只记日志,不挡住开箱。幂等。
pub(crate) fn install_builtin(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for (id, ver, envelope) in BUILTIN {
        match profile::cache_store(dir, envelope) {
            Ok(_) | Err(profile::PackageError::Downgrade { .. }) => out.push(id.to_string()),
            Err(e) => log_warn(&format!("[skills] 内置包 {id} {ver} 装不上:{e}")),
        }
    }
    out
}
