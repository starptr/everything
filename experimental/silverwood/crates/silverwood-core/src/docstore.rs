use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::error::{Error, Result};
use crate::id::{IdScheme, WorkstreamId};

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

    /// The canonical, scheme-explicit path for a document (`uuidv7_<uuid>.loro`).
    /// Brand-new documents are written here.
    fn explicit_path(&self, id: WorkstreamId) -> PathBuf {
        self.dir.join(format!("{}.{DOC_EXT}", id.storage_key()))
    }

    /// The deprecated bare (scheme-less) path for a uuidv7 document
    /// (`<uuid>.loro`), or `None` for schemes that never had a bare form.
    /// Pre-scheme forests wrote this name; it is read but never freshly minted.
    fn bare_path(&self, id: WorkstreamId) -> Option<PathBuf> {
        match id.scheme() {
            IdScheme::Uuidv7 => Some(self.dir.join(format!("{}.{DOC_EXT}", id.uuid()))),
        }
    }

    /// The existing on-disk path for `id` — canonical form preferred, then the
    /// deprecated bare form; `None` if no document exists yet.
    fn existing_path(&self, id: WorkstreamId) -> Option<PathBuf> {
        let explicit = self.explicit_path(id);
        if explicit.exists() {
            return Some(explicit);
        }
        self.bare_path(id).filter(|p| p.exists())
    }
}

impl DocStore for FilesDocStore {
    fn load(&self, id: WorkstreamId) -> Result<Option<Vec<u8>>> {
        // Canonical name first, then the deprecated bare name (pre-scheme forests).
        let candidates = std::iter::once(self.explicit_path(id)).chain(self.bare_path(id));
        for path in candidates {
            match fs::read(&path) {
                Ok(bytes) => return Ok(Some(bytes)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(Error::io(path, e)),
            }
        }
        Ok(None)
    }

    fn save(&self, id: WorkstreamId, bytes: &[u8]) -> Result<()> {
        // Write to a sibling temp file then rename, so a crash mid-write leaves the
        // previous document intact rather than a truncated one. Reuse the existing
        // on-disk name if the document already exists — a pre-scheme forest's bare
        // name is updated in place, never renamed — and mint the canonical
        // scheme-explicit name only for a brand-new document. The `.tmp` extension
        // is not `.loro`, so `list_ids` ignores any leftover.
        let path = self
            .existing_path(id)
            .unwrap_or_else(|| self.explicit_path(id));
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, bytes).map_err(|e| Error::io(&tmp, e))?;
        fs::rename(&tmp, &path).map_err(|e| Error::io(&path, e))
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
            // Lenient: an explicit `uuidv7_<uuid>` stem parses by scheme; a bare
            // stem is read as the deprecated implicit uuidv7. Dedup defensively in
            // case a bare and explicit file for the same id ever coexist.
            let id = WorkstreamId::parse_storage_key(stem)
                .map_err(|_| Error::InvalidDocId(path.clone()))?;
            if !ids.contains(&id) {
                ids.push(id);
            }
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
    use uuid::Uuid;

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
    fn new_document_is_written_with_explicit_scheme() {
        let dir = TempDir::new("docstore-new-explicit");
        let store = FilesDocStore::new(&dir.0);
        let id = WorkstreamId::generate();

        store.save(id, b"x").unwrap();

        let explicit = dir.0.join(format!("{}.{DOC_EXT}", id.storage_key()));
        let bare = dir.0.join(format!("{}.{DOC_EXT}", id.uuid()));
        assert!(explicit.exists(), "new doc must use the explicit name");
        assert!(!bare.exists(), "new doc must not use the bare name");
    }

    #[test]
    fn bare_loro_file_is_read_as_uuidv7() {
        let dir = TempDir::new("docstore-bare-read");
        let store = FilesDocStore::new(&dir.0);
        let id = WorkstreamId::generate();

        // Simulate a pre-scheme forest: a bare `<uuid>.loro`, never renamed.
        let bare = dir.0.join(format!("{}.{DOC_EXT}", id.uuid()));
        fs::write(&bare, b"legacy").unwrap();

        assert_eq!(store.list_ids().unwrap(), vec![id]);
        assert_eq!(store.load(id).unwrap().as_deref(), Some(&b"legacy"[..]));
    }

    #[test]
    fn save_reuses_existing_bare_path_without_renaming() {
        let dir = TempDir::new("docstore-bare-save");
        let store = FilesDocStore::new(&dir.0);
        let id = WorkstreamId::generate();

        let bare = dir.0.join(format!("{}.{DOC_EXT}", id.uuid()));
        fs::write(&bare, b"old").unwrap();

        store.save(id, b"new").unwrap();

        // The bare file is updated in place; no explicit duplicate is created.
        assert_eq!(fs::read(&bare).unwrap(), b"new");
        let explicit = dir.0.join(format!("{}.{DOC_EXT}", id.storage_key()));
        assert!(!explicit.exists(), "must not create an explicit duplicate");
        assert_eq!(store.list_ids().unwrap(), vec![id]);
    }

    #[test]
    fn list_ids_on_absent_dir_is_empty() {
        let store = FilesDocStore::new(std::env::temp_dir().join("silverwood-does-not-exist-xyz"));
        assert!(store.list_ids().unwrap().is_empty());
    }
}
