use chrono::{DateTime, Utc};
use core_model::{DocType, NewDocument, NewImagingInstance, NewOcr, OcrBackendKind, Vault};
use std::collections::HashMap;
use std::path::Path;

/// 原件真实页数(多页 TIFF → >1,其余一律 1)。转出给移动端 crate 用:它在
/// 宿主/安卓构建下并**不**直接依赖 `ocr`(见 `apps/mobile_flutter/rust/Cargo.toml`
/// 里 `ocr` 的 target 门控),但它自己那条图片入库路径
/// (`api::vault::ingest_image_with_text`,Dart 侧已经 OCR 完再落库)同样需要
/// 知道原件有几页才能不撒谎。语义见 `ocr::image_page_count`。
pub use ocr::image_page_count;

/// 单个文件导入体积上限(字节)。超过即拒绝,**在把整份文件读进内存之前**就返回
/// 错误 —— 否则一份几个 GB 的文件/畸形附件会在任何解析器跑起来之前就把进程 OOM。
/// 200MB 足以覆盖高分辨率照片、扫描 PDF 与常见单张 DICOM;超大 DICOM 序列本就按
/// 单张切片逐个导入,单文件不会撞上限。移动端 `ingest_bytes` 复用此常量校验 payload。
pub const MAX_INGEST_BYTES: u64 = 200 * 1024 * 1024;

fn is_pdf(path: &Path) -> bool {
    mime_for(path) == "application/pdf"
}

fn is_dicom(path: &Path) -> bool {
    mime_for(path) == "application/dicom"
}

/// Builds a readable title from DICOM tags: modality+body part is most
/// specific ("CT · 头部"), then StudyDescription, then modality alone,
/// falling back to the original filename if nothing else is present.
fn dicom_title(meta: &dicom::DicomMeta, name: &str) -> String {
    if let (Some(m), Some(b)) = (&meta.modality, &meta.body_part) {
        return format!("{m} · {b}");
    }
    if let Some(d) = &meta.description {
        return d.clone();
    }
    if let Some(m) = &meta.modality {
        return m.clone();
    }
    name.to_string()
}

/// A short, searchable summary line synthesized from DICOM tags — DICOM has
/// no OCR text, so this stands in as the document's `ocr_result` body.
fn dicom_summary(meta: &dicom::DicomMeta) -> String {
    let mut lines = vec!["DICOM 影像检查".to_string()];
    if let Some(m) = &meta.modality {
        let cn = match m.as_str() {
            "CT" => "CT",
            "MR" => "MRI",
            "US" => "超声",
            "CR" | "DX" | "DR" => "X线",
            "MG" => "钼靶",
            "PT" => "PET",
            "NM" => "核医学",
            _ => m.as_str(),
        };
        lines.push(format!("检查类型:{cn}({m})"));
    }
    if let Some(d) = meta.study_date.as_deref().and_then(|d| d.split('T').next()) {
        lines.push(format!("检查日期:{d}"));
    }
    if let Some(b) = &meta.body_part {
        lines.push(format!("检查部位:{b}"));
    }
    if let Some(desc) = &meta.description {
        lines.push(format!("检查描述:{desc}"));
    }
    if let Some(i) = &meta.institution {
        lines.push(format!("检查机构:{i}"));
    }
    if let Some(p) = &meta.patient_name {
        lines.push(format!("患者:{p}"));
    }
    lines.push(
        "(DICOM 影像文件,点击上方原件可进行窗宽窗位 / 缩放 / 序列滚动交互阅片。)".to_string(),
    );
    lines.join("\n")
}

/// 按 DICOM 标签建/挂 study 文档(Study→Series→Instance,见 docs/014_Imaging_Overhaul.md)。
/// 免 OCR:DICOM 自带结构化元数据(见 docs/010_Imaging_DICOM.md)。
///
/// 分组:同 `StudyInstanceUID` 的多张切片归入**一个** imaging_report 文档 ——
/// 第一张切片建文档(合成摘要 + study 级标题/日期),其后同 study 的切片仅 append
/// 一条 imaging_instance(不建新文档)。因此一台 200 层 CT = 1 张时间线卡而非 200 份。
fn add_dicom_document(
    vault: &Vault,
    sid: i64,
    name: &str,
    bytes: &[u8],
    deduped: bool,
    parse_dicom_meta: DicomMetaParser<'_>,
) -> anyhow::Result<IngestOutcome> {
    let meta = parse_dicom_meta(bytes)?;

    // 去重:同一张切片(非 study 锚点、无自己的 document)再次导入时,靠
    // imaging_instance 判定已入库,避免重复挂载。锚点切片的再导入由上游
    // `has_document` 早已拦截。
    if deduped {
        if let Some(_doc_id) = vault.imaging_document_for_source(sid)? {
            return Ok(IngestOutcome {
                source_file_id: sid,
                name: name.to_string(),
                status: IngestStatus::Deduped,
                doc_type: Some(DocType::ImagingReport),
                pages_without_text: Vec::new(),
            });
        }
    }

    // 已有同 study 的文档 → 只挂切片,不建新文档。
    if let Some(study_uid) = meta.study_uid.as_deref() {
        if let Some(doc_id) = vault.document_id_for_study(study_uid)? {
            vault.add_imaging_instance(NewImagingInstance {
                document_id: doc_id,
                source_file_id: sid,
                study_uid: study_uid.to_string(),
                series_uid: meta.series_uid.clone(),
                series_number: meta.series_number,
                instance_number: meta.instance_number,
            })?;
            let doc_type = vault
                .document_by_id(doc_id)?
                .map(|d| d.doc_type)
                .unwrap_or(DocType::ImagingReport);
            return Ok(IngestOutcome {
                source_file_id: sid,
                name: name.to_string(),
                status: IngestStatus::InstanceAttached,
                doc_type: Some(doc_type),
                pages_without_text: Vec::new(),
            });
        }
    }

    // 该 study 的第一张切片(或无 study_uid 的单张)→ 建 study 文档。
    let doc_date: Option<DateTime<Utc>> = meta
        .study_date
        .as_deref()
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc));
    let title = dicom_title(&meta, name);
    let summary = dicom_summary(&meta);

    let doc = vault.add_document(NewDocument {
        source_file_id: sid,
        doc_type: DocType::ImagingReport,
        doc_date,
        doc_date_end: None,
        title: Some(title),
        language: None,
        page_count: 1,
    })?;
    vault.add_ocr(NewOcr {
        document_id: doc.id,
        page_no: 1,
        backend: OcrBackendKind::Native,
        model_version: "dicom-meta".into(),
        text: summary,
        confidence: None,
    })?;
    // 首张切片挂到新建的 study 文档上(顺带把 study_uid 落到文档,供后续切片查找)。
    if let Some(study_uid) = meta.study_uid.as_deref() {
        vault.add_imaging_instance(NewImagingInstance {
            document_id: doc.id,
            source_file_id: sid,
            study_uid: study_uid.to_string(),
            series_uid: meta.series_uid.clone(),
            series_number: meta.series_number,
            instance_number: meta.instance_number,
        })?;
    }
    let status = if deduped {
        IngestStatus::Backfilled
    } else {
        IngestStatus::New
    };
    Ok(IngestOutcome {
        source_file_id: sid,
        name: name.to_string(),
        status,
        doc_type: Some(doc.doc_type),
        pages_without_text: Vec::new(),
    })
}

/// 按文本层(纯 txt;PDF 现在走 `ingest_pdf`,逐页判定,见其文档注释)建
/// document + ocr_result(Native 后端)。
fn add_text_layer_document(
    vault: &Vault,
    sid: i64,
    name: &str,
    e: parser::Extracted,
    deduped: bool,
) -> anyhow::Result<IngestOutcome> {
    let doc = vault.add_document(NewDocument {
        source_file_id: sid,
        doc_type: e.doc_type.clone(),
        doc_date: e.doc_date,
        doc_date_end: e.doc_date_end,
        title: Some(name.to_string()),
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
    let status = if deduped {
        IngestStatus::Backfilled
    } else {
        IngestStatus::New
    };
    Ok(IngestOutcome {
        source_file_id: sid,
        name: name.to_string(),
        status,
        doc_type: Some(doc.doc_type),
        pages_without_text: Vec::new(),
    })
}

/// 「已存但暂无文本」:只按文件名元数据建 document(不建 ocr_result),状态
/// `StoredNoText`。原件已永存、时间线可见可查看原件,留待后续 reindex 补 OCR。
/// 图片/扫描件的 OCR 失败或空时统一走这里 —— 包括扫描 PDF(#55:失败不再冒充
/// 成功文本层),与直接图片路径行为一致。
///
/// `page_count`:非 PDF 调用方(单张图片)传 1;PDF 调用方(`ingest_pdf`)传
/// 真实页数——即便一页可用文本都没有,页数本身仍是已知的,不该退化成 1
/// (旧版换页符 heuristic 从未生效导致的老问题,见 `ocr::MIN_TEXT_LAYER_LEN`)。
fn store_no_text(
    vault: &Vault,
    sid: i64,
    name: &str,
    page_count: i32,
) -> anyhow::Result<IngestOutcome> {
    let (doc_date, doc_date_end) = parser::guess_date_range(name);
    let doc_type = parser::classify(name);
    vault.add_document(NewDocument {
        source_file_id: sid,
        doc_type: doc_type.clone(),
        doc_date,
        doc_date_end,
        title: Some(name.to_string()),
        language: None,
        page_count,
    })?;
    // 不建 ocr_result(暂无文本)
    Ok(IngestOutcome {
        source_file_id: sid,
        name: name.to_string(),
        status: IngestStatus::StoredNoText,
        doc_type: Some(doc_type),
        pages_without_text: Vec::new(),
    })
}

/// 把 `ocr::recognize_platform_best`/`recognize_pdf_platform_best` 报告的实际引擎映射为 vault 里记录的
/// (后端, 模型版本) —— 桌面上 mac/Win 的主引擎是 Apple Vision / Windows.Media.Ocr,
/// 不再一律谎称 ONNX/ppocr-v5(#56 溯源准确性)。
fn ocr_provenance(b: ocr::OcrBackend) -> (OcrBackendKind, &'static str) {
    match b {
        ocr::OcrBackend::AppleVision => (OcrBackendKind::AppleVision, "apple-vision"),
        ocr::OcrBackend::WindowsOcr => (OcrBackendKind::WindowsOcr, "windows-media-ocr"),
        ocr::OcrBackend::Onnx => (OcrBackendKind::Onnx, "ppocr-v5"),
    }
}

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
        // iPhone photos default to HEIC/HEIF. macOS Apple Vision OCR decodes it
        // (via ImageIO); on platforms whose OCR engine can't, ingest degrades
        // gracefully (stores the file with no extracted text).
        "heic" | "heif" => "image/heic",
        "dcm" => "application/dicom",
        _ => "application/octet-stream",
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum IngestStatus {
    New,
    Deduped,
    Backfilled,
    StoredNoText,
    /// DICOM 切片并入了已存在的同 study 影像检查文档(未新建文档)。
    InstanceAttached,
    /// dedup 命中(同一份文件再导一次)、document 也早已存在,但该文档还有页
    /// 缺文本层——本次重新导入顺手把能恢复的 PDF 页补进了 `ocr_result`(见
    /// `reindex_existing_document`)。`pages_without_text` 是补完之后**仍然**
    /// 缺文本的页,可能是空(全补上了)也可能非空(部分页依旧识别不出)。
    Reindexed,
}

#[derive(Debug, Clone)]
pub struct IngestOutcome {
    pub source_file_id: i64,
    pub name: String,
    pub status: IngestStatus,
    pub doc_type: Option<DocType>,
    /// 1-based page numbers **of the original file** whose text never made it
    /// into the vault. **Must not be discarded by callers.** The whole point of
    /// this field is that a document can come back `status: New` (real,
    /// useful, in the timeline) while still being incomplete -- callers
    /// (mobile: attempt targeted OCR backfill on exactly these pages, then
    /// tell the user what's still missing; desktop/CLI: at minimum log it)
    /// must surface a non-empty list rather than let the user believe every
    /// page was captured.
    ///
    /// **Which multi-page originals populate it** -- this is deliberately
    /// *not* "PDF only" any more (it was, and that is exactly why the second
    /// defect below went unnoticed for so long: the image path had no way to
    /// even express "I dropped a page"):
    ///
    /// * **PDF** (`ingest_pdf`): pages that had neither a usable text layer
    ///   nor OCR-able content -- no embedded image, OCR found nothing, or the
    ///   per-document OCR cap was hit.
    /// * **Multi-page images, i.e. multi-page TIFF** (`ingest_image`): pages
    ///   `2..=n`, because every recognizer this app has reads frame 1 only
    ///   (see `ocr::image_page_count`). Their content is *not* in the vault
    ///   and, unlike a PDF page, cannot be recovered on-device by rendering.
    /// * Everything else (single-page images, txt, DICOM) leaves it empty --
    ///   nothing was skipped, so there is nothing to report.
    ///
    /// A page named here means "this page's content is missing", nothing more;
    /// **it is not an instruction to render the original as a PDF.** The mobile
    /// backfill in `import_flow.dart` only applies to the PDF case and gates on
    /// that; see the comment there.
    pub pages_without_text: Vec<i32>,
}

/// 导入一个文件:存 CAS(去重)→ 若尚无 document 则抽文本层并建 document/ocr。
/// 抽取失败(如扫描图片)不致命 → StoredNoText(原文件已永存,留待后续 OCR 补索引)。
/// 已去重且 document 已存在时不再无条件短路——见 [`reindex_existing_document`]:
/// 这就是"留待后续 OCR 补索引"如何真正发生的地方,同一份文件再导一次即可补齐
/// 当初漏掉的 PDF 页(#63b)。
/// 可注入的 DICOM 元数据解析器。桌面端注入**隔离子进程**版本:按文件里声明的
/// 长度分配内存发生在解析期,畸形文件可诱导数 GB 分配(模糊测试实测),隔离后
/// 崩溃只波及短命子进程,不影响持有保险箱的主进程。
///
/// 不注入时用进程内解析 —— 适用于 CLI(调试工具)与移动端(其文件选择器不接受
/// `.dcm`,这条路不可达)。
pub type DicomMetaParser<'a> = &'a dyn Fn(&[u8]) -> anyhow::Result<dicom::DicomMeta>;

/// 导入一个文件(进程内解析 DICOM 元数据)。桌面端请用
/// [`ingest_with_dicom_parser`] 注入隔离解析器。
pub fn ingest(vault: &Vault, path: &Path) -> anyhow::Result<IngestOutcome> {
    ingest_with_dicom_parser(vault, path, &dicom::parse_meta)
}

/// 同 [`ingest`],但由调用方提供 DICOM 元数据解析器(见 [`DicomMetaParser`])。
pub fn ingest_with_dicom_parser(
    vault: &Vault,
    path: &Path,
    parse_dicom_meta: DicomMetaParser<'_>,
) -> anyhow::Result<IngestOutcome> {
    // 体积闸门:先看元数据里的文件大小,超上限就拒绝 —— 绝不 slurp 一份不可信的
    // 超大文件进内存(那会在解析前就 OOM)。用 metadata().len() 而非读入后再判。
    let len = std::fs::metadata(path)?.len();
    if len > MAX_INGEST_BYTES {
        anyhow::bail!(
            "文件过大:{len} 字节,超过上限 {MAX_INGEST_BYTES} 字节(200MB),已拒绝导入 / file too large"
        );
    }
    let bytes = std::fs::read(path)?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();
    let imp = vault.import(&name, mime_for(path), &bytes)?;
    let sid = imp.source_file.id;

    if imp.deduped && vault.has_document(sid)? {
        return reindex_existing_document(vault, sid, &name, is_pdf(path), &bytes);
    }

    // .dcm 走独立分支(不经 parser/OCR):DICOM 自带结构化元数据,免 OCR 即可
    // 拿到类型/日期/机构(见 docs/010_Imaging_DICOM.md)。
    if is_dicom(path) {
        return add_dicom_document(vault, sid, &name, &bytes, imp.deduped, parse_dicom_meta);
    }

    // PDF 走独立分支(逐页判定文本层,而非整份拼接后的长度——见 `ingest_pdf`
    // 文档注释里的"混合页 PDF 静默丢数据"缺陷)。
    if is_pdf(path) {
        return ingest_pdf(vault, sid, &name, &bytes, imp.deduped);
    }

    match parser::extract(path) {
        Ok(e) => add_text_layer_document(vault, sid, &name, e, imp.deduped),
        // 无文本层(图片/扫描件):走图片分支 OCR。
        Err(_) => ingest_image(vault, sid, &name, &bytes, imp.deduped),
    }
}

/// 图片专用导入分支(无文本层的 png/jpg/tiff/heic):OCR 第一页,并**如实点名
/// 没被读到的页**。
///
/// **修的缺陷(#63 关早了,实测仍复现)**:这个应用里所有识别器都只读一帧 ——
/// `ocr::decode_image_bounded` 的 `DynamicImage::from_decoder` 只解第一帧,
/// Apple Vision / `Windows.Media.Ocr` 拿到整份字节也只认主图。而 **TIFF 可以是
/// 多页的**(桌面文件选择器与移动端 `kImageExtensions` 都接受 `.tiff`)。于是一份
/// 两页 TIFF 导入后:`page_count == 1`、只有 page_no=1 一条 `ocr_result`、状态
/// `New`、UI 报「已识别入库」—— 第 2 页整页人间蒸发,**任何一层都产不出「漏了页」
/// 这个信号**,因为 `pages_without_text` 当时是 PDF 专属字段。
///
/// 现在:先数原件真实页数(`ocr::image_page_count`,只走 TIFF 的 IFD 链,不解像素),
/// 页数如实落进 `page_count`(不再一律 1),没被识别的页码进
/// `pages_without_text`。**这里没有真的去识别第 2 页** —— 逐帧识别是另一件事
/// (要引入多帧解码 + 每页一条 `ocr_result` 的写入路径);本分支只保证不再撒谎。
///
/// 单页图片(绝大多数:照片、单页扫描)行为**逐字节不变**:`page_count` 仍是 1,
/// `pages_without_text` 仍是空 —— 整份原件都被看过了,没有可报的遗漏。
fn ingest_image(
    vault: &Vault,
    sid: i64,
    name: &str,
    bytes: &[u8],
    deduped: bool,
) -> anyhow::Result<IngestOutcome> {
    let page_count = ocr::image_page_count(bytes) as i32;
    // 只有多页原件才有「漏了页」可报;单页图片留空,与旧行为一致。
    let unread_pages: Vec<i32> = if page_count > 1 {
        (2..=page_count).collect()
    } else {
        Vec::new()
    };
    if !unread_pages.is_empty() {
        eprintln!(
            "ingest_image: {name}: multi-page image ({page_count} pages) -- only page 1 is \
             recognized by any available engine; {} page(s) were NOT read: {unread_pages:?}",
            unread_pages.len()
        );
    }
    match ocr::recognize_platform_best(bytes) {
        Ok(outcome) if !outcome.text.trim().is_empty() => {
            // OCR 成功:像文本文档一样处理(分类/日期取自识别文本)
            let (backend, model_version) = ocr_provenance(outcome.backend);
            let text = outcome.text;
            let doc_type = parser::classify(&text);
            let (doc_date, doc_date_end) = parser::guess_date_range(&text);
            let doc = vault.add_document(NewDocument {
                source_file_id: sid,
                doc_type: doc_type.clone(),
                doc_date,
                doc_date_end,
                title: Some(name.to_string()),
                language: parser::detect_language(&text),
                page_count,
            })?;
            vault.add_ocr(NewOcr {
                document_id: doc.id,
                page_no: 1,
                backend,
                model_version: model_version.into(),
                text,
                confidence: Some(outcome.confidence),
            })?;
            let status = if deduped {
                IngestStatus::Backfilled
            } else {
                IngestStatus::New
            };
            Ok(IngestOutcome {
                source_file_id: sid,
                name: name.to_string(),
                status,
                doc_type: Some(doc_type),
                pages_without_text: unread_pages,
            })
        }
        // OCR 失败/空:退回「已存但无文本」(见 `store_no_text`)。多页原件此时
        // 一页文本都没拿到,故全部页码都进 `pages_without_text`(与 `ingest_pdf`
        // 的全篇扫描 PDF 分支同口径);单页仍留空。
        _ => {
            let mut outcome = store_no_text(vault, sid, name, page_count)?;
            if page_count > 1 {
                outcome.pages_without_text = (1..=page_count).collect();
            }
            Ok(outcome)
        }
    }
}

/// PDF 专用导入分支:逐页判定文本层(不再对整份文档拼接后的字符数判定)。
///
/// **修的缺陷**:旧版本把 `parser::extract` 抽出的**整份文档**文本长度拿去和
/// `MIN_TEXT_LAYER_LEN` 比——一份"第 1 页是打印文本、后面几页是扫描图片"的
/// 混合页 PDF(常见于出院小结附检验报告扫描件),因为第 1 页贡献的文本已经
/// 远超阈值,整篇被当成"有文本层"处理,后续扫描页**从未进入 OCR 分支**,UI
/// 却照样报"已识别入库"——用户永久丢失那几页内容而不自知。现在按页判定:
/// 每页各自检查有没有可用文本层,没有的页各自尝试 OCR(`ocr::recognize_pdf_mixed`)。
///
/// **不静默**:任何一页最终既没有文本层、也没能 OCR 出文本(无可 OCR 图片 /
/// OCR 失败或为空 / 触达 `MAX_OCR_PAGE_IMAGES` 页数上限),其页码进
/// `IngestOutcome::pages_without_text`——调用方(尤其移动端 UI)必须显式告知
/// 用户"这些页未能识别",不能让人以为整份都读了。桌面/CLI 目前还没有对应的
/// UI 横幅(不在本次改动范围),至少落一条 `eprintln!` 留痕。
fn ingest_pdf(
    vault: &Vault,
    sid: i64,
    name: &str,
    bytes: &[u8],
    deduped: bool,
) -> anyhow::Result<IngestOutcome> {
    let mixed = match ocr::recognize_pdf_mixed(bytes) {
        Ok(m) => m,
        // 连 lopdf 都解析不了(畸形/损坏 PDF):和旧版行为一致——不致命,退回
        // 「已存但无文本」而不是让整次 ingest 报错(原文件已进 CAS,时间线仍
        // 可见,留待后续处理)。页数未知,沿用非 PDF 分支的默认值 1。
        Err(e) => {
            eprintln!("ingest_pdf: {name}: failed to parse PDF, storing without text: {e:#}");
            return store_no_text(vault, sid, name, 1);
        }
    };
    let pages_without_text = mixed.unrecognized_pages();
    if !pages_without_text.is_empty() {
        eprintln!(
            "ingest_pdf: {name}: {} page(s) had no usable text layer and could not be OCR'd: {pages_without_text:?}",
            pages_without_text.len()
        );
    }
    // **康熙部首折叠 —— 缺陷进入系统的唯一入口,这里折一次,下游全部受益。**
    //
    // Chrome / Skia 打印出来的 PDF(国内医院门户导出的常见路径)在自己的
    // `ToUnicode` CMap 里就把常用字声明成了康熙部首码位:`见`→`⻅` U+2EC5、
    // `大`→`⼤` U+2F24、`血`→`⾎`……。**换 PDF 库解决不了** —— `pdf-extract`
    // 忠实照读了 PDF 声明的东西,是那份 PDF 自己错了。(`pdftotext` 不吐部首
    // 只是 poppler 有自己的兜底,不代表 CMap 是对的。)
    //
    // 屏幕上完全看不出来 —— 两者渲染出的字形一模一样。但对每一个做文本匹配的
    // 下游来说它们是不同的字,于是 22 份 demo 上实测:
    //
    //   诊断挂上泳道         1 → 4      「⾼⾎压」对不上 problem_map 的「高血压」
    //   影像/病理诊断意见     1/3 → 3/3  「影像所⻅」对不上「所见」——**那两段
    //                                   整段进不了医生摘要与二维码分享**,而
    //                                   用户以为分享出去了
    //   药物映射到 ATC       6 → 7
    //   classify 判定        3 份被带偏(门诊病历被判成影像报告)
    //   时间线日期           2 份被带偏(MRI 日期变成横跨七个月的假区间)
    //   FTS 26 个关键词      14 个搜不到
    //
    // 化验**几乎不受影响,但那是运气不是设计**:demo 化验单印了 `TC`/`Cr`/`Glu`
    // 拉丁缩写列,词典靠缩写命中。只印中文项目名的化验单不受这条保护。
    //
    // ## 为什么折在这里
    //
    // `classify` / `guess_date_range` 的结果写进 `DocumentAdded` **事件**,建档时
    // 就定死、事后 `rebuild_from_log` 也不自愈 —— 必须赶在它们之前折,放
    // `materialize` 侧救不回来。而 `ocr` crate 不依赖 `core-model`,为一个折叠把
    // rusqlite/jieba 拖进 OCR crate 不划算。`pipeline` 两边都已经依赖,这里是唯一
    // 不需要新增依赖、又赶在所有消费者之前的位置。
    //
    // ## 为什么改「存进库的文字」是安全的
    //
    // 康熙部首块 214 个码位的 NFKC **全部 1:1 折成统一汉字,零例外**(测试
    // `every_kangxi_radical_folds_to_exactly_one_unified_ideograph` 穷举钉住)。
    // 严格同形替换:用户在「文档详情 · 文档内容」里看到的字**一个都不会变样**,
    // 变的只有「复制出去的码位」和「能不能被搜到」—— 而这两样现在都是坏的
    // (复制「⾎糖」去搜是搜不到的)。
    //
    // 「原件永远可达」不受影响:CAS 里的原始 PDF 字节一个 bit 不动。
    //
    // 而且 `.txt` 导入走的 `parser::extract` **早就在折了**,只有 PDF 这条路是
    // 例外 —— 这不是开新口子,是把漏掉的一处补上。
    //
    // ⚠️ 仍有缺口:CJK Radicals Supplement 块(U+2E80–2EF3)**114 个码位没有 NFKC
    // 分解**,现有手写表只覆盖 12 个。`⻉贝 ⻋车 ⻘青 ⻚页 ⻢马 ⻥鱼 ⻦鸟 ⻮齿 ⻰龙`
    // 都还不折,`⻮`(齿)对口腔科文档是实打实的风险。补全要从 Unicode
    // `CJKRadicals.txt` 一次性来,见 `text.rs` 里那条覆盖面测试。
    let text = core_model::text::normalize_cjk_radicals(&mixed.text());
    if text.trim().is_empty() {
        // 一页可用文本都没拿到:和旧版"扫描 PDF 全篇无文本"行为一致(#55)——
        // 降级为 StoredNoText 而非建一个空文档冒充成功,但页数如实带上真实
        // page_count(不再退化成 1),且仍把 pages_without_text 带回去,供
        // 移动端后续针对性补 OCR。
        let mut outcome = store_no_text(vault, sid, name, mixed.page_count())?;
        outcome.pages_without_text = pages_without_text;
        return Ok(outcome);
    }
    let doc_type = parser::classify(&text);
    let (doc_date, doc_date_end) = parser::guess_date_range(&text);
    let doc = vault.add_document(NewDocument {
        source_file_id: sid,
        doc_type: doc_type.clone(),
        doc_date,
        doc_date_end,
        title: Some(name.to_string()),
        language: parser::detect_language(&text),
        page_count: mixed.page_count(),
    })?;
    add_ocr_pages(vault, doc.id, mixed.pages.iter())?;
    let status = if deduped {
        IngestStatus::Backfilled
    } else {
        IngestStatus::New
    };
    Ok(IngestOutcome {
        source_file_id: sid,
        name: name.to_string(),
        status,
        doc_type: Some(doc_type),
        pages_without_text,
    })
}

/// 把 `recognize_pdf_mixed` 逐页判定的结果写进 `ocr_result`——`ingest_pdf`
/// 建档时(全部页)与 `reindex_existing_document` 补页时(只挑 missing 的页)
/// 共用同一段 match/落库逻辑,不许长成两份会走偏的拷贝。`Unrecognized` 的页
/// 跳过不写(该页仍然没有文本,调用方自行从 `pages_without_text`/重新查库
/// 得知)。
fn add_ocr_pages<'a>(
    vault: &Vault,
    document_id: i64,
    pages: impl Iterator<Item = &'a ocr::PdfPage>,
) -> anyhow::Result<()> {
    for page in pages {
        let (page_text, backend, model_version, confidence): (
            &str,
            OcrBackendKind,
            &str,
            Option<f32>,
        ) = match &page.result {
            ocr::PdfPageText::TextLayer(t) => (t, OcrBackendKind::Native, "text-layer", None),
            ocr::PdfPageText::Ocr {
                text,
                confidence,
                backend,
            } => {
                let (backend, model_version) = ocr_provenance(*backend);
                (text, backend, model_version, Some(*confidence))
            }
            // 没恢复出文本的页不落 ocr_result 行——`pages_without_text` 已经
            // 如实带出了它的页码,没必要在这里再造一条空/占位记录。
            ocr::PdfPageText::Unrecognized => continue,
        };
        vault.add_ocr(NewOcr {
            document_id,
            page_no: page.page_no,
            backend,
            model_version: model_version.to_string(),
            // 逐页也要折 —— 上面折的是喂给 classify/guess_date 的整篇副本,
            // 落进 `ocr_result` 的是这一份。`ocr_result.text` 同时是 FTS 索引的
            // 来源、医生分享正文的来源、以及用户在「文档内容」里看到的东西:
            // 这里不折,搜索和影像诊断意见照样是坏的。折叠幂等,重复折无害。
            text: core_model::text::normalize_cjk_radicals(page_text),
            confidence,
        })?;
    }
    Ok(())
}

/// 给定 document 建档时定死的 `page_count` 与当前已落库的 `ocr_result.page_no`
/// 集合,算出仍然缺文本的页码(1-based,升序)。纯函数,不碰库——
/// `reindex_existing_document` 补页前后各调一次,分别得到「该补哪些页」和
/// 「补完之后还缺哪些页」。
fn missing_pages(page_count: i32, present: &[i32]) -> Vec<i32> {
    let present: std::collections::HashSet<i32> = present.iter().copied().collect();
    (1..=page_count).filter(|p| !present.contains(p)).collect()
}

/// dedup 命中(同一份文件字节再导一次)、且 document 早已存在时的处理:默认
/// 什么都不做,原样报 `Deduped`;但如果这份文档还有页缺文本层
/// (`pages_without_text` 当年非空)、这次拿到的又是 PDF,就顺手用这次重新读到
/// 的原始字节把能恢复的页补进 `ocr_result`,状态改报 `Reindexed`。
///
/// **修的缺陷(#63b,GitHub 上被关早了)**:在这个改动之前,`ingest` 顶层看到
/// `imp.deduped && vault.has_document(sid)?` 就直接短路返回 `Deduped`——不管
/// 这份文档当初有没有页因为超出单次 OCR 上限、渲染失败、或"本次会话第一份
/// 就是 PDF、OCR 模型还没落盘"而漏了文本。全仓没有任何别的入口能把这些页
/// 补上,用户能做的只有删除整份、重新导入。现在:同一份文件再导一次,
/// 如果它是 PDF 且还缺页,就顺带把缺的页重新识别一遍——不用户特地找一个
/// "重新识别"按钮,今天最朴素的"再选一次这份文件导入"就能把缺的页找回来。
///
/// **为什么这样补不破坏 CAS 去重的幂等性 / 事件溯源的可重放性**:
///
/// 1. CAS 去重(`Vault::import` 命中已有 `content_hash` 就不再 append
///    `FileImported`)保证的是「同一份**字节**不重复落库」——它从未是、也不该是
///    「同一份文件不许再识别一次」的承诺。这里补的是全新的 `OcrAdded` 事件,
///    不涉及 `FileImported`/`DocumentAdded`:不会有第二条 source_file、不会有
///    第二个 document,CAS 的"一份内容一条记录"没有被动过。
/// 2. 会不会补出重复的 `ocr_result` 行?不会:传进来的 `missing` 只包含**当前
///    库里还没有 `ocr_result` 行**的页码(由 `missing_pages` 现查现算,不是
///    沿用导入当年缓存的旧值),所以这里 append 的每一条 `OcrAdded` 事件在
///    `materialize::apply_event` 眼里都是"这页第一次出现",按
///    `UNIQUE(document_id, page_no)` 正常插入。万一用户手快、并发/重复触发了
///    两次同样的补页(比如两次点了同一个"再导一次"),第二次 append 的
///    `OcrAdded` 在 apply 时会撞上第一次已经写好的同一 `(document_id,
///    page_no)`,`materialize.rs` 里那段 "Idempotency guard" 直接跳过插入和
///    FTS 索引——不会长出两条 `ocr_result`。
/// 3. `rebuild_from_log` 全量重放后是否与当前库一致?一致——因为"库里现在长
///    什么样"完全由「日志里已经 append 了哪些事件」决定,不由「重放时是否
///    调用过这个函数」决定。这个函数只负责**决定要不要 append 新的
///    `OcrAdded` 事件**;一旦事件写进日志,它和任何其它 `OcrAdded` 一样,
///    重放到哪个设备、多少次,都会投影出同一行(2 里说的幂等 guard 保证)。
///    换句话说:补页 = 正常追加一批新事件,不是"回头改历史",重放规则完全
///    不用为它开特例。
///
/// **只有 PDF 能补**:多页 TIFF 第 2 页起的缺页恢复需要新的逐帧解码路径
/// (`ocr::decode_image_bounded` 目前只解第一帧,见 `ingest_image` 文档注释),
/// 不在本次范围——非 PDF 或已完整的文档原样返回 `Deduped`,`pages_without_text`
/// 留空,与改动前的行为逐字节一致(不引入新的字段语义)。
fn reindex_existing_document(
    vault: &Vault,
    sid: i64,
    name: &str,
    is_pdf: bool,
    bytes: &[u8],
) -> anyhow::Result<IngestOutcome> {
    let doc = vault.document_by_source_file_id(sid)?.ok_or_else(|| {
        // has_document(sid) 刚判定为真,这里查不到是数据不一致(而非正常分支),
        // 直接报错而不是悄悄退化成某个默认状态。
        anyhow::anyhow!("has_document 为真但 document_by_source_file_id 查不到 document")
    })?;
    let present = vault.ocr_page_numbers(doc.id)?;
    let missing = missing_pages(doc.page_count, &present);
    if missing.is_empty() || !is_pdf {
        return Ok(IngestOutcome {
            source_file_id: sid,
            name: name.to_string(),
            status: IngestStatus::Deduped,
            doc_type: Some(doc.doc_type),
            pages_without_text: Vec::new(),
        });
    }
    let want: std::collections::HashSet<i32> = missing.iter().copied().collect();
    let mixed = ocr::recognize_pdf_mixed(bytes)?;
    add_ocr_pages(
        vault,
        doc.id,
        mixed.pages.iter().filter(|p| want.contains(&p.page_no)),
    )?;
    let present_after = vault.ocr_page_numbers(doc.id)?;
    let still_missing = missing_pages(doc.page_count, &present_after);
    Ok(IngestOutcome {
        source_file_id: sid,
        name: name.to_string(),
        status: IngestStatus::Reindexed,
        doc_type: Some(doc.doc_type),
        pages_without_text: still_missing,
    })
}

pub struct PatientProfile {
    pub name: Option<String>,
    pub gender: Option<String>,
    pub birth_date: Option<String>,
    pub age: Option<String>,
    pub record_count: i64,
}

/// 从所有文档 OCR 文本派生病人档案:各字段取众数(最常出现值)。
/// 年龄随时间变,取众数为近似;身份靠姓名+性别(稳定)。
pub fn patient_profile(vault: &Vault) -> anyhow::Result<PatientProfile> {
    let texts = vault.all_ocr_texts()?;
    let record_count = texts.len() as i64;
    let mut names: HashMap<String, i32> = HashMap::new();
    let mut genders: HashMap<String, i32> = HashMap::new();
    let mut births: HashMap<String, i32> = HashMap::new();
    let mut ages: HashMap<String, i32> = HashMap::new();
    for t in &texts {
        let d = parser::extract_demographics(t);
        if let Some(n) = d.name {
            *names.entry(n).or_insert(0) += 1;
        }
        if let Some(g) = d.gender {
            *genders.entry(g).or_insert(0) += 1;
        }
        if let Some(b) = d.birth_date {
            *births.entry(b).or_insert(0) += 1;
        }
        if let Some(a) = d.age {
            *ages.entry(a).or_insert(0) += 1;
        }
    }
    let mode = |m: HashMap<String, i32>| m.into_iter().max_by_key(|(_, c)| *c).map(|(k, _)| k);
    Ok(PatientProfile {
        name: mode(names),
        gender: mode(genders),
        birth_date: mode(births),
        age: mode(ages),
        record_count,
    })
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
        let f = tmp_txt(
            fdir.path(),
            "report.txt",
            "出院记录 2023-05-01 肌酐 Creatinine 120",
        );

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
    fn ingest_no_text_still_creates_visible_document() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        // 文件名带日期+影像关键词;内容无文本层(.png 扩展名 → parser 报错)
        let p = fdir.path().join("2025-09-01_胸部X线_扫描件.png");
        std::fs::write(&p, b"\x89PNG\r\n\x1a\nnot-a-real-image").unwrap();

        let o = ingest(&v, &p).unwrap();
        assert_eq!(o.status, IngestStatus::StoredNoText);
        // 现在建了 document → 时间线可见,类型/日期取自文件名
        assert!(v.has_document(o.source_file_id).unwrap());
        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        assert_eq!(tl[0].doc_type, core_model::DocType::ImagingReport);
        assert_eq!(
            tl[0].doc_date.unwrap().format("%Y-%m-%d").to_string(),
            "2025-09-01"
        );
        // 无 OCR 文本
        assert_eq!(v.ocr_text(tl[0].document_id).unwrap(), "");
    }

    /// #55:扫描 PDF(无文本层)且 OCR 取不到任何文本时,必须降级为
    /// `StoredNoText`,而不是把 pdf-extract 的近空文本冒充成「有文本层」的成功
    /// 文档(会谎报 New/Backfilled)。这里用一份合法但空白(无文本、无 DCTDecode
    /// 图片)的 PDF:解析出空文本 → 无可 OCR 图片 → 应如实落 StoredNoText。
    #[test]
    fn scanned_pdf_with_no_ocrable_text_degrades_to_stored_no_text() {
        // 合法单空白页 PDF(无文本、无图片);缺省 xref 由 lopdf 扫描重建。
        const EMPTY_PDF: &[u8] = b"%PDF-1.4\n\
1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n\
2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n\
3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n\
trailer\n<< /Root 1 0 R /Size 4 >>\n%%EOF\n";
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("2025-09-01_检验报告_扫描件.pdf");
        std::fs::write(&p, EMPTY_PDF).unwrap();

        let o = ingest(&v, &p).unwrap();
        assert_eq!(
            o.status,
            IngestStatus::StoredNoText,
            "OCR 取不到文本的扫描 PDF 应落 StoredNoText,不冒充成功文本层"
        );
        // 建了 document(时间线可见)但没有 OCR 文本。
        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        assert_eq!(v.ocr_text(tl[0].document_id).unwrap(), "");
    }

    /// Hand-builds a real 2-page PDF: page 1 has an actual (Helvetica) text
    /// layer long enough to clear `MIN_TEXT_LAYER_LEN` on its own; page 2 is
    /// blank -- no text, no embedded image, i.e. genuinely nothing to
    /// recover. Mirrors a real "printed page 1 + appended scan" discharge
    /// summary, minus the scan itself (kept dependency-free: JPEG/`image`
    /// isn't otherwise a `pipeline` dependency, and a genuinely-unrecoverable
    /// page reproduces the silent-drop defect just as well as a
    /// scanned-image page would -- see the test using this).
    fn build_two_page_pdf_second_page_blank() -> Vec<u8> {
        use lopdf::content::{Content, Operation};
        use lopdf::{dictionary, Document as LoDocument, Object, Stream};

        let mut doc = LoDocument::with_version("1.5");
        let pages_id = doc.new_object_id();
        let font_id = doc.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
        });
        let resources_id = doc.add_object(dictionary! {
            "Font" => dictionary! { "F1" => font_id },
        });
        let content = Content {
            operations: vec![
                Operation::new("BT", vec![]),
                Operation::new("Tf", vec!["F1".into(), 12.into()]),
                Operation::new("Td", vec![20.into(), 700.into()]),
                Operation::new(
                    "Tj",
                    vec![Object::string_literal(
                        "Discharge summary printed page one clinical text",
                    )],
                ),
                Operation::new("ET", vec![]),
            ],
        };
        let content_id = doc.add_object(Stream::new(
            dictionary! {},
            content.encode().expect("encode content stream"),
        ));
        let page1_id = doc.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "Contents" => content_id,
            "Resources" => resources_id,
        });
        // Page 2: blank -- no Contents, no image. Nothing recoverable, which
        // is exactly the case that must be *reported*, not swallowed.
        let page2_id = doc.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
        });
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![page1_id.into(), page2_id.into()],
                "Count" => 2,
                "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            }),
        );
        let catalog_id = doc.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        doc.trailer.set("Root", catalog_id);
        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).expect("save PDF");
        bytes
    }

    /// Same shape as [`build_two_page_pdf_second_page_blank`], except page 2
    /// also carries a real (Helvetica) text layer -- long enough to clear
    /// `ocr::MIN_TEXT_LAYER_LEN` on its own, so recognizing it never touches
    /// an OCR engine (deterministic on every machine/CI, unlike an
    /// OCR-recovered scanned page). Used by the reindex test below to prove a
    /// page gets recovered on retry *without* the test depending on which (if
    /// any) OCR engine is linked -- the same reason
    /// `multi_page_tiff_reports_the_pages_it_never_read_...` avoids asserting
    /// on recognized text.
    fn build_two_page_pdf_both_pages_have_text() -> Vec<u8> {
        use lopdf::content::{Content, Operation};
        use lopdf::{dictionary, Document as LoDocument, Object, Stream};

        let mut doc = LoDocument::with_version("1.5");
        let pages_id = doc.new_object_id();
        let font_id = doc.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
        });
        let resources_id = doc.add_object(dictionary! {
            "Font" => dictionary! { "F1" => font_id },
        });
        let page_of = |doc: &mut LoDocument, text: &str, parent, resources| {
            let content = Content {
                operations: vec![
                    Operation::new("BT", vec![]),
                    Operation::new("Tf", vec!["F1".into(), 12.into()]),
                    Operation::new("Td", vec![20.into(), 700.into()]),
                    Operation::new("Tj", vec![Object::string_literal(text)]),
                    Operation::new("ET", vec![]),
                ],
            };
            let content_id = doc.add_object(Stream::new(
                dictionary! {},
                content.encode().expect("encode content stream"),
            ));
            doc.add_object(dictionary! {
                "Type" => "Page",
                "Parent" => parent,
                "Contents" => content_id,
                "Resources" => resources,
            })
        };
        let page1_id = page_of(
            &mut doc,
            "Discharge summary printed page one clinical text",
            pages_id,
            resources_id,
        );
        let page2_id = page_of(
            &mut doc,
            "Lab report appended as page two clinical text",
            pages_id,
            resources_id,
        );
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![page1_id.into(), page2_id.into()],
                "Count" => 2,
                "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            }),
        );
        let catalog_id = doc.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        doc.trailer.set("Root", catalog_id);
        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).expect("save PDF");
        bytes
    }

    /// **修 #63b(GitHub 关早了):dedup 命中的已存在文档,重新导入必须能补上
    /// 当年漏掉的页,而不是被短路成永久 `Deduped`。**
    ///
    /// 用底层 `Vault` API 直接摆出"首次导入当年漏了第 2 页"这个可观察状态——
    /// document 已建、`page_count == 2`、`ocr_result` 只有第 1 页——而不经
    /// `ingest_pdf` 走一遍完整流程:这份 PDF 两页都有真实文本层,`ingest_pdf`
    /// 今天根本不会漏页,没法用来复现"首次漏页"这个前提(现实中漏页的原因是
    /// 超出单次 OCR 上限 / 渲染失败 / 模型还没落盘,不是文本层本身有没有——但
    /// 那些原因都不确定性、依赖具体 OCR 引擎,断言不动;这里只固定"漏页之后
    /// 的库状态",不纠结漏页的成因)。
    ///
    /// 断言的是**真正的缺陷信号**:重新导入同一份文件后,`ocr_result` 里第 2
    /// 页那一行是不是真的出现了——不是"函数没 panic"这种弱断言。
    #[test]
    fn reindex_recovers_missing_pdf_page_on_reimport() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let name = "2026-02-01_出院小结_两页文本.pdf";
        let p = fdir.path().join(name);
        let bytes = build_two_page_pdf_both_pages_have_text();
        std::fs::write(&p, &bytes).unwrap();

        let imp = v.import(name, "application/pdf", &bytes).unwrap();
        assert!(!imp.deduped, "首次 import 不应该去重");
        let doc = v
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::DischargeSummary,
                doc_date: None,
                doc_date_end: None,
                title: Some("出院小结".into()),
                language: None,
                page_count: 2,
            })
            .unwrap();
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 1,
            backend: OcrBackendKind::Native,
            model_version: "text-layer".into(),
            text: "page one text".into(),
            confidence: None,
        })
        .unwrap();
        // 摆好前提:此刻确实只有第 1 页有 ocr_result,第 2 页缺。
        assert_eq!(v.ocr_page_numbers(doc.id).unwrap(), vec![1]);

        // 重新导入**同一份文件**(同字节 ⇒ CAS 命中 dedup)。改动前:
        // `imp.deduped && vault.has_document(sid)?` 直接短路返回 Deduped,
        // ocr_result 行数原地不动——这正是本次要修的缺陷,退回该行为应让
        // 下面的断言变红(见 PR 描述里的 red→green 记录)。
        let o2 = ingest(&v, &p).unwrap();

        assert_eq!(
            o2.status,
            IngestStatus::Reindexed,
            "文档已存在但仍缺页时,再导一次应报 Reindexed 而不是原地 Deduped"
        );
        assert!(
            o2.pages_without_text.is_empty(),
            "第 2 页这次应该补上了,got {:?}",
            o2.pages_without_text
        );
        // 核心断言:ocr_result 真的多了一行,不是只测状态字段没 panic。
        assert_eq!(
            v.ocr_page_numbers(doc.id).unwrap(),
            vec![1, 2],
            "ocr_result 应该多出第 2 页这一行"
        );
        let full_text = v.ocr_text(doc.id).unwrap();
        assert!(
            full_text.contains("Lab report appended as page two"),
            "第 2 页的文本应该已经落库:{full_text}"
        );

        // 事件溯源的硬约束:补页靠的是普通的 `OcrAdded` 事件(见
        // `reindex_existing_document` 头部注释的推理),不是什么脱离日志的
        // 旁路写入——`rebuild_from_log` 清空全部派生表、只从 `log/` + `objects/`
        // 重放,结果必须逐页一致,否则说明补页走了日志之外的路。
        //
        // 重放后不假定 `document.id` 数值不变(`document` 表是 `INTEGER PRIMARY
        // KEY` 无 AUTOINCREMENT,理论上重放顺序一致时会落回同一个 id,但不靠这个
        // 巧合——按 `source_file_id` 重新查一次,和别处 rebuild 测试的做法一致)。
        v.rebuild_from_log().unwrap();
        let doc_after = v
            .document_by_source_file_id(imp.source_file.id)
            .unwrap()
            .expect("重放后 document 必须还在");
        assert_eq!(
            v.ocr_page_numbers(doc_after.id).unwrap(),
            vec![1, 2],
            "rebuild_from_log 重放后,第 2 页的 ocr_result 必须还在"
        );
        assert_eq!(
            v.ocr_text(doc_after.id).unwrap(),
            full_text,
            "rebuild_from_log 重放后文本必须与重放前逐字一致"
        );

        // 再导一次(此刻已完整):不该再报 Reindexed,也不该重复写 ocr_result。
        let o3 = ingest(&v, &p).unwrap();
        assert_eq!(
            o3.status,
            IngestStatus::Deduped,
            "已经补完的文档,再导一次应该原样 Deduped(没有更多可补的页)"
        );
        assert_eq!(v.ocr_page_numbers(doc_after.id).unwrap(), vec![1, 2]);
    }

    /// **Reproduces the mixed-page-PDF silent-data-loss defect this file's
    /// `ingest_pdf` split fixes.** A document whose page 1 has a real
    /// printed text layer and whose page 2 has nothing recoverable used to
    /// be judged by the *whole document's concatenated* text length: page 1
    /// alone cleared the old `MIN_TEXT_LAYER_LEN` check, so the document was
    /// accepted as "fully has a text layer" and page 2 was never even looked
    /// at. Result: `IngestStatus::New` (UI reports success), `page_count`
    /// wrong (the dead form-feed heuristic always says 1 -- see
    /// `ocr::MIN_TEXT_LAYER_LEN`'s doc comment), and *zero* signal anywhere
    /// that page 2's content never made it in.
    ///
    /// Run this against `origin/main` (pre-fix): it fails to compile, because
    /// `IngestOutcome` has no `pages_without_text` field there -- the field
    /// itself is part of the fix (undetectable data loss can't be asserted
    /// against without something to assert on). After the fix: page count is
    /// accurate and page 2 is explicitly named as unrecognized rather than
    /// silently dropped.
    #[test]
    fn mixed_page_pdf_reports_unreadable_pages_instead_of_silently_dropping_them() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("2026-01-10_出院小结_混合页.pdf");
        std::fs::write(&p, build_two_page_pdf_second_page_blank()).unwrap();

        let o = ingest(&v, &p).unwrap();
        // Page 1's real text is enough to make this a genuine, useful
        // document -- not StoredNoText.
        assert_eq!(o.status, IngestStatus::New);
        // The crux of the fix: page 2 must be named, not swallowed.
        assert_eq!(
            o.pages_without_text,
            vec![2],
            "page 2 has no text layer and no OCR-able image -- must be reported, not silently dropped"
        );

        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        let doc = v.document_by_id(tl[0].document_id).unwrap().unwrap();
        assert_eq!(
            doc.page_count, 2,
            "page count must reflect both pages, not the dead form-feed heuristic's stuck-at-1"
        );
        // Page 1's text made it in; nothing fabricated for page 2.
        let text = v.ocr_text(tl[0].document_id).unwrap();
        assert!(
            text.contains("Discharge summary"),
            "page 1 text missing: {text}"
        );
    }

    /// **Reproduces the multi-page-image silent-data-loss defect `ingest_image`
    /// fixes** (the image twin of the mixed-page-PDF case above; GitHub #63 was
    /// closed while this still reproduced).
    ///
    /// A two-page TIFF -- accepted by the desktop file picker and by mobile's
    /// `kImageExtensions` alike -- used to come back with `page_count == 1`,
    /// one `ocr_result` row for page 1, and `pages_without_text` empty, because
    /// that field was PDF-only. Page 2 vanished with **no signal at any layer**
    /// while the UI reported success.
    ///
    /// Deliberately asserts nothing about recognized *text*: no OCR engine runs
    /// in CI (and on macOS `recognize_platform_best` is Apple Vision, a
    /// different engine from the phones'), so this pins only what is
    /// engine-independent -- the page count and the named missing pages. On
    /// pre-fix code it fails on both regardless of which recognizer is present.
    #[test]
    fn multi_page_tiff_reports_the_pages_it_never_read_instead_of_dropping_them() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("2026-03-11_化验单_两页.tiff");
        std::fs::write(&p, ocr::testing::plain_multipage_tiff(2)).unwrap();

        let o = ingest(&v, &p).unwrap();
        // The crux of the fix: page 2 was never looked at by any recognizer, so
        // it must be named. Whether page 1 yielded text depends on the engine
        // available on this machine, so accept either page set -- but never an
        // empty one, which is precisely the silent loss.
        assert!(
            o.pages_without_text == vec![2] || o.pages_without_text == vec![1, 2],
            "page 2 of a 2-page TIFF is never read -- it must be reported, not \
             silently dropped; got {:?} (status {:?})",
            o.pages_without_text,
            o.status
        );

        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        let doc = v.document_by_id(tl[0].document_id).unwrap().unwrap();
        assert_eq!(
            doc.page_count, 2,
            "page count must reflect the original's real page count, not the \
             image path's hardcoded 1"
        );
    }

    /// The counterweight to the test above: an ordinary single-page image must
    /// behave exactly as before -- `page_count` 1 and **nothing** reported as
    /// missing. Widening `pages_without_text` beyond PDFs must not start
    /// flagging the overwhelmingly common case (a photo / one-page scan), which
    /// would turn a real signal into noise users learn to ignore.
    #[test]
    fn single_page_image_reports_no_missing_pages() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("2026-03-11_化验单_单页.tiff");
        std::fs::write(&p, ocr::testing::plain_multipage_tiff(1)).unwrap();

        let o = ingest(&v, &p).unwrap();
        assert!(
            o.pages_without_text.is_empty(),
            "nothing was skipped in a single-page image; got {:?}",
            o.pages_without_text
        );
        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        assert_eq!(
            v.document_by_id(tl[0].document_id)
                .unwrap()
                .unwrap()
                .page_count,
            1
        );
    }

    /// .dcm 走独立分支:元数据(非 OCR)驱动 doc_type/日期/标题,原文件+摘要
    /// 均可查。样本文件随仓库提交,读取本地路径,离线可跑。
    #[test]
    fn ingest_dicom_ct_builds_imaging_document() {
        let vdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/dicom/CT_small.dcm"
        ));
        let o = ingest(&v, p).unwrap();
        assert_eq!(o.status, IngestStatus::New);
        assert_eq!(o.doc_type, Some(core_model::DocType::ImagingReport));

        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        assert_eq!(tl[0].doc_type, core_model::DocType::ImagingReport);
        assert_eq!(
            tl[0].doc_date.unwrap().format("%Y-%m-%d").to_string(),
            "2004-01-19"
        );

        let text = v.ocr_text(tl[0].document_id).unwrap();
        assert!(text.contains("CT"), "unexpected summary text: {text}");
        assert!(
            text.contains("JFK IMAGING CENTER"),
            "unexpected summary text: {text}"
        );

        // 去重再导入:不重复建 document,时间线仍只有一条
        let o2 = ingest(&v, p).unwrap();
        assert_eq!(o2.status, IngestStatus::Deduped);
        assert_eq!(v.timeline().unwrap().len(), 1);
    }

    /// 导入一个 12 张切片的 DICOM 序列文件夹 → 应聚成**一个** imaging_report 文档
    /// (而非 12 份),含 12 条有序 imaging_instance(按 instance_number)。再次导入
    /// 整个文件夹全部去重,文档与切片数均不变。样本随仓库提交,离线可跑。
    #[test]
    fn ingest_dicom_series_groups_into_one_study() {
        let vdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let dir = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/imaging/头颅CT序列"
        ));
        let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("dcm"))
            .collect();
        files.sort();
        assert_eq!(files.len(), 12, "fixture should have 12 slices");

        let mut new_count = 0;
        let mut attached_count = 0;
        for f in &files {
            let o = ingest(&v, f).unwrap();
            match o.status {
                IngestStatus::New => new_count += 1,
                IngestStatus::InstanceAttached => attached_count += 1,
                s => panic!("unexpected status {s:?} for {}", f.display()),
            }
            assert_eq!(o.doc_type, Some(core_model::DocType::ImagingReport));
        }
        // 第一张建文档,其余 11 张并入。
        assert_eq!(new_count, 1);
        assert_eq!(attached_count, 11);

        // 时间线只有一张卡。
        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        let doc_id = tl[0].document_id;

        // 12 条切片,按 instance_number 有序(1..=12)。
        let insts = v.imaging_instances(doc_id).unwrap();
        assert_eq!(insts.len(), 12);
        let order: Vec<i32> = insts.iter().map(|i| i.instance_number.unwrap()).collect();
        assert_eq!(order, (1..=12).collect::<Vec<_>>());

        // 再次导入整个文件夹 → 全部去重,不新增文档/切片。
        for f in &files {
            let o = ingest(&v, f).unwrap();
            assert_eq!(
                o.status,
                IngestStatus::Deduped,
                "re-import should dedup {}",
                f.display()
            );
        }
        assert_eq!(v.timeline().unwrap().len(), 1);
        assert_eq!(v.imaging_instances(doc_id).unwrap().len(), 12);

        // rebuild_from_log 后状态一致(脱库重放也是一个 study + 12 切片)。
        v.rebuild_from_log().unwrap();
        assert_eq!(v.timeline().unwrap().len(), 1);
        assert_eq!(v.imaging_instances(doc_id).unwrap().len(), 12);
    }

    /// 单张 DICOM(带 study_uid、无同伴切片)仍工作:1 个 study 文档 + 1 条切片。
    #[test]
    fn ingest_single_dicom_is_one_study_one_instance() {
        let vdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/dicom/CT_small.dcm"
        ));
        let o = ingest(&v, p).unwrap();
        assert_eq!(o.status, IngestStatus::New);
        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        let insts = v.imaging_instances(tl[0].document_id).unwrap();
        assert_eq!(insts.len(), 1);
        assert_eq!(insts[0].instance_number, Some(1));
    }

    /// 扫描图 PDF(无文本层):应通过 recognize_pdf 补 OCR 文本,分类/日期取自
    /// 识别文本,而非退回文件名。需要 OCR 模型(联网首次下载,之后缓存)。
    ///   cargo test -p pipeline -- --ignored
    #[test]
    #[ignore]
    fn ingest_scanned_pdf_ocrs_and_dates() {
        let vdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/photos/2026-03-15_检验报告_扫描图PDF.pdf"
        ));
        let o = ingest(&v, p).unwrap();
        assert_eq!(o.status, IngestStatus::New);
        assert_eq!(o.doc_type, Some(core_model::DocType::LabReport));
        let tl = v.timeline().unwrap();
        assert_eq!(tl.len(), 1);
        assert_eq!(
            tl[0].doc_date.unwrap().format("%Y-%m-%d").to_string(),
            "2026-03-15"
        );
        let text = v.ocr_text(tl[0].document_id).unwrap();
        assert!(
            text.contains("肌酐") || text.contains("Creatinine"),
            "unexpected OCR text: {text}"
        );
    }

    /// 超过体积上限的文件被拒绝:用 `set_len` 造一个稀疏文件(metadata 报的大小
    /// 超过上限,但磁盘上几乎不占空间、内存里一个字节都没读),确认 ingest 在
    /// `fs::read` 之前就凭 metadata 返回「文件过大」错误,而非 OOM。
    #[test]
    fn ingest_rejects_oversized_file_before_reading() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("huge.pdf");
        let f = std::fs::File::create(&p).unwrap();
        // 稀疏:声明比上限多 1 字节的长度,不实际写入数据。
        f.set_len(MAX_INGEST_BYTES + 1).unwrap();
        drop(f);

        let err = ingest(&v, &p).unwrap_err();
        assert!(
            err.to_string().contains("文件过大"),
            "expected size-cap error, got: {err}"
        );
        // 什么都不该入库(既没读文件,也没建 document)。
        assert_eq!(v.timeline().unwrap().len(), 0);
    }

    #[test]
    fn ingest_captures_date_range() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        let p = fdir.path().join("discharge.txt");
        std::fs::write(
            &p,
            "出院记录\n入院日期:2023-01-01 出院日期:2023-01-20\n脑梗死",
        )
        .unwrap();
        ingest(&v, &p).unwrap();
        let tl = v.timeline().unwrap();
        assert_eq!(
            tl[0].doc_date.unwrap().format("%Y-%m-%d").to_string(),
            "2023-01-01"
        );
        assert_eq!(
            tl[0].doc_date_end.unwrap().format("%Y-%m-%d").to_string(),
            "2023-01-20"
        );
    }

    #[test]
    fn patient_profile_aggregates_mode() {
        let vdir = tempfile::tempdir().unwrap();
        let fdir = tempfile::tempdir().unwrap();
        let v = Vault::open(vdir.path()).unwrap();
        for (i, body) in [
            "检验报告\n姓名:张建国 性别:男 年龄:59岁\n日期 2024-01-01 肌酐 90",
            "出院记录\n姓名:张建国 性别:男 年龄:60岁\n日期 2025-02-02 脑梗死",
        ]
        .iter()
        .enumerate()
        {
            let p = fdir.path().join(format!("r{i}.txt"));
            std::fs::write(&p, body).unwrap();
            ingest(&v, &p).unwrap();
        }
        let prof = patient_profile(&v).unwrap();
        assert_eq!(prof.name.as_deref(), Some("张建国"));
        assert_eq!(prof.gender.as_deref(), Some("男"));
        assert_eq!(prof.record_count, 2);
    }
}
