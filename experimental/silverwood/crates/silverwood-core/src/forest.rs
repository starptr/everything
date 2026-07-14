use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use serde::Serialize;

use crate::config::ForestConfig;
use crate::doc;
use crate::docstore::{DocStore, FilesDocStore};
use crate::error::{Error, Result};
use crate::id::{ForestId, WorkstreamId};
use crate::migrate;
use crate::provider::{CheckoutProvider, JjColocated};
use crate::workstream::{
    AgentKind, Checkout, CheckoutState, CodeChange, NewKind, NewWorkstream, Status, Workstream,
    WorkstreamBody, WorkstreamKind,
};

/// The outcome for one document in a [`Forest::upgrade_all`] pass.
#[derive(Debug, Clone, Serialize)]
pub struct UpgradeReport {
    /// The workstream whose document was inspected.
    pub id: WorkstreamId,
    /// The document's schema version before the pass.
    pub from: u32,
    /// The latest schema version (what it was, or would be, upgraded to).
    pub to: u32,
}

impl UpgradeReport {
    /// Whether the document was below the latest version — i.e. upgraded, or in
    /// a dry run *would* be upgraded.
    pub fn upgraded(&self) -> bool {
        self.from != self.to
    }
}

/// Config file at the forest root.
const CONFIG_FILE: &str = "config.toml";
/// Subdirectory holding one document per workstream.
const WORKSTREAMS_DIR: &str = "workstreams";
/// Subdirectory holding provisioned checkouts.
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

    /// Create a workstream, provisioning its checkout.
    ///
    /// The document is written first with the checkout `Pending`, then the
    /// checkout is provisioned, then the state is flipped to `Ready`/`Failed`
    /// in place. A failed provision leaves a recoverable workstream (its
    /// document persists with state `Failed`) and surfaces the error.
    pub fn create_workstream(&self, new: NewWorkstream) -> Result<Workstream> {
        let (source, mode) = match &new.kind {
            NewKind::Basic { source, mode } => (source, *mode),
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
            created_at: now_rfc3339(),
            kind: WorkstreamKind::Basic {
                code_change: CodeChange {
                    source: source.as_str().to_string(),
                    mode,
                },
                checkouts,
                sessions: BTreeMap::new(),
            },
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
        let doc = self.load_doc(id)?;
        doc::set_status(&doc, Status::Archived)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Set a namespaced key-value entry on a workstream. The value is an opaque
    /// JSON string; core never interprets it — it is a frontend's own state.
    pub fn set_kv(&self, id: WorkstreamId, namespace: &str, key: &str, value: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::set_kv(&doc, namespace, key, value)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Remove a namespaced key-value entry (no-op if absent).
    pub fn unset_kv(&self, id: WorkstreamId, namespace: &str, key: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::unset_kv(&doc, namespace, key)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Read a namespaced key-value entry, if present.
    pub fn get_kv(&self, id: WorkstreamId, namespace: &str, key: &str) -> Result<Option<String>> {
        Ok(self
            .get(id)?
            .body
            .kv
            .get(namespace)
            .and_then(|m| m.get(key))
            .cloned())
    }

    /// List all key-value entries in a namespace (empty if the namespace is absent).
    pub fn list_kv(&self, id: WorkstreamId, namespace: &str) -> Result<BTreeMap<String, String>> {
        Ok(self
            .get(id)?
            .body
            .kv
            .get(namespace)
            .cloned()
            .unwrap_or_default())
    }

    /// Attach an agent session to a workstream. Errors if already attached.
    pub fn attach_session(
        &self,
        id: WorkstreamId,
        session_id: &str,
        agent_kind: AgentKind,
        name: &str,
    ) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::attach_session(&doc, session_id, agent_kind, name, &now_rfc3339())?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Rename an attached session. Errors if not attached.
    pub fn rename_session(&self, id: WorkstreamId, session_id: &str, name: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::rename_session(&doc, session_id, name)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Detach a session from a workstream (no-op if not attached).
    pub fn detach_session(&self, id: WorkstreamId, session_id: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::detach_session(&doc, session_id)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Load a workstream's document, ready to author under this forest's peer id.
    ///
    /// Lazily upgrades the document to the latest schema first (persisting the
    /// rewrite), since in-place mutators navigate the latest layout. Errors
    /// [`Error::SchemaTooNew`] if the document is newer than this build.
    fn load_doc(&self, id: WorkstreamId) -> Result<loro::LoroDoc> {
        let bytes = self.docs.load(id)?.ok_or(Error::NotFound(id))?;
        let bytes = match doc::migrate_bytes(id, &bytes, self.peer_id())? {
            Some(rewritten) => {
                self.docs.save(id, &rewritten)?;
                rewritten
            }
            None => bytes,
        };
        doc::load(self.peer_id(), &bytes)
    }

    /// Upgrade every document in the forest to the latest schema version,
    /// returning a per-document report sorted by id. With `dry_run`, inspects and
    /// reports without writing. Idempotent — documents already at the latest are
    /// left untouched. Errors [`Error::SchemaTooNew`] if any document is newer
    /// than this build supports.
    pub fn upgrade_all(&self, dry_run: bool) -> Result<Vec<UpgradeReport>> {
        let latest = migrate::DOC_SCHEMA_VERSION;
        let mut reports = Vec::new();
        for id in self.docs.list_ids()? {
            let bytes = self.docs.load(id)?.ok_or(Error::NotFound(id))?;
            let from = doc::peek_version(id, &bytes)?;
            if from > latest {
                return Err(Error::SchemaTooNew {
                    found: from,
                    supported: latest,
                });
            }
            if from < latest && !dry_run {
                if let Some(rewritten) = doc::migrate_bytes(id, &bytes, self.peer_id())? {
                    self.docs.save(id, &rewritten)?;
                }
            }
            reports.push(UpgradeReport {
                id,
                from,
                to: latest,
            });
        }
        reports.sort_by_key(|r| r.id);
        Ok(reports)
    }

    /// Count documents below the latest schema version (a read-only scan).
    pub fn pending_upgrades(&self) -> Result<usize> {
        Ok(self
            .upgrade_all(true)?
            .iter()
            .filter(|r| r.upgraded())
            .count())
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
