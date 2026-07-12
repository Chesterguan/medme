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
    Import { files: Vec<PathBuf> },
    Search { query: String },
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
                };
                println!("{line}");
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
