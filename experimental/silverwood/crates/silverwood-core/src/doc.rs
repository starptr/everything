//! Mapping between a [`Workstream`] and its Loro document.
//!
//! One `LoroDoc` per workstream. Loro has no derive layer, so this module owns
//! the container⇄struct translation by hand. Writes go through typed containers;
//! reads hydrate via `get_deep_value()` + serde. Mutations of an existing
//! document reuse its containers (load → edit in place → snapshot) so document
//! lineage — and therefore future mergeability — is preserved.
//!
//! ## Layout
//!
//! The root map holds the scalars (`name`, `status`, `created_at`) plus the
//! `kind` discriminant, one kind container named after the kind (today `basic`),
//! and a root-level `kv` map. The `basic` container nests `code_change`,
//! `checkouts` (keyed by forest id) and `sessions`.
//!
//! ## Merge-safety invariant
//!
//! Concurrently creating the *same* nested-container key on two forests is
//! unsafe: each forest makes a distinct container and the parent map LWW-picks
//! one, silently dropping the other's contents. We avoid this by only ever
//! creating containers **once, at genesis in [`build`]** — the `kind` is fixed
//! at creation and the `basic`/`code_change`/`checkouts`/`sessions`/`kv`
//! containers are never lazily re-created in a mutator (mutators fetch them with
//! `child_map`, which errors if absent). Two forests derive from the same base
//! snapshot, so they share those container ids.
//!
//! Within those genesis containers, `sessions` and `kv` store *scalar string*
//! values (kv keyed by JSON `["namespace","key"]`, sessions keyed by session id
//! with a JSON-encoded [`AgentSession`]) so independent entries merge as ordinary
//! LWW keys; `checkouts` nests per-forest maps, safe because keyed by forest id.

use loro::{Container, ExportMode, LoroDoc, LoroMap, ValueOrContainer};

use crate::error::{Error, Result};
use crate::id::WorkstreamId;
use crate::migrate;
use crate::workstream::{
    AgentKind, AgentSession, Checkout, CheckoutState, Status, Workstream, WorkstreamBody,
    WorkstreamKind, BASIC_KIND,
};

/// Name of the single root map container.
const ROOT: &str = "workstream";

fn loro_err<E: std::fmt::Display>(e: E) -> Error {
    Error::Loro(e.to_string())
}

/// Build a fresh document from a body, authored under `peer_id`.
pub(crate) fn build(peer_id: u64, body: &WorkstreamBody) -> Result<LoroDoc> {
    let doc = LoroDoc::new();
    doc.set_peer_id(peer_id).map_err(loro_err)?;

    let root = doc.get_map(ROOT);
    root.insert("name", body.name.as_str()).map_err(loro_err)?;
    root.insert("status", body.status.as_str())
        .map_err(loro_err)?;
    root.insert("created_at", body.created_at.as_str())
        .map_err(loro_err)?;
    root.insert("kind", body.kind.tag()).map_err(loro_err)?;
    root.insert(
        migrate::SCHEMA_VERSION_KEY,
        migrate::DOC_SCHEMA_VERSION as i64,
    )
    .map_err(loro_err)?;

    // The kind container (named after the kind). Created once here — never in a
    // mutator — per the module's merge-safety invariant.
    match &body.kind {
        WorkstreamKind::Basic {
            code_change,
            checkouts,
            sessions,
        } => {
            let basic = root
                .insert_container(BASIC_KIND, LoroMap::new())
                .map_err(loro_err)?;

            let cc = basic
                .insert_container("code_change", LoroMap::new())
                .map_err(loro_err)?;
            cc.insert("source", code_change.source.as_str())
                .map_err(loro_err)?;
            cc.insert("mode", code_change.mode.as_str())
                .map_err(loro_err)?;

            // checkouts: nested map-of-maps, safe because keyed by forest id.
            let checkouts_map = basic
                .insert_container("checkouts", LoroMap::new())
                .map_err(loro_err)?;
            for (forest_id, checkout) in checkouts {
                write_checkout(&checkouts_map, forest_id, checkout)?;
            }

            // sessions: flat map of scalar strings (see module docs).
            let sessions_map = basic
                .insert_container("sessions", LoroMap::new())
                .map_err(loro_err)?;
            for (session_id, session) in sessions {
                sessions_map
                    .insert(session_id.as_str(), agent_session_json(session))
                    .map_err(loro_err)?;
            }
        }
    }

    // kv: flat map of scalar strings at the root — kind-agnostic frontend state.
    let kv = root
        .insert_container("kv", LoroMap::new())
        .map_err(loro_err)?;
    for (namespace, entries) in &body.kv {
        for (key, value) in entries {
            kv.insert(kv_key(namespace, key).as_str(), value.as_str())
                .map_err(loro_err)?;
        }
    }

    doc.commit();
    Ok(doc)
}

/// Load a document from stored bytes, ready to author under `peer_id`.
pub(crate) fn load(peer_id: u64, bytes: &[u8]) -> Result<LoroDoc> {
    let doc = LoroDoc::new();
    doc.import(bytes).map_err(loro_err)?;
    doc.set_peer_id(peer_id).map_err(loro_err)?;
    Ok(doc)
}

/// Serialize a document to a snapshot for persistence.
pub(crate) fn snapshot(doc: &LoroDoc) -> Result<Vec<u8>> {
    doc.export(ExportMode::snapshot()).map_err(loro_err)
}

/// The JSON of a document's root map (resolving nested containers).
fn root_json(id: WorkstreamId, doc: &LoroDoc) -> Result<serde_json::Value> {
    serde_json::to_value(doc.get_map(ROOT).get_deep_value())
        .map_err(|e| Error::Corrupt(format!("workstream {id} not serializable: {e}")))
}

/// Hydrate a [`Workstream`] from stored bytes, upgrading any older schema to the
/// latest in memory (no disk write). Errors [`Error::SchemaTooNew`] if the
/// document is newer than this build supports.
pub(crate) fn hydrate(id: WorkstreamId, bytes: &[u8]) -> Result<Workstream> {
    let doc = LoroDoc::new();
    doc.import(bytes).map_err(loro_err)?;
    let root = root_json(id, &doc)?;
    Ok(Workstream {
        id,
        body: migrate::to_latest_body(id, &root)?,
    })
}

/// Read a stored document's schema version without fully hydrating it.
pub(crate) fn peek_version(id: WorkstreamId, bytes: &[u8]) -> Result<u32> {
    let doc = LoroDoc::new();
    doc.import(bytes).map_err(loro_err)?;
    migrate::detect_version(&root_json(id, &doc)?)
}

/// Migrate a stored document to the latest schema, re-encoding under `peer_id`.
/// Returns the rebuilt bytes (a fresh snapshot at the latest version) if the
/// document was older, or `None` if it is already at the latest. Errors
/// [`Error::SchemaTooNew`] if the document is newer than this build supports.
pub(crate) fn migrate_bytes(
    id: WorkstreamId,
    bytes: &[u8],
    peer_id: u64,
) -> Result<Option<Vec<u8>>> {
    let doc = LoroDoc::new();
    doc.import(bytes).map_err(loro_err)?;
    let root = root_json(id, &doc)?;
    let from = migrate::detect_version(&root)?;
    if from > migrate::DOC_SCHEMA_VERSION {
        return Err(Error::SchemaTooNew {
            found: from,
            supported: migrate::DOC_SCHEMA_VERSION,
        });
    }
    if from == migrate::DOC_SCHEMA_VERSION {
        return Ok(None);
    }
    let body = migrate::to_latest_body(id, &root)?;
    let rebuilt = build(peer_id, &body)?;
    Ok(Some(snapshot(&rebuilt)?))
}

/// Overwrite the root `status` scalar (used to archive).
pub(crate) fn set_status(doc: &LoroDoc, status: Status) -> Result<()> {
    doc.get_map(ROOT)
        .insert("status", status.as_str())
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Overwrite the `state` of an existing per-forest checkout entry, in place.
pub(crate) fn set_checkout_state(
    doc: &LoroDoc,
    forest_id: &str,
    state: CheckoutState,
) -> Result<()> {
    let checkouts = child_map(&basic_map(doc)?, "checkouts")?;
    let entry = child_map(&checkouts, forest_id)?;
    entry.insert("state", state.as_str()).map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Set a namespaced key-value entry (value is an opaque JSON string).
pub(crate) fn set_kv(doc: &LoroDoc, namespace: &str, key: &str, value: &str) -> Result<()> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    kv.insert(kv_key(namespace, key).as_str(), value)
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Remove a namespaced key-value entry. A no-op if it is absent.
pub(crate) fn unset_kv(doc: &LoroDoc, namespace: &str, key: &str) -> Result<()> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    let composite = kv_key(namespace, key);
    if kv.get(&composite).is_some() {
        kv.delete(&composite).map_err(loro_err)?;
        doc.commit();
    }
    Ok(())
}

/// Attach an agent session. Errors if `session_id` is already attached.
pub(crate) fn attach_session(
    doc: &LoroDoc,
    session_id: &str,
    agent_kind: AgentKind,
    name: &str,
    created_at: &str,
) -> Result<()> {
    let sessions = child_map(&basic_map(doc)?, "sessions")?;
    if sessions.get(session_id).is_some() {
        return Err(Error::SessionExists(session_id.to_string()));
    }
    let session = AgentSession {
        kind: agent_kind,
        name: name.to_string(),
        created_at: created_at.to_string(),
    };
    sessions
        .insert(session_id, agent_session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Rename an attached session (preserving its `kind` and `created_at`). Errors
/// if absent.
pub(crate) fn rename_session(doc: &LoroDoc, session_id: &str, name: &str) -> Result<()> {
    let sessions = child_map(&basic_map(doc)?, "sessions")?;
    let existing = sessions
        .get(session_id)
        .and_then(value_as_string)
        .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?;
    let mut session: AgentSession = serde_json::from_str(&existing)
        .map_err(|e| Error::Corrupt(format!("session {session_id}: {e}")))?;
    session.name = name.to_string();
    sessions
        .insert(session_id, agent_session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Detach a session. A no-op if it is not attached.
pub(crate) fn detach_session(doc: &LoroDoc, session_id: &str) -> Result<()> {
    let sessions = child_map(&basic_map(doc)?, "sessions")?;
    if sessions.get(session_id).is_some() {
        sessions.delete(session_id).map_err(loro_err)?;
        doc.commit();
    }
    Ok(())
}

/// Fetch the genesis-created `basic` kind container for in-place mutation. It is
/// created once in [`build`] and the kind is immutable, so it is always present
/// for a basic workstream (see the merge-safety invariant).
fn basic_map(doc: &LoroDoc) -> Result<LoroMap> {
    child_map(&doc.get_map(ROOT), BASIC_KIND)
}

/// Write a checkout entry as a fresh nested map under `checkouts`.
fn write_checkout(checkouts: &LoroMap, forest_id: &str, checkout: &Checkout) -> Result<()> {
    let entry = checkouts
        .insert_container(forest_id, LoroMap::new())
        .map_err(loro_err)?;
    entry
        .insert("location", checkout.location.as_str())
        .map_err(loro_err)?;
    entry
        .insert("state", checkout.state.as_str())
        .map_err(loro_err)?;
    entry
        .insert("mode", checkout.mode.as_str())
        .map_err(loro_err)?;
    Ok(())
}

/// Fetch an existing child map container from `parent` for in-place mutation.
fn child_map(parent: &LoroMap, key: &str) -> Result<LoroMap> {
    match parent.get(key) {
        Some(ValueOrContainer::Container(Container::Map(map))) => Ok(map),
        _ => Err(Error::Corrupt(format!("expected map at {key:?}"))),
    }
}

/// Extract a scalar string value (reusing the proven LoroValue→JSON path).
fn value_as_string(vc: ValueOrContainer) -> Option<String> {
    match vc {
        ValueOrContainer::Value(v) => serde_json::to_value(&v).ok()?.as_str().map(str::to_string),
        ValueOrContainer::Container(_) => None,
    }
}

/// The document key for a namespaced kv entry: JSON `["namespace","key"]`.
fn kv_key(namespace: &str, key: &str) -> String {
    serde_json::to_string(&[namespace, key]).expect("json array of two strings is infallible")
}

/// JSON-encode an agent session for storage as a scalar map value.
fn agent_session_json(session: &AgentSession) -> String {
    serde_json::to_string(session).expect("encoding an agent session is infallible")
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use loro::ExportMode;

    use super::*;
    use crate::id::WorkstreamId;
    use crate::workstream::{AgentKind, AgentSession, CheckoutMode, CodeChange, WorkstreamKind};

    fn sample_body() -> WorkstreamBody {
        WorkstreamBody {
            name: "sample".into(),
            status: Status::Active,
            created_at: "1970-01-01T00:00:00Z".into(),
            kind: WorkstreamKind::Basic {
                code_change: CodeChange {
                    source: "https://example.com/x.git".into(),
                    mode: CheckoutMode::JjColocated,
                },
                checkouts: BTreeMap::new(),
                sessions: BTreeMap::new(),
            },
            kv: BTreeMap::new(),
        }
    }

    #[test]
    fn build_then_hydrate_round_trips() {
        let mut body = sample_body();
        body.kv
            .entry("com.example".into())
            .or_default()
            .insert("theme".into(), "\"dark\"".into());
        let WorkstreamKind::Basic { sessions, .. } = &mut body.kind;
        sessions.insert(
            "sid-1".into(),
            AgentSession {
                kind: AgentKind::ClaudeCode,
                name: "planning".into(),
                created_at: "t0".into(),
            },
        );

        let doc = build(7, &body).unwrap();
        let ws = hydrate(WorkstreamId::generate(), &snapshot(&doc).unwrap()).unwrap();
        assert_eq!(ws.body, body);
    }

    /// The heart of the CRDT model: two forests editing the same workstream
    /// concurrently (same kv namespace, different keys; different sessions) must
    /// converge to the union after exchanging updates — now through the nested
    /// `basic` kind container.
    #[test]
    fn concurrent_edits_converge() {
        let base = snapshot(&build(1, &sample_body()).unwrap()).unwrap();

        // Two forests load the same base under distinct peer ids.
        let a = load(10, &base).unwrap();
        let b = load(20, &base).unwrap();

        // Concurrent edits — crucially, the SAME kv namespace on both sides.
        set_kv(&a, "fe", "left", "1").unwrap();
        attach_session(&a, "sess-A", AgentKind::ClaudeCode, "from A", "t0").unwrap();
        set_kv(&b, "fe", "right", "2").unwrap();
        attach_session(&b, "sess-B", AgentKind::ClaudeCode, "from B", "t0").unwrap();

        // Exchange updates in both directions.
        let ua = a.export(ExportMode::all_updates()).unwrap();
        let ub = b.export(ExportMode::all_updates()).unwrap();
        a.import(&ub).unwrap();
        b.import(&ua).unwrap();

        // Both converge to the same merged state...
        let wa = hydrate(WorkstreamId::generate(), &snapshot(&a).unwrap()).unwrap();
        let wb = hydrate(WorkstreamId::generate(), &snapshot(&b).unwrap()).unwrap();
        assert_eq!(wa.body, wb.body);

        // ...which is the union of both forests' edits in the shared namespace.
        assert_eq!(wa.body.kv["fe"]["left"], "1");
        assert_eq!(wa.body.kv["fe"]["right"], "2");
        let sessions = wa.body.sessions().expect("basic kind has sessions");
        assert!(sessions.contains_key("sess-A"));
        assert!(sessions.contains_key("sess-B"));
    }

    /// The public `--json` contract is flat: `kind` is a string discriminant and
    /// the basic kind's data (code_change/checkouts/sessions) plus kv sit at the
    /// top level alongside the id. Frontends (and the CLI e2e tests) depend on it.
    #[test]
    fn public_json_shape_is_flat() {
        let mut body = sample_body();
        let WorkstreamKind::Basic { sessions, .. } = &mut body.kind;
        sessions.insert(
            "sid-1".into(),
            AgentSession {
                kind: AgentKind::ClaudeCode,
                name: "planning".into(),
                created_at: "t0".into(),
            },
        );
        let ws = Workstream {
            id: WorkstreamId::generate(),
            body,
        };

        let json = serde_json::to_value(&ws).unwrap();
        assert!(json["id"].is_string());
        assert_eq!(json["kind"], "basic");
        assert_eq!(json["code_change"]["mode"], "jj-colocated");
        assert!(json["checkouts"].is_object());
        assert_eq!(json["sessions"]["sid-1"]["kind"], "claude-code");
        assert_eq!(json["sessions"]["sid-1"]["name"], "planning");
        assert!(json["kv"].is_object());
    }
}
