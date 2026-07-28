//! 认领:把医生代拍的加密包**还原进病人自己的保险箱**。
//!
//! 与浏览器查看器读的是**同一份密文**([`crate::share::build_claim_blob`] 产出),
//! 只是消费方式不同 —— 浏览器渲染给人看,这里落盘成病人自己的记录。一份密文两个
//! 消费者,是这条链路能成立的关键:病人先在浏览器里看见,再决定要不要装 App 存下来。
//!
//! **不重跑 OCR。** 文字在密文里已经有了(医生那台设备识别的),再跑一遍既慢又可能
//! 更差 —— 病人的手机未必比医生的强。所以这里绕开 `pipeline::ingest`,直接用
//! core-model 写入,把 payload 里的文字原样存进去。
//!
//! **影像会缺。** 分享包对影像有体积上限,超限时只留锚点切片 PNG(见
//! `SHARE_IMAGING_CAP`)。代拍拍的是纸质材料,这条路上本来就没有 DICOM;但如果哪天
//! 有了,认领拿到的影像可能不是诊断级 —— 那时要么抬上限,要么另开一条原件通道。

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD as B64URL};
use base64::Engine as _;
use core_model::{DocType, NewDocument, NewOcr, OcrBackendKind, Vault};

use crate::share::SHARE_AAD;

/// 认领结果:导入了几份、其中几份是本来就有的(按内容哈希去重)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaimOutcome {
    pub imported: i64,
    pub deduped: i64,
    /// 没有内嵌原件、只还原了文字的记录数(分享包体积降级的后果)。
    pub text_only: i64,
}

/// 解开认领密文并写进 `v`。`key_b64` 是 URL fragment 里那把钥匙(base64url,无填充)。
///
/// 幂等靠 CAS:同一份原件重复认领会被内容哈希去重,不会在保险箱里长出两份。
pub fn import_claim(v: &Vault, blob: &[u8], key_b64: &str) -> Result<ClaimOutcome, String> {
    let payload = decrypt_claim(blob, key_b64)?;
    let records = payload["records"]
        .as_array()
        .ok_or_else(|| "认领包里没有 records".to_string())?;

    let mut out = ClaimOutcome {
        imported: 0,
        deduped: 0,
        text_only: 0,
    };
    for rec in records {
        match import_one(v, rec)? {
            Imported::New => out.imported += 1,
            Imported::Dedup => out.deduped += 1,
            Imported::TextOnly => out.text_only += 1,
        }
    }
    v.rebuild_encounters().map_err(|e| e.to_string())?;
    Ok(out)
}

/// 只解密、不写入 —— 供调用方先看一眼(几份记录、谁的),再决定存进哪个成员。
pub fn decrypt_claim(blob: &[u8], key_b64: &str) -> Result<serde_json::Value, String> {
    if blob.len() < 13 {
        return Err("认领数据不完整".into());
    }
    let key = B64URL
        .decode(key_b64.trim())
        .map_err(|_| "认领密钥格式不对".to_string())?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| "认领密钥长度不对".to_string())?;
    let nonce: &Nonce<_> = (&blob[..12]).try_into().expect("已按 12 字节切片");
    // AAD 与整份分享一致:两条路共用同一个密文格式,查看器与 App 解的是同一份东西。
    let pt = cipher
        .decrypt(
            nonce,
            Payload {
                msg: &blob[12..],
                aad: SHARE_AAD,
            },
        )
        .map_err(|_| "认领数据解不开(链接不完整或已损坏)".to_string())?;
    serde_json::from_slice(&pt).map_err(|e| format!("认领包格式错误:{e}"))
}

enum Imported {
    New,
    Dedup,
    TextOnly,
}

fn import_one(v: &Vault, rec: &serde_json::Value) -> Result<Imported, String> {
    let title = rec["title"].as_str().unwrap_or("未命名").to_string();
    let text = rec["text"].as_str().unwrap_or("").to_string();
    let doc_type = DocType::from_str(rec["doc_type"].as_str().unwrap_or("other"));

    // 原件:PDF 优先,否则取图片。分享包里每条记录至多对应一个 source_file
    // (`images` 由单个 source_file 生成),故这里最多解出一份。
    let data_uri = rec["pdf"].as_str().or_else(|| {
        rec["images"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|s| s.as_str())
    });

    let Some((mime, bytes)) = data_uri.and_then(parse_data_uri) else {
        // 没有内嵌原件(体积降级)。仍然把文字存下来 —— 丢文字比丢原件更糟:
        // 病人至少还能读、能搜、能给下一个医生看。用一个占位 source_file 承载。
        let placeholder = format!("{title}(仅文字,原件未随包).txt");
        let imp = v
            .import(&placeholder, "text/plain", text.as_bytes())
            .map_err(|e| e.to_string())?;
        write_document(v, imp.source_file.id, &title, &text, doc_type, rec)?;
        return Ok(Imported::TextOnly);
    };

    let name = format!("{title}{}", ext_for(&mime));
    let imp = v.import(&name, &mime, &bytes).map_err(|e| e.to_string())?;
    // 去重命中说明这份原件本来就在箱子里(重复点了认领链接),不再重复建文档。
    if imp.deduped
        && v.has_document(imp.source_file.id)
            .map_err(|e| e.to_string())?
    {
        return Ok(Imported::Dedup);
    }
    write_document(v, imp.source_file.id, &title, &text, doc_type, rec)?;
    Ok(Imported::New)
}

fn write_document(
    v: &Vault,
    source_file_id: i64,
    title: &str,
    text: &str,
    doc_type: DocType,
    rec: &serde_json::Value,
) -> Result<(), String> {
    let doc = v
        .add_document(NewDocument {
            source_file_id,
            doc_type,
            doc_date: parse_date(rec["doc_date"].as_str()),
            doc_date_end: parse_date(rec["doc_date_end"].as_str()),
            title: Some(title.to_string()),
            language: Some("zh".into()),
            page_count: 1,
        })
        .map_err(|e| e.to_string())?;

    if !text.trim().is_empty() {
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 1,
            backend: OcrBackendKind::Native,
            // 溯源写明这段文字**不是本机识别的**,是随认领包来的。日后排查
            // 「这段字哪来的」时,这一栏是唯一线索。
            model_version: "claim-import".into(),
            text: text.to_string(),
            confidence: None,
        })
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// `data:<mime>;base64,<数据>` → `(mime, 字节)`。非法则 `None`(调用方降级为仅文字)。
fn parse_data_uri(s: &str) -> Option<(String, Vec<u8>)> {
    let rest = s.strip_prefix("data:")?;
    let (meta, b64) = rest.split_once(",")?;
    let mime = meta.strip_suffix(";base64")?;
    let bytes = B64.decode(b64.trim()).ok()?;
    Some((mime.to_string(), bytes))
}

fn ext_for(mime: &str) -> &'static str {
    match mime {
        "application/pdf" => ".pdf",
        "image/png" => ".png",
        "image/tiff" => ".tiff",
        _ => ".jpg",
    }
}

/// 分享包里的日期是 `%Y-%m-%d`(见 `share::fmt_date`),补回 UTC 零点。
fn parse_date(s: Option<&str>) -> Option<chrono::DateTime<chrono::Utc>> {
    use chrono::TimeZone as _;
    let d = chrono::NaiveDate::parse_from_str(s?, "%Y-%m-%d").ok()?;
    chrono::Utc
        .from_local_datetime(&d.and_hms_opt(0, 0, 0)?)
        .single()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 端到端:医生那台设备产出认领密文 → 病人这台设备认领 → 保险箱里应出现同样的
    /// 内容。这是整条链路唯一一条把「产出」与「消费」接在一起的测试。
    #[test]
    fn claim_round_trip_restores_records_into_a_fresh_vault() {
        use core_model::{DocType, NewDocument, NewOcr, OcrBackendKind};

        // ── 医生侧 ──
        let doc_dir = tempfile::tempdir().unwrap();
        let doctor = Vault::open(doc_dir.path()).unwrap();
        let png = {
            // 1×1 PNG,够真实走完 import/CAS 这条路。
            const B: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
            B64.decode(B).unwrap()
        };
        let imp = doctor.import("化验单.png", "image/png", &png).unwrap();
        let d = doctor
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date: parse_date(Some("2026-03-04")),
                doc_date_end: None,
                title: Some("血常规".into()),
                language: Some("zh".into()),
                page_count: 1,
            })
            .unwrap();
        doctor
            .add_ocr(NewOcr {
                document_id: d.id,
                page_no: 1,
                backend: OcrBackendKind::Native,
                model_version: "test".into(),
                text: "白细胞 10.5".into(),
                confidence: None,
            })
            .unwrap();

        let consent = crate::share::ShareConsent {
            utc_ts: "2026-07-28T00:00:00Z".into(),
            consent_text_version: "v1".into(),
            signature_png_base64: None,
            method: "press_hold".into(),
            session_id: "s".into(),
        };
        let confirmed = [d.id].into_iter().collect();
        let (blob, key, _) = crate::share::build_claim_blob(
            &doctor,
            15,
            &crate::render_dicom_png_in_process,
            consent,
            &confirmed,
        )
        .unwrap();

        // ── 病人侧:一个全新的空保险箱 ──
        let pt_dir = tempfile::tempdir().unwrap();
        let patient = Vault::open(pt_dir.path()).unwrap();
        let out = import_claim(&patient, &blob, &key).unwrap();
        assert_eq!(out.imported, 1, "应导入 1 份");
        assert_eq!(out.text_only, 0, "原件够小,不该降级为仅文字");

        // 文字原样带过来(没有重跑 OCR —— 溯源栏写的是 claim-import)。
        // 注:导入尾部会 rebuild_encounters,文档可能被归进某次就诊,故两处都要看。
        let all_docs = |v: &Vault| -> Vec<core_model::Document> {
            let mut d = v.standalone_documents().unwrap();
            for (_, docs) in v.encounters_with_docs().unwrap() {
                d.extend(docs);
            }
            d
        };
        let docs = all_docs(&patient);
        assert_eq!(docs.len(), 1);
        assert_eq!(docs[0].title.as_deref(), Some("血常规"));
        assert_eq!(patient.ocr_text(docs[0].id).unwrap().trim(), "白细胞 10.5");

        // ── 重复认领同一条链接:不该长出第二份 ──
        // 这一条同时**证明了原件是逐字节还原的**:去重走的是内容哈希,只要有一个
        // 字节不同就会当成新文件再存一份。
        let again = import_claim(&patient, &blob, &key).unwrap();
        assert_eq!(again.imported, 0);
        assert_eq!(again.deduped, 1, "重复认领应被内容哈希挡掉");
        assert_eq!(all_docs(&patient).len(), 1);
    }

    #[test]
    fn wrong_key_fails_cleanly() {
        let blob = vec![0u8; 64];
        let bogus = B64URL.encode([7u8; 32]);
        let e = decrypt_claim(&blob, &bogus).unwrap_err();
        assert!(
            e.contains("解不开"),
            "错误应是给人看的话,而不是密码学术语:{e}"
        );
    }
}
