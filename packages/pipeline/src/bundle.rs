//! 结构化导入:吃 myEHR Epic 适配器产出的包。
//!
//! 包 = `manifest.json` + `docs/<...>.pdf` + 同名 `docs/<...>.extraction.json`
//! (sidecar,`deid::Extraction` 同形,多 `loinc`/`rxnorm` 两个可选键)。格式由
//! myEHR 定,这里只读。设计:`docs/superpowers/specs/2026-10-21-structured-import-design.md`。
//!
//! 每份文档:核 sha256 → `Vault::import` → `ingest_pdf`(类型/标题/日期以 manifest
//! 为准,不再 classify)→ sidecar **原文**作为 `result_json` 挂一条
//! `ExtractionAdded{backend:"epic-adapter"}`。`deid::verify` 只在 MedMe 自己抽出的
//! 页文本上**计数**(两边文本抽取是否一致的体检信号),不用它的产物落库——它的
//! 候选集只认整行/单词,多词英文项目名会被整条丢掉,而适配器已对原文做过逐字校验。
//! 整包末尾 `rebuild_encounters` 一次。零新事件类型。
//!
//! zip 不解压到磁盘:按 manifest 列的名字 `by_name` 读进内存。没有临时目录、没有
//! 明文副本、没有 zip-slip 面(从不按归档里的名字写文件)。
use crate::{ingest_pdf, IngestStatus, MAX_INGEST_BYTES};
use anyhow::Context;
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use core_model::{DocType, NewExtraction, Vault};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

/// `import_bundle` 的结果。`failed` 里的每份都没有挂上 extraction;文档本身
/// 可能已建(sidecar 坏/缺的情形),再导一次会报 `deduped`。
#[derive(Debug, Default, Clone)]
pub struct BundleReport {
    pub total: usize,
    /// 新建文档且挂上 extraction。
    pub imported: usize,
    /// 同一份 PDF 已在库里(含用户之前手动导过的):元数据不改、不重复挂 extraction。
    pub deduped: usize,
    /// 文档在、类型相同、但包里 sidecar 的内容(sha256)与已挂的 extraction 不同 → 重新挂
    /// (`ExtractionAdded` 以 `created_at` 新者为准,零新事件类型)。适配器修了解析后,
    /// 用户重导新包即可刷新抽取,不必删成员重来。
    pub updated: usize,
    /// 整份没有可用文本(建不了文档,原件仍在 CAS)。
    pub no_text: usize,
    /// (manifest 里的 `file`, 原因)。
    pub failed: Vec<(String, String)>,
    /// `deid::verify` 在 MedMe 自己抽的页文本上找不到的字段总数(只计数,不改内容)。
    pub verify_rejected: usize,
    pub verify_unverified: usize,
}

/// manifest 里 MedMe 用到的键;其余(`source`/`encounters`/`coverage`/
/// `encounter_title`/`pages`)事件里没有位置,忽略。
#[derive(Deserialize)]
struct Manifest {
    docs: Vec<ManifestDoc>,
}

#[derive(Deserialize)]
struct ManifestDoc {
    file: String,
    #[serde(default)]
    sha256: Option<String>,
    doc_type: String,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    doc_date: Option<String>,
    #[serde(default)]
    doc_date_end: Option<String>,
}

/// 包的两种形态,统一成「按相对路径读字节」。
enum Source {
    Dir(PathBuf),
    Zip {
        archive: zip::ZipArchive<File>,
        /// `manifest.json` 在归档里的目录前缀(macOS「压缩」会多一层顶级文件夹)。
        prefix: String,
    },
}

const MANIFEST: &str = "manifest.json";

impl Source {
    fn open(path: &Path) -> anyhow::Result<Source> {
        if path.is_dir() {
            return Ok(Source::Dir(path.to_path_buf()));
        }
        let is_zip = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("zip"));
        if !is_zip {
            anyhow::bail!("{} 既不是文件夹也不是 .zip", path.display());
        }
        let archive = zip::ZipArchive::new(File::open(path)?)
            .with_context(|| format!("打不开 zip {}", path.display()))?;
        // 最浅的那个 manifest.json 当包根(macOS「压缩」多一层顶级文件夹);同一深度
        // 有两个就是把两个包压在一起了,不猜。`__MACOSX/` 里的 `._manifest.json`
        // 资源叉不以 `/manifest.json` 结尾,天然进不来。
        let mut candidates: Vec<&str> = archive
            .file_names()
            .filter_map(|n| n.strip_suffix(MANIFEST))
            .filter(|p| p.is_empty() || p.ends_with('/'))
            .collect();
        candidates.sort_by_key(|p| (p.matches('/').count(), p.to_string()));
        let prefix = match candidates.as_slice() {
            [] => anyhow::bail!("zip 里没有 manifest.json"),
            [one] => one.to_string(),
            [a, b, ..] if a.matches('/').count() == b.matches('/').count() => {
                anyhow::bail!("zip 里有不止一个包(manifest.json 出现在 {a:?} 与 {b:?})")
            }
            [first, ..] => first.to_string(),
        };
        Ok(Source::Zip { archive, prefix })
    }

    fn read(&mut self, rel: &str) -> anyhow::Result<Vec<u8>> {
        // manifest 里的路径只许是包内相对路径:不许绝对、不许 `..`。sha 不符本来也会
        // 挡,但读一个包外文件进内存这一步本身就不该发生。
        if !Path::new(rel)
            .components()
            .all(|c| matches!(c, std::path::Component::Normal(_)))
        {
            anyhow::bail!("file 路径不合法(只许包内相对路径):{rel:?}");
        }
        match self {
            Source::Dir(dir) => {
                let p = dir.join(rel);
                let len = std::fs::metadata(&p)
                    .with_context(|| format!("读不到 {rel}"))?
                    .len();
                if len > MAX_INGEST_BYTES {
                    anyhow::bail!("{rel} 过大:{len} 字节,超过上限 {MAX_INGEST_BYTES}");
                }
                Ok(std::fs::read(&p)?)
            }
            Source::Zip { archive, prefix } => {
                let name = format!("{prefix}{rel}");
                let mut f = archive
                    .by_name(&name)
                    .with_context(|| format!("zip 里没有 {rel}"))?;
                if f.size() > MAX_INGEST_BYTES {
                    anyhow::bail!("{rel} 过大:{} 字节,超过上限 {MAX_INGEST_BYTES}", f.size());
                }
                let mut buf = Vec::with_capacity(f.size() as usize);
                f.read_to_end(&mut buf)?;
                Ok(buf)
            }
        }
    }
}

/// `YYYY-MM-DD` → 当天 00:00:00Z,与 `parser::guess_date_range` 同一口径。
fn parse_date(s: &str) -> anyhow::Result<DateTime<Utc>> {
    let d =
        NaiveDate::parse_from_str(s, "%Y-%m-%d").with_context(|| format!("日期不合法:{s:?}"))?;
    Utc.from_local_datetime(&d.and_hms_opt(0, 0, 0).expect("00:00:00 is valid"))
        .single()
        .ok_or_else(|| anyhow::anyhow!("日期不合法:{s:?}"))
}

fn opt_date(s: &Option<String>) -> anyhow::Result<Option<DateTime<Utc>>> {
    match s.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) => Ok(Some(parse_date(s)?)),
        None => Ok(None),
    }
}

/// 导入一个包(文件夹或 `.zip`)。`progress(done, total)` 每份调一次(不论成败)。
/// manifest 读不到/不合法 → `Err`,什么都不写;单份失败不中止整批,进 `failed`。
pub fn import_bundle(
    vault: &Vault,
    path: &Path,
    progress: &mut dyn FnMut(usize, usize),
) -> anyhow::Result<BundleReport> {
    let mut src = Source::open(path)?;
    let manifest: Manifest =
        serde_json::from_slice(&src.read(MANIFEST)?).context("manifest.json 不合法")?;
    let total = manifest.docs.len();
    let mut report = BundleReport {
        total,
        ..Default::default()
    };
    for (i, d) in manifest.docs.iter().enumerate() {
        if let Err(e) = import_one(vault, &mut src, d, &mut report) {
            report.failed.push((d.file.clone(), format!("{e:#}")));
        }
        progress(i + 1, total);
    }
    vault.rebuild_encounters()?;
    Ok(report)
}

fn import_one(
    vault: &Vault,
    src: &mut Source,
    d: &ManifestDoc,
    report: &mut BundleReport,
) -> anyhow::Result<()> {
    // 先把 manifest 这一条本身核完(类型/日期/sha),再碰库——`DocumentAdded`
    // 只写一次,不能先建档再发现日期是坏的。
    let doc_type = DocType::from_str(&d.doc_type);
    if doc_type == DocType::Unknown {
        anyhow::bail!("doc_type 不认识:{:?}", d.doc_type);
    }
    let date_span = (opt_date(&d.doc_date)?, opt_date(&d.doc_date_end)?);
    match date_span {
        (None, Some(_)) => anyhow::bail!("只有 doc_date_end 没有 doc_date"),
        (Some(a), Some(b)) if b < a => anyhow::bail!("doc_date_end 早于 doc_date"),
        _ => {}
    }
    let expected = d
        .sha256
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow::anyhow!("manifest 没给 sha256(--text-only 包没有 PDF)"))?;
    let name = Path::new(&d.file)
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|n| !n.is_empty())
        .ok_or_else(|| anyhow::anyhow!("file 不合法:{:?}", d.file))?;
    let sidecar_rel = d
        .file
        .strip_suffix(".pdf")
        .map(|stem| format!("{stem}.extraction.json"))
        .ok_or_else(|| anyhow::anyhow!("file 不是 .pdf:{:?}", d.file))?;

    let bytes = src.read(&d.file)?;
    let actual = core_model::cas::sha256_hex(&bytes);
    if !actual.eq_ignore_ascii_case(expected) {
        anyhow::bail!("sha256 不符:manifest {expected},实际 {actual}");
    }

    let imp = vault.import(name, "application/pdf", &bytes)?;
    let sid = imp.source_file.id;
    if imp.deduped {
        if let Some(doc) = vault.document_by_source_file_id(sid)? {
            // 文档在了。上次 sidecar 缺/坏、或建档后被杀,extraction 还没挂上 → 这次
            // 补挂(就是「重跑即续传」);类型对不上说明是用户手动导过的同一份 PDF,
            // 元数据不动、也不替它挂包里的抽取。
            if doc.doc_type == doc_type {
                match vault.extraction_json(doc.id)? {
                    None => {
                        attach_sidecar(vault, src, &sidecar_rel, doc.id, report)?;
                        report.imported += 1;
                    }
                    Some(existing) => {
                        // 内容变了才重挂:同一份 sidecar 再导一次仍是 deduped。
                        let incoming = src.read(&sidecar_rel).context("sidecar")?;
                        if core_model::cas::sha256_hex(&incoming)
                            != core_model::cas::sha256_hex(existing.as_bytes())
                        {
                            attach_sidecar(vault, src, &sidecar_rel, doc.id, report)?;
                            report.updated += 1;
                        } else {
                            report.deduped += 1;
                        }
                    }
                }
            } else {
                report.deduped += 1;
            }
            return Ok(());
        }
    }
    let title = d
        .title
        .as_deref()
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .unwrap_or(name)
        .to_string();
    let outcome = ingest_pdf(
        vault,
        sid,
        name,
        &bytes,
        imp.deduped,
        &BTreeMap::new(),
        date_span,
        Some((doc_type, title)),
    )?;
    if outcome.status == IngestStatus::StoredNoText {
        report.no_text += 1;
        return Ok(());
    }
    let doc = vault
        .document_by_source_file_id(sid)?
        .ok_or_else(|| anyhow::anyhow!("建档后找不到 document"))?;
    attach_sidecar(vault, src, &sidecar_rel, doc.id, report)?;
    report.imported += 1;
    Ok(())
}

/// sidecar 原文 → `ExtractionAdded`。`deid::verify` 只计数(见模块文档)。
fn attach_sidecar(
    vault: &Vault,
    src: &mut Source,
    sidecar_rel: &str,
    document_id: i64,
    report: &mut BundleReport,
) -> anyhow::Result<()> {
    let raw = String::from_utf8(src.read(sidecar_rel).context("sidecar")?)
        .context("sidecar 不是 UTF-8")?;
    let parsed = deid::parse_extraction(&raw)
        .map_err(|e| anyhow::anyhow!("sidecar 不是合法抽取 JSON:{e}"))?;
    let verified = deid::verify(parsed, &vault.ocr_text(document_id)?, deid::Mode::Text);
    report.verify_rejected += verified.rejected;
    report.verify_unverified += verified.unverified;
    vault.add_extraction(NewExtraction {
        document_id,
        backend: "epic-adapter".into(),
        model_version: "myehr-epic-adapter".into(),
        mode: "text".into(),
        schema: 1,
        result_json: raw,
    })?;
    Ok(())
}
