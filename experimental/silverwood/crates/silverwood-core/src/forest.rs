use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::config::ForestConfig;
use crate::docstore::FilesDocStore;
use crate::error::{Error, Result};
use crate::id::ForestId;

/// Config file at the forest root.
const CONFIG_FILE: &str = "config.toml";
/// Subdirectory holding one document per workstream.
const WORKSTREAMS_DIR: &str = "workstreams";
/// Subdirectory holding provisioned code-checkouts.
const WORKING_COPIES_DIR: &str = "working-copies";

/// One local instance of silverwood state, rooted at a directory.
///
/// [`Forest::open`] is idempotent: it creates the layout and mints the forest
/// identity on first use, and thereafter loads the existing identity. Per
/// `DESIGN.md`, core takes an explicit root — resolving a default location
/// (e.g. `~/.silverwood`) is a frontend concern.
pub struct Forest {
    root: PathBuf,
    config: ForestConfig,
    docs: FilesDocStore,
}

impl Forest {
    /// Open the forest at `root`, creating its layout and identity if absent.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref().to_path_buf();
        ensure_dir(&root)?;
        let workstreams = root.join(WORKSTREAMS_DIR);
        ensure_dir(&workstreams)?;
        ensure_dir(&root.join(WORKING_COPIES_DIR))?;

        let config = load_or_init_config(&root)?;

        Ok(Self {
            root,
            config,
            docs: FilesDocStore::new(workstreams),
        })
    }

    /// This forest's stable id.
    pub fn id(&self) -> ForestId {
        self.config.forest_id
    }

    /// The Loro peer id for edits originating in this forest.
    pub fn peer_id(&self) -> u64 {
        self.config.peer_id
    }

    /// The forest's root directory.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The full forest configuration.
    pub fn config(&self) -> &ForestConfig {
        &self.config
    }

    /// The workstream document store.
    pub fn docs(&self) -> &FilesDocStore {
        &self.docs
    }
}

/// Create `path` (and parents) if it does not already exist.
fn ensure_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path).map_err(|e| Error::io(path, e))
}

/// Load the forest config, or mint and persist a fresh one if none exists.
fn load_or_init_config(root: &Path) -> Result<ForestConfig> {
    let path = root.join(CONFIG_FILE);
    match fs::read_to_string(&path) {
        Ok(contents) => {
            toml::from_str(&contents).map_err(|source| Error::ConfigDe { path, source })
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            let config = ForestConfig::generate();
            let contents = toml::to_string_pretty(&config)?;
            fs::write(&path, contents).map_err(|e| Error::io(&path, e))?;
            Ok(config)
        }
        Err(e) => Err(Error::io(path, e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    /// A unique temp directory for an isolated test, removed on drop.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            TempDir(std::env::temp_dir().join(format!("silverwood-{tag}-{}", Uuid::now_v7())))
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn open_creates_layout() {
        let dir = TempDir::new("forest-layout");
        let forest = Forest::open(&dir.0).unwrap();

        assert!(dir.0.join(CONFIG_FILE).is_file());
        assert!(dir.0.join(WORKSTREAMS_DIR).is_dir());
        assert!(dir.0.join(WORKING_COPIES_DIR).is_dir());
        assert_eq!(forest.root(), dir.0.as_path());
    }

    #[test]
    fn open_is_idempotent_and_stable_identity() {
        let dir = TempDir::new("forest-idempotent");

        let first = Forest::open(&dir.0).unwrap();
        let id = first.id();
        let peer = first.peer_id();

        let second = Forest::open(&dir.0).unwrap();
        assert_eq!(second.id(), id, "forest id must persist across opens");
        assert_eq!(second.peer_id(), peer, "peer id must persist across opens");
    }

    #[test]
    fn peer_id_is_nonzero() {
        let dir = TempDir::new("forest-peer");
        let forest = Forest::open(&dir.0).unwrap();
        assert_ne!(forest.peer_id(), 0);
    }
}
