use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Stable identity of a [`crate::Forest`], used (via the derived Loro peer id)
/// to attribute edits. Local to a forest and never synced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ForestId(pub Uuid);

/// Stable identity of a workstream. Doubles as its document's name in a
/// [`crate::DocStore`]. Time-ordered (UUIDv7) so ids roughly sort by creation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct WorkstreamId(pub Uuid);

impl ForestId {
    /// Mint a fresh, time-ordered forest id.
    pub fn generate() -> Self {
        Self(Uuid::now_v7())
    }
}

impl WorkstreamId {
    /// Mint a fresh, time-ordered workstream id.
    pub fn generate() -> Self {
        Self(Uuid::now_v7())
    }
}

impl fmt::Display for ForestId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl fmt::Display for WorkstreamId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl FromStr for WorkstreamId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Uuid::from_str(s).map(WorkstreamId)
    }
}
