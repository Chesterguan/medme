//! 病程档案(disease profile):病种包的加载与规则求值。
//!
//! 两条硬边界:
//! 1. **本 crate 不碰网络。** 包从哪来(HTTP / 缓存文件 / 测试常量)是调用方的事,
//!    这里只接受字节、验签、求值 —— 这样规则引擎在纯 Rust 单测里可完整覆盖。
//! 2. **规则求值是纯函数。** 同一份输入 + 同一个包 + 同一个 `today` 永远得到同一份
//!    `ProfileView`,所以档案「永远可重算」(spec §0),不需要任何新的事件类型。
pub mod package;

pub use package::{
    cache_load, cache_store, load_signed, verify_envelope, ActivityRules, Analyte, Display, Drug,
    Manifest, Marker, Package, PackageError, Rules, Source, Terms, Triggers, UnitRow, Views,
    ENGINE_VERSION, SIGNING_PUBLIC_KEY_HEX,
};
