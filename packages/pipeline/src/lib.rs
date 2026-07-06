use core_model::{DocType, NewDocument, NewOcr, OcrBackendKind, Vault};
use std::path::Path;

pub fn mime_for(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "pdf" => "application/pdf",
        "txt" => "text/plain",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "tif" | "tiff" => "image/tiff",
        _ => "application/octet-stream",
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum IngestStatus {
    New,
    Deduped,
    Backfilled,
    StoredNoText,
}

#[derive(Debug, Clone)]
pub struct IngestOutcome {
    pub source_file_id: i64,
    pub name: String,
    pub status: IngestStatus,
    pub doc_type: Option<DocType>,
}

/// 导入一个文件:存 CAS(去重)→ 若尚无 document 则抽文本层并建 document/ocr。
/// 抽取失败(如扫描图片)不致命 → StoredNoText(原文件已永存,留待后续 OCR 补索引)。
pub fn ingest(vault: &Vault, path: &Path) -> anyhow::Result<IngestOutcome> {
    let bytes = std::fs::read(path)?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();
    let imp = vault.import(&name, mime_for(path), &bytes)?;
    let sid = imp.source_file.id;

    if imp.deduped && vault.has_document(sid)? {
        return Ok(IngestOutcome {
            source_file_id: sid,
            name,
            status: IngestStatus::Deduped,
            doc_type: None,
        });
    }

    match parser::extract(path) {
        Ok(e) => {
            let doc = vault.add_document(NewDocument {
                source_file_id: sid,
                doc_type: e.doc_type.clone(),
                doc_date: e.doc_date,
                doc_date_end: e.doc_date_end,
                title: Some(name.clone()),
                language: e.language,
                page_count: e.page_count,
            })?;
            vault.add_ocr(NewOcr {
                document_id: doc.id,
                page_no: 1,
                backend: OcrBackendKind::Native,
                model_version: "text-layer".into(),
                text: e.text,
                confidence: None,
            })?;
            let status = if imp.deduped {
                IngestStatus::Backfilled
            } else {
                IngestStatus::New
            };
            Ok(IngestOutcome {
                source_file_id: sid,
                name,
                status,
                doc_type: Some(doc.doc_type),
            })
        }
        Err(_) => Ok(IngestOutcome {
            source_file_id: sid,
            name,
            status: IngestStatus::StoredNoText,
            doc_type: None,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_model::Vault;
    use std::io::Write;

    fn tmp_txt(dir: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
        let p = dir.join(name);
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(body.as_bytes()).unwrap();
        p
    }

    #[test]
    fn ingest_new_then_dedup() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let f = tmp_txt(fdir.path(), "report.txt", "出院记录 2023-05-01 肌酐 Creatinine 120");

        let o1 = ingest(&v, &f).unwrap();
        assert_eq!(o1.status, IngestStatus::New);
        assert!(o1.doc_type.is_some());

        let o2 = ingest(&v, &f).unwrap();
        assert_eq!(o2.status, IngestStatus::Deduped); // 已存在且已索引
        assert_eq!(o1.source_file_id, o2.source_file_id);

        // 时间线只有一条
        assert_eq!(v.timeline().unwrap().len(), 1);
    }

    #[test]
    fn ingest_stored_no_text_for_unsupported() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        // .bin 扩展名 → parser::extract 报错 → StoredNoText,但文件已入 CAS
        let p = fdir.path().join("scan.bin");
        std::fs::write(&p, b"\x00\x01\x02rawbytes").unwrap();

        let o = ingest(&v, &p).unwrap();
        assert_eq!(o.status, IngestStatus::StoredNoText);
        assert!(!v.has_document(o.source_file_id).unwrap()); // 没建 document
        assert_eq!(v.timeline().unwrap().len(), 0);
    }

    #[test]
    fn ingest_captures_date_range() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("discharge.txt");
        std::fs::write(&p, "出院记录\n入院日期:2023-01-01 出院日期:2023-01-20\n脑梗死").unwrap();
        ingest(&v, &p).unwrap();
        let tl = v.timeline().unwrap();
        assert_eq!(tl[0].doc_date.unwrap().format("%Y-%m-%d").to_string(), "2023-01-01");
        assert_eq!(tl[0].doc_date_end.unwrap().format("%Y-%m-%d").to_string(), "2023-01-20");
    }
}
