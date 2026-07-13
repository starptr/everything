use serde::{Deserialize, Serialize};

use crate::id::ForestId;

/// On-disk schema version for [`ForestConfig`]. Bumped when the layout changes.
pub const CONFIG_VERSION: u32 = 1;

/// Machine-local forest configuration, persisted as `config.toml`. Holds the
/// forest's identity and the Loro peer id derived from it. Never synced.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ForestConfig {
    /// Schema version of this config file.
    pub version: u32,
    /// This forest's stable id.
    pub forest_id: ForestId,
    /// Loro peer/actor id, derived deterministically from `forest_id`.
    pub peer_id: u64,
}

impl ForestConfig {
    /// Generate a fresh config with a new forest id and its derived peer id.
    pub fn generate() -> Self {
        let forest_id = ForestId::generate();
        Self {
            version: CONFIG_VERSION,
            peer_id: derive_peer_id(forest_id),
            forest_id,
        }
    }
}

/// Derive a stable, nonzero Loro peer id from a forest id's leading bytes.
fn derive_peer_id(id: ForestId) -> u64 {
    let bytes = id.0.as_bytes();
    let raw = u64::from_le_bytes(bytes[..8].try_into().expect("uuid is 16 bytes"));
    // TOML integers are i64, so keep the peer id in [1, i64::MAX] to round-trip
    // through `config.toml`. 63 bits of entropy is ample for Loro peer-id
    // uniqueness across a handful of forests; avoid 0 as a default sentinel.
    let value = raw & (i64::MAX as u64);
    if value == 0 {
        1
    } else {
        value
    }
}
