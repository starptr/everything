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
use uuid::Uuid;

use crate::error::{Error, Result};
use crate::id::{ForestId, WorkstreamId};
use crate::workstream::{
    CheckoutMode, CheckoutState, Location, LocationWithinForest, Status, WorkstreamBody,
    WorkstreamKind, BASIC_KIND, SESSION_NS,
};

/// The document schema version this build reads and writes.
///
/// v1 stored agent sessions inside the `basic` kind container; v2 relocated them
/// into the reserved `app.andref.silverwood.session` kv namespace (`DESIGN.md` §5);
/// v3 collapses the basic kind's `code_change` + per-forest `checkouts` map into a
/// single data-carrying `mode` (seed + state) and a single `location`.
pub const DOC_SCHEMA_VERSION: u32 = 3;

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
        1 => decode_v1(id, root)?.into_v2().into_v3().into_body(id),
        2 => decode_v2(id, root)?.into_v3().into_body(id),
        3 => decode_v3(id, root)?.into_body(id),
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

fn decode_v2(id: WorkstreamId, root: &serde_json::Value) -> Result<StoredBodyV2> {
    serde_json::from_value(root.clone())
        .map_err(|e| Error::Corrupt(format!("workstream {id} (schema v2): {e}")))
}

fn decode_v3(id: WorkstreamId, root: &serde_json::Value) -> Result<StoredBodyV3> {
    serde_json::from_value(root.clone())
        .map_err(|e| Error::Corrupt(format!("workstream {id} (schema v3): {e}")))
}

// ---- frozen decode types for the pre-v3 `basic` container -------------------

/// The v1/v2 stored `code_change` shape. **Frozen.** The domain `CodeChange` type
/// was removed in v3, so migration keeps its own decode copy. The `mode` field
/// (always `"jj-colocated"`) is intentionally omitted — serde ignores it, and v3
/// has a single mode.
#[derive(Deserialize)]
struct StoredCodeChange {
    source: String,
}

/// The v1/v2 stored per-forest `checkout` shape. **Frozen.** Its `mode` field
/// (redundant with `code_change.mode`) is omitted — serde ignores it.
#[derive(Deserialize)]
struct StoredCheckout {
    location: String,
    state: CheckoutState,
}

// ---- v1 (frozen) ------------------------------------------------------------

/// The v1 on-disk body shape. **Frozen.** Extra keys (e.g. `schema_version`) are
/// ignored by serde, so a versioned or un-versioned v1 document decodes
/// identically. v1 stored sessions *inside* the `basic` container; the v1→v2 step
/// relocates them into the reserved kv namespace (see [`StoredBodyV1::into_v2`]).
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
    code_change: StoredCodeChange,
    #[serde(default)]
    checkouts: BTreeMap<String, StoredCheckout>,
    /// session id → JSON-encoded `AgentSession`.
    #[serde(default)]
    sessions: BTreeMap<String, String>,
}

impl StoredBodyV1 {
    /// v1 → v2: relocate sessions from `basic.sessions` into the flat kv map under
    /// the reserved [`SESSION_NS`] — each value carried over verbatim, since v1
    /// already stored the JSON-encoded `AgentSession`. Destructive (it moves a
    /// container; see `DESIGN.md` §9.2/§9.3). **Frozen.**
    fn into_v2(self) -> StoredBodyV2 {
        let StoredBodyV1 {
            name,
            status,
            kind,
            created_at,
            basic,
            mut kv,
        } = self;
        let basic = basic.map(|b| {
            let StoredBasicV1 {
                code_change,
                checkouts,
                sessions,
            } = b;
            for (session_id, encoded) in sessions {
                let composite = serde_json::to_string(&[SESSION_NS, session_id.as_str()])
                    .expect("json array of two strings is infallible");
                kv.insert(composite, encoded);
            }
            StoredBasicV2 {
                code_change,
                checkouts,
            }
        });
        StoredBodyV2 {
            name,
            status,
            kind,
            created_at,
            basic,
            kv,
        }
    }
}

// ---- v2 (frozen) ------------------------------------------------------------

/// The v2 on-disk body shape. **Frozen.** Sessions are kv entries under the
/// reserved [`SESSION_NS`], so v2's `basic` holds only the code-change and the
/// per-forest checkouts map.
#[derive(Deserialize)]
struct StoredBodyV2 {
    name: String,
    status: Status,
    kind: String,
    created_at: String,
    /// Present iff `kind == "basic"`.
    #[serde(default)]
    basic: Option<StoredBasicV2>,
    /// JSON `["namespace","key"]` → value (sessions live here under SESSION_NS).
    #[serde(default)]
    kv: BTreeMap<String, String>,
}

/// The v2 stored shape of the `basic` kind container. **Frozen.**
#[derive(Deserialize)]
struct StoredBasicV2 {
    code_change: StoredCodeChange,
    #[serde(default)]
    checkouts: BTreeMap<String, StoredCheckout>,
}

impl StoredBodyV2 {
    /// v2 → v3: collapse `code_change` + the per-forest `checkouts` map into a
    /// single data-carrying `mode` (owning the seed + provisioning state) and a
    /// single `location`. **Destructive/compacting** (`DESIGN.md` §9.2/§9.3): a
    /// basic workstream is single-forest, so only the first checkout (by forest-id
    /// order) survives and the rest are dropped; real docs have exactly one. A
    /// document with zero checkouts (only synthetic pre-v3 corpus) degrades to a
    /// never-provisioned `pending` location with a nil forest id. **Frozen** once
    /// v4 lands.
    fn into_v3(self) -> StoredBodyV3 {
        let StoredBodyV2 {
            name,
            status,
            kind,
            created_at,
            basic,
            kv,
        } = self;
        let basic = basic.map(|b| {
            let StoredBasicV2 {
                code_change,
                checkouts,
            } = b;
            // The single materialization: first checkout (deterministic BTreeMap
            // order), or a degenerate never-provisioned one if there were none.
            let (forest_key, path, state) = checkouts
                .into_iter()
                .next()
                .map(|(fid, c)| (fid, c.location, c.state))
                .unwrap_or_else(|| (String::new(), String::new(), CheckoutState::Pending));
            let forest_id = forest_key
                .parse::<Uuid>()
                .map(ForestId)
                .unwrap_or(ForestId(Uuid::nil()));
            StoredBasicV3 {
                mode: CheckoutMode::JjColocated {
                    initial_source: code_change.source,
                    state,
                },
                location: Location {
                    forest_id,
                    within: LocationWithinForest::BasicForest { path },
                },
            }
        });
        StoredBodyV3 {
            name,
            status,
            kind,
            created_at,
            basic,
            kv,
        }
    }
}

// ---- v3 (current latest) ----------------------------------------------------

/// The v3 on-disk body shape — the current latest. **Frozen** once v4 lands.
/// The `basic` container holds a data-carrying `mode` and a single `location`
/// (decoded straight into the domain types, which are `Deserialize`).
#[derive(Deserialize)]
struct StoredBodyV3 {
    name: String,
    status: Status,
    kind: String,
    created_at: String,
    /// Present iff `kind == "basic"`.
    #[serde(default)]
    basic: Option<StoredBasicV3>,
    /// JSON `["namespace","key"]` → value (sessions live here under SESSION_NS).
    #[serde(default)]
    kv: BTreeMap<String, String>,
}

/// The v3 stored shape of the `basic` kind container. **Frozen** once v4 lands.
#[derive(Deserialize)]
struct StoredBasicV3 {
    mode: CheckoutMode,
    location: Location,
}

impl StoredBodyV3 {
    /// Encode into the latest domain body. v3 is the latest, so this is the
    /// `into_body` encoder; when v4 lands it moves onto the v4 struct and v3
    /// instead keeps only decode + a `migrate_to_v4`.
    fn into_body(self, id: WorkstreamId) -> Result<WorkstreamBody> {
        let kind = match self.kind.as_str() {
            BASIC_KIND => {
                let basic = self.basic.ok_or_else(|| {
                    Error::Corrupt(format!(
                        "workstream {id}: kind=basic but no `basic` container"
                    ))
                })?;
                WorkstreamKind::Basic {
                    mode: basic.mode,
                    location: basic.location,
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
