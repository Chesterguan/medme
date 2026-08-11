//! FRB 全量 vault API —— 镜像 Tauri 移动端 `apps/mobile/src-tauri/src/commands.rs`
//! 与 `lib.rs`(AppState/resolve_vault_paths/open_vault_with_fallback)的能力,底下
//! 调的是同一套 `core-model`/`pipeline`/`medme-share`/`dicom`/`parser`,保证保险箱
//! 格式与桌面**逐字节一致**(直接复用 core-model,不另写序列化)。
//!
//! 与 Tauri 版的结构差异只在于「怎么拿到 Vault」:Tauri 用 `tauri::State`(每次
//! 调用由框架注入 `AppState`);FRB 函数是纯自由函数,没有这个注入点,所以这里用
//! 一个进程级 `static VAULT` 替代 `AppState`,`open_vault` 初始化它、其余函数取锁
//! 使用 —— 语义与 Tauri 版的 `AppState`/`VaultPaths` 一致(真相根/派生库路径/
//! 设备 id 一起存,重置/迁移时一并替换)。
use crate::api::dto::*;
use crate::diagnostics::warn as log_warn;
// `StreamSink` 不是 `flutter_rust_bridge` crate 本身导出的类型——codegen 按
// `frb_generated_stream_sink!` 宏把它生成进 `frb_generated.rs`,API 侧照官方
// 约定从那里 `use`(见 `load_demo_data` 的进度回报,`DemoLoadProgressDto`)。
use crate::frb_generated::StreamSink;
use core_model::{DocType, NewDocument, NewOcr, OcrBackendKind, Vault};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

// 移动端图片 OCR 落库时如实标注引擎(溯源):iOS + 安卓都走 PP-OCRv5(ONNX
// Runtime,见 `ocr_bridge.dart` 的 `recognize_image_pp` 分支;安卓侧
// feat/android-pp-ocr,ADR 0005 尚未 supersede)。按编译目标区分——本 crate 由
// cargokit 分别为 aarch64-apple-ios / Android 交叉编译;ML Kit 依赖还留着
// (`recognizeImageText` 的 else 分支,`google_mlkit_text_recognition` 未删),
// 万一某些安卓机型上 PP 表现不好可以退回,但默认走 PP。
#[cfg(pp_ocr)]
const MOBILE_OCR_BACKEND: OcrBackendKind = OcrBackendKind::Onnx;
#[cfg(not(pp_ocr))]
const MOBILE_OCR_BACKEND: OcrBackendKind = OcrBackendKind::MlKit;
#[cfg(pp_ocr)]
const MOBILE_OCR_MODEL: &str = "pp-ocrv5-mobile";
#[cfg(not(pp_ocr))]
const MOBILE_OCR_MODEL: &str = "mlkit-v2-zh";

/// 随应用二进制打包的示例数据(张建国示例病历,corpus/scenarios,文本+PDF,
/// 不含大体积 DICOM——与 Tauri 移动端 `demo-data/` 同一份数据集)。
///
/// Tauri 版靠 `bundle.resources` 把 `demo-data/` 打进应用包、运行时用
/// `app.path().resource_dir()` 定位;FRB 生成的是一个纯 Rust 静态库,没有
/// 「应用资源目录」这个概念,也没有 Tauri 的路径 API。最简单、构建期就固定、
/// 无需 Flutter 端额外打包/解压逻辑的做法是用 `include_dir!` 把这份数据集直接
/// 编译进本 crate 的二进制(~4MB,可接受)。见 `load_demo_data`。
static DEMO_DATA: include_dir::Dir<'_> = include_dir::include_dir!("$CARGO_MANIFEST_DIR/demo-data");

/// 全局 Vault 持有者,镜像 Tauri 的 `AppState`:真相根/派生库路径/设备 id 随
/// Vault 一起存(`reset_vault` 需要同时读写这几样)。`data_dir` 是 App 沙盒 data
/// 目录,存 `device_id` 文件,也是 `ingest_bytes`/`load_demo_data` 的临时文件落点
/// (镜像 Tauri 版用 `app_cache_dir()` 存一次性导入临时文件的做法)。
struct VaultState {
    vault: Vault,
    /// 真相(`objects/` + `log/`)所在目录:本机 `<docs_dir>/vault`,或(开了 iCloud
    /// 同步且容器可用时)iCloud 容器 `<container>/Documents/vault`。
    truth_root: PathBuf,
    db_path: PathBuf,
    device_id: String,
    /// App 沙盒 Documents 目录;本机保险箱固定 `<docs_dir>/vault`(关 iCloud 时复制回这)。
    docs_dir: PathBuf,
    data_dir: PathBuf,
}

static VAULT: OnceLock<Mutex<Option<VaultState>>> = OnceLock::new();

fn vault_cell() -> &'static Mutex<Option<VaultState>> {
    VAULT.get_or_init(|| Mutex::new(None))
}

/// 在已打开的 vault 状态上跑 `f`。恢复被污染的锁而不是让此后每次调用都失败——
/// 镜像 Tauri 版 `commands::lock()` 的理由:Vault 的「真相」是追加式日志 + CAS,
/// 一把被 panic 污染过的锁里的 Vault 仍然可用。
fn with_state<T>(f: impl FnOnce(&VaultState) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let guard = vault_cell().lock().unwrap_or_else(|p| p.into_inner());
    let state = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("保险箱尚未打开,请先调用 open_vault"))?;
    f(state)
}

/// 需要替换 `VaultState` 本身(目前只有 `reset_vault`)时用这个。
fn with_state_mut<T>(f: impl FnOnce(&mut VaultState) -> anyhow::Result<T>) -> anyhow::Result<T> {
    let mut guard = vault_cell().lock().unwrap_or_else(|p| p.into_inner());
    let state = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("保险箱尚未打开,请先调用 open_vault"))?;
    f(state)
}

/// 本机持久设备 id,存在 `<data_dir>/device_id`(沙盒 data 目录,不进保险箱本身——
/// 保险箱可能是个跨设备共享/同步的文件夹,设备 id 必须留在本机)。首次打开时生成
/// 并落盘。镜像 Tauri 版 `lib.rs::machine_device_id`。
fn machine_device_id(data_dir: &Path) -> anyhow::Result<String> {
    let file = data_dir.join("device_id");
    if let Ok(s) = std::fs::read_to_string(&file) {
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    let id = core_model::generate_device_id();
    std::fs::write(&file, &id)?;
    Ok(id)
}

/// 影像 study 文档在时间线上显示切片数;非影像文档 slice_count 为 None。
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

/// 打开(或新建)保险箱。iCloud 容器路径由 **Dart 侧经 MethodChannel 解析后传入**
/// (`icloud_container_dir`,容器根目录;不可用/非 iOS 传 `None`)——避免 Rust 框架
/// 反向链接 app target 的 Swift 符号(Flutter 插件框架不允许,会 archive linker 失败)。
///
/// 是否用 iCloud 布局以持久标记 `<data_dir>/icloud_enabled` 为准(enable/disable 写/删)。
/// 开了标记且传入了容器 → 真相在 `<container>/Documents/vault`、派生库在沙盒;否则本机
/// `<docs_dir>/vault`。在解析出的 truth_root 打开失败则回退本机,绝不因 iCloud 问题崩。
pub fn open_vault(
    docs_dir: String,
    data_dir: String,
    icloud_container_dir: Option<String>,
) -> anyhow::Result<()> {
    let docs_dir = PathBuf::from(docs_dir);
    let data_dir = PathBuf::from(data_dir);
    std::fs::create_dir_all(&docs_dir)?;
    std::fs::create_dir_all(&data_dir)?;
    let device_id = machine_device_id(&data_dir)?;

    let local_vault = docs_dir.join("vault");
    let local_db = local_vault.join("medme.db");
    let (truth_root, db_path) =
        resolve_vault_paths(&docs_dir, &data_dir, icloud_container_dir.as_deref());

    let (vault, truth_root, db_path) =
        open_resilient_with_fallback(&truth_root, &db_path, &local_vault, &local_db, &device_id)?;

    let mut guard = vault_cell().lock().unwrap_or_else(|p| p.into_inner());
    *guard = Some(VaultState {
        vault,
        truth_root,
        db_path,
        device_id,
        docs_dir,
        data_dir,
    });
    Ok(())
}

/// 决定真相/派生库路径:开了 iCloud 标记且 Dart 传入了容器根 → 真相在
/// `<container>/Documents/vault`(与旧 Tauri 版路径拼法一致)、派生库在沙盒
/// `<data_dir>/medme.db`;否则本机 `<docs_dir>/vault`(派生库同目录)。
fn resolve_vault_paths(
    docs_dir: &Path,
    data_dir: &Path,
    container: Option<&str>,
) -> (PathBuf, PathBuf) {
    let local_vault = docs_dir.join("vault");
    let local_db = local_vault.join("medme.db");
    if data_dir.join("icloud_enabled").exists() {
        if let Some(c) = container {
            // `container` 是 Dart 拼好的「该成员的 iCloud 目录基」(含 Documents 及
            // 多成员子文件夹),这里只补 `vault`;派生库放**该成员的本机基目录**下
            // (每成员独立、且不进 iCloud——多成员共用 data_dir/medme.db 会撞库)。
            let _ = data_dir;
            let cv = Path::new(c).join("vault");
            return (cv, docs_dir.join("medme.db"));
        }
    }
    (local_vault, local_db)
}

/// 在 `truth_root` 用 `open_split_resilient` 打开(派生库损坏可从日志重建);失败且
/// truth_root 非本机时回退本机沙盒保险箱。返回实际使用的 `(vault, truth_root, db_path)`。
fn open_resilient_with_fallback(
    truth_root: &Path,
    db_path: &Path,
    local_vault: &Path,
    local_db: &Path,
    device_id: &str,
) -> anyhow::Result<(Vault, PathBuf, PathBuf)> {
    match Vault::open_split_resilient(truth_root, db_path, device_id) {
        Ok(v) => Ok((v, truth_root.to_path_buf(), db_path.to_path_buf())),
        Err(_) if truth_root != local_vault => {
            let v = Vault::open_split_resilient(local_vault, local_db, device_id)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok((v, local_vault.to_path_buf(), local_db.to_path_buf()))
        }
        Err(e) => Err(anyhow::anyhow!(e.to_string())),
    }
}

/// 健康档案时间线:就诊组 + 独立文档,按日期倒序(无日期最后)。与桌面/Tauri
/// 移动端的 `load_archive` 同构——复用同一套 core-model 查询。
pub fn load_archive() -> anyhow::Result<Vec<TimelineGroupDto>> {
    with_state(|state| {
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

/// 文档详情:类型/日期 + 来源文件 + 识别文本。与桌面/Tauri 移动端的
/// `get_document` 同构。
pub fn get_document(id: i64) -> anyhow::Result<DocumentDetailDto> {
    with_state(|state| {
        let v = &state.vault;
        let doc = v
            .document_by_id(id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("找不到文档 {id}"))?;
        let sf = v
            .source_file_by_id(doc.source_file_id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("来源文件缺失"))?;
        let ocr_text = v.ocr_text(id).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let ocr_confidence = v
            .ocr_confidence(id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let ocr_backend = v
            .ocr_backend(id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(DocumentDetailDto {
            document: doc_summary(v, &doc),
            source_file: SourceFileMetaDto::from(&sf),
            ocr_text,
            ocr_confidence,
            ocr_backend,
        })
    })
}

/// 一份来源文件在磁盘上的**绝对路径**(CAS `objects/…` 下的对象文件)。
///
/// 供 iOS「查看原件」路径在读盘前先把可能被 iCloud 逐出的对象物化到本地用:Dart
/// 拿到此路径后经 `medme/icloud` MethodChannel 触发 `startDownloadingUbiquitousItem`
/// 并等待下载完成(见 `AppDelegate.swift` 的 `ensureDownloaded`),再调
/// `read_source_bytes` / `render_dicom_png` 读盘。安卓无 iCloud、不走这一步。
pub fn source_file_object_path(id: i64) -> anyhow::Result<String> {
    with_state(|state| {
        let v = &state.vault;
        let sf = v
            .source_file_by_id(id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("找不到来源文件 {id}"))?;
        Ok(v.root_join(&sf.storage_path).to_string_lossy().to_string())
    })
}

/// 一份来源文件的原始字节(图片文档据此渲染缩略图/大图)。与桌面/Tauri 移动端的
/// `read_source_bytes` 同构。iOS 上保险箱开了 iCloud 同步时,`objects/` 里的对象可能
/// 被 iCloud 逐出(替换为 `.icloud` 占位符);Dart 侧在调用本函数前已按平台先经
/// `source_file_object_path` + `medme/icloud`.`ensureDownloaded` 把对象物化回本地,
/// 故这里保持一次普通读盘(已在本地的对象即快路径,不触发任何网络/下载)。
pub fn read_source_bytes(id: i64) -> anyhow::Result<Vec<u8>> {
    with_state(|state| {
        let v = &state.vault;
        let sf = v
            .source_file_by_id(id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("找不到来源文件 {id}"))?;
        let bytes = std::fs::read(v.root_join(&sf.storage_path))?;
        Ok(bytes)
    })
}

/// 渲染一份 DICOM 来源文件的锚点切片为 PNG。
///
/// 安全:`apps/mobile_flutter/rust/Cargo.toml` 给 iOS + 安卓两端都关掉了 `dicom`
/// 的 `codecs` 特性(C/C++ JPEG2000/JPEG-LS 解码器,GHSA-24px 的 RCE 面),与
/// Tauri 移动端 `apps/mobile/src-tauri/Cargo.toml` 的取舍完全一致——桌面才需要
/// 子进程隔离渲染(`dicom_subprocess`),移动端直接用 `medme_share` 提供的进程内
/// 渲染器就是安全的(其文档明确写了这点)。不支持的压缩格式返回错误,前端按现有
/// 「无法预览」的降级处理即可。
pub fn render_dicom_png(id: i64) -> anyhow::Result<Vec<u8>> {
    with_state(|state| {
        let v = &state.vault;
        let sf = v
            .source_file_by_id(id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("找不到来源文件 {id}"))?;
        let bytes = std::fs::read(v.root_join(&sf.storage_path))?;
        medme_share::render_dicom_png_in_process(&bytes)
            .ok_or_else(|| anyhow::anyhow!("无法渲染该 DICOM(暂不支持的压缩格式)"))
    })
}

/// 删除一份文档(用户在 review 队列 / 时间线 / 详情页移除)。追加 `DocumentDeleted`
/// 事件 + 重放,原始字节留在 CAS(见 core-model `delete_document`)。文档不存在 = no-op。
/// 前端删完 `bumpVaultRevision` 刷新即可。
pub fn delete_document(document_id: i64) -> anyhow::Result<()> {
    with_state(|state| {
        state
            .vault
            .delete_document(document_id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))
    })
}

/// 把同一批导入的多张单页照片合成一份多页 PDF 文档(「拍了三页化验单却变成三条
/// 独立记录」的修复——见 `pipeline::merge_documents_into_pdf` 的文档注释,那里
/// 写清楚了为什么这个功能能做到零事件类型/零 schema 改动)。
///
/// `document_ids` 至少 2 个,且必须都是当前会话里刚建好的单页图片文档
/// (`page_count == 1`,来源文件 mime 为 png/jpeg/tiff——校验见
/// `merge_documents_into_pdf`,不满足直接报错,错误文案可以原样透给用户)。
/// 合成失败(如某张解码不出)时原文档一份不动;合成成功后才逐个墓碑掉原文档
/// (原始字节仍在 CAS——`delete_document` 同一套 Raw Never Dies 语义)。
///
/// 未跟随 `mod.rs` 顶部「新增模块名排在字典序末尾,不挪动 wire 序号」那条纪律
/// (那条纪律专为保护 `recognize_image_pp`——iOS PP-OCR 路径——的 wire 序号不被
/// 挪动而设,见 `mod.rs` 的注释)。这里新增的是 `vault.rs` 自己模块内的一个全新
/// 读写函数,不在那条纪律的保护范围内,直白的函数名比追加位置更值得优先。
pub fn merge_photos_into_document(
    name: String,
    document_ids: Vec<i64>,
) -> anyhow::Result<MergeOutcomeDto> {
    let base = Path::new(&name)
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|n| !n.is_empty())
        .unwrap_or("merged.pdf");
    let safe_name = if Path::new(base).extension().is_some() {
        base.to_string()
    } else {
        format!("{base}.pdf")
    };
    with_state(|state| {
        let v = &state.vault;
        let outcome = pipeline::merge_documents_into_pdf(v, &safe_name, &document_ids)?;
        let doc = v
            .document_by_source_file_id(outcome.source_file_id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("合并后未能找到新文档"))?;
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(MergeOutcomeDto {
            document_id: doc.id,
            page_count: doc.page_count,
            pages_without_text: outcome.pages_without_text,
            merged_count: document_ids.len() as i64,
        })
    })
}

/// 患者档案头(姓名/性别/年龄/记录数)。与桌面/Tauri 移动端同构。
pub fn patient_profile() -> anyhow::Result<PatientProfileDto> {
    with_state(|state| {
        let p = pipeline::patient_profile(&state.vault)?;
        Ok(PatientProfileDto {
            name: p.name,
            gender: p.gender,
            birth_date: p.birth_date,
            age: p.age,
            record_count: p.record_count,
        })
    })
}

/// 从一份文档的 OCR 文本里识别患者姓名(用于「导错人」核对)。读文本失败或识别不到返回 None。
fn detected_name_for(v: &Vault, doc_id: i64) -> Option<String> {
    v.ocr_text(doc_id)
        .ok()
        .and_then(|t| parser::extract_demographics(&t).name)
}

/// 跑一次 `pipeline::ingest` 并映射成 `ImportOutcomeDto`。抽取失败(扫描图等)
/// 不致命——原文件已进 CAS,返回 status="failed" 让前端提示「未能识别」而非报错
/// 崩溃。与 Tauri 版 `ingest_one` 同构。
///
/// 图片**不走这里**:Flutter 端先用 PP-OCRv5(`ocr_bridge.dart` →
/// `recognize_image_pp`,iOS/安卓同引擎同模型)识别好文本,再走
/// `ingest_image_with_text`。这里只处理 PDF/TXT/DICOM 等有文本层/结构化元数据的
/// 文件类型。(旧注释写「安卓走 google_mlkit_text_recognition」,那条依赖早已
/// 删除,别再据此推断。)
fn ingest_one(v: &Vault, path: &Path) -> ImportOutcomeDto {
    // Panic firewall:parser/dicom 栈里的 panic 不能一路 unwind 穿过持锁的 Vault、
    // 污染共享 Mutex(与 Tauri 版 `ingest_one` 同一理由)。
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
                // 同一份文件再导一次、文档已存在但当年有页缺文本 → 这次顺手
                // 补上了(`pages_without_text` 带出补完之后仍缺的页,可能是空)。
                pipeline::IngestStatus::Reindexed => "reindexed",
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
                pages_without_text: o.pages_without_text,
            }
        }
        Err(e) => {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "unknown".to_string());
            log_warn(&format!("[ingest] failed for {}: {e}", path.display()));
            ImportOutcomeDto {
                name,
                source_file_id: 0,
                status: "failed".to_string(),
                doc_type: None,
                document_id: None,
                detected_name: None,
                pages_without_text: Vec::new(),
            }
        }
    }
}

/// 采集:对一个真实文件路径(如系统文件选择器返回的路径)跑 ingest,然后重建
/// 就诊分组。PDF/TXT/DICOM 走 `pipeline::ingest`。
pub fn ingest_file(path: String) -> anyhow::Result<ImportOutcomeDto> {
    with_state(|state| {
        let v = &state.vault;
        let outcome = ingest_one(v, Path::new(&path));
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(outcome)
    })
}

/// 采集(字节直传):Flutter 侧从相机/相册/文件选择器拿到的字节 + 原始文件名。
/// 落到沙盒 data 目录下的一次性临时文件(保留扩展名——`pipeline::mime_for` 靠
/// 扩展名判 MIME/PDF/DICOM)→ 跑 ingest → 重建分组 → 删临时文件。镜像 Tauri 版
/// `ingest_bytes`,只是临时文件目录用 `data_dir`(FRB 没有 `app_cache_dir()`)。
pub fn ingest_bytes(filename: String, data: Vec<u8>) -> anyhow::Result<ImportOutcomeDto> {
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

    with_state(|state| {
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

/// 扫描版 PDF 的逐页 OCR 回填。`ingest_bytes`/`ingest_pdf`(Rust pipeline)对
/// 没能恢复出文本的页给出 `IngestOutcome::pages_without_text`,文档可能已建好
/// (部分页有文本层)、也可能整份 `stored_no_text`(一页可用文本都没有)。
/// Flutter 侧用 `pdfx` 把这些页逐一渲染成 PNG、走 `recognizeImageText`
/// (PP-OCRv5,iOS/安卓同一条路)拿到文本后,逐页调本函数补进该文档。
///
/// ⚠️ 旧注释说「移动端未链接 Rust OCR 引擎」——**已经不对了**:iOS 与 arm64
/// 安卓都直接依赖 `packages/ocr` 的 `engine`,`pipeline::ingest_pdf` 在端上真的
/// 会去调 PP-OCRv5。但 `ocr::set_model_dir` 只由 `ensure_pp_models_ready`
/// (`recognize_image_pp` 的入口)设置,所以一次会话里**第一份**导入是 PDF 时
/// 模型还没落盘,Rust 侧逐页 OCR 会全部失败、整份落到 `pages_without_text`,
/// 全靠这条回填路径兜底。不是数据丢失(页码如实报了),但白跑一趟。
///
/// `page_no` 是 1-based、对应 PDF 里的真实页码(与 `pages_without_text` 的口径
/// 一致)——不再固定写 1:一份文档现在可能有多条 `ocr_result`(每页一条,
/// `core_model::Vault::add_ocr` 按 `(document_id, page_no)` 天然去重/幂等),
/// `ocr_text` 读取时按页码拼接。只补 `ocr_result`;`doc_type` 暂沿用建档时的
/// 分类(用 OCR 文本重分类属质量提升,另做)。文本为空则报错(调用方不应回填空)。
pub fn backfill_pdf_text(
    document_id: i64,
    page_no: i32,
    text: String,
    confidence: f64,
) -> anyhow::Result<()> {
    let text = text.trim().to_string();
    if text.is_empty() {
        anyhow::bail!("回填文本为空,拒绝");
    }
    with_state(|state| {
        state
            .vault
            .add_ocr(NewOcr {
                document_id,
                page_no,
                backend: MOBILE_OCR_BACKEND,
                model_version: MOBILE_OCR_MODEL.into(),
                text,
                confidence: Some(confidence as f32),
            })
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(())
    })
}

/// 采集(图片,Flutter 端已识别好文本):原始字节先入 CAS(与 `pipeline::ingest`
/// 一致,去重同一张图);识别出文字则建 document + ocr_result(backend 按编译目标
/// 如实标注 `MOBILE_OCR_BACKEND`——iOS=PP-OCRv5/Onnx,安卓=ML Kit;置信度取调用方
/// 传入值);识别为空则退回文件名元数据(`StoredNoText`),原件仍可见。落库语义逐字
/// 镜像 Tauri 版 `ingest_image_via_vision`/`ingest_image_via_mlkit`,只是识别文本来自
/// 参数而非本地再跑一次 OCR。
///
/// **多页原件(多页 TIFF)**:Dart 侧把**文件路径**交给 Apple Vision / ML Kit,
/// 两者都只识别第一帧,所以 `ocr_text` 里永远只有第 1 页。这条路径过去把
/// `page_count` 写死 1、`pages_without_text` 写死空,于是第 2 页起整页丢失而
/// UI 报「已识别入库」——与 `pipeline::ingest_image` 修的是同一个缺陷,只是发生
/// 在移动端这条**不经 `pipeline::ingest`** 的独立路径上(移动端的 `.tiff` 由
/// `isImageName` 判为图片,走的就是这里,不是 `ingest_bytes`)。现在如实带出真实
/// 页数与没读到的页码;调用方 `import_flow.dart` 据此报「N 页未能识别文字」。
pub fn ingest_image_with_text(
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

    // 原件真实页数(多页 TIFF>1,其余一律 1)。`ocr_text` 只可能是第 1 页的,
    // 故 2..=n 是「没读到的页」;一页文字都没识别出来时 1..=n 全都没读到。
    // 单页图片(绝大多数)两者都退化成 1 页 / 空表,行为与旧版逐字节相同。
    let page_count = pipeline::image_page_count(&bytes) as i32;
    let unread_from = |first: i32| -> Vec<i32> {
        if page_count > 1 {
            (first..=page_count).collect()
        } else {
            Vec::new()
        }
    };

    with_state(|state| {
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
                pages_without_text: Vec::new(),
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
                        page_count,
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
                    // 第 1 页有文字,2..=n 没读到。
                    pages_without_text: unread_from(2),
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
                        page_count,
                    })
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                ImportOutcomeDto {
                    name: safe_name.clone(),
                    source_file_id: sid,
                    status: "stored_no_text".to_string(),
                    doc_type: Some(doc_type.as_str().to_string()),
                    document_id: Some(doc.id),
                    detected_name: None, // 无文本,识别不到名字
                    // 一页文字都没有,1..=n 全都没读到。
                    pages_without_text: unread_from(1),
                }
            }
        };
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(outcome)
    })
}

/// `SelfMeasuredValueDto.analyte_key` → 中文标签,只用于合成文本的人类可读部分
/// (不是临床判定,判定/参考区间在 `parser::self_entry::home_ref_range`)。这五个
/// 键是「记录」入口封闭五选一的全部取值 —— 不接受任意字符串,故这里穷举即可,
/// 不需要接一份完整词典(本 crate 未直接依赖 `terminology`,Rust 2018+ 的
/// direct-dependency 规则也不允许隔着 `parser` 传递 `use` 它)。
fn self_measured_label(analyte_key: &str) -> &'static str {
    match analyte_key {
        "bp_systolic" => "收缩压",
        "bp_diastolic" => "舒张压",
        "heart_rate" => "心率",
        "body_weight" => "体重",
        "body_temperature" => "体温",
        "glucose" => "血糖",
        _ => "记录值",
    }
}

/// 这批值该给文档起的标题:血压(收缩压+舒张压同时在场)统一叫「血压」,其余
/// 单值记录直接用那个值的中文标签。
fn self_measured_title(values: &[SelfMeasuredValueDto]) -> String {
    let has = |k: &str| values.iter().any(|v| v.analyte_key == k);
    if has("bp_systolic") || has("bp_diastolic") {
        "血压".to_string()
    } else {
        values
            .first()
            .map(|v| self_measured_label(&v.analyte_key).to_string())
            .unwrap_or_else(|| "记录".to_string())
    }
}

/// 数值渲染:与 `handoff::fmt_num`/`vault_projections::fmt_num` 同一取法 ——
/// `{}` 的默认 f64 格式,`72` 不会印成 `72.0`。合成文本是给人看的,这个 `.0`
/// 是 IEEE 754 的产物,不是用户填的数字。
fn fmt_value(v: f64) -> String {
    format!("{v}")
}

/// `parser::PlausibilityViolation` → 用户可读的中文提示。`parser` crate 没有
/// UI 词汇(不知道"收缩压"这种中文标签怎么说),所以标签拼接放在这一层,复用
/// 已有的 [`self_measured_label`]。这是兜底路径的文案(见调用处注释),不需要
/// 像 `manual_entry_sheet.dart` 那样引导用户改哪个字段,但仍要说清"哪项、
/// 什么值、超出多少"。
fn format_plausibility_violation(v: &parser::PlausibilityViolation) -> String {
    match v {
        parser::PlausibilityViolation::OutOfRange {
            analyte_key,
            value,
            low,
            high,
        } => format!(
            "{}({})超出可能范围({}–{}),请检查是否输入有误",
            self_measured_label(analyte_key),
            fmt_value(*value),
            fmt_value(*low),
            fmt_value(*high),
        ),
        parser::PlausibilityViolation::SystolicNotAboveDiastolic {
            systolic,
            diastolic,
        } => {
            format!(
                "收缩压({})应大于舒张压({}),请检查是否填反了",
                fmt_value(*systolic),
                fmt_value(*diastolic),
            )
        }
    }
}

/// 约定与 `parser::build_date`(导入文档猜日期用的,`packages/parser/src/lib.rs`)
/// 同一条:落库的是"挂钟读数"本身,不做时区换算——`.naive_local()` 取出调用方
/// 传来的偏移下的字面 Y-M-D-H-M-S,`.and_utc()` 只是重新贴 `Utc` 标签(数值不变,
/// 不是"转换到那一刻的真实 UTC 瞬间"),直接落库。
///
/// 这是本次修 bug(自测记录早间测量错位到前一天)定下的约定,别再改回
/// `.with_timezone(&Utc)`——那是真的时区转换,会把"北京时间 06:50"变成
/// "UTC 前一天 22:50",doc_date 与「记录时间」文案都会跟着掉到前一天。
///
/// 自测记录与导入文档因此共享同一套"日期/时间即字面挂钟读数"规则:两者的
/// `doc_date` 按 UTC 分量读出来的都是"文档/用户当时表上的那一天",趋势图
/// 按日归组时不会一边按本地一边按 UTC 而错位。
///
/// 传入的偏移是调用方(`manual_entry_sheet.dart`)当时的真实设备时区,动态
/// 读取、不写死 +08:00——用户出国就医/旅行中测量时,记的是"当时手表上看到的
/// 那一刻"(与本函数对导入文档"PDF 上印的日期,不管文档来自哪个时区"的处理
/// 是同一件事),不追求跨时区场景下的"绝对时刻"还原。
///
/// `measured_at` 缺省(`None`,调用方永远不传——见 `add_self_measurement`/
/// `add_note` 文档)时退到 `Utc::now()`:这是进程的真实 UTC 瞬间,不是"设备本地
/// 此刻",因为没有输入就没有偏移可用——但这条路径不是本次要修的用户 bug 的成因
/// (真实 App 调用方 `manual_entry_sheet.dart` 恒显式传 `measured_at`)。
fn parse_measured_at(measured_at: Option<&str>) -> chrono::DateTime<chrono::Utc> {
    measured_at
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.naive_local().and_utc())
        .unwrap_or_else(chrono::Utc::now)
}

/// 写一条自测记录(结构化,append-only)。血压两个值(收缩压+舒张压)共享
/// 同一份文档/同一个 `measured_at` —— 一次测量是最小操作单元,一起删一起改
/// (MANUAL-ENTRY-DESIGN.md §5.3);其余四项(心率/体重/体温/血糖)各自单独一条
/// 记录一份文档。`measured_at` 缺省(`None`)= 写入时刻,否则调用方传用户选择
/// 的测量时间(RFC3339)。
///
/// 与 DICOM/txt 导入同构(见 `pipeline::add_text_layer_document`/
/// `pipeline::dicom_summary` 的先例):没有原件,把合成文本本身当"文件"过一遍
/// `vault.import`,再走 `add_document`+`add_ocr`。`doc_type` 固定
/// `SelfMeasurement`,不经 `parser::classify` 猜 —— 这条录入路径的类型是
/// 确定的,不需要也不该走给不确定文本猜类型的那条推断。
///
/// 硬约束(设计文档反复强调):**不支持任意化验项**——`values` 里的
/// `analyte_key` 由 Dart 侧封闭五选一界面产出,这里不做白名单校验(校验属于
/// UI 层拒绝非法输入的职责),但也不会因为一个陌生 key 而崩:未知 key 落进
/// `parser::home_ref_range` 的 `_ => None` 分支,裸值显示、不出 flag。
pub fn add_self_measurement(
    values: Vec<SelfMeasuredValueDto>,
    measured_at: Option<String>,
) -> anyhow::Result<i64> {
    with_state(|state| add_self_measurement_to(&state.vault, &values, measured_at.as_deref()))
}

/// [`add_self_measurement`] 的核心逻辑,不经全局 `VAULT` 锁 —— 单独抽出来是为了
/// 让 `load_demo_data`(载入示例数据时,调用者已经在 `with_state` 闭包里持有
/// `&state.vault`,不该再抢一次同一把锁)与单元测试(见文件末尾
/// `home_monitoring_demo_data_tests`,在一个独立临时保险箱上跑,不碰全局静态/
/// `StreamSink`)都走**同一条**写入路径,而不是各自另造一条。参数与
/// [`add_self_measurement`] 逐一对应,只是多一个 `v: &Vault`、`values` 借用而非
/// 移动(两处调用方各自还要用 `values` 拼标题/human_lines,不必两次 clone)。
fn add_self_measurement_to(
    v: &Vault,
    values: &[SelfMeasuredValueDto],
    measured_at: Option<&str>,
) -> anyhow::Result<i64> {
    if values.is_empty() {
        anyhow::bail!("没有要记录的数值");
    }
    let when = parse_measured_at(measured_at);

    let sv: Vec<parser::SelfMeasuredValue> = values
        .iter()
        .map(|v| parser::SelfMeasuredValue {
            analyte_key: v.analyte_key.clone(),
            value: v.value,
            unit: v.unit.clone(),
        })
        .collect();
    // 生理学"可能性"校验(拒绝像 138388 mmHg 这种打错的值,不是判断
    // "正常/偏高"——那是 home_ref_range 的职责,见 `parser::self_entry` 的文档)。
    // `manual_entry_sheet.dart` 保存前已经跑过同一条校验并给出更具体的引导
    // 文案,这里是它被绕过时的兜底——这是所有自测数据写入的唯一入口(不论调用方
    // 是真实用户还是 `load_demo_data`),不能只靠 UI 层这一道防线。
    if let Err(violation) = parser::validate_self_measured_values(&sv) {
        anyhow::bail!(format_plausibility_violation(&violation));
    }

    let mut human_lines: Vec<String> = values
        .iter()
        .map(|v| {
            format!(
                "{} {} {}",
                self_measured_label(&v.analyte_key),
                fmt_value(v.value),
                v.unit
            )
        })
        .collect();
    human_lines.push(format!("记录时间:{}", when.format("%Y-%m-%d %H:%M")));
    let text = parser::render_self_measurement_text(&human_lines, &sv);
    let title = self_measured_title(values);

    let name = format!("self-measurement-{}.txt", when.format("%Y%m%dT%H%M%S%.f"));
    let imp = v
        .import(&name, "text/plain", text.as_bytes())
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let sid = imp.source_file.id;
    // 合成文本逐字节相同(极少见,但见 `Vault::import` 的 CAS 去重)且已建过
    // 档 —— 真·重复提交,直接回传已有文档 id,不再建档(`document.source_file_id`
    // 唯一,重复建档会违反约束)。与 `ingest_image_with_text` 的同一防线同构。
    if imp.deduped
        && v.has_document(sid)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
    {
        return v
            .document_by_source_file_id(sid)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .map(|d| d.id)
            .ok_or_else(|| anyhow::anyhow!("去重后未能找到已有文档"));
    }
    let doc = v
        .add_document(NewDocument {
            source_file_id: sid,
            doc_type: DocType::SelfMeasurement,
            doc_date: Some(when),
            doc_date_end: None,
            title: Some(title),
            language: Some("zh".into()),
            page_count: 1,
        })
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    v.add_ocr(NewOcr {
        document_id: doc.id,
        page_no: 1,
        backend: OcrBackendKind::Native,
        model_version: "self-entry".into(),
        text,
        confidence: None,
    })
    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    v.rebuild_encounters()
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    Ok(doc.id)
}

/// 读回一份 `self_measurement` 文档的结构化值 —— 供「编辑」预填表单用(编辑=
/// 删除旧文档+重新走一遍 `add_self_measurement`,见 MANUAL-ENTRY-DESIGN.md
/// §3.6:没有专门的编辑 API,复用现成的 `delete_document`+新增)。
///
/// 读不出结构化载荷(文档不是这个类型 / 载荷损坏)→ 空列表,调用方按「没有可
/// 编辑的值」处理,不猜(与 `parser::parse_self_measurement_payload` 同一条
/// "读不出就是没有,不半猜"的规矩)。
pub fn self_measurement_values(document_id: i64) -> anyhow::Result<Vec<SelfMeasuredValueDto>> {
    with_state(|state| {
        let text = state
            .vault
            .ocr_text(document_id)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(parser::parse_self_measurement_payload(&text)
            .unwrap_or_default()
            .into_iter()
            .map(|v| SelfMeasuredValueDto {
                analyte_key: v.analyte_key,
                value: v.value,
                unit: v.unit,
            })
            .collect())
    })
}

/// 写一条笔记(纯文本自由文字)。原文即内容 —— 不需要 `self_entry` 那层结构化
/// 载荷编码(那是给数值用的),`ocr_result.text` 直接是用户输入的原文,读回来
/// 就是它本身。`doc_type` 固定 `Note`,不解析、不关联到具体用药/诊断
/// (`aggregate()` 对 `note` 类型文档显式跳过 meds/conditions 抽取)。
///
/// 与 [`add_self_measurement`] 同构:没有原件,把这段文字本身当"文件"过一遍
/// `vault.import`。`measured_at` 缺省 = 写入时刻。
pub fn add_note(text: String, measured_at: Option<String>) -> anyhow::Result<i64> {
    let text = text.trim().to_string();
    if text.is_empty() {
        anyhow::bail!("笔记内容为空");
    }
    let when = parse_measured_at(measured_at.as_deref());
    // 标题取首行(超长截断到 30 个字符——列表页标题不需要整段笔记)。
    let title: String = text
        .lines()
        .next()
        .unwrap_or(&text)
        .chars()
        .take(30)
        .collect();

    with_state(|state| {
        let v = &state.vault;
        let name = format!("note-{}.txt", when.format("%Y%m%dT%H%M%S%.f"));
        let imp = v
            .import(&name, "text/plain", text.as_bytes())
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let sid = imp.source_file.id;
        if imp.deduped
            && v.has_document(sid)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            return v
                .document_by_source_file_id(sid)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?
                .map(|d| d.id)
                .ok_or_else(|| anyhow::anyhow!("去重后未能找到已有文档"));
        }
        let doc = v
            .add_document(NewDocument {
                source_file_id: sid,
                doc_type: DocType::Note,
                doc_date: Some(when),
                doc_date_end: None,
                title: Some(title),
                language: parser::detect_language(&text),
                page_count: 1,
            })
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 1,
            backend: OcrBackendKind::Native,
            model_version: "self-entry".into(),
            text,
            confidence: None,
        })
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(doc.id)
    })
}

/// 端到端加密分享:复用 `medme_share::share::build_encrypted_share`,把全部病历
/// 面对面二维码分享:把「当下病情」压成一条 URL,由手机端渲染成二维码给医生扫。
///
/// 与 [`create_share`] 的分工:那个是**整份病历**(含原件、影像,给医生带走);
/// 这个是**当下病情**(在治的病、关键指标最近几个点、在用的药),只够医生三十秒
/// 看懂大局 —— 要看原件或阅片,患者手机当场翻。
///
/// 载荷有界(见 `medme_share::qr::QrLimits`),因此体积与病历总量无关,永远塞得进
/// 一张二维码。密钥在 URL 的 `#` 之后,按 HTTP 规范不会发给服务器 —— 医生扫码后
/// 只从我们的静态页下载一个空壳查看器,病历数据全程只在两台手机之间。
pub fn build_qr_share_url(base_url: String) -> anyhow::Result<QrShareDto> {
    with_state(|state| {
        let (url, qr) = medme_share::qr::build_qr_share(
            &state.vault,
            &base_url,
            medme_share::qr::QrLimits::default(),
        )
        .map_err(|e| anyhow::anyhow!(e))?;
        Ok(QrShareDto {
            url,
            problem_count: qr.problem_count as i64,
            fits_qr: qr.fits_qr(&base_url),
        })
    })
}

/// 打包成自包含加密 HTML 写进保险箱 `shares/` 目录,返回口令、记录数、字节数与
/// 文件路径。与桌面/Tauri 移动端同构;安全性说明见 `render_dicom_png` 的 doc
/// (进程内 DICOM 渲染在移动端是安全的,`codecs` 特性已关)。
pub fn create_share(expires_days: i64) -> anyhow::Result<ShareResultDto> {
    let days: u32 = expires_days
        .try_into()
        .map_err(|_| anyhow::anyhow!("expires_days 取值无效:{expires_days}"))?;

    with_state(|state| {
        let v = &state.vault;
        let (html, passphrase, record_count) = medme_share::share::build_encrypted_share(
            v,
            days,
            &medme_share::render_dicom_png_in_process,
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

/// 当前进程里打开的是哪个保险箱(真相根目录的绝对路径)。
///
/// 存在的理由是**医生代拍**:开一个代拍病人的箱子会顶掉进程级 vault,写入类调用
/// (ingest / create_proxy_share)必须能在动手前确认「此刻开着的确实是这个病人的
/// 箱子」——把「谁先 await 谁后 await」这种靠不住的约定,换成一次可验证的比对。
/// 见 Dart 侧 `ensureProxyVaultOpen`。
pub fn current_vault_root() -> anyhow::Result<String> {
    with_state(|state| Ok(state.truth_root.to_string_lossy().to_string()))
}

/// 出码用的密文:整份病历(含原件),交给 Dart 传上瞬时云。
///
/// 返回 `(密文, base64url 密钥, 记录数)`。拿到对象 id 后二维码内容是
/// `<查看器>/#q2.<id>.<密钥>` —— 八十来个字符,格子稀疏、隔着桌子好扫。
///
/// **密钥不上传**,只进二维码的 `#` 之后。云上那份我们自己也解不开。
pub fn qr_share_blob(expires_days: i64) -> anyhow::Result<(Vec<u8>, String, i64)> {
    let days: u32 = expires_days
        .try_into()
        .map_err(|_| anyhow::anyhow!("expires_days 取值无效:{expires_days}"))?;
    with_state(|state| {
        medme_share::share::build_own_share_blob(
            &state.vault,
            days,
            &medme_share::render_dicom_png_in_process,
        )
        .map_err(|e| anyhow::anyhow!(e))
    })
}

/// 代拍交付用的密文:**带同意书**、按已确认份数筛选摘要,交给 Dart 传上瞬时云。
///
/// 与 [`qr_share_blob`] 是同一种产物、同一套查看器解密逻辑,差别只有两处:这里带
/// 病人签过字的同意书,并且摘要只统计医生逐份确认过的那些(未确认的原件仍全在包里
/// 并标注待确认)。
///
/// 返回 `(密文, base64url 密钥, 记录数)`。拿到对象 id 后认领链接是
/// `https://medmenow.com/claim/#c1.<id>.<密钥>` —— 病人点开先在浏览器看,再决定存不存。
///
/// **密钥不上传**,只进链接的 `#` 之后。云上那份我们自己也解不开。
pub fn proxy_claim_blob(
    expires_days: i64,
    consent: ConsentDto,
    confirmed_ids: Vec<i64>,
) -> anyhow::Result<(Vec<u8>, String, i64)> {
    let days: u32 = expires_days
        .try_into()
        .map_err(|_| anyhow::anyhow!("expires_days 取值无效:{expires_days}"))?;
    let confirmed: std::collections::HashSet<i64> = confirmed_ids.into_iter().collect();
    with_state(|state| {
        medme_share::share::build_claim_blob(
            &state.vault,
            days,
            &medme_share::render_dicom_png_in_process,
            consent.into(),
            &confirmed,
        )
        .map_err(|e| anyhow::anyhow!(e))
    })
}

/// 认领:把医生代拍的加密包还原进**当前打开的**保险箱。
///
/// `blob` 是从瞬时云取回的密文,`key_b64` 是认领链接 `#` 后面那把钥匙 —— 两者都由
/// Dart 侧拿到后传进来,Rust 不联网(取密文是 Dart 的事,这里只管解密与落盘)。
///
/// 写的是「当前打开的箱子」,所以调用前必须已经切到病人自己要存进去的那个成员。
pub fn claim_import(blob: Vec<u8>, key_b64: String) -> anyhow::Result<ClaimResultDto> {
    with_state(|state| {
        let out = medme_share::claim::import_claim(&state.vault, &blob, &key_b64)
            .map_err(|e| anyhow::anyhow!(e))?;
        Ok(ClaimResultDto {
            imported: out.imported,
            deduped: out.deduped,
            text_only: out.text_only,
        })
    })
}

/// 只解密、不落盘:让病人在「存进哪个成员」之前先看到这包里有几份、是谁的。
/// 返回 `(记录数, 患者姓名)`;姓名解析不出时为空串。
pub fn claim_preview(blob: Vec<u8>, key_b64: String) -> anyhow::Result<(i64, String)> {
    let payload =
        medme_share::claim::decrypt_claim(&blob, &key_b64).map_err(|e| anyhow::anyhow!(e))?;
    let n = payload["records"].as_array().map(|a| a.len()).unwrap_or(0) as i64;
    let name = payload["patient"]["name"]
        .as_str()
        .unwrap_or("")
        .to_string();
    Ok((n, name))
}

/// 代拍(医生模式)专用的加密分享:与 [`create_share`] 只差两点 —— **把拍前同意
/// 记录打进加密包**、且只打包医生逐份确认过的文档。底下与临时会话版
/// `ephemeral_create_share` 调**同一个** `build_encrypted_share_with_consent_and_confirmed`,
/// 产出格式同构。
///
/// 确认状态由调用方(Dart 侧 `ProxyPatientManager`)传入而不是像临时会话那样存在
/// Rust 进程内存里:代拍病人要在本机保留 12 小时、跨 app 重启存活,内存 map 活不了
/// 那么久。Rust 侧不落盘确认状态 = 不动保险箱格式(不新增事件类型)。
pub fn create_proxy_share(
    expires_days: i64,
    consent: ConsentDto,
    confirmed_ids: Vec<i64>,
) -> anyhow::Result<ShareResultDto> {
    let days: u32 = expires_days
        .try_into()
        .map_err(|_| anyhow::anyhow!("expires_days 取值无效:{expires_days}"))?;
    let confirmed: std::collections::HashSet<i64> = confirmed_ids.into_iter().collect();

    with_state(|state| {
        let v = &state.vault;
        let (html, passphrase, record_count) =
            medme_share::share::build_encrypted_share_with_consent_and_confirmed(
                v,
                days,
                &medme_share::render_dicom_png_in_process,
                consent.into(),
                &confirmed,
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

/// 代拍审阅屏的「病情摘要卡」:对**当前打开的**保险箱(= 某个代拍病人的箱子)跑
/// 与 `ephemeral_summary` 同一套装配,只把 `confirmed_ids` 里的文档喂进去。
/// 复用 `vault_ephemeral` 的取文档/映射两个 helper,不另写一套排序与字段映射。
pub fn proxy_summary(confirmed_ids: Vec<i64>) -> anyhow::Result<ProxySummaryDto> {
    let confirmed: std::collections::HashSet<i64> = confirmed_ids.into_iter().collect();
    with_state(|state| {
        let owned = crate::api::vault_ephemeral::gather_ephemeral_docs(&state.vault)?;
        let docs: Vec<parser::SourceDoc> = owned
            .iter()
            .filter(|d| confirmed.contains(&d.document_id))
            .enumerate()
            .map(|(i, d)| parser::SourceDoc {
                index: i,
                date: d.date,
                text: &d.text,
                doc_type: d.doc_type.clone(),
                title: d.title.clone(),
            })
            .collect();
        let summary = parser::assemble_summary(&docs);
        Ok(crate::api::vault_ephemeral::proxy_summary_from_json(
            &summary,
        ))
    })
}

/// 导出时间线:复用 `medme_share::export::build_timeline_html_ranged`,把时间线
/// 渲染成未加密、可打印的自包含 HTML 写进保险箱 `shares/` 目录(与加密分享共用
/// 同一目录——都是本机生成、交给系统分享 sheet 的临时导出件)。
///
/// `from_date` / `to_date` 为可选的 `YYYY-MM-DD`(前端日期选择器传入);任一为空
/// 表示该侧不限,两者都为空即全量导出。`from` 取当天 00:00、`to` 取当天 23:59:59
/// (含端点)。无 `doc_date` 的记录仅在完全不筛选时纳入(见共享 crate 的说明)。
pub fn export_timeline_html(
    from_date: Option<String>,
    to_date: Option<String>,
) -> anyhow::Result<ExportResultDto> {
    let parse = |s: &str, end_of_day: bool| -> anyhow::Result<chrono::DateTime<chrono::Utc>> {
        let d = chrono::NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d")
            .map_err(|e| anyhow::anyhow!("日期格式应为 YYYY-MM-DD:{e}"))?;
        let t = if end_of_day {
            d.and_hms_opt(23, 59, 59)
        } else {
            d.and_hms_opt(0, 0, 0)
        }
        .ok_or_else(|| anyhow::anyhow!("无效日期"))?;
        Ok(t.and_utc())
    };
    let from = from_date
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| parse(s, false))
        .transpose()?;
    let to = to_date
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| parse(s, true))
        .transpose()?;
    with_state(|state| {
        let v = &state.vault;
        let (html, record_count) = medme_share::export::build_timeline_html_ranged(
            v,
            &medme_share::render_dicom_png_in_process,
            from,
            to,
        )
        .map_err(|e| anyhow::anyhow!(e))?;
        let byte_size = html.len() as i64;
        let sha256 = core_model::cas::sha256_hex(html.as_bytes());

        let shares_dir = state.truth_root.join("shares");
        std::fs::create_dir_all(&shares_dir)?;
        let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
        let dest = shares_dir.join(format!("medme-timeline-{stamp}.html"));
        std::fs::write(&dest, html)?;

        v.record_export("timeline_html", &sha256, record_count)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(ExportResultDto {
            record_count,
            byte_size,
            path: dest.to_string_lossy().to_string(),
        })
    })
}

/// 递归收集 `include_dir!` 打进二进制的示例数据集里的全部文件。
fn collect_demo_files<'a>(dir: &'a include_dir::Dir<'a>, out: &mut Vec<&'a include_dir::File<'a>>) {
    out.extend(dir.files());
    for sub in dir.dirs() {
        collect_demo_files(sub, out);
    }
}

/// 张建国示例病历「家庭血压/血糖自测记录」的原始读数 —— 与
/// `demo-data/corpus/2026-04-30_血压记录_家庭监测.pdf` 用 `pdftotext` 通读全文
/// 逐条核对过(不是只看前几行推测后面的)。字段顺序:日期 / 时(24h)/ 分 /
/// 收缩压(mmHg)/ 舒张压(mmHg)/ 心率(次/分)/ 空腹血糖(mmol/L)。PDF 备注列
/// (「晨起」「轻度头晕」等)不落进这张表,见 [`home_monitoring_demo_entries`]
/// 文档——`add_self_measurement` 的入参没有备注字段,不为了塞示例数据改这份
/// 现有接口。
const HOME_MONITORING_READINGS: &[(&str, u32, u32, f64, f64, f64, f64)] = &[
    ("2026-04-01", 6, 50, 138.0, 86.0, 72.0, 7.2),
    ("2026-04-05", 6, 55, 142.0, 88.0, 75.0, 7.6),
    ("2026-04-08", 7, 0, 135.0, 84.0, 70.0, 7.0),
    ("2026-04-12", 7, 10, 142.0, 90.0, 68.0, 7.4),
    ("2026-04-15", 6, 45, 130.0, 80.0, 71.0, 6.8),
    ("2026-04-19", 6, 50, 128.0, 78.0, 69.0, 6.5),
    ("2026-04-22", 6, 55, 126.0, 76.0, 70.0, 6.6),
    ("2026-04-26", 7, 0, 124.0, 78.0, 68.0, 6.4),
    ("2026-04-30", 6, 50, 122.0, 76.0, 70.0, 6.3),
];

/// 把 [`HOME_MONITORING_READINGS`] 展开成 [`add_self_measurement_to`] 能直接吃的
/// 调用参数:每天三条独立记录(与真实用户逐次录入「记录」同构)—— 血压(收缩压
/// +舒张压共享一份文档,见 [`add_self_measurement`] 文档「血压两个值……」一节)、
/// 心率、血糖各自单独一份文档,顺序固定 `[血压, 心率, 血糖]`(供
/// `home_monitoring_demo_data_tests` 按索引核对)。
///
/// `measured_at` 用 `+08:00`(北京时间偏移),不是 `Z`——这是真实用户在
/// `manual_entry_sheet.dart` 上保存一条记录时,`measured_at` 参数实际的形状
/// (设备本地挂钟时间 + 该设备当时的真实时区偏移,见该文件 `_save()` 与
/// `parse_measured_at` 顶部的约定文档)。张建国这份示例病历假定是一台中国大陆
/// 设备记的,`+08:00` 是这个示例场景的具体取值,不是 App 逻辑本身写死的常量——
/// `parse_measured_at` 认的是"传入什么偏移就按字面存那个偏移下的挂钟读数",
/// 换一台外国设备记录的示例数据,这里应该换成对应的偏移。
///
/// 早前这里用 `Z` 是为了绕开自测记录早间测量错位到前一天的 bug(`parse_measured_at`
/// 那时把 `+08:00` 之类的偏移真按时区转换成 UTC 瞬间,早晨的记录会被转到前一天)。
/// 那个 bug 已经修了(`parse_measured_at` 现在不做真时区转换,只是把传入偏移下的
/// 字面挂钟读数重新贴上 `Utc` 标签),`Z` 这个绕过手段没有必要再留着——留着反而
/// 让示例数据成了唯一一份不符合真实录入形状的数据,不利于用示例数据本身发现同类
/// 回归。
fn home_monitoring_demo_entries() -> Vec<(Vec<SelfMeasuredValueDto>, String)> {
    HOME_MONITORING_READINGS
        .iter()
        .flat_map(
            |&(date, hour, minute, systolic, diastolic, heart_rate, glucose)| {
                let measured_at = format!("{date}T{hour:02}:{minute:02}:00+08:00");
                [
                    (
                        vec![
                            SelfMeasuredValueDto {
                                analyte_key: "bp_systolic".into(),
                                value: systolic,
                                unit: "mmHg".into(),
                            },
                            SelfMeasuredValueDto {
                                analyte_key: "bp_diastolic".into(),
                                value: diastolic,
                                unit: "mmHg".into(),
                            },
                        ],
                        measured_at.clone(),
                    ),
                    (
                        vec![SelfMeasuredValueDto {
                            analyte_key: "heart_rate".into(),
                            value: heart_rate,
                            unit: "/min".into(),
                        }],
                        measured_at.clone(),
                    ),
                    (
                        vec![SelfMeasuredValueDto {
                            analyte_key: "glucose".into(),
                            value: glucose,
                            unit: "mmol/L".into(),
                        }],
                        measured_at,
                    ),
                ]
            },
        )
        .collect()
}

/// 一键「载入示例数据」:把编译进本 crate 的张建国示例病历(见 `DEMO_DATA`)
/// 批量导入保险箱,让测试者无需手动选文件就能看到 健康档案。按路径排序保证
/// 可复现;`pipeline::ingest` 去重,重复点击安全。返回成功处理的文件数。
///
/// 与 Tauri 版的差异只在「示例数据从哪来」:Tauri 版随 `bundle.resources` 打包、
/// 运行时用 `resource_dir()` 定位;这里没有「应用资源目录」,数据集直接编译进
/// 二进制(`DEMO_DATA`),运行时落一份到 `data_dir` 下的临时目录再喂给
/// `pipeline::ingest`(它按路径操作,不接受内存字节),用完即删。
///
/// 文件批量导入之后,额外把 [`home_monitoring_demo_entries`] 里的家庭自测读数
/// 写进同一个保险箱——那份 PDF(`2026-04-30_血压记录_家庭监测.pdf`)本身已经在
/// 上面的文件循环里照常按文档路径入库(硬不变量「原件永远可达」,不换不删),
/// 这里是**同一批数据**额外再走一遍「记录」入口([`add_self_measurement_to`],
/// 与用户手动录入完全同一条写入路径),让示例数据里第一次有真实的自测记录可看
/// (载入示例前,「记录」这条入库路径在示例数据里一条都没有)。
///
/// `progress` 每处理完一份(不论成败)推一条 [DemoLoadProgressDto]——华为 Mate 9
/// 真机实测 22 份 11 秒零反馈,用户以为没点上又点了第二次。这颗 sink 让设置屏能画
/// 「正在载入 N/22」而不是一个不知道在不在跑的忙态。`total` 把自测读数也算进去,
/// 不然文件都处理完之后进度条又莫名其妙继续跳。
///
/// **本函数恒返回 `Ok(())`,成败一律走 `progress` 的 `error` 字段**——见
/// [DemoLoadProgressDto] 顶部文档:带 `StreamSink` 参数的 FRB 函数,Dart 侧没有
/// 任何代码 `await` 这个函数自身的返回值,真返回 `Err` 会在这里悄悄丢失。
pub fn load_demo_data(progress: StreamSink<DemoLoadProgressDto>) -> anyhow::Result<()> {
    let result = with_state(|state| {
        let v = &state.vault;
        let mut files: Vec<&include_dir::File<'_>> = Vec::new();
        collect_demo_files(&DEMO_DATA, &mut files);
        files.sort_by_key(|f| f.path().to_path_buf());
        let home_readings = home_monitoring_demo_entries();
        let total = files.len() as i64 + home_readings.len() as i64;

        let tmp_root = state.data_dir.join("medme-demo-data");
        std::fs::create_dir_all(&tmp_root)?;
        let mut count = 0i64;
        let mut loaded = 0i64;
        for f in files.iter() {
            let tmp_path = tmp_root.join(f.path());
            if let Some(parent) = tmp_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&tmp_path, f.contents())?;
            // Panic firewall(与 `ingest_one` 同一理由):parser/dicom 栈里的
            // panic 不能一路 unwind 穿过持锁的 Vault。
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                pipeline::ingest(v, &tmp_path)
            }));
            match result {
                Ok(Ok(_)) => count += 1,
                Ok(Err(e)) => log_warn(&format!(
                    "[demo-data] ingest failed for {}: {e}",
                    tmp_path.display()
                )),
                Err(_) => log_warn(&format!(
                    "[demo-data] ingest panicked (isolated) for {}",
                    tmp_path.display()
                )),
            }
            loaded += 1;
            // 忽略发送失败:监听端已断开不该打断导入本身(单向 UI 反馈,不是
            // 导入流程的一部分)。
            let _ = progress.add(DemoLoadProgressDto {
                loaded,
                total,
                succeeded: count,
                error: None,
            });
        }
        let _ = std::fs::remove_dir_all(&tmp_root); // 尽力清理,失败无妨

        // 见本函数顶部文档:同一批家庭监测读数,额外走一遍「记录」写入路径。
        for (values, measured_at) in &home_readings {
            match add_self_measurement_to(v, values, Some(measured_at)) {
                Ok(_) => count += 1,
                Err(e) => log_warn(&format!(
                    "[demo-data] self-measurement seed failed for {measured_at}: {e}"
                )),
            }
            loaded += 1;
            let _ = progress.add(DemoLoadProgressDto {
                loaded,
                total,
                succeeded: count,
                error: None,
            });
        }

        v.rebuild_encounters()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(count)
    });
    if let Err(e) = result {
        // 整段操作失败——可能一份都没来得及处理(如「保险箱尚未打开」),也可能
        // 半途 I/O 出错。不管哪种,都得经流报出来,否则等于这个工单要修的
        // 「安卓上失败静默不可见」在另一个地方原样复发。
        let _ = progress.add(DemoLoadProgressDto {
            loaded: 0,
            total: 0,
            succeeded: 0,
            error: Some(e.to_string()),
        });
    }
    Ok(())
}

/// 「清空保险箱 · 重置」:删掉当前真相目录(`truth_root`)+ 派生库
/// (`db_path`),再用 `open_split_resilient` 在同一位置重建。之后 `load_archive`
/// 会返回空。与桌面/Tauri 移动端的 `reset_vault` 同构,包括同一条安全兜底:
/// `truth_root` 必须是一个名为 `vault` 的目录,防止误删沙盒其它内容。
pub fn reset_vault() -> anyhow::Result<()> {
    with_state_mut(|state| {
        if state.truth_root.file_name().and_then(|n| n.to_str()) != Some("vault") {
            anyhow::bail!("保险箱路径异常,已中止重置");
        }
        if state.truth_root.exists() {
            std::fs::remove_dir_all(&state.truth_root)?;
        }
        if state.db_path.exists() && !state.db_path.starts_with(&state.truth_root) {
            std::fs::remove_file(&state.db_path)?;
        }
        let fresh =
            Vault::open_split_resilient(&state.truth_root, &state.db_path, &state.device_id)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        state.vault = fresh; // 旧 Vault(连接/日志句柄)在此被 drop
        Ok(())
    })
}

/// iCloud 同步是否已在本设备开启(读持久标记 `<data_dir>/icloud_enabled`)。
///
/// 分工:`enabled` 由 Rust 据持久标记如实返回;`available`(能否解析到 iCloud 容器)
/// 是 iOS-only 且需原生 API,Rust 拿不到容器,恒返回 `false` 交由 Dart 侧经
/// `medme/icloud` MethodChannel(`IcloudBridge.containerPath`)判断后覆盖。整套 iCloud
/// 开关/迁移逻辑见 `enable_icloud_sync` / `disable_icloud_sync` 与 `open_vault`。
pub fn icloud_status() -> IcloudStatusDto {
    let enabled = with_state(|s| Ok(s.data_dir.join("icloud_enabled").exists())).unwrap_or(false);
    IcloudStatusDto {
        available: false,
        enabled,
    }
}

/// 开启 iCloud 同步:把保险箱真相迁进 iCloud 容器 `<container_dir>/Documents/vault`,
/// 派生库留沙盒,写持久标记。容器路径由 Dart 经 MethodChannel 解析后传入。迁移用
/// core-model `relocate_to`(搬 objects/log/db/VERSION;容器里已有别设备的 vault 则
/// adopt+merge)——与已验证的 Tauri #38 同一套安全操作。幂等。
pub fn enable_icloud_sync(container_dir: String) -> anyhow::Result<()> {
    // `container_dir` 是 Dart 拼好的「该成员 iCloud 目录基」(含 Documents 及多成员
    // 子文件夹),这里只补 `vault`。
    let container_vault = Path::new(&container_dir).join("vault");
    with_state_mut(|state| {
        if state.truth_root == container_vault {
            std::fs::write(state.data_dir.join("icloud_enabled"), "1")?;
            return Ok(());
        }
        // 派生库放该成员本机基目录(每成员独立,不进 iCloud),避免多成员撞库。
        let sandbox_db = state.docs_dir.join("medme.db");
        state
            .vault
            .relocate_to(&container_vault)
            .map_err(|e| anyhow::anyhow!(format!("迁移保险箱到 iCloud 失败:{e}")))?;
        let _ = std::fs::remove_file(container_vault.join("medme.db"));
        let fresh = Vault::open_split(&container_vault, &sandbox_db, &state.device_id)
            .map_err(|e| anyhow::anyhow!(format!("在 iCloud 容器打开保险箱失败:{e}")))?;
        state.vault = fresh;
        state.truth_root = container_vault;
        state.db_path = sandbox_db;
        std::fs::write(state.data_dir.join("icloud_enabled"), "1")?;
        Ok(())
    })
}

/// 关闭 iCloud 同步:把真相从容器**复制**回本机 `<docs_dir>/vault`(容器副本保留),
/// 本地重开派生库,清标记 + 沙盒 iCloud 派生库。用 `copy_to` 只复制不删源。幂等。
pub fn disable_icloud_sync() -> anyhow::Result<()> {
    with_state_mut(|state| {
        let local_vault = state.docs_dir.join("vault");
        let local_db = local_vault.join("medme.db");
        if state.truth_root == local_vault {
            let _ = std::fs::remove_file(state.data_dir.join("icloud_enabled"));
            return Ok(());
        }
        state
            .vault
            .copy_to(&local_vault)
            .map_err(|e| anyhow::anyhow!(format!("把保险箱复制回本机失败:{e}")))?;
        let fresh = Vault::open_split(&local_vault, &local_db, &state.device_id)
            .map_err(|e| anyhow::anyhow!(format!("在本机打开保险箱失败:{e}")))?;
        state.vault = fresh;
        state.truth_root = local_vault;
        state.db_path = local_db;
        let _ = std::fs::remove_file(state.data_dir.join("icloud_enabled"));
        let _ = std::fs::remove_file(state.data_dir.join("medme.db"));
        Ok(())
    })
}

// ============================================================================
// **PP-OCRv5(iOS + 安卓)**。iOS 侧已合入 main(ADR 0006 采纳)。安卓侧
// feat/android-pp-ocr 分支 —— 用户反馈安卓 ML Kit 识别质量不够,拍板换成和
// iOS 同引擎同模型(ADR 0005 尚未 supersede,这段落地后再补)。`ocr_bridge.dart`
// 的 iOS + 安卓分支都走这里,不再经 Vision MethodChannel / ML Kit 插件
// (ML Kit 依赖仍留着做回退,见该文件)。想撤回到纯 ML Kit:删这段 + `dto.rs`
// 的 `OcrPpResultDto` + `Cargo.toml` 那条 `cfg(any(target_os = "ios",
// target_os = "android"))` 依赖 + `rust/ocr-models/` 目录,不影响其它任何
// 函数(没有别处依赖这几样)。
// ============================================================================

/// PP-OCRv5 三个模型文件(det/rec + 字典,约 20MB)编译期用 `include_bytes!` 打进
/// 本 crate 的静态库 —— 镜像 `DEMO_DATA`(`include_dir!`)打包示例病历数据集的
/// 做法:FRB 生成的是纯静态库,没有「应用资源目录」这个概念,编译进二进制是最
/// 简单的打包方式,不用碰 Xcode「Copy Bundle Resources」/ Info.plist / Flutter
/// assets 那一整套。
///
/// **与任务描述的原始设计不同**:原计划是模型走 Xcode bundle resources、Dart 侧
/// 传路径给 Rust。这里改成编译期打进二进制 + 首次落盘沙盒目录,复用本文件已有的
/// `DEMO_DATA` 精确先例,免去 Dart 侧定位 bundle 路径 + 一整套 Xcode 工程改动。
/// 代价:换模型必须重新编译这个 crate(测试阶段可接受);二进制体积多 ~20MB。
/// 如果不想要这个取舍(比如想不重编就能换模型),告诉我,改成 bundle resources
/// 传路径不难。
#[cfg(pp_ocr)]
const PP_DET_MODEL: &[u8] = include_bytes!("../../ocr-models/pp-ocrv5_mobile_det.onnx");
#[cfg(pp_ocr)]
const PP_REC_MODEL: &[u8] = include_bytes!("../../ocr-models/pp-ocrv5_mobile_rec.onnx");
#[cfg(pp_ocr)]
const PP_DICT: &[u8] = include_bytes!("../../ocr-models/ppocrv5_dict.txt");

/// 进程内只落盘一次(`ocr::set_model_dir` 也是「先到先得」,重复调用无副作用,
/// 但没必要每次识别都重新校验/写盘)。
#[cfg(pp_ocr)]
static PP_MODELS_READY: OnceLock<()> = OnceLock::new();

/// 把编译进二进制的模型字节落盘到 `<data_dir>/medme-ocr-pp-models/`,再调
/// `ocr::set_model_dir` 指过去(`oar-ocr`/`ort` 从磁盘路径读模型,不接受内存字节
/// —— 这也是必须落盘而不能只留在内存里的原因)。按文件大小判断是否已落盘过
/// (跳过重写,不必每次 app 启动都重写 20MB);首次调用 `ocr::recognize_engine_layout`
/// 前必须先跑通本函数(`set_model_dir` 的「必须在首次 recognize 前调用」契约)。
/// `data_dir` 在安卓上是 app 私有可写目录(与 iOS 沙盒同一抽象,`with_state`
/// 拿到的 `state.data_dir` 两端走同一套 `resolve_vault_paths` 逻辑,非
/// iOS/安卓专属代码),落盘逻辑不用按平台分叉。
#[cfg(pp_ocr)]
fn ensure_pp_models_ready(data_dir: &Path) -> anyhow::Result<()> {
    if PP_MODELS_READY.get().is_some() {
        return Ok(());
    }
    let dir = data_dir.join("medme-ocr-pp-models");
    std::fs::create_dir_all(&dir)?;
    let write_if_needed = |name: &str, bytes: &[u8]| -> anyhow::Result<()> {
        let path = dir.join(name);
        let already_written = std::fs::metadata(&path)
            .map(|m| m.len() as usize == bytes.len())
            .unwrap_or(false);
        if !already_written {
            std::fs::write(&path, bytes)?;
        }
        Ok(())
    };
    write_if_needed("pp-ocrv5_mobile_det.onnx", PP_DET_MODEL)?;
    write_if_needed("pp-ocrv5_mobile_rec.onnx", PP_REC_MODEL)?;
    write_if_needed("ppocrv5_dict.txt", PP_DICT)?;
    ocr::set_model_dir(dir);
    let _ = PP_MODELS_READY.set(());
    Ok(())
}

/// 识别一张图片(PP-OCRv5 引擎,iOS + 安卓共用路径)。返回文本已按
/// [`ocr::rebuild_layout_text`] 在 Rust 侧做过表格列对齐(取代了 Dart
/// `ocr_bridge.dart` 里给 ML Kit 用的 `_rebuildLayoutText`——安卓走 PP 之后不再
/// 经那条路径,但那份代码仍留着给 ML Kit 回退分支用,没删)+ 平均置信度。要求
/// vault 已打开(落模型要 `data_dir`)——与 Dart 侧 `recognizeImageText` 在
/// `import_flow.dart::_runImport` 里的调用时机一致,导入流程走到这里 vault
/// 必然已打开,不额外加约束。
#[cfg(pp_ocr)]
pub fn recognize_image_pp(bytes: Vec<u8>) -> anyhow::Result<OcrPpResultDto> {
    if bytes.is_empty() {
        anyhow::bail!("空图片字节");
    }
    let data_dir = with_state(|state| Ok(state.data_dir.clone()))?;
    ensure_pp_models_ready(&data_dir)?;
    let outcome =
        ocr::recognize_engine_layout(&bytes).map_err(|e| anyhow::anyhow!(e.to_string()))?;
    Ok(OcrPpResultDto {
        text: outcome.text,
        confidence: outcome.confidence,
    })
}

/// 非 iOS/安卓构建(桌面/CLI)的占位实现。FRB codegen 在开发机上跑一次生成
/// `frb_generated.rs` + Dart 绑定,这份生成文件不按平台分叉,所以这个函数签名
/// 必须在所有 target 上都存在;函数体在非 iOS/安卓直接报错即可 —— `ocr` 依赖
/// 本身按 `cfg(pp_ocr)` 门控(见 `build.rs` 的规则与
/// `Cargo.toml`),桌面/CLI 构建压根不链接 oar-ocr/onnxruntime,这个分支不产生
/// 任何额外体积或依赖。
#[cfg(not(pp_ocr))]
pub fn recognize_image_pp(_bytes: Vec<u8>) -> anyhow::Result<OcrPpResultDto> {
    anyhow::bail!("PP-OCR 路径仅 iOS/安卓构建可用")
}

#[cfg(test)]
mod home_monitoring_demo_data_tests {
    use super::*;

    /// 张建国示例病历的家庭监测读数(`load_demo_data` 用 [`add_self_measurement_to`]
    /// 写进保险箱那份)必须与源 PDF(`demo-data/corpus/2026-04-30_血压记录_家庭监测.pdf`)
    /// 逐条一致 —— 用一个不经全局 `VAULT` 静态、单独打开的临时保险箱验证,不依赖
    /// `load_demo_data` 本身(它需要一个真实 Dart 消息端口才能构造 `StreamSink`,
    /// 单测环境下造不出来)。这正是把核心写入逻辑抽成 [`add_self_measurement_to`]
    /// 的意义:能在不碰 FRB/`StreamSink` 的前提下,对「示例数据里的自测记录写没写对」
    /// 单独下断言。
    #[test]
    fn seeds_nine_days_of_readings_matching_the_source_pdf_exactly() {
        let tmp = tempfile::tempdir().unwrap();
        let truth_root = tmp.path().join("vault");
        let db_path = truth_root.join("medme.db");
        let v = Vault::open_split_resilient(&truth_root, &db_path, "test-device").unwrap();

        let entries = home_monitoring_demo_entries();
        // 9 天 × 3 条(血压共享一份文档 + 心率 + 血糖)= 27 份文档。
        assert_eq!(entries.len(), 27, "9 天 × 3 条自测记录");

        let mut doc_ids = Vec::new();
        for (values, measured_at) in &entries {
            let id = add_self_measurement_to(&v, values, Some(measured_at))
                .unwrap_or_else(|e| panic!("写入 {measured_at} 失败:{e}"));
            doc_ids.push(id);
        }
        // 27 份各自建了独立文档(内容互不相同,不会被 CAS 去重合并)。
        let unique: std::collections::HashSet<_> = doc_ids.iter().collect();
        assert_eq!(unique.len(), 27, "27 份记录应各自成文档,不应被去重合并");

        // `measured_at` 现在带 `+08:00`(与真实录入同形状,见
        // `home_monitoring_demo_entries` 文档),而 6-7 点是北京时间的清晨——
        // 正是「自测记录早间测量掉到前一天」这个 bug 的打击面。这里钉住 9 天
        // 的 `doc_date` 都落在 PDF 印的那一天,不是转 UTC 后的前一天(0/12/24 是
        // 每天血压文档在 `doc_ids` 里的起点,见下面「按索引核对」的说明)。
        for (day_idx, &(date, ..)) in HOME_MONITORING_READINGS.iter().enumerate() {
            let bp_doc_id = doc_ids[day_idx * 3];
            let doc = v
                .document_by_id(bp_doc_id)
                .unwrap()
                .unwrap_or_else(|| panic!("文档 {bp_doc_id} 应能读到"));
            assert_eq!(
                doc.doc_date
                    .unwrap_or_else(|| panic!("{date} 这条应有 doc_date"))
                    .date_naive()
                    .to_string(),
                date,
                "{date} 06/07 点这条清晨记录不该因转 UTC 掉到前一天",
            );
        }

        // 抽样核对几个点与 PDF 原文(pdftotext 逐行核对过)完全一致:
        // 2026-04-01 06:50 138/86 72 7.2;2026-04-15 06:45 130/80 71 6.8(药物
        // 调整当天);2026-04-30 06:50 122/76 70 6.3(月末最后一条)。
        let payload_of = |doc_id: i64| -> Vec<parser::SelfMeasuredValue> {
            let text = v.ocr_text(doc_id).unwrap();
            parser::parse_self_measurement_payload(&text).expect("payload parses")
        };

        // entries 里每天固定 [血压, 心率, 血糖] 三条,按 HOME_MONITORING_READINGS 顺序展开。
        let bp_04_01 = payload_of(doc_ids[0]);
        assert_eq!(
            bp_04_01,
            vec![
                parser::SelfMeasuredValue {
                    analyte_key: "bp_systolic".into(),
                    value: 138.0,
                    unit: "mmHg".into(),
                },
                parser::SelfMeasuredValue {
                    analyte_key: "bp_diastolic".into(),
                    value: 86.0,
                    unit: "mmHg".into(),
                },
            ]
        );
        let hr_04_01 = payload_of(doc_ids[1]);
        assert_eq!(hr_04_01[0].value, 72.0);
        let glucose_04_01 = payload_of(doc_ids[2]);
        assert_eq!(glucose_04_01[0].value, 7.2);

        // 2026-04-15 是第 5 天(索引 4),三条记录起点在 doc_ids[4*3] = doc_ids[12]。
        let bp_04_15 = payload_of(doc_ids[12]);
        assert_eq!(bp_04_15[0].value, 130.0);
        assert_eq!(bp_04_15[1].value, 80.0);
        let hr_04_15 = payload_of(doc_ids[13]);
        assert_eq!(hr_04_15[0].value, 71.0);
        let glucose_04_15 = payload_of(doc_ids[14]);
        assert_eq!(glucose_04_15[0].value, 6.8);

        // 2026-04-30 是第 9(最后)天,起点在 doc_ids[8*3] = doc_ids[24]。
        let bp_04_30 = payload_of(doc_ids[24]);
        assert_eq!(bp_04_30[0].value, 122.0);
        assert_eq!(bp_04_30[1].value, 76.0);
        let hr_04_30 = payload_of(doc_ids[25]);
        assert_eq!(hr_04_30[0].value, 70.0);
        let glucose_04_30 = payload_of(doc_ids[26]);
        assert_eq!(glucose_04_30[0].value, 6.3);

        // 血糖(glucose)故意没有家测参考区间(`home_ref_range` 的既定行为,不是
        // 这次改动漏补)—— 钉住这条设计不被悄悄"补全"。
        assert!(parser::home_ref_range("glucose").is_none());
    }
}

#[cfg(test)]
mod measured_at_timezone_tests {
    use super::*;

    /// 复现真实用户 bug:早上 6:50(北京时间,+08:00)量的血压,不能被系统记成
    /// 前一天晚上。回归前 `parse_measured_at` 直接转真 UTC 瞬间——
    /// `2026-05-01T06:50:00+08:00` 变成 `2026-04-30T22:50:00Z`,`doc_date` 与
    /// 「记录时间」文案都掉到 04-30,家庭血压监测的标准晨起测量场景全部中招。
    #[test]
    fn a_beijing_morning_measurement_lands_on_the_local_calendar_day_not_the_utc_one() {
        let tmp = tempfile::tempdir().unwrap();
        let truth_root = tmp.path().join("vault");
        let db_path = truth_root.join("medme.db");
        let v = Vault::open_split_resilient(&truth_root, &db_path, "test-device").unwrap();

        let values = vec![SelfMeasuredValueDto {
            analyte_key: "heart_rate".into(),
            value: 72.0,
            unit: "/min".into(),
        }];
        let doc_id = add_self_measurement_to(&v, &values, Some("2026-05-01T06:50:00+08:00"))
            .unwrap_or_else(|e| panic!("写入失败:{e}"));

        let doc = v
            .document_by_id(doc_id)
            .unwrap()
            .expect("刚写入的文档应能读到");
        assert_eq!(
            doc.doc_date
                .expect("自测记录必须落 doc_date")
                .date_naive()
                .to_string(),
            "2026-05-01",
            "早间(北京时间)测量的自测记录必须落在用户表上看到的那一天,不能因转 UTC 掉到前一天",
        );

        // 「记录时间」这行给用户看的文案同样必须是本地挂钟读数,不是转换后的 UTC 分量。
        let text = v.ocr_text(doc_id).unwrap();
        assert!(
            text.contains("记录时间:2026-05-01 06:50"),
            "记录时间应显示用户表上看到的本地时间,实际文本:\n{text}",
        );
    }

    /// 跨时区场景(出国就医/旅行中测量):不同偏移下的字面挂钟读数各自直接落库,
    /// 不做"统一成一个真实时刻"的换算——与本文件顶部 `parse_measured_at` 文档
    /// 记的约定一致,这里钉住"偏移不写死 +08:00,输入什么偏移就按字面存"。
    #[test]
    fn a_non_china_offset_still_stores_the_literal_wall_clock_reading() {
        let tmp = tempfile::tempdir().unwrap();
        let truth_root = tmp.path().join("vault");
        let db_path = truth_root.join("medme.db");
        let v = Vault::open_split_resilient(&truth_root, &db_path, "test-device").unwrap();

        let values = vec![SelfMeasuredValueDto {
            analyte_key: "heart_rate".into(),
            value: 65.0,
            unit: "/min".into(),
        }];
        // 美东时间(-05:00)晚上 23:30 —— 若转真 UTC 瞬间会跨到第二天 04:30。
        let doc_id = add_self_measurement_to(&v, &values, Some("2026-05-01T23:30:00-05:00"))
            .unwrap_or_else(|e| panic!("写入失败:{e}"));

        let doc = v
            .document_by_id(doc_id)
            .unwrap()
            .expect("刚写入的文档应能读到");
        assert_eq!(
            doc.doc_date
                .expect("自测记录必须落 doc_date")
                .date_naive()
                .to_string(),
            "2026-05-01",
            "应按传入偏移下的字面日期落库,不因转 UTC 跨到下一天",
        );
    }
}
