use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::config::ForestConfig;
use crate::doc;
use crate::docstore::{DocStore, FilesDocStore};
use crate::error::{Error, Result};
use crate::id::{ForestId, WorkstreamId};
use crate::provider::{CheckoutProvider, JjColocated};
use crate::workstream::{
    Checkout, CheckoutPrimitive, CheckoutState, NewPrimitive, NewWorkstream, Status, Workstream,
    WorkstreamBody, CODE_CHECKOUT_KIND,
};

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
    provider: Box<dyn CheckoutProvider>,
}

impl Forest {
    /// Open the forest at `root` with the default (jj-colocated) provider.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_provider(root, Box::new(JjColocated))
    }

    /// Open the forest at `root` with an explicit checkout provider (used by
    /// tests to avoid the network).
    pub fn open_with_provider(
        root: impl AsRef<Path>,
        provider: Box<dyn CheckoutProvider>,
    ) -> Result<Self> {
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
            provider,
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

    /// Create a workstream, provisioning its code-checkout.
    ///
    /// The document is written first with the checkout `Pending`, then the
    /// checkout is provisioned, then the state is flipped to `Ready`/`Failed`
    /// in place. A failed provision leaves a recoverable workstream (its
    /// document persists with state `Failed`) and surfaces the error.
    pub fn create_workstream(&self, new: NewWorkstream) -> Result<Workstream> {
        let (source, mode) = match &new.primitive {
            NewPrimitive::CodeCheckout { source, mode } => (source, *mode),
        };

        let id = WorkstreamId::generate();
        let forest_id = self.id().to_string();
        let dest = self.root.join(WORKING_COPIES_DIR).join(id.to_string());

        let mut checkouts = BTreeMap::new();
        checkouts.insert(
            forest_id.clone(),
            Checkout {
                location: dest.display().to_string(),
                state: CheckoutState::Pending,
                mode,
            },
        );
        let body = WorkstreamBody {
            name: new.name,
            status: Status::Active,
            kind: CODE_CHECKOUT_KIND.to_string(),
            created_at: now_rfc3339(),
            primitive: CheckoutPrimitive {
                source: source.as_str().to_string(),
                mode,
            },
            checkouts,
            sessions: BTreeMap::new(),
            kv: BTreeMap::new(),
        };

        // Persist the pending document, then provision, then record the outcome
        // by mutating the same in-memory document in place.
        let doc = doc::build(self.peer_id(), &body)?;
        self.docs.save(id, &doc::snapshot(&doc)?)?;

        let provisioned = self.provider.provision(mode, source, &dest);
        let state = if provisioned.is_ok() {
            CheckoutState::Ready
        } else {
            CheckoutState::Failed
        };
        doc::set_checkout_state(&doc, &forest_id, state)?;
        self.docs.save(id, &doc::snapshot(&doc)?)?;

        provisioned?;
        self.get(id)
    }

    /// Load a workstream by id.
    pub fn get(&self, id: WorkstreamId) -> Result<Workstream> {
        let bytes = self.docs.load(id)?.ok_or(Error::NotFound(id))?;
        doc::hydrate(id, &bytes)
    }

    /// List workstreams, sorted by id (roughly creation order). Archived
    /// workstreams are excluded unless `include_archived` is set.
    pub fn list(&self, include_archived: bool) -> Result<Vec<Workstream>> {
        let mut out = Vec::new();
        for id in self.docs.list_ids()? {
            let ws = self.get(id)?;
            if include_archived || ws.body.status == Status::Active {
                out.push(ws);
            }
        }
        out.sort_by_key(|w| w.id);
        Ok(out)
    }

    /// Archive a workstream (tombstone; the document is retained).
    pub fn archive(&self, id: WorkstreamId) -> Result<()> {
        let bytes = self.docs.load(id)?.ok_or(Error::NotFound(id))?;
        let doc = doc::load(self.peer_id(), &bytes)?;
        doc::set_status(&doc, Status::Archived)?;
        self.docs.save(id, &doc::snapshot(&doc)?)?;
        Ok(())
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

/// The current time as an RFC3339 string.
fn now_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .expect("RFC3339 formatting of now_utc is infallible")
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
