use crate::dto::*;
use core_model::Vault;
use std::sync::Mutex;
use tauri::State;

pub struct AppState {
    pub vault: Mutex<Vault>,
}

fn lock<'a>(s: &'a State<'a, AppState>) -> Result<std::sync::MutexGuard<'a, Vault>, String> {
    s.vault.lock().map_err(|_| "vault lock poisoned".to_string())
}

#[tauri::command]
pub fn list_timeline(state: State<AppState>) -> Result<Vec<DocumentSummary>, String> {
    let v = lock(&state)?;
    let entries = v.timeline().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for e in entries {
        // 用 document_by_id 拿完整字段(timeline 的 title 已是真实值,但这里统一走 summary)
        if let Some(doc) = v.document_by_id(e.document_id).map_err(|e| e.to_string())? {
            out.push(DocumentSummary::from(&doc));
        }
    }
    Ok(out)
}

#[tauri::command]
pub fn search(
    state: State<AppState>,
    query: String,
    limit: usize,
) -> Result<Vec<SearchResult>, String> {
    let v = lock(&state)?;
    let hits = v.search(&query, limit).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for h in hits {
        // 取真实 document.title(而非 SearchHit 里的分词 title)
        if let Some(doc) = v.document_by_id(h.document_id).map_err(|e| e.to_string())? {
            out.push(SearchResult {
                document: DocumentSummary::from(&doc),
                snippet: h.snippet,
            });
        }
    }
    Ok(out)
}

#[tauri::command]
pub fn get_document(state: State<AppState>, id: i64) -> Result<DocumentDetail, String> {
    let v = lock(&state)?;
    let doc = v
        .document_by_id(id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("document {id} not found"))?;
    let sf = v
        .source_file_by_id(doc.source_file_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "source_file missing".to_string())?;
    let text = v.ocr_text(id).map_err(|e| e.to_string())?;
    Ok(DocumentDetail {
        document: DocumentSummary::from(&doc),
        source_file: SourceFileMeta::from(&sf),
        ocr_text: text,
    })
}

#[tauri::command]
pub fn import_paths(
    state: State<AppState>,
    paths: Vec<String>,
) -> Result<Vec<ImportOutcome>, String> {
    let v = lock(&state)?;
    let mut out = Vec::new();
    for p in paths {
        let o = pipeline::ingest(&v, std::path::Path::new(&p)).map_err(|e| e.to_string())?;
        let status = match o.status {
            pipeline::IngestStatus::New => "new",
            pipeline::IngestStatus::Backfilled => "backfilled",
            pipeline::IngestStatus::Deduped => "deduped",
            pipeline::IngestStatus::StoredNoText => "stored_no_text",
        }
        .to_string();
        out.push(ImportOutcome {
            name: o.name,
            source_file_id: o.source_file_id,
            status,
            doc_type: o.doc_type.map(|d| d.as_str().to_string()),
        });
    }
    Ok(out)
}

#[tauri::command]
pub fn read_source_bytes(state: State<AppState>, id: i64) -> Result<Vec<u8>, String> {
    let v = lock(&state)?;
    let sf = v
        .source_file_by_id(id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("source_file {id} not found"))?;
    let path = v.root_join(&sf.storage_path); // 见 core-model cas.rs 的 root_join
    std::fs::read(&path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn export_vault(_state: State<AppState>, _dest_path: String) -> Result<ExportSummary, String> {
    // C2/后续:真正打包 objects/ + JSON 清单。此处占位返回 0,避免未实现命令。
    Ok(ExportSummary {
        file_count: 0,
        byte_size: 0,
    })
}

#[tauri::command]
pub fn get_patient_profile(state: State<AppState>) -> Result<PatientProfile, String> {
    let v = lock(&state)?;
    let p = pipeline::patient_profile(&v).map_err(|e| e.to_string())?;
    Ok(PatientProfile {
        name: p.name, gender: p.gender, birth_date: p.birth_date, age: p.age, record_count: p.record_count,
    })
}
