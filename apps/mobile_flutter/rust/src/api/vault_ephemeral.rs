//! 临时会话(即焚)—— 「医生代拍病人纸质材料」流程专用的**平行** vault cell。
//!
//! 与 `api::vault::VAULT`(医生自己的保险箱)完全独立:不同的进程级 `static`、
//! 不同的磁盘根(`getTemporaryDirectory()` 下的一次性子目录,绝不进
//! docs/vault/profiles 子树)、一次性随机 `device_id`(`core_model::generate_device_id`,
//! 不落盘、不用 `machine_device_id`——分享件不该带医生自己的设备身份)。这样任何
//! 走神的调用**结构上不可能**读到/写到医生自己的病历,也不可能把病人数据误认成
//! 医生自己的档案。
//!
//! **故意与 `api::vault` 零共享代码**(不 `pub(crate)` 暴露 `vault.rs` 的
//! `VaultState`/`ingest_one`/`doc_summary` 等给这里复用,哪怕逻辑重复)。上一版
//! (`feat/doctor-proxy-mode` 分支)把 `vault.rs` 的这些函数抽成 `pub(crate)` 的
//! `*_core` 自由函数供本模块调用,那次改动上线后真机 OCR 识别质量出现回归——
//! 即使 OCR 函数本身字节未变,`vault.rs` 的结构改动仍是唯一的嫌疑改动。这次
//! 宁可整段复制 `ingest_image_with_text`/`ingest_bytes`/`load_archive`/
//! `create_share` 的落库逻辑,也不碰 `vault.rs` 一个字节——本文件对 `vault.rs`
//! 的 git diff 恒为 0。
use crate::api::dto::*;
use core_model::{DocType, NewDocument, NewOcr, OcrBackendKind, Vault};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

// 与 `vault.rs` 顶部同名常量逐字复制(该文件禁止修改,故不能 `pub(crate)` 借用)。
// 移动端图片 OCR 落库时如实标注引擎(溯源):iOS 走 PP-OCRv5,安卓走 Google ML Kit。
#[cfg(target_os = "ios")]
const MOBILE_OCR_BACKEND: OcrBackendKind = OcrBackendKind::Onnx;
#[cfg(not(target_os = "ios"))]
const MOBILE_OCR_BACKEND: OcrBackendKind = OcrBackendKind::MlKit;
#[cfg(target_os = "ios")]
const MOBILE_OCR_MODEL: &str = "pp-ocrv5-mobile";
#[cfg(not(target_os = "ios"))]
const MOBILE_OCR_MODEL: &str = "mlkit-v2-zh";

/// 会话目录名前缀,`ephemeral_sweep` 据此识别、清理崩溃/异常退出留下的残留目录。
const EPHEMERAL_DIR_PREFIX: &str = "ephemeral-";

/// 临时会话持有的状态。与 `api::vault::VaultState` 字段相似但**不是同一个类型**
/// (故意不共享——见文件顶部说明);只留临时会话真正用到的字段。
struct EphemeralState {
    vault: Vault,
    truth_root: PathBuf,
    data_dir: PathBuf,
}

static EPHEMERAL: OnceLock<Mutex<Option<EphemeralState>>> = OnceLock::new();

fn ephemeral_cell() -> &'static Mutex<Option<EphemeralState>> {
    EPHEMERAL.get_or_init(|| Mutex::new(None))
}

/// 在已开始的临时会话上跑 `f`。恢复被污染的锁而不是让此后每次调用都失败——
/// 与 `vault::with_state` 同一理由。
fn with_ephemeral<T>(f: impl FnOnce(&EphemeralState) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let guard = ephemeral_cell().lock().unwrap_or_else(|p| p.into_inner());
    let state = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("临时会话尚未开始,请先调用 ephemeral_begin"))?;
    f(state)
}

/// 开始一次临时会话:在 `<cache_dir>/ephemeral-<随机>/` 下建全新空箱并打开。
///
/// `cache_dir` 由 Dart 侧传入 `getTemporaryDirectory()`(不进 iCloud/云备份,系统
/// 可随时清空——即焚语义与「系统可能替我们清」互为兜底)。会话目录后缀取一次性
/// 随机 `device_id` 的前 16 位:既避免与其它并发/历史会话撞名,又不必再引入一个
/// 独立的随机源。`device_id` 本身**不落盘、不复用** `machine_device_id`——分享件
/// 因此不带医生本机的设备身份。
pub fn ephemeral_begin(cache_dir: String) -> anyhow::Result<()> {
    let cache_root = PathBuf::from(cache_dir);
    std::fs::create_dir_all(&cache_root)?;

    let device_id = core_model::generate_device_id();
    let session_root = cache_root.join(format!("{EPHEMERAL_DIR_PREFIX}{}", &device_id[..16]));
    if session_root.exists() {
        // 极小概率的目录名碰撞(或上次残留未被 sweep 清掉):清空重来,绝不复用旧内容。
        std::fs::remove_dir_all(&session_root)?;
    }
    std::fs::create_dir_all(&session_root)?;

    let truth_root = session_root.join("vault");
    let db_path = truth_root.join("medme.db");
    let data_dir = session_root.join("data"); // ingest 临时文件等落这里
    std::fs::create_dir_all(&data_dir)?;

    let vault = Vault::open_split_resilient(&truth_root, &db_path, &device_id)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;

    let mut guard = ephemeral_cell().lock().unwrap_or_else(|p| p.into_inner());
    *guard = Some(EphemeralState {
        vault,
        truth_root,
        data_dir,
    });
    Ok(())
}

/// 从一份文档的 OCR 文本里识别患者姓名。与 `vault.rs::detected_name_for` 同逻辑
/// (逐字复制,见文件顶部「零共享代码」说明)。
fn detected_name_for(v: &Vault, doc_id: i64) -> Option<String> {
    v.ocr_text(doc_id)
        .ok()
        .and_then(|t| parser::extract_demographics(&t).name)
}

/// 与 `vault.rs::ingest_one` 同逻辑(逐字复制):panic firewall,parser/dicom 栈里
/// 的 panic 不能一路 unwind 穿过持锁的 Vault、污染共享 Mutex。
fn ingest_one(v: &Vault, path: &Path) -> ImportOutcomeDto {
    let dispatched = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        pipeline::ingest(v, path)
    })) {
        Ok(r) => r,
        Err(_) => Err(anyhow::anyhow!("导入时发生内部错误(已隔离),该文件已跳过")),
    };
    match dispatched {
        Ok(o) => {
            let status = match o.status {
                pipeline::IngestStatus::New => "new",
                pipeline::IngestStatus::Backfilled => "backfilled",
                pipeline::IngestStatus::Deduped => "deduped",
                pipeline::IngestStatus::StoredNoText => "stored_no_text",
                pipeline::IngestStatus::InstanceAttached => "instance_attached",
            }
            .to_string();
            let document_id = v
                .document_by_source_file_id(o.source_file_id)
                .ok()
                .flatten()
                .map(|d| d.id);
            let detected_name = document_id.and_then(|id| detected_name_for(v, id));
            ImportOutcomeDto {
                name: o.name,
                source_file_id: o.source_file_id,
                status,
                doc_type: o.doc_type.map(|d| d.as_str().to_string()),
                document_id,
                detected_name,
            }
        }
        Err(e) => {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "unknown".to_string());
            eprintln!("[ephemeral-ingest] failed for {}: {e}", path.display());
            ImportOutcomeDto {
                name,
                source_file_id: 0,
                status: "failed".to_string(),
                doc_type: None,
                document_id: None,
                detected_name: None,
            }
        }
    }
}

/// 采集(字节直传,如「选择文件」拿到的 PDF/TXT):与 `vault.rs::ingest_bytes` 同
/// 落库语义(逐段复制),落临时会话箱。
pub fn ephemeral_ingest_bytes(filename: String, data: Vec<u8>) -> anyhow::Result<ImportOutcomeDto> {
    if data.is_empty() {
        anyhow::bail!("空文件,未采集到任何数据");
    }
    if data.len() as u64 > pipeline::MAX_INGEST_BYTES {
        anyhow::bail!(
            "文件过大:{} 字节,超过上限 {} 字节(200MB),已拒绝采集 / file too large",
            data.len(),
            pipeline::MAX_INGEST_BYTES
        );
    }
    let base = Path::new(&filename)
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|n| !n.is_empty())
        .unwrap_or("capture.jpg");
    let safe_name = if Path::new(base).extension().is_some() {
        base.to_string()
    } else {
        format!("{base}.jpg")
    };

    with_ephemeral(|state| {
        let stamp = chrono::Utc::now().format("%Y%m%d%H%M%S%f");
        let tmp_dir = state.data_dir.join("medme-ingest").join(stamp.to_string());
        std::fs::create_dir_all(&tmp_dir)?;
        let tmp_path = tmp_dir.join(&safe_name);
        std::fs::write(&tmp_path, &data)?;

        let v = &state.vault;
        let outcome = ingest_one(v, &tmp_path);
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let _ = std::fs::remove_dir_all(&tmp_dir); // 尽力清理,失败无妨
        Ok(outcome)
    })
}

/// 采集(图片,Flutter 端已用现有 `recognizeImageText`——iOS Vision/PP-OCR、安卓
/// ML Kit——识别好文本):与 `vault.rs::ingest_image_with_text` 同落库语义
/// (逐段复制),落临时会话箱。**本函数不碰任何 OCR 逻辑**,只接收调用方已识别好
/// 的文本 + 置信度。
pub fn ephemeral_ingest_image_with_text(
    name: String,
    bytes: Vec<u8>,
    ocr_text: String,
    confidence: f32,
) -> anyhow::Result<ImportOutcomeDto> {
    if bytes.is_empty() {
        anyhow::bail!("空文件,未采集到任何数据");
    }
    if bytes.len() as u64 > pipeline::MAX_INGEST_BYTES {
        anyhow::bail!(
            "文件过大:{} 字节,超过上限 {} 字节(200MB),已拒绝采集 / file too large",
            bytes.len(),
            pipeline::MAX_INGEST_BYTES
        );
    }
    let base = Path::new(&name)
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|n| !n.is_empty())
        .unwrap_or("capture.jpg");
    let safe_name = if Path::new(base).extension().is_some() {
        base.to_string()
    } else {
        format!("{base}.jpg")
    };

    with_ephemeral(|state| {
        let v = &state.vault;
        let mime = pipeline::mime_for(Path::new(&safe_name));
        let imp = v
            .import(&safe_name, mime, &bytes)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let sid = imp.source_file.id;

        let outcome = if imp.deduped
            && v.has_document(sid)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            ImportOutcomeDto {
                name: safe_name.clone(),
                source_file_id: sid,
                status: "deduped".to_string(),
                doc_type: None,
                document_id: None,
                detected_name: None,
            }
        } else {
            let text = ocr_text.trim().to_string();
            if !text.is_empty() {
                let doc_type = parser::classify(&text);
                let (doc_date, doc_date_end) = parser::guess_date_range(&text);
                let doc = v
                    .add_document(NewDocument {
                        source_file_id: sid,
                        doc_type: doc_type.clone(),
                        doc_date,
                        doc_date_end,
                        title: Some(safe_name.clone()),
                        language: parser::detect_language(&text),
                        page_count: 1,
                    })
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                v.add_ocr(NewOcr {
                    document_id: doc.id,
                    page_no: 1,
                    backend: MOBILE_OCR_BACKEND,
                    model_version: MOBILE_OCR_MODEL.into(),
                    text: ocr_text,
                    confidence: Some(confidence),
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                let status = if imp.deduped { "backfilled" } else { "new" };
                ImportOutcomeDto {
                    name: safe_name.clone(),
                    source_file_id: sid,
                    status: status.to_string(),
                    doc_type: Some(doc_type.as_str().to_string()),
                    document_id: Some(doc.id),
                    detected_name: parser::extract_demographics(&text).name,
                }
            } else {
                let (doc_date, doc_date_end) = parser::guess_date_range(&safe_name);
                let doc_type = parser::classify(&safe_name);
                let doc = v
                    .add_document(NewDocument {
                        source_file_id: sid,
                        doc_type: doc_type.clone(),
                        doc_date,
                        doc_date_end,
                        title: Some(safe_name.clone()),
                        language: None,
                        page_count: 1,
                    })
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                ImportOutcomeDto {
                    name: safe_name.clone(),
                    source_file_id: sid,
                    status: "stored_no_text".to_string(),
                    doc_type: Some(doc_type.as_str().to_string()),
                    document_id: Some(doc.id),
                    detected_name: None, // 无文本,识别不到名字
                }
            }
        };
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(outcome)
    })
}

/// 影像 study 文档在时间线上显示切片数;与 `vault.rs::doc_summary` 同逻辑
/// (逐字复制)。
fn doc_summary(v: &Vault, d: &core_model::Document) -> DocumentSummaryDto {
    let mut s = DocumentSummaryDto::from(d);
    if d.doc_type == DocType::ImagingReport {
        if let Ok(n) = v.imaging_instance_count(d.id) {
            if n > 0 {
                s.slice_count = Some(n as i32);
            }
        }
    }
    s
}

/// 预览时间线:与 `vault.rs::load_archive` 同逻辑(逐段复制),给医生在交付前
/// 核对这次代拍收了什么、分类对不对。
pub fn ephemeral_load_preview() -> anyhow::Result<Vec<TimelineGroupDto>> {
    with_ephemeral(|state| {
        let v = &state.vault;
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?; // 幂等
        let mut groups: Vec<(Option<String>, TimelineGroupDto)> = Vec::new();
        for (enc, docs) in v
            .encounters_with_docs()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            let sort = enc.start_date.map(|d| d.to_rfc3339());
            let summary = EncounterSummaryDto::from_encounter(&enc, docs.len() as i64);
            let doc_dtos = docs.iter().map(|d| doc_summary(v, d)).collect();
            groups.push((
                sort,
                TimelineGroupDto::Encounter {
                    encounter: summary,
                    docs: doc_dtos,
                },
            ));
        }
        for d in v
            .standalone_documents()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            let sort = d.doc_date.map(|x| x.to_rfc3339());
            groups.push((
                sort,
                TimelineGroupDto::Document {
                    doc: doc_summary(v, &d),
                },
            ));
        }
        groups.sort_by(|a, b| match (&a.0, &b.0) {
            (Some(x), Some(y)) => y.cmp(x),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        });
        Ok(groups.into_iter().map(|(_, g)| g).collect())
    })
}

impl From<ConsentDto> for medme_share::share::ShareConsent {
    fn from(c: ConsentDto) -> Self {
        medme_share::share::ShareConsent {
            utc_ts: c.utc_ts,
            consent_text_version: c.consent_text_version,
            signature_png_base64: c.signature_png_base64,
            method: c.method,
            session_id: c.session_id,
        }
    }
}

/// 打包成自包含加密 HTML(带拍前同意记录),写进**临时会话箱**的 `shares/`——
/// 不是医生自己的 vault。与 `vault.rs::create_share` 同逻辑(逐段复制),唯一
/// 差异是永远经 `medme_share::share::build_encrypted_share_with_consent` 传入
/// `consent`(该函数是纯加法,不影响 `vault.rs::create_share` 走的
/// `build_encrypted_share` 原路径)。
pub fn ephemeral_create_share(
    expires_days: i64,
    consent: ConsentDto,
) -> anyhow::Result<ShareResultDto> {
    let days: u32 = expires_days
        .try_into()
        .map_err(|_| anyhow::anyhow!("expires_days 取值无效:{expires_days}"))?;

    with_ephemeral(|state| {
        let v = &state.vault;
        let (html, passphrase, record_count) =
            medme_share::share::build_encrypted_share_with_consent(
                v,
                days,
                &medme_share::render_dicom_png_in_process,
                consent.into(),
            )
            .map_err(|e| anyhow::anyhow!(e))?;
        let byte_size = html.len() as i64;
        let sha256 = core_model::cas::sha256_hex(html.as_bytes());

        let shares_dir = state.truth_root.join("shares");
        std::fs::create_dir_all(&shares_dir)?;
        let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
        let dest = shares_dir.join(format!("medme-share-{stamp}.html"));
        std::fs::write(&dest, html)?;

        let expires = (chrono::Utc::now() + chrono::Duration::days(days as i64)).to_rfc3339();
        v.record_share(&sha256, record_count, &expires)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(ShareResultDto {
            passphrase,
            record_count,
            byte_size,
            path: dest.to_string_lossy().to_string(),
        })
    })
}

/// 即焚:关掉这次会话的 db/日志句柄(`drop`),再整棵删掉它的会话根目录
/// (CAS 原字节 + 事件日志 + db/wal/shm + OCR 文本 + 生成的 share html 全在这棵目录下,
/// 一次 `remove_dir_all` 清干净)。cell 置空。用户取消 / 交付完成 / 路由 dispose 兜底
/// 都调这个,幂等——未开始过会话时是 no-op。
pub fn ephemeral_wipe() -> anyhow::Result<()> {
    let mut guard = ephemeral_cell().lock().unwrap_or_else(|p| p.into_inner());
    if let Some(state) = guard.take() {
        let session_root = state.truth_root.parent().map(|p| p.to_path_buf());
        drop(state); // 显式:先关连接/日志句柄,再删目录
        if let Some(root) = session_root {
            let _ = std::fs::remove_dir_all(&root); // 尽力删除;失败不致命,sweep 兜底
        }
    }
    Ok(())
}

/// 启动时清崩溃残留:遍历 `<cache_dir>` 下所有 `ephemeral-*` 前缀目录并删除。
/// App 启动(`main()`,`RustLib.init()` 之后)调一次。不依赖当前进程是否持有某个
/// cell(上次进程崩溃/被系统杀掉时,`ephemeral_wipe` 根本没机会跑,残留只能靠这个
/// 兜底 + 系统本就可能随时清空 `getTemporaryDirectory()` 双保险)。
pub fn ephemeral_sweep(cache_dir: String) -> anyhow::Result<()> {
    let cache_root = PathBuf::from(cache_dir);
    let entries = match std::fs::read_dir(&cache_root) {
        Ok(e) => e,
        Err(_) => return Ok(()), // 目录不存在等同「没有残留」,不是错误
    };
    for entry in entries.flatten() {
        let is_ephemeral_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false)
            && entry
                .file_name()
                .to_str()
                .is_some_and(|n| n.starts_with(EPHEMERAL_DIR_PREFIX));
        if is_ephemeral_dir {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // 这些测试串行跑同一个进程级 EPHEMERAL cell(和生产代码一样,一次只有一个
    // 活跃会话),不能像多数 Rust 测试那样并发跑;用一把粗互斥锁串行化,避免
    // 相互践踏对方的会话状态。
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn begin_ingest_wipe_round_trip() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let cache = tempfile::tempdir().unwrap();
        let cache_dir = cache.path().to_string_lossy().to_string();

        ephemeral_begin(cache_dir.clone()).unwrap();

        // 会话目录应已在 cache_dir 下创建,前缀符合 sweep 的识别规则。
        let session_dirs: Vec<_> = std::fs::read_dir(&cache_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .is_some_and(|n| n.starts_with(EPHEMERAL_DIR_PREFIX))
            })
            .collect();
        assert_eq!(session_dirs.len(), 1, "应恰好建了一个会话目录");

        let outcome =
            ephemeral_ingest_bytes("血常规.txt".into(), b"data".to_vec().repeat(50)).unwrap();
        assert_eq!(outcome.status, "new");

        let preview = ephemeral_load_preview().unwrap();
        assert_eq!(preview.len(), 1, "刚采集的一份应出现在预览时间线里");

        ephemeral_wipe().unwrap();

        // wipe 之后会话目录应已被整棵删除。
        let remaining: Vec<_> = std::fs::read_dir(&cache_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .is_some_and(|n| n.starts_with(EPHEMERAL_DIR_PREFIX))
            })
            .collect();
        assert!(remaining.is_empty(), "wipe 后不应残留会话目录");

        // 未开始会话时调用应报错(不是 panic),wipe 则应是无害 no-op。
        assert!(ephemeral_load_preview().is_err());
        ephemeral_wipe().unwrap(); // 幂等:再 wipe 一次不报错
    }

    #[test]
    fn sweep_removes_crash_leftovers_but_not_other_dirs() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let cache = tempfile::tempdir().unwrap();
        let cache_dir = cache.path().to_string_lossy().to_string();

        // 模拟一次崩溃残留(没走 wipe 就没了的会话目录)+ 一个不相关的目录。
        std::fs::create_dir_all(cache.path().join(format!("{EPHEMERAL_DIR_PREFIX}deadbeef")))
            .unwrap();
        std::fs::create_dir_all(cache.path().join("not-ephemeral")).unwrap();

        ephemeral_sweep(cache_dir).unwrap();

        assert!(!cache
            .path()
            .join(format!("{EPHEMERAL_DIR_PREFIX}deadbeef"))
            .exists());
        assert!(
            cache.path().join("not-ephemeral").exists(),
            "不应误删无关目录"
        );
    }

    #[test]
    fn ephemeral_create_share_embeds_consent() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let cache = tempfile::tempdir().unwrap();
        ephemeral_begin(cache.path().to_string_lossy().to_string()).unwrap();
        ephemeral_ingest_bytes("a.txt".into(), b"hello world".to_vec()).unwrap();

        let consent = ConsentDto {
            utc_ts: "2026-07-22T10:00:00Z".into(),
            consent_text_version: "v1".into(),
            signature_png_base64: Some("iVBORw0KGgo=".into()),
            method: "signature".into(),
            session_id: "sess-test".into(),
        };
        let result = ephemeral_create_share(7, consent).unwrap();
        assert!(result.byte_size > 0);
        assert!(!result.passphrase.is_empty());

        ephemeral_wipe().unwrap();
    }
}
