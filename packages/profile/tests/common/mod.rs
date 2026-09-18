//! 测试共用夹具。**不要**在这里塞断言或规则逻辑 —— 它只造输入。
//!
//! 这个文件被**每个**集成测试二进制各编一份,所以「本文件里没人用」对任何一个
//! 二进制都成立 —— 不 allow 就会在只用了一半夹具的那些二进制里报 dead_code。
#![allow(dead_code)]
use profile::Package;

/// 一个签好名的最小包(与 `package.rs` 单测里的 MINIMAL 同一份内容)。
/// **id 仍是 `t`** —— 它只给开启闸用例当壳,与发布的 SLE 包无关。
pub fn minimal_pkg() -> Package {
    serde_json::from_str(MINIMAL).expect("夹具包必须解析")
}

pub const MINIMAL: &str = r#"{"manifest":{"id":"t","family":"immune","version":"2026.09.1","min_engine":1,
  "display":{"name":"测试病","short":"测试"},"disclaimer":"仅整理你的病历,不做诊断",
  "sources":[{"id":"S1","cite":"test","url":null}]},
  "triggers":{"diagnosis_patterns":[],"serology_any_two":[]},
  "terms":{"aliases":{},"analytes":[]},"markers":[],"drugs":[],
  "rules":{"activity":{"window_days":10,"max":18,"items":[]},"states":[],"monitoring":[],"milestones":[]},
  "views":{"sections":[],"handoff":[]}}"#;

/// 一份长得像化验单的文本,用来证明「没开启就不算」不是因为没有输入。
pub fn sle_like_doc() -> String {
    "检验报告单\n补体C3 0.42 g/L 0.9-1.8 L\n补体C4 0.06 g/L 0.1-0.4 L\n".to_string()
}

/// 活动度用例统一的「今天」。窗口边界(前 10 天)全部相对它算。
pub const TODAY: &str = "2026-09-16";

/// 用 [`full_pkg`] 的用例里,`ProfileEvent.package` 必须写这个 —— 它就是发布包的
/// `manifest.id`(开启闸、忽略提醒、PGA、体重全按它过滤,写错了整块档案直接不出)。
pub const PKG_ID: &str = "sle";

/// 把几行化验包成一份像样的报告单文本(`extract_labs` 要看到报告的样子)。
pub fn lab_doc(rows: &str) -> String {
    format!("检验报告单\n项目 结果 单位 参考区间\n{rows}\n")
}

/// 把几行医嘱包成一份处方笺文本(`extract_meds` 只在 `doc_type` 含 prescription
/// 时整份跑,见 `parser::aggregate::wants_meds`)。
pub fn rx_doc(rows: &str) -> String {
    format!("处方笺\nRp:\n{rows}\n")
}

/// **发布出去的那一份 SLE 包的原文逐字节**(`skills/sle/2026.09.1.src.json`,
/// 由 `scripts/sign_skill.py` 签成同目录的 `.json` 信封)。
///
/// 夹具与真包从此是同一份字节:规则引擎的每一条用例测的都是用户真会装上的那个包,
/// 不是一份「长得差不多」的复制品 —— 两份内容各自长歪过一次,就再也没人说得清
/// golden 钉住的是哪一个。「签好的信封里也是这一份」由
/// `packages/profile/tests/shipped_package.rs` 另外钉住。
pub const FULL: &str = include_str!("../../../../skills/sle/2026.09.1.src.json");

/// 发布包解析出来的那一份。
pub fn full_pkg() -> Package {
    serde_json::from_str(FULL).expect("发布包必须解析")
}

/// [`full_pkg`] 的 JSON 形态,给要改几个字段再用的用例(改包的用例改这份,别另抄)。
pub fn full_json() -> serde_json::Value {
    serde_json::from_str(FULL).expect("发布包必须解析")
}

/// 活动度用例用的包 —— 就是发布包本身。真包的 `rules.activity` 已经是那 8 条,
/// 再留一份单独的活动度夹具只会让两份各自长歪。
pub fn activity_pkg() -> Package {
    full_pkg()
}

/// 包 `terms.analytes` → 运行时术语覆盖层的条目。**真机上这一步是 Task 20 的 FFI
/// 在装包时做的**,测试里手动做一遍 —— 不做的话包自己定义的分析物(尿红细胞/尿白
/// 细胞按高倍视野计数)连认都认不出来,用到它们的规则一律出「未知」。
///
/// `category` 固定 `lab`:包的 `terms.analytes` 只能定义化验项(药物走 `drugs[]`),
/// 这不是从包里读出来的,所以也不该由包说了算。
pub fn overlay_entries(pkg: &Package) -> Vec<terminology::Entry> {
    pkg.terms
        .analytes
        .iter()
        .map(|a| {
            serde_json::from_value(serde_json::json!({
                "key": a.key, "canonical_name": a.name, "category": "lab",
                "panel": a.panel, "codes": {}, "canonical_unit": a.canonical_unit,
                "units": a.units.iter().map(|u| serde_json::json!(
                    {"unit": u.unit, "slope": u.slope, "intercept": u.intercept})).collect::<Vec<_>>(),
                "aliases": a.aliases,
            }))
            .expect("覆盖层条目必须解析")
        })
        .collect()
}

/// 把 `(日期, 文本)` 列表变成 `SourceDoc`。文本**借**调用方那一份(元组里的
/// `String` 自己就是所有者),不复制也不泄漏 —— 调用方只要让 `docs` 活到用完,
/// 借用检查自然成立。
/// `doc_type` 与 `title` 都按**首行**认:首行含「处方」→ 处方笺,否则化验单。
/// 这不是凑测试 —— `parser::aggregate` 的两道门控正好相反(`extract_labs` 只跑
/// 化验单类,`extract_meds` 只整份跑处方类),夹具统一给 `lab_report` 的话,
/// 处方永远抽不出药来。
pub fn mk_docs<'a>(docs: &'a [(&str, String)]) -> Vec<parser::SourceDoc<'a>> {
    docs.iter()
        .enumerate()
        .map(|(i, (d, t))| {
            let head = t.lines().next().unwrap_or_default();
            parser::SourceDoc {
                index: i,
                date: d.parse().ok(),
                text: t,
                doc_type: Some(if head.contains("处方") {
                    "prescription".into()
                } else {
                    "lab_report".into()
                }),
                title: Some(head.to_string()),
                extraction_json: None,
            }
        })
        .collect()
}
