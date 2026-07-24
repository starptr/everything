use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use serde::Serialize;

use crate::apfs;
use crate::config::ForestConfig;
use crate::doc;
use crate::docstore::{DocStore, FilesDocStore};
use crate::error::{Error, Result};
use crate::id::{ForestId, WorkstreamId};
use crate::migrate;
use crate::provider::{CheckoutProvider, JjColocated};
use crate::workstream::{
    AgentKind, CheckoutMode, CheckoutState, Location, LocationWithinForest, NewCheckoutMode,
    NewKind, NewWorkstream, SessionLock, Status, Workstream, WorkstreamBody, WorkstreamKind,
    RESERVED_NS_PREFIX,
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
        let NewKind::Basic { mode: new_mode } = &new.kind;

        let working_copies = self.root.join(WORKING_COPIES_DIR);

        // Mode-specific creation preconditions that must reject *before* anything is
        // persisted (a hard failure, unlike a provisioning error, which leaves a
        // recoverable `Failed` document). Today only apfs-cow has one.
        precheck_new_mode(new_mode, &working_copies)?;

        let id = WorkstreamId::generate();
        let dest = working_copies.join(id.to_string());

        // The stored mode starts `pending`; core flips it after provisioning. Each
        // NewCheckoutMode maps to its matching pending CheckoutMode (dest/location and
        // the provision call below are mode-independent).
        let mode = match new_mode {
            NewCheckoutMode::JjColocated { initial_source } => CheckoutMode::JjColocated {
                initial_source: initial_source.as_str().to_string(),
                state: CheckoutState::Pending,
            },
            NewCheckoutMode::JjColocatedDirenvUnsafe { initial_source } => {
                CheckoutMode::JjColocatedDirenvUnsafe {
                    initial_source: initial_source.as_str().to_string(),
                    state: CheckoutState::Pending,
                }
            }
            NewCheckoutMode::ApfsCow { source_path } => CheckoutMode::ApfsCow {
                initial_source: source_path.as_str().to_string(),
                state: CheckoutState::Pending,
            },
        };

        // The location records this forest as the single materialization site.
        let body = WorkstreamBody {
            name: new.name,
            status: Status::Active,
            created_at: now_rfc3339(),
            kind: WorkstreamKind::Basic {
                mode,
                location: Location {
                    forest_id: self.id(),
                    within: LocationWithinForest::BasicForest {
                        path: dest.display().to_string(),
                    },
                },
            },
            kv: BTreeMap::new(),
        };

        // Persist the pending document, then provision, then record the outcome
        // by mutating the same in-memory document in place.
        let doc = doc::build(self.peer_id(), &body)?;
        self.docs.save(id, &doc::snapshot(&doc)?)?;

        let provisioned = self.provider.provision(new_mode, &dest);
        let state = if provisioned.is_ok() {
            CheckoutState::Ready
        } else {
            CheckoutState::Failed
        };
        doc::set_state(&doc, state)?;
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

    /// Rename a workstream (overwrite its `name`).
    pub fn rename(&self, id: WorkstreamId, name: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::set_name(&doc, name)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Set a namespaced key-value entry on a workstream. The value is an opaque
    /// JSON string; core never interprets it — it is a frontend's own state.
    /// Namespaces under the core-reserved prefix (e.g. sessions) are rejected.
    pub fn set_kv(&self, id: WorkstreamId, namespace: &str, key: &str, value: &str) -> Result<()> {
        reject_reserved(namespace)?;
        let doc = self.load_doc(id)?;
        doc::set_kv(&doc, namespace, key, value)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Remove a namespaced key-value entry (no-op if absent). Reserved namespaces
    /// are rejected (they are core-owned; use the session API).
    pub fn unset_kv(&self, id: WorkstreamId, namespace: &str, key: &str) -> Result<()> {
        reject_reserved(namespace)?;
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

    /// Create an agent session on a workstream (core mints `created_at`). Errors
    /// if a session with this id already exists. Stored as reserved-namespace kv.
    pub fn create_session(
        &self,
        id: WorkstreamId,
        session_id: &str,
        agent_kind: AgentKind,
        name: &str,
    ) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::create_session(&doc, session_id, agent_kind, name, &now_rfc3339())?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Rename a session (preserving its kind + created_at). Errors if absent.
    pub fn rename_session(&self, id: WorkstreamId, session_id: &str, name: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::rename_session(&doc, session_id, name)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Remove a session from a workstream (no-op if absent).
    pub fn remove_session(&self, id: WorkstreamId, session_id: &str) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::remove_session(&doc, session_id)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Acquire the best-effort advisory lock on a session for `holder`. Succeeds
    /// if the session is unlocked or already held by `holder` (refreshing
    /// `acquired_at`). If held by someone else, errors [`Error::SessionLocked`]
    /// unless `force` steals it. Errors [`Error::SessionNotFound`] if absent.
    ///
    /// The lock is cooperative, not enforced: it records who is currently
    /// resuming a claude-code session so considerate clients back off.
    pub fn lock_session(
        &self,
        id: WorkstreamId,
        session_id: &str,
        holder: &str,
        force: bool,
    ) -> Result<()> {
        let doc = self.load_doc(id)?;
        let current = doc::get_session(&doc, session_id)?
            .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?
            .lock()
            .cloned();
        if let Some(existing) = current {
            if existing.holder != holder && !force {
                return Err(Error::SessionLocked {
                    session_id: session_id.to_string(),
                    holder: existing.holder,
                });
            }
        }
        doc::set_session_lock(
            &doc,
            session_id,
            Some(SessionLock {
                holder: holder.to_string(),
                acquired_at: now_rfc3339(),
            }),
        )?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Release the advisory lock on a session (no-op if already unlocked). If held
    /// by a different holder, errors [`Error::SessionLocked`] unless `force`.
    /// Errors [`Error::SessionNotFound`] if the session is absent.
    pub fn unlock_session(
        &self,
        id: WorkstreamId,
        session_id: &str,
        holder: Option<&str>,
        force: bool,
    ) -> Result<()> {
        let doc = self.load_doc(id)?;
        let current = doc::get_session(&doc, session_id)?
            .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?
            .lock()
            .cloned();
        match current {
            None => Ok(()),
            Some(existing) if force || holder == Some(existing.holder.as_str()) => {
                doc::set_session_lock(&doc, session_id, None)?;
                self.docs.save(id, &doc::snapshot(&doc)?)
            }
            Some(existing) => Err(Error::SessionLocked {
                session_id: session_id.to_string(),
                holder: existing.holder,
            }),
        }
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

/// Validate a mode's creation preconditions that must reject *before* any document
/// is persisted. A no-op for modes without one.
///
/// `apfs-cow` requires a native copy-on-write clone, which `clonefile(2)` can only
/// perform within one APFS volume — so the source must be an existing directory, and
/// both it and the forest's checkout location (`working_copies_dir`) must be APFS and
/// share a volume. Any failure is an [`Error::InvalidSource`] (a hard rejection, not a
/// recoverable `Failed` checkout).
fn precheck_new_mode(mode: &NewCheckoutMode, working_copies_dir: &Path) -> Result<()> {
    match mode {
        NewCheckoutMode::JjColocated { .. } | NewCheckoutMode::JjColocatedDirenvUnsafe { .. } => {
            Ok(())
        }
        NewCheckoutMode::ApfsCow { source_path } => {
            let src = source_path.as_path();
            if !src.is_dir() {
                return Err(Error::InvalidSource(format!(
                    "apfs-cow source {src:?} is not an existing directory"
                )));
            }
            for path in [src, working_copies_dir] {
                if !apfs::is_apfs(path)? {
                    return Err(Error::InvalidSource(format!(
                        "apfs-cow requires APFS: {path:?} is not on an APFS volume"
                    )));
                }
            }
            if !apfs::same_volume(src, working_copies_dir)? {
                return Err(Error::InvalidSource(format!(
                    "apfs-cow requires one APFS volume: source {src:?} and the forest's \
                     checkout location {working_copies_dir:?} are on different volumes"
                )));
            }
            Ok(())
        }
    }
}

/// Reject writes to a core-reserved kv namespace. Reserved namespaces
/// (`app.andref.silverwood.*`) hold core-owned state such as sessions; frontends
/// mutate them through the typed API, not raw `set_kv`/`unset_kv`.
fn reject_reserved(namespace: &str) -> Result<()> {
    if namespace.starts_with(RESERVED_NS_PREFIX) {
        return Err(Error::ReservedNamespace(namespace.to_string()));
    }
    Ok(())
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
