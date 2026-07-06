use crate::types::{parse_dt, Document, SourceFile};
use crate::{DocType, MedmeError, Vault};
use chrono::{DateTime, Utc};
use rusqlite::OptionalExtension;

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub document_id: i64,
    pub title: Option<String>,
    pub snippet: String,
}

#[derive(Debug, Clone)]
pub struct TimelineEntry {
    pub document_id: i64,
    pub doc_date: Option<DateTime<Utc>>,
    pub doc_date_end: Option<DateTime<Utc>>,
    pub doc_type: DocType,
    pub title: Option<String>,
}

impl Vault {
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, MedmeError> {
        // 把每个 token 包成 FTS5 字面短语("...",内部引号翻倍),并丢弃纯标点 token,
        // 使 '-'/':'/'"'/'(' 等运算符字符被当作字面量,原始用户输入不会触发 FTS5 语法错误。
        let match_q: String = crate::tokenize::tokenize(query)
            .split_whitespace()
            .filter(|t| t.chars().any(|c| c.is_alphanumeric()))
            .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" ");
        if match_q.is_empty() {
            return Ok(vec![]);
        }
        let mut stmt = self.conn().prepare(
            "SELECT document_id, title, snippet(document_fts, 1, '[', ']', '…', 12) AS snip
             FROM document_fts WHERE document_fts MATCH ?1 LIMIT ?2",
        )?;
        let rows = stmt.query_map(rusqlite::params![match_q, limit as i64], |r| {
            Ok(SearchHit {
                document_id: r.get(0)?,
                title: r.get(1)?, // FTS 里存的是分词后的 title;仅作展示提示
                snippet: r.get(2)?,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn timeline(&self) -> Result<Vec<TimelineEntry>, MedmeError> {
        let mut stmt = self.conn().prepare(
            "SELECT id, doc_date, doc_date_end, doc_type, title FROM document
             ORDER BY doc_date IS NULL, doc_date DESC, id DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            let date_s: Option<String> = r.get(1)?;
            let date_end_s: Option<String> = r.get(2)?;
            Ok(TimelineEntry {
                document_id: r.get(0)?,
                doc_date: date_s.map(parse_dt),
                doc_date_end: date_end_s.map(parse_dt),
                doc_type: DocType::from_str(&r.get::<_, String>(3)?),
                title: r.get(4)?,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// 该 source_file 是否已建立 document(用于判断是否需要补索引)。
    pub fn has_document(&self, source_file_id: i64) -> Result<bool, MedmeError> {
        let n: i64 = self.conn().query_row(
            "SELECT COUNT(*) FROM document WHERE source_file_id = ?1",
            [source_file_id],
            |r| r.get(0),
        )?;
        Ok(n > 0)
    }

    pub fn document_by_id(&self, id: i64) -> Result<Option<Document>, MedmeError> {
        let row = self
            .conn()
            .query_row(
                "SELECT id, source_file_id, doc_type, doc_date, doc_date_end, title, language, page_count, created_at
                 FROM document WHERE id = ?1",
                [id],
                |r| {
                    Ok(Document {
                        id: r.get(0)?,
                        source_file_id: r.get(1)?,
                        doc_type: DocType::from_str(&r.get::<_, String>(2)?),
                        doc_date: r.get::<_, Option<String>>(3)?.map(parse_dt),
                        doc_date_end: r.get::<_, Option<String>>(4)?.map(parse_dt),
                        title: r.get(5)?,
                        language: r.get(6)?,
                        page_count: r.get(7)?,
                        created_at: parse_dt(r.get::<_, String>(8)?),
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    pub fn source_file_by_id(&self, id: i64) -> Result<Option<SourceFile>, MedmeError> {
        let row = self
            .conn()
            .query_row(
                "SELECT id, content_hash, original_name, mime_type, byte_size, storage_path, imported_at
                 FROM source_file WHERE id = ?1",
                [id],
                |r| {
                    Ok(SourceFile {
                        id: r.get(0)?,
                        content_hash: r.get(1)?,
                        original_name: r.get(2)?,
                        mime_type: r.get(3)?,
                        byte_size: r.get(4)?,
                        storage_path: r.get(5)?,
                        imported_at: parse_dt(r.get::<_, String>(6)?),
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    pub fn ocr_text(&self, document_id: i64) -> Result<String, MedmeError> {
        let mut stmt = self.conn().prepare(
            "SELECT text FROM ocr_result WHERE document_id = ?1 ORDER BY page_no ASC",
        )?;
        let rows = stmt.query_map([document_id], |r| r.get::<_, String>(0))?;
        let mut parts = Vec::new();
        for r in rows {
            parts.push(r?);
        }
        Ok(parts.join("\n"))
    }

    /// 所有 OCR 文本(用于派生病人档案等跨文档聚合)。
    pub fn all_ocr_texts(&self) -> Result<Vec<String>, MedmeError> {
        let mut stmt = self.conn().prepare("SELECT text FROM ocr_result")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use crate::types::{NewDocument, NewOcr};
    use crate::Vault;
    use crate::{DocType, OcrBackendKind};

    fn seed(v: &Vault, title: &str, text: &str, date: Option<&str>) {
        let imp = v.import(title, "text/plain", text.as_bytes()).unwrap();
        let doc_date = date.map(|d| {
            chrono::DateTime::parse_from_rfc3339(d)
                .unwrap()
                .with_timezone(&chrono::Utc)
        });
        let doc = v
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date,
                doc_date_end: None,
                title: Some(title.into()),
                language: Some("mixed".into()),
                page_count: 1,
            })
            .unwrap();
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 1,
            backend: OcrBackendKind::Native,
            model_version: "text-layer".into(),
            text: text.into(),
            confidence: None,
        })
        .unwrap();
    }

    #[test]
    fn search_matches_chinese_and_english() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(
            &v,
            "血常规",
            "肌酐 Creatinine 120 升高",
            Some("2023-05-01T00:00:00Z"),
        );
        seed(
            &v,
            "用药单",
            "美托洛尔 Metoprolol 25mg",
            Some("2024-01-02T00:00:00Z"),
        );

        assert_eq!(v.search("Creatinine", 10).unwrap().len(), 1);
        assert_eq!(v.search("肌酐", 10).unwrap().len(), 1);
        assert_eq!(v.search("Metoprolol", 10).unwrap().len(), 1);
        assert_eq!(v.search("nonexistent", 10).unwrap().len(), 0);
    }

    #[test]
    fn search_handles_fts5_special_chars_gracefully() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(
            &v,
            "炎症",
            "C-reactive protein 反应蛋白 升高",
            Some("2023-05-01T00:00:00Z"),
        );

        // 连字符查询过去会报 Sqlite 错误;现在应正常命中
        let hits = v.search("C-reactive", 10).unwrap();
        assert_eq!(hits.len(), 1);
        // 杂散引号 / 冒号 / 括号:不得 panic 或返回 Err
        assert!(v.search("\"unterminated", 10).is_ok());
        assert!(v.search("col:val", 10).is_ok());
        assert!(v.search("a AND (b", 10).is_ok());
        // 纯标点:短路返回空
        assert!(v.search("---", 10).unwrap().is_empty());
    }

    #[test]
    fn timeline_orders_desc_nulls_last() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(&v, "old", "a", Some("2023-05-01T00:00:00Z"));
        seed(&v, "new", "b", Some("2024-01-02T00:00:00Z"));
        seed(&v, "undated", "c", None);

        let t = v.timeline().unwrap();
        assert_eq!(t.len(), 3);
        assert_eq!(t[0].title.as_deref(), Some("new"));
        assert_eq!(t[1].title.as_deref(), Some("old"));
        assert!(t[2].doc_date.is_none()); // NULL 最后
    }

    #[test]
    fn reads_document_source_and_ocr_text() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(&v, "血常规", "肌酐 Creatinine 120", Some("2023-05-01T00:00:00Z"));

        let doc = v.timeline().unwrap()[0].clone();
        let full = v.document_by_id(doc.document_id).unwrap().unwrap();
        assert_eq!(full.title.as_deref(), Some("血常规"));

        let sf = v.source_file_by_id(full.source_file_id).unwrap().unwrap();
        assert_eq!(sf.original_name, "血常规");

        let text = v.ocr_text(doc.document_id).unwrap();
        assert!(text.contains("Creatinine"));

        // 不存在的 id → None / 空
        assert!(v.document_by_id(99999).unwrap().is_none());
        assert!(v.source_file_by_id(99999).unwrap().is_none());
        assert_eq!(v.ocr_text(99999).unwrap(), "");
    }

    #[test]
    fn has_document_reflects_indexing() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let imp = v.import("x.txt", "text/plain", b"hello").unwrap();
        assert!(!v.has_document(imp.source_file.id).unwrap()); // 存了但未建 document
        v.add_document(crate::types::NewDocument {
            source_file_id: imp.source_file.id,
            doc_type: crate::DocType::Unknown,
            doc_date: None,
            doc_date_end: None,
            title: None,
            language: None,
            page_count: 1,
        })
        .unwrap();
        assert!(v.has_document(imp.source_file.id).unwrap());
    }
}
