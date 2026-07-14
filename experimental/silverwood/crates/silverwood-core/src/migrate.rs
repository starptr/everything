//! Document schema versioning and migration.
//!
//! Each workstream document self-describes its schema via a `schema_version`
//! root scalar (absent = v1, the pre-versioning shape). This module owns the
//! current [`DOC_SCHEMA_VERSION`], a frozen decode struct per historical version
//! (`StoredBodyV1`, …), and the chain that folds any older version up to the
//! latest domain [`WorkstreamBody`].
//!
//! Migrations are pure functions over plain Rust types (no Loro), so they are
//! deterministic and unit-testable; persistence re-encodes the migrated body via
//! [`crate::doc::build`], which stamps the latest version and — being a fresh
//! op-graph — shrinks the document. See `DESIGN.md` §9.
//!
//! **Frozen-struct discipline.** Once a version ships, its `StoredBody*Vn` decode
//! is immutable. Adding a version means: add `StoredBodyV{n+1}`, add a
//! `v{n} → v{n+1}` step, and move the `into_body` encoder onto the new latest
//! struct (older structs keep only decode + their upgrade step).

use std::collections::BTreeMap;

use serde::Deserialize;

use crate::error::{Error, Result};
use crate::id::WorkstreamId;
use crate::workstream::{
    AgentSession, Checkout, CodeChange, Status, WorkstreamBody, WorkstreamKind, BASIC_KIND,
};

/// The document schema version this build reads and writes.
pub const DOC_SCHEMA_VERSION: u32 = 1;

/// Root scalar key holding a document's schema version.
pub(crate) const SCHEMA_VERSION_KEY: &str = "schema_version";

/// Read the schema version from a document's root JSON. Absent = v1 (the
/// pre-versioning shape). Present-but-not-a-non-negative-integer is corrupt.
pub(crate) fn detect_version(root: &serde_json::Value) -> Result<u32> {
    match root.get(SCHEMA_VERSION_KEY) {
        None => Ok(1),
        Some(v) => v
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or_else(|| Error::Corrupt(format!("invalid {SCHEMA_VERSION_KEY}: {v}"))),
    }
}

/// Decode a document's root JSON at whatever version it declares, migrate it up
/// to the latest, and produce the domain [`WorkstreamBody`]. Errors
/// [`Error::SchemaTooNew`] if the document is newer than this build supports.
pub(crate) fn to_latest_body(id: WorkstreamId, root: &serde_json::Value) -> Result<WorkstreamBody> {
    let version = detect_version(root)?;
    match version {
        1 => decode_v1(id, root)?.into_body(id),
        v if v > DOC_SCHEMA_VERSION => Err(Error::SchemaTooNew {
            found: v,
            supported: DOC_SCHEMA_VERSION,
        }),
        v => Err(Error::Migration(format!(
            "workstream {id}: no migration path from schema v{v}"
        ))),
    }
}

fn decode_v1(id: WorkstreamId, root: &serde_json::Value) -> Result<StoredBodyV1> {
    serde_json::from_value(root.clone())
        .map_err(|e| Error::Corrupt(format!("workstream {id} (schema v1): {e}")))
}

// ---- v1 (current latest) ----------------------------------------------------

/// The v1 on-disk body shape — also the current latest. **Frozen.** Extra keys
/// (e.g. `schema_version`) are ignored by serde, so a versioned or un-versioned
/// v1 document decodes identically.
#[derive(Deserialize)]
struct StoredBodyV1 {
    name: String,
    status: Status,
    kind: String,
    created_at: String,
    /// Present iff `kind == "basic"`.
    #[serde(default)]
    basic: Option<StoredBasicV1>,
    /// JSON `["namespace","key"]` → value.
    #[serde(default)]
    kv: BTreeMap<String, String>,
}

/// The v1 stored shape of the `basic` kind container. **Frozen.**
#[derive(Deserialize)]
struct StoredBasicV1 {
    code_change: CodeChange,
    #[serde(default)]
    checkouts: BTreeMap<String, Checkout>,
    /// session id → JSON-encoded `AgentSession`.
    #[serde(default)]
    sessions: BTreeMap<String, String>,
}

impl StoredBodyV1 {
    /// Encode into the latest domain body. v1 is the latest, so this is the
    /// `into_body` encoder; when v2 lands it moves onto the v2 struct and v1
    /// instead gains a `migrate_to_v2`.
    fn into_body(self, id: WorkstreamId) -> Result<WorkstreamBody> {
        let kind = match self.kind.as_str() {
            BASIC_KIND => {
                let basic = self.basic.ok_or_else(|| {
                    Error::Corrupt(format!(
                        "workstream {id}: kind=basic but no `basic` container"
                    ))
                })?;
                let mut sessions = BTreeMap::new();
                for (session_id, encoded) in basic.sessions {
                    let session: AgentSession = serde_json::from_str(&encoded).map_err(|e| {
                        Error::Corrupt(format!("workstream {id} session {session_id}: {e}"))
                    })?;
                    sessions.insert(session_id, session);
                }
                WorkstreamKind::Basic {
                    code_change: basic.code_change,
                    checkouts: basic.checkouts,
                    sessions,
                }
            }
            other => {
                return Err(Error::Corrupt(format!(
                    "workstream {id}: unknown kind {other:?}"
                )))
            }
        };

        let mut kv: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
        for (composite, value) in self.kv {
            let [namespace, key]: [String; 2] = serde_json::from_str(&composite).map_err(|e| {
                Error::Corrupt(format!("workstream {id} kv key {composite:?}: {e}"))
            })?;
            kv.entry(namespace).or_default().insert(key, value);
        }

        Ok(WorkstreamBody {
            name: self.name,
            status: self.status,
            created_at: self.created_at,
            kind,
            kv,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_version_is_v1() {
        let root = serde_json::json!({ "name": "x" });
        assert_eq!(detect_version(&root).unwrap(), 1);
    }

    #[test]
    fn explicit_version_is_read() {
        let root = serde_json::json!({ "schema_version": 7 });
        assert_eq!(detect_version(&root).unwrap(), 7);
    }

    #[test]
    fn non_integer_version_is_corrupt() {
        let root = serde_json::json!({ "schema_version": "nope" });
        assert!(matches!(detect_version(&root), Err(Error::Corrupt(_))));
    }

    #[test]
    fn newer_than_supported_errors_schema_too_new() {
        let root = serde_json::json!({ "schema_version": DOC_SCHEMA_VERSION + 1 });
        let err = to_latest_body(WorkstreamId::generate(), &root).unwrap_err();
        assert!(matches!(err, Error::SchemaTooNew { .. }));
    }
}
