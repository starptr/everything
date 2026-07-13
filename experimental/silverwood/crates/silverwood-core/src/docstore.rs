use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use uuid::Uuid;

use crate::error::{Error, Result};
use crate::id::WorkstreamId;

/// File extension for a persisted workstream document.
const DOC_EXT: &str = "loro";

/// Where workstream documents are persisted. Each document is keyed by its
/// [`WorkstreamId`]; the store is oblivious to document contents (opaque bytes).
///
/// The default backend is [`FilesDocStore`]; alternative backends (SQLite blob,
/// remote-over-SSH) may implement this trait without touching the domain layer.
pub trait DocStore {
    /// Load a document's bytes, or `None` if no such document exists.
    fn load(&self, id: WorkstreamId) -> Result<Option<Vec<u8>>>;

    /// Persist a document's bytes, overwriting any existing document.
    fn save(&self, id: WorkstreamId, bytes: &[u8]) -> Result<()>;

    /// Enumerate the ids of all documents currently present.
    fn list_ids(&self) -> Result<Vec<WorkstreamId>>;
}

/// A [`DocStore`] backed by one file per document under a directory.
pub struct FilesDocStore {
    dir: PathBuf,
}

impl FilesDocStore {
    /// Create a store rooted at `dir`. The directory is expected to exist.
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    fn path_for(&self, id: WorkstreamId) -> PathBuf {
        self.dir.join(format!("{id}.{DOC_EXT}"))
    }
}

impl DocStore for FilesDocStore {
    fn load(&self, id: WorkstreamId) -> Result<Option<Vec<u8>>> {
        let path = self.path_for(id);
        match fs::read(&path) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::io(path, e)),
        }
    }

    fn save(&self, id: WorkstreamId, bytes: &[u8]) -> Result<()> {
        let path = self.path_for(id);
        fs::write(&path, bytes).map_err(|e| Error::io(path, e))
    }

    fn list_ids(&self) -> Result<Vec<WorkstreamId>> {
        let entries = match fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(Error::io(&self.dir, e)),
        };

        let mut ids = Vec::new();
        for entry in entries {
            let path = entry.map_err(|e| Error::io(&self.dir, e))?.path();
            if !is_doc(&path) {
                continue;
            }
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .ok_or_else(|| Error::InvalidDocId(path.clone()))?;
            let uuid = Uuid::parse_str(stem).map_err(|_| Error::InvalidDocId(path.clone()))?;
            ids.push(WorkstreamId(uuid));
        }
        Ok(ids)
    }
}

/// Whether `path` names a document file (`*.loro`).
fn is_doc(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()) == Some(DOC_EXT)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A unique temp directory for an isolated test, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("silverwood-{tag}-{}", Uuid::now_v7()));
            fs::create_dir_all(&dir).unwrap();
            TempDir(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn load_missing_is_none() {
        let dir = TempDir::new("docstore-missing");
        let store = FilesDocStore::new(&dir.0);
        assert!(store.load(WorkstreamId::generate()).unwrap().is_none());
    }

    #[test]
    fn save_then_load_round_trips() {
        let dir = TempDir::new("docstore-roundtrip");
        let store = FilesDocStore::new(&dir.0);
        let id = WorkstreamId::generate();

        store.save(id, b"hello silverwood").unwrap();

        assert_eq!(
            store.load(id).unwrap().as_deref(),
            Some(&b"hello silverwood"[..])
        );
    }

    #[test]
    fn list_ids_reports_saved_docs_only() {
        let dir = TempDir::new("docstore-list");
        let store = FilesDocStore::new(&dir.0);
        let id = WorkstreamId::generate();
        store.save(id, b"x").unwrap();

        // A non-document file must be ignored.
        fs::write(dir.0.join("README.txt"), b"ignore me").unwrap();

        assert_eq!(store.list_ids().unwrap(), vec![id]);
    }

    #[test]
    fn list_ids_on_absent_dir_is_empty() {
        let store = FilesDocStore::new(std::env::temp_dir().join("silverwood-does-not-exist-xyz"));
        assert!(store.list_ids().unwrap().is_empty());
    }
}
