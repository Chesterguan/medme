pub mod cas;
pub mod error;
pub mod schema;
pub mod tokenize;
pub mod types;

pub use error::MedmeError;
pub use types::{SourceFile, DocType, OcrBackendKind, Import, Document, NewDocument, NewOcr};

use std::path::{Path, PathBuf};
use rusqlite::Connection;

pub struct Vault {
    conn: Connection,
    root: PathBuf,
}

impl Vault {
    pub fn open(root: &Path) -> Result<Vault, MedmeError> {
        std::fs::create_dir_all(root.join("objects"))?;
        std::fs::write(root.join("VERSION"), "1")?;
        let conn = Connection::open(root.join("medme.db"))?;
        schema::migrate(&conn)?;
        Ok(Vault { conn, root: root.to_path_buf() })
    }

    pub fn user_version(&self) -> Result<i64, MedmeError> {
        Ok(self.conn.query_row("PRAGMA user_version", [], |r| r.get(0))?)
    }

    pub(crate) fn conn(&self) -> &rusqlite::Connection { &self.conn }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_creates_vault_and_migrates() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        assert_eq!(v.user_version().unwrap(), 1);
        assert!(dir.path().join("objects").is_dir());
        assert!(dir.path().join("medme.db").is_file());
    }
}
