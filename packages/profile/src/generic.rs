//! 通用病程档案层(2026-10-22 spec):不靠包,从诊断/用药/化验/就诊直接推三视图。
use chrono::NaiveDate;

/// 一次就诊(`core-model` 的 `Encounter` 投影),调用方按 `Vault::encounters_with_docs()`
/// 给;`doc_indices` 是 `parser::SourceDoc::index`。parser 不认识 encounter,所以它是
/// 引擎的独立输入(spec §8.1 决定 1)。
#[derive(Debug, Clone)]
pub struct EncounterRef {
    /// `inpatient` / `emergency` / `outpatient` / `exam`(`EncounterKind::as_str`)。
    pub kind: String,
    pub start: Option<NaiveDate>,
    pub end: Option<NaiveDate>,
    pub provider: Option<String>,
    pub title: Option<String>,
    pub doc_indices: Vec<usize>,
}
