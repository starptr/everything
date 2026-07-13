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

    /// A stored workstream document did not match the expected structure.
    #[error("corrupt workstream document: {0}")]
    Corrupt(String),
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
