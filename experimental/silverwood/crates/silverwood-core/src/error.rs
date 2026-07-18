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

    /// No workstream exists with the given id.
    #[error("workstream not found: {0}")]
    NotFound(WorkstreamId),

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
