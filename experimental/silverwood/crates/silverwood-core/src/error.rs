use std::path::PathBuf;

use crate::id::WorkstreamId;

/// Errors returned by `silverwood-core`.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A filesystem operation failed, annotated with the offending path.
    #[error("i/o error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    /// The forest config could not be serialized.
    #[error("serializing forest config: {0}")]
    ConfigSer(#[from] toml::ser::Error),

    /// The forest config on disk could not be parsed.
    #[error("parsing forest config at {path}: {source}")]
    ConfigDe {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },

    /// A document store held a file whose name is not a valid workstream id.
    #[error("invalid workstream id in doc store: {0:?}")]
    InvalidDocId(PathBuf),

    /// The underlying CRDT engine (Loro) reported an error.
    #[error("crdt error: {0}")]
    Loro(String),

    /// A code-change source was not a valid HTTPS git endpoint.
    #[error("invalid source: {0}")]
    InvalidSource(String),

    /// Provisioning a checkout failed.
    #[error("checkout provisioning failed: {0}")]
    Provision(String),

    /// A version-control (jj) query failed while evaluating removal safety — jj was
    /// missing, failed to spawn, or exited non-zero unexpectedly.
    #[error("vcs error: {0}")]
    Vcs(String),

    /// No workstream exists with the given id.
    #[error("workstream not found: {0}")]
    NotFound(WorkstreamId),

    /// A checkout was requested on a workstream that is not awaiting one — it was not
    /// created with the checkout deferred (`--checkout-extent skip`), or has already
    /// been checked out (or is mid-provision). Only an `initialized-without-checkout`
    /// workstream can be checked out.
    #[error("workstream {id} is not awaiting checkout (state: {state})")]
    NotAwaitingCheckout {
        id: WorkstreamId,
        state: &'static str,
    },

    /// A workstream was not deemed safe to remove (and `--force` was not given).
    #[error("workstream {0} is not safe to remove; pass --force to remove anyway")]
    UnsafeToRemove(WorkstreamId),

    /// A workstream's kind forbids removal entirely — even `--force` cannot remove it,
    /// because its directory is managed by a lifecycle outside silverwood (a
    /// `local-unmanaged-existing-path` workstream).
    #[error("workstream {0} cannot be removed (its path is managed outside silverwood)")]
    RemovalUnsupported(WorkstreamId),

    /// A session with this id is already attached to the workstream.
    #[error("session already attached: {0}")]
    SessionExists(String),

    /// No session with this id is attached to the workstream.
    #[error("session not attached: {0}")]
    SessionNotFound(String),

    /// A session's advisory lock is held by a different holder (acquire/release
    /// without `--force`). Best-effort: cooperative clients back off; `--force`
    /// steals it.
    #[error("session {session_id} is locked by {holder}")]
    SessionLocked { session_id: String, holder: String },

    /// A lock operation was attempted on a session whose kind carries no lock
    /// (e.g. a `plain-shell`, which has no shared resumable state to guard).
    #[error("session {session_id} is a {kind} session, which has no lock")]
    SessionNotLockable { session_id: String, kind: String },

    /// A session could not be spawned because its workstream has no ready checkout to
    /// run in (none materialized, or provisioning is incomplete). Carries the checkout
    /// state string (or `none`).
    #[error("workstream {id} has no ready checkout to spawn in (checkout state: {state})")]
    NotSpawnable { id: WorkstreamId, state: String },

    /// A frontend tried to write a core-reserved kv namespace directly.
    #[error("namespace {0:?} is reserved for silverwood core; use `silverwood session`")]
    ReservedNamespace(String),

    /// A stored workstream document did not match the expected structure.
    #[error("corrupt workstream document: {0}")]
    Corrupt(String),

    /// A document's schema is newer than this build can read; upgrade silverwood.
    #[error("document schema v{found} is newer than supported v{supported}; upgrade silverwood")]
    SchemaTooNew { found: u32, supported: u32 },

    /// A schema migration step failed.
    #[error("migrating workstream document: {0}")]
    Migration(String),
}

/// Convenience alias for results from this crate.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// Build an [`Error::Io`] tagged with the path it occurred at.
    pub(crate) fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Error::Io {
            path: path.into(),
            source,
        }
    }
}
