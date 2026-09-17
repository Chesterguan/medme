//! 病程档案(disease profile):病种包的加载与规则求值。
//!
//! 两条硬边界:
//! 1. **本 crate 不碰网络。** 包从哪来(HTTP / 缓存文件 / 测试常量)是调用方的事,
//!    这里只接受字节、验签、求值 —— 这样规则引擎在纯 Rust 单测里可完整覆盖。
//! 2. **规则求值是纯函数。** 同一份输入 + 同一个包 + 同一个 `today` 永远得到同一份
//!    `ProfileView`,所以档案「永远可重算」(spec §0),不需要任何新的事件类型。
pub mod package;
// 规则求值是本 crate 的内部实现:`Ctx`/`Evidence` 的形状会随 Task 11–15 一路长,
// 不对外承诺。对外只有 `view` 里那三个类型 + `materialize`。
mod rules;
pub mod view;

pub use package::{
    cache_load, cache_store, load_signed, load_signed_index, verify_envelope, verify_envelope_body,
    version_tuple, ActivityRules, Analyte, Display, Drug, Index, IndexEntry, Manifest, Marker,
    Package, PackageError, Rules, Source, Terms, Triggers, UnitRow, Views, ENGINE_VERSION,
    SIGNING_PUBLIC_KEY_HEX,
};
pub use view::{ProfileView, Section, SourceOut};

use chrono::NaiveDate;

/// 从保险箱数据 + 一个病种包算出 `ProfileView`。**纯函数**,可重算。
///
/// `docs` 是调用方从保险箱投影出来的全部文档(与 `parser::assemble_summary` 吃的
/// 是同一份);`events` 是其中 `doc_type == "profile_event"` 的文档解出来的动作日志
/// (调用方负责解,因为只有它知道怎么从库里取文本)。
///
/// **`events` 必须按保险箱事件日志的追加顺序给**(调用方本来就是按写入顺序投影
/// 出来的)。`at` 只到天,所以同一天内的真实先后只剩数组顺序这一个信息源 ——
/// 顺序乱了,「同一天先关后开」会被读成「先开后关」。见 [`is_enabled`]。
pub fn materialize(
    docs: &[parser::SourceDoc<'_>],
    events: &[parser::ProfileEvent],
    pkg: &package::Package,
    today: NaiveDate,
) -> ProfileView {
    let enabled = is_enabled(events, &pkg.manifest.id);
    let sections = if enabled {
        let _ctx = rules::Ctx::build(docs, events, today);
        // Task 11–15 往这里加 section。此刻先空着 —— 「开启了但还没有任何数据」
        // 与「没开启」必须是两种不同的显示状态。
        Vec::new()
    } else {
        // 没开启就**不碰**临床输入:不 aggregate、不解抽取结果。既省一趟全量
        // 计算,也是 spec §4「从未开启 = 不算、不显示、不提醒」的字面实现。
        Vec::new()
    };
    ProfileView {
        package_id: pkg.manifest.id.clone(),
        package_version: pkg.manifest.version.clone(),
        display_name: pkg.manifest.display.name.clone(),
        enabled,
        disclaimer: pkg.manifest.disclaimer.clone(),
        sections,
        sources: pkg
            .manifest
            .sources
            .iter()
            .map(|s| SourceOut {
                id: s.id.clone(),
                cite: s.cite.clone(),
                url: s.url.clone(),
            })
            .collect(),
    }
}

/// 这个包**当前**是不是开着的:只看 `enable`/`disable` 两种 kind,取「最新」的那条。
/// 从没开过 = 关着(spec §4:「从未开启 = 不算、不显示、不提醒」)。
///
/// 「最新」先比 `at`(`YYYY-MM-DD`,定宽,字典序即时间序);**同一天时以 `events`
/// 里靠后的那条为准** —— `events` 按保险箱事件日志的追加顺序给(见 [`materialize`]
/// 的参数说明),而 `at` 只到天,所以日内的真实先后只能靠数组顺序。同一天里先关
/// 后开就是开着,反之就是关着。
///
/// 这里显式用 `>=` 把同 `at` 的后来者顶上去,不借 `max_by` 「相等取后者」的隐含
/// 行为:那是 `Iterator::max_by` 的文档保证没错,但闸门的语义不该挂在一句容易被
/// 后人改成 `min_by`/`sort` 就悄悄反过来的实现细节上。
fn is_enabled(events: &[parser::ProfileEvent], package_id: &str) -> bool {
    let mut latest: Option<&parser::ProfileEvent> = None;
    for e in events {
        if e.package != package_id || (e.kind != "enable" && e.kind != "disable") {
            continue;
        }
        if latest.is_none_or(|cur| e.at >= cur.at) {
            latest = Some(e);
        }
    }
    latest.is_some_and(|e| e.kind == "enable")
}
