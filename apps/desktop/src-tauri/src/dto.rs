use core_model::{Document, SourceFile};
use serde::Serialize;

#[derive(Serialize)]
pub struct DocumentSummary {
    pub id: i64,
    pub doc_type: String,
    pub doc_date: Option<String>, // RFC3339
    pub title: Option<String>,
    pub page_count: i32,
}
impl From<&Document> for DocumentSummary {
    fn from(d: &Document) -> Self {
        DocumentSummary {
            id: d.id,
            doc_type: d.doc_type.as_str().to_string(),
            doc_date: d.doc_date.map(|x| x.to_rfc3339()),
            title: d.title.clone(),
            page_count: d.page_count,
        }
    }
}

#[derive(Serialize)]
pub struct SourceFileMeta {
    pub id: i64,
    pub original_name: String,
    pub mime_type: String,
    pub byte_size: i64,
    pub imported_at: String,
}
impl From<&SourceFile> for SourceFileMeta {
    fn from(s: &SourceFile) -> Self {
        SourceFileMeta {
            id: s.id,
            original_name: s.original_name.clone(),
            mime_type: s.mime_type.clone(),
            byte_size: s.byte_size,
            imported_at: s.imported_at.to_rfc3339(),
        }
    }
}

#[derive(Serialize)]
pub struct SearchResult {
    pub document: DocumentSummary,
    pub snippet: String,
}

#[derive(Serialize)]
pub struct DocumentDetail {
    pub document: DocumentSummary,
    pub source_file: SourceFileMeta,
    pub ocr_text: String,
}

#[derive(Serialize)]
pub struct ImportOutcome {
    pub name: String,
    pub source_file_id: i64,
    pub status: String, // new|backfilled|deduped|stored_no_text
    pub doc_type: Option<String>,
}

#[derive(Serialize)]
pub struct ExportSummary {
    pub file_count: i64,
    pub byte_size: i64,
}
