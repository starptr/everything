use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use loro::LoroDoc;
use serde::Serialize;

use crate::apfs;
use crate::config::ForestConfig;
use crate::doc;
use crate::docstore::{DocStore, FilesDocStore};
use crate::error::{Error, Result};
use crate::id::{ForestId, WorkstreamId};
use crate::migrate;
use crate::provider::{CheckoutProvider, JjColocated};
use crate::spawn::{
    claude_code_noninteractive_plan, claude_code_plan, disk_space_plan, plain_shell_plan,
    ClaudeRun, ShellPlan, SpawnSeed,
};
use crate::workstream::{
    CheckoutExtent, CheckoutMode, CheckoutState, DoctorReport, Location, LocationWithinForest,
    NewCheckoutMode, NewKind, NewWorkstream, SessionKind, SessionLock, Status, Workstream,
    WorkstreamBody, WorkstreamKind, RESERVED_NS_PREFIX,
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
/// Parent directory for the ephemeral `local-tmp` kind's created checkout.
const LOCAL_TMP_DIR: &str = "/tmp";

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

    /// Create a workstream. Dispatches on the [`NewKind`]:
    ///
    /// - **`Basic`** materializes a code-checkout. The document is written first (with the
    ///   checkout `Pending` for a `Full` create, or `InitializedWithoutCheckout` for a
    ///   `Skip` create). A `Full` create then provisions the checkout and flips the state
    ///   to `Ready`/`Failed` in place; a failed provision leaves a recoverable workstream
    ///   and surfaces the error. A `Skip` create returns immediately, to be materialized
    ///   later by [`Self::checkout_workstream`].
    /// - **`LocalBlank`/`LocalTmp`** create their own empty directory (no checkout) —
    ///   under `working-copies/<uuid>` and `/tmp/<uuid>` respectively — *before* persisting,
    ///   so a saved record always has its directory.
    /// - **`LocalUnmanagedExistingPath`** adopts an existing directory as-is (validated
    ///   absolute + on the forest's filesystem); it is never created or deleted by silverwood.
    pub fn create_workstream(&self, new: NewWorkstream) -> Result<Workstream> {
        let working_copies = self.root.join(WORKING_COPIES_DIR);
        let id = WorkstreamId::generate();

        match new.kind {
            NewKind::Basic {
                mode: new_mode,
                checkout_extent,
            } => {
                // Mode-specific creation preconditions that must reject *before* anything is
                // persisted (a hard failure, unlike a provisioning error, which leaves a
                // recoverable `Failed` document). Today only apfs-cow has one. Runs for both
                // extents, so a deferred (`Skip`) create still rejects a bad seed up front.
                precheck_new_mode(&new_mode, &working_copies)?;

                let dest = working_copies.join(id.to_string());

                // `Full` starts `Pending` (core flips it after provisioning below); `Skip`
                // rests at `InitializedWithoutCheckout`. dest/location are extent-independent.
                let initial_state = match checkout_extent {
                    CheckoutExtent::Full => CheckoutState::Pending,
                    CheckoutExtent::Skip => CheckoutState::InitializedWithoutCheckout,
                };
                let mode = stored_mode(&new_mode, initial_state);

                let doc = self.save_new(
                    id,
                    new.name,
                    WorkstreamKind::Basic {
                        mode,
                        location: self.location_at(dest.display().to_string()),
                    },
                )?;

                match checkout_extent {
                    // Registered only; the caller provisions later via `checkout_workstream`.
                    CheckoutExtent::Skip => self.get(id),
                    // Provision now, recording the outcome in place.
                    CheckoutExtent::Full => self.provision_checkout(id, &doc, &new_mode, &dest),
                }
            }

            NewKind::LocalBlank => {
                let dest = working_copies.join(id.to_string());
                ensure_dir(&dest)?;
                self.save_new(
                    id,
                    new.name,
                    WorkstreamKind::LocalBlank {
                        location: self.location_at(dest.display().to_string()),
                    },
                )?;
                self.get(id)
            }

            NewKind::LocalTmp => {
                let dest = Path::new(LOCAL_TMP_DIR).join(id.to_string());
                ensure_dir(&dest)?;
                self.save_new(
                    id,
                    new.name,
                    WorkstreamKind::LocalTmp {
                        location: self.location_at(dest.display().to_string()),
                    },
                )?;
                self.get(id)
            }

            NewKind::LocalUnmanagedExistingPath { path } => {
                // Hard-reject before persisting: the path must be an existing directory on
                // the forest's filesystem. silverwood never creates or deletes it.
                precheck_existing_path(path.as_path(), &working_copies)?;
                self.save_new(
                    id,
                    new.name,
                    WorkstreamKind::LocalUnmanagedExistingPath {
                        location: self.location_at(path.as_str().to_string()),
                    },
                )?;
                self.get(id)
            }
        }
    }

    /// A single-forest location at `path` (this forest is the materialization site).
    fn location_at(&self, path: String) -> Location {
        Location {
            forest_id: self.id(),
            within: LocationWithinForest::BasicForest { path },
        }
    }

    /// Build a fresh active workstream body around `kind`, persist it, and return the
    /// built document (a `Basic` create reuses it to provision; other kinds discard it).
    fn save_new(&self, id: WorkstreamId, name: String, kind: WorkstreamKind) -> Result<LoroDoc> {
        let body = WorkstreamBody {
            name,
            status: Status::Active,
            created_at: now_rfc3339(),
            kind,
            kv: BTreeMap::new(),
        };
        let doc = doc::build(self.peer_id(), &body)?;
        self.docs.save(id, &doc::snapshot(&doc)?)?;
        Ok(doc)
    }

    /// Provision the checkout of a workstream that was created with the checkout
    /// deferred (`InitializedWithoutCheckout`).
    ///
    /// Validates the workstream is basic and has not been checked out, then runs the
    /// same `Pending` → `Ready`/`Failed` provisioning as a `Full` create. Errors
    /// [`Error::NotAwaitingCheckout`] (leaving the document untouched) if it is already
    /// checked out, mid-provision, or previously failed.
    pub fn checkout_workstream(&self, id: WorkstreamId) -> Result<Workstream> {
        let bytes = self.docs.load(id)?.ok_or(Error::NotFound(id))?;
        let ws = doc::hydrate(id, &bytes)?;

        // Only `Basic` has a checkout to provision; the checkout-less `Local*` kinds have
        // nothing to await. (The CLI already gates `workstream <id> basic checkout` on the
        // kind, so this is defense-in-depth.)
        let WorkstreamKind::Basic { mode, location } = &ws.body.kind else {
            return Err(Error::NotAwaitingCheckout {
                id,
                state: ws.body.kind.tag(),
            });
        };
        if mode.state() != CheckoutState::InitializedWithoutCheckout {
            return Err(Error::NotAwaitingCheckout {
                id,
                state: mode.state().as_str(),
            });
        }

        let new_mode = mode.to_new_mode()?;
        let LocationWithinForest::BasicForest { path } = &location.within;
        let dest = PathBuf::from(path);

        let doc = doc::load(self.peer_id(), &bytes)?;
        self.provision_checkout(id, &doc, &new_mode, &dest)
    }

    /// Provision `new_mode` into `dest` for the already-persisted workstream `id`,
    /// marking it `Pending` while the provider runs and recording `Ready`/`Failed`
    /// afterward — mutating the same in-memory document in place so lineage is
    /// preserved. Surfaces a provisioning error after persisting the recoverable
    /// `Failed` state. Shared by a `Full` create and [`Self::checkout_workstream`].
    fn provision_checkout(
        &self,
        id: WorkstreamId,
        doc: &LoroDoc,
        new_mode: &NewCheckoutMode,
        dest: &Path,
    ) -> Result<Workstream> {
        doc::set_state(doc, CheckoutState::Pending)?;
        self.docs.save(id, &doc::snapshot(doc)?)?;

        let provisioned = self.provider.provision(new_mode, dest);
        let state = if provisioned.is_ok() {
            CheckoutState::Ready
        } else {
            CheckoutState::Failed
        };
        doc::set_state(doc, state)?;
        self.docs.save(id, &doc::snapshot(doc)?)?;

        provisioned?;
        self.get(id)
    }

    /// Load a workstream by id.
    pub fn get(&self, id: WorkstreamId) -> Result<Workstream> {
        let bytes = self.docs.load(id)?.ok_or(Error::NotFound(id))?;
        doc::hydrate(id, &bytes)
    }

    /// List workstreams, sorted by id (roughly creation order). Inactive
    /// (archived or deleted) workstreams are excluded unless `include_inactive` is set.
    pub fn list(&self, include_inactive: bool) -> Result<Vec<Workstream>> {
        let mut out = Vec::new();
        for id in self.docs.list_ids()? {
            let ws = self.get(id)?;
            if include_inactive || ws.body.status == Status::Active {
                out.push(ws);
            }
        }
        out.sort_by_key(|w| w.id);
        Ok(out)
    }

    /// Archive a workstream (tombstone; the document and checkout are retained).
    pub fn archive(&self, id: WorkstreamId) -> Result<()> {
        let doc = self.load_doc(id)?;
        doc::set_status(&doc, Status::Archived)?;
        self.docs.save(id, &doc::snapshot(&doc)?)
    }

    /// Soft-delete a workstream: keep the document but mark it `Deleted`, then discard
    /// the on-disk directory silverwood manages for it. Removability is per-kind (see
    /// the private `removability` helper):
    /// - `Basic` — safe once its checkout is a jj workspace root with all non-empty revs
    ///   already on the remote trunk; otherwise refuses with [`Error::UnsafeToRemove`]
    ///   unless `force`. An operational VCS failure surfaces as [`Error::Vcs`] on the
    ///   non-`force` path; `force` skips the check.
    /// - `LocalTmp` — safe once its directory is gone; otherwise `force`-only.
    /// - `LocalBlank` — safe while its directory is empty; otherwise `force`-only.
    /// - `LocalUnmanagedExistingPath` — **never** removable (errors [`Error::RemovalUnsupported`]
    ///   even with `force`), and its adopted directory is never deleted.
    ///
    /// Unlike a hard delete (impossible under the add-wins membership union, see
    /// `DESIGN.md` §2.1), the document is retained so the tombstone merges under sync —
    /// this is a stronger sibling of [`Forest::archive`] that also discards the directory.
    pub fn remove(&self, id: WorkstreamId, force: bool) -> Result<()> {
        let ws = self.get(id)?; // NotFound if absent
        match removability(&ws)? {
            // Forbidden outright — `force` cannot override, and nothing is tombstoned.
            Removability::Forbidden => return Err(Error::RemovalUnsupported(id)),
            Removability::ForceOnly if !force => return Err(Error::UnsafeToRemove(id)),
            Removability::ForceOnly | Removability::Safe => {}
        }

        // Tombstone first (the sync-relevant record of truth), then discard the directory.
        let doc = self.load_doc(id)?;
        doc::set_status(&doc, Status::Deleted)?;
        self.docs.save(id, &doc::snapshot(&doc)?)?;

        // Delete only a silverwood-managed directory. `LocalUnmanagedExistingPath` returns
        // `None` here (and is already `Forbidden` above), so an adopted path is never touched.
        if let Some(path) = managed_checkout_path(&ws.body.kind) {
            remove_tree_if_present(Path::new(path))?;
        }
        Ok(())
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
        agent_kind: SessionKind,
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

    /// Read-only health check for a session: report its variant and, for a
    /// claude-code session, whether Claude's conversation transcript still exists
    /// under `config_dir` (the resumability ground truth — a session created but
    /// never prompted has none). **Never mutates**; removing an orphaned session is
    /// the caller's job via [`Forest::remove_session`]. Errors
    /// [`Error::SessionNotFound`] if the session is absent.
    ///
    /// The match over the session kind is deliberately exhaustive: adding an
    /// [`SessionKind`] forces a decision here about how (or whether) doctor checks it,
    /// rather than silently reporting `conversation_exists: None`.
    pub fn doctor_session(
        &self,
        id: WorkstreamId,
        session_id: &str,
        config_dir: &Path,
    ) -> Result<DoctorReport> {
        let doc = self.load_doc(id)?;
        let session = doc::get_session(&doc, session_id)?
            .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?;
        let conversation_exists = match &session.kind {
            SessionKind::ClaudeCode { .. } | SessionKind::ClaudeCodeNoninteractive { .. } => Some(
                crate::claude::claude_conversation_exists(config_dir, session_id),
            ),
            // A shell kind has no persisted conversation to check; doctor can't
            // judge whether it's safe to remove, so report `None`.
            SessionKind::PlainShell {} | SessionKind::DiskSpace {} => None,
        };
        Ok(DoctorReport {
            workstream_id: id.to_string(),
            session_id: session_id.to_string(),
            kind: session.kind.tag().to_string(),
            conversation_exists,
        })
    }

    /// Build the [`ShellPlan`] for running a durable session (`silverwood spawn from-id`).
    /// A session records *how to run itself*: this reads its [`SessionKind`] and materializes
    /// the matching command in the workstream's directory (the private `spawn_cwd` helper),
    /// so a frontend
    /// never re-derives the command. For a claude kind, first-run vs resume is chosen from
    /// whether Claude's transcript exists on disk under `claude_config_dir` (so a never-prompted
    /// session starts fresh rather than failing a resume). `seed`/`claude_config_dir` are
    /// frontend policy (env/passwd), supplied by the caller — mirroring [`Forest::doctor_session`].
    ///
    /// Errors [`Error::NotSpawnable`] if the workstream has no directory to run in (a `Basic`
    /// checkout that is not yet `Ready`, or a `Local*` kind whose directory is gone), or
    /// [`Error::SessionNotFound`] if the session is absent.
    pub fn spawn_plan_from_session(
        &self,
        id: WorkstreamId,
        session_id: &str,
        seed: &SpawnSeed,
        claude_config_dir: &Path,
    ) -> Result<ShellPlan> {
        let ws = self.get(id)?;
        let cwd = spawn_cwd(&ws)?;

        let session = doc::get_session(&self.load_doc(id)?, session_id)?
            .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?;

        // First-run vs resume from ground truth: does Claude's transcript exist on disk?
        let claude_run = || {
            if crate::claude::claude_conversation_exists(claude_config_dir, session_id) {
                ClaudeRun::Resume
            } else {
                ClaudeRun::FirstRun
            }
        };

        let plan = match session.kind {
            SessionKind::ClaudeCode { .. } => {
                claude_code_plan(&cwd, session_id, claude_run(), seed)
            }
            SessionKind::ClaudeCodeNoninteractive {
                run_direnv_exec, ..
            } => claude_code_noninteractive_plan(
                &cwd,
                session_id,
                claude_run(),
                run_direnv_exec,
                seed,
            ),
            SessionKind::PlainShell {} => plain_shell_plan(&cwd, seed),
            SessionKind::DiskSpace {} => disk_space_plan(&cwd, seed),
        };
        Ok(plan)
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

/// Build the stored [`CheckoutMode`] for a new checkout from its creation-side seed,
/// stamping the given initial provisioning `state`. dest/location are handled by the
/// caller; only the mode's seed and state are set here.
fn stored_mode(new_mode: &NewCheckoutMode, state: CheckoutState) -> CheckoutMode {
    match new_mode {
        NewCheckoutMode::JjColocated { initial_source } => CheckoutMode::JjColocated {
            initial_source: initial_source.as_str().to_string(),
            state,
        },
        NewCheckoutMode::JjColocatedDirenvUnsafe { initial_source } => {
            CheckoutMode::JjColocatedDirenvUnsafe {
                initial_source: initial_source.as_str().to_string(),
                state,
            }
        }
        NewCheckoutMode::ApfsCow { source_path } => CheckoutMode::ApfsCow {
            initial_source: source_path.as_str().to_string(),
            state,
        },
        NewCheckoutMode::ApfsCowDirenvUnsafe { source_path } => CheckoutMode::ApfsCowDirenvUnsafe {
            initial_source: source_path.as_str().to_string(),
            state,
        },
    }
}

/// Validate a mode's creation preconditions that must reject *before* any document
/// is persisted. A no-op for modes without one.
///
/// The apfs-cow modes require a native copy-on-write clone, which `clonefile(2)` can only
/// perform within one APFS volume — so the source must be an existing directory, and
/// both it and the forest's checkout location (`working_copies_dir`) must be APFS and
/// share a volume. Any failure is an [`Error::InvalidSource`] (a hard rejection, not a
/// recoverable `Failed` checkout).
fn precheck_new_mode(mode: &NewCheckoutMode, working_copies_dir: &Path) -> Result<()> {
    match mode {
        NewCheckoutMode::JjColocated { .. } | NewCheckoutMode::JjColocatedDirenvUnsafe { .. } => {
            Ok(())
        }
        NewCheckoutMode::ApfsCow { source_path }
        | NewCheckoutMode::ApfsCowDirenvUnsafe { source_path } => {
            let src = source_path.as_path();
            if !src.is_dir() {
                return Err(Error::InvalidSource(format!(
                    "apfs copy-on-write source {src:?} is not an existing directory"
                )));
            }
            for path in [src, working_copies_dir] {
                if !apfs::is_apfs(path)? {
                    return Err(Error::InvalidSource(format!(
                        "apfs copy-on-write requires APFS: {path:?} is not on an APFS volume"
                    )));
                }
            }
            if !apfs::same_volume(src, working_copies_dir)? {
                return Err(Error::InvalidSource(format!(
                    "apfs copy-on-write requires one APFS volume: source {src:?} and the \
                     forest's checkout location {working_copies_dir:?} are on different volumes"
                )));
            }
            Ok(())
        }
    }
}

/// The trunk bookmark whose remote copy defines "already pushed" for the removal
/// safety check.
const TRUNK_BOOKMARK: &str = "main";

/// Remotes to look for the trunk on, in preference order. Provisioning clones with
/// `jj git clone --colocate` (jj's default remote name is `origin`), so `origin` is
/// the common case; `github` covers checkouts made outside silverwood. Kept in
/// lockstep with the clone remote name in `provider.rs`.
const SAFETY_REMOTES: [&str; 2] = ["origin", "github"];

/// Whether — and under what condition — a workstream may be removed. The exhaustive
/// per-kind match forces each new kind to decide its own removal policy.
enum Removability {
    /// Safe to remove without `--force`.
    Safe,
    /// Not safe by itself; `--force` overrides.
    ForceOnly,
    /// Never removable — even `--force` cannot remove it.
    Forbidden,
}

/// The [`Removability`] of a workstream:
/// - `Basic` — [`Removability::Safe`] iff all jj revs are already on the remote trunk
///   (see [`all_jj_revs_are_in_remote_github`]); else [`Removability::ForceOnly`]. An
///   operational VCS failure surfaces as `Err`.
/// - `LocalUnmanagedExistingPath` — always [`Removability::Forbidden`] (its path is
///   managed outside silverwood).
/// - `LocalTmp` — `Safe` once its directory no longer exists; else `ForceOnly`.
/// - `LocalBlank` — `Safe` while its directory is empty (or already gone); else `ForceOnly`.
fn removability(ws: &Workstream) -> Result<Removability> {
    let managed = |safe: bool| {
        if safe {
            Removability::Safe
        } else {
            Removability::ForceOnly
        }
    };
    match &ws.body.kind {
        WorkstreamKind::Basic { location, .. } => {
            let LocationWithinForest::BasicForest { path } = &location.within;
            Ok(managed(all_jj_revs_are_in_remote_github(Path::new(path))?))
        }
        WorkstreamKind::LocalUnmanagedExistingPath { .. } => Ok(Removability::Forbidden),
        WorkstreamKind::LocalTmp { location } => {
            let LocationWithinForest::BasicForest { path } = &location.within;
            Ok(managed(!Path::new(path).exists()))
        }
        WorkstreamKind::LocalBlank { location } => {
            let LocationWithinForest::BasicForest { path } = &location.within;
            Ok(managed(dir_is_empty(Path::new(path))?))
        }
    }
}

/// The on-disk directory silverwood may delete when removing this workstream. `None`
/// for a kind whose directory is managed outside silverwood
/// (`LocalUnmanagedExistingPath`), which must never be deleted.
fn managed_checkout_path(kind: &WorkstreamKind) -> Option<&str> {
    match kind {
        WorkstreamKind::Basic { location, .. }
        | WorkstreamKind::LocalTmp { location }
        | WorkstreamKind::LocalBlank { location } => {
            let LocationWithinForest::BasicForest { path } = &location.within;
            Some(path)
        }
        WorkstreamKind::LocalUnmanagedExistingPath { .. } => None,
    }
}

/// Whether `path` is an empty directory. An absent path counts as empty — there is
/// nothing to lose by removing the record.
fn dir_is_empty(path: &Path) -> Result<bool> {
    match fs::read_dir(path) {
        Ok(mut entries) => Ok(entries.next().is_none()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(true),
        Err(e) => Err(Error::io(path, e)),
    }
}

/// The directory to run a session in, if the workstream is ready to be spawned into,
/// else [`Error::NotSpawnable`]. `Basic` is ready only once its checkout is `Ready`;
/// the `Local*` kinds are ready as long as their recorded directory exists on disk.
fn spawn_cwd(ws: &Workstream) -> Result<String> {
    let not_spawnable = |state: &str| Error::NotSpawnable {
        id: ws.id,
        state: state.to_string(),
    };
    match &ws.body.kind {
        WorkstreamKind::Basic { mode, location } => {
            if mode.state() != CheckoutState::Ready {
                return Err(not_spawnable(mode.state().as_str()));
            }
            let LocationWithinForest::BasicForest { path } = &location.within;
            Ok(path.clone())
        }
        WorkstreamKind::LocalUnmanagedExistingPath { location }
        | WorkstreamKind::LocalTmp { location }
        | WorkstreamKind::LocalBlank { location } => {
            let LocationWithinForest::BasicForest { path } = &location.within;
            if Path::new(path).is_dir() {
                Ok(path.clone())
            } else {
                Err(not_spawnable("missing"))
            }
        }
    }
}

/// Validate the `local-unmanaged-existing-path` seed before anything is persisted: the
/// path must be an existing directory on the same filesystem as the forest's storage
/// (`working_copies_dir`). Any failure is an [`Error::InvalidSource`].
fn precheck_existing_path(path: &Path, working_copies_dir: &Path) -> Result<()> {
    if !path.is_dir() {
        return Err(Error::InvalidSource(format!(
            "existing path {path:?} is not an existing directory"
        )));
    }
    if !apfs::same_volume(path, working_copies_dir)? {
        return Err(Error::InvalidSource(format!(
            "existing path {path:?} must be on the same filesystem as the forest \
             (its storage is at {working_copies_dir:?})"
        )));
    }
    Ok(())
}

/// True iff `checkout` is a jj workspace root and every non-empty rev in it is an
/// ancestor-or-equal of the remote trunk bookmark (`main@origin`, else `main@github`)
/// — i.e. all local work already lives on the remote, so discarding the checkout loses
/// nothing. Returns `Ok(false)` for a definite "not safe" (not a jj root, no remote
/// trunk, or unpushed non-empty work) and `Err` for an operational jj failure.
fn all_jj_revs_are_in_remote_github(checkout: &Path) -> Result<bool> {
    // Condition 1 — `checkout` must be its own jj workspace root, checked BEFORE any
    // `jj` runs here: a colocated root has `.jj` at its own root, a mere subdirectory
    // of an ancestor jj repo does not. Skipping this would let the revsets below run
    // against the ancestor repo and wrongly report "safe".
    if !checkout.join(".jj").is_dir() {
        return Ok(false);
    }

    // The remote trunk to compare against, or "not safe" if neither remote has it.
    let Some(trunk) = resolve_remote_trunk(checkout)? else {
        return Ok(false);
    };

    // Condition 2 — any non-empty rev not yet an ancestor of the trunk is unpushed
    // work. No `--ignore-working-copy`: letting `jj log` snapshot the working copy
    // means uncommitted edits count as a non-empty `@` and are flagged. Empty output
    // ⇒ nothing outside the trunk ⇒ safe.
    let revset = format!("~empty() & ~::{trunk}");
    let out = run_jj(
        checkout,
        &["log", "--no-graph", "-T", "commit_id", "-r", &revset],
    )?;
    Ok(out.stdout.is_empty())
}

/// Resolve the remote trunk bookmark to compare against: `main@origin` if it exists,
/// else `main@github`, else `None`. Probes with `remote_bookmarks(...)`, which yields
/// an *empty set* (not an error) for an absent bookmark, so absence falls through to
/// the next remote while a genuine jj failure still surfaces as `Err`.
fn resolve_remote_trunk(checkout: &Path) -> Result<Option<String>> {
    for remote in SAFETY_REMOTES {
        let revset = format!(r#"remote_bookmarks(exact:"{TRUNK_BOOKMARK}", exact:"{remote}")"#);
        let out = run_jj(
            checkout,
            &[
                "log",
                "--ignore-working-copy",
                "--no-graph",
                "-T",
                "commit_id",
                "-r",
                &revset,
            ],
        )?;
        if !out.stdout.is_empty() {
            return Ok(Some(format!("{TRUNK_BOOKMARK}@{remote}")));
        }
    }
    Ok(None)
}

/// Run `jj` in `checkout` and capture its output, mapping a spawn failure or a
/// non-zero exit to [`Error::Vcs`] (mirrors `provider.rs`'s command pattern, plus
/// `current_dir`). A successful run may still have empty `stdout`; callers interpret
/// that as a meaningful, non-error result.
fn run_jj(checkout: &Path, args: &[&str]) -> Result<Output> {
    let out = Command::new("jj")
        .current_dir(checkout)
        .args(args)
        .output()
        .map_err(|e| Error::Vcs(format!("spawning jj: {e}")))?;
    if !out.status.success() {
        return Err(Error::Vcs(format!(
            "`jj {}` exited {}: {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(out)
}

/// Remove a directory tree, treating an already-absent path as success (a
/// never-provisioned `Pending`/`Failed` checkout may have no directory).
fn remove_tree_if_present(path: &Path) -> Result<()> {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::io(path, e)),
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
