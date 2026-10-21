use clap::{Parser, Subcommand};
use core_model::Vault;
use std::path::PathBuf;

#[derive(Parser)]
struct Cli {
    #[arg(long)]
    vault: PathBuf,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    Import {
        files: Vec<PathBuf>,
    },
    /// 导入 myEHR Epic 适配器产出的包(文件夹或 .zip):类型/日期/标题以 manifest
    /// 为准,sidecar 原样挂成 extraction。见 `pipeline::import_bundle`。
    ImportBundle {
        path: PathBuf,
    },
    Search {
        query: String,
    },
    Timeline,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let vault = Vault::open(&cli.vault)?;

    match cli.cmd {
        Cmd::Import { files } => {
            for f in files {
                // 单个坏文件不中止整批(与桌面/手机的 ingest_guarded / ingest_one
                // 一致的不变式:一份文件失败只记一行,继续下一份)。
                let o = match pipeline::ingest(&vault, &f) {
                    Ok(o) => o,
                    Err(e) => {
                        eprintln!("failed {} ({e})", f.display());
                        continue;
                    }
                };
                let line = match o.status {
                    pipeline::IngestStatus::New => format!(
                        "import {} (id={}, type={})",
                        o.name,
                        o.source_file_id,
                        o.doc_type.as_ref().map(|d| d.as_str()).unwrap_or("unknown")
                    ),
                    pipeline::IngestStatus::Backfilled => format!(
                        "index  {} (backfilled, id={}, type={})",
                        o.name,
                        o.source_file_id,
                        o.doc_type.as_ref().map(|d| d.as_str()).unwrap_or("unknown")
                    ),
                    pipeline::IngestStatus::Deduped => format!(
                        "dedup  {} (already stored & indexed, id={})",
                        o.name, o.source_file_id
                    ),
                    pipeline::IngestStatus::StoredNoText => format!(
                        "import {} (stored, no text layer, id={})",
                        o.name, o.source_file_id
                    ),
                    pipeline::IngestStatus::InstanceAttached => format!(
                        "attach {} (DICOM slice merged into study, id={})",
                        o.name, o.source_file_id
                    ),
                    pipeline::IngestStatus::Reindexed => {
                        if o.pages_without_text.is_empty() {
                            format!(
                                "reindex {} (missing pages recovered, id={})",
                                o.name, o.source_file_id
                            )
                        } else {
                            format!(
                                "reindex {} (still missing pages {:?}, id={})",
                                o.name, o.pages_without_text, o.source_file_id
                            )
                        }
                    }
                };
                println!("{line}");
            }
        }
        Cmd::ImportBundle { path } => {
            let r = pipeline::import_bundle(&vault, &path, &mut |done, total| {
                eprintln!("[{done}/{total}]");
            })?;
            println!(
                "total {}  imported {}  deduped {}  no_text {}  failed {}  verify_rejected {}  verify_unverified {}",
                r.total,
                r.imported,
                r.deduped,
                r.no_text,
                r.failed.len(),
                r.verify_rejected,
                r.verify_unverified
            );
            for (file, why) in &r.failed {
                println!("failed {file}: {why}");
            }
        }
        Cmd::Search { query } => {
            let hits = vault.search(&query, 20)?;
            if hits.is_empty() {
                println!("no matches");
            }
            for h in hits {
                println!("#{}  {}", h.document_id, h.snippet);
            }
        }
        Cmd::Timeline => {
            for e in vault.timeline()? {
                let date = e
                    .doc_date
                    .map(|d| d.format("%Y-%m-%d").to_string())
                    .unwrap_or_else(|| "无日期".into());
                println!(
                    "{date}  [{}]  {}",
                    e.doc_type.as_str(),
                    e.title.unwrap_or_default()
                );
            }
        }
    }
    Ok(())
}
