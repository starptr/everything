//! Mapping between a [`Workstream`] and its Loro document.
//!
//! One `LoroDoc` per workstream. Loro has no derive layer, so this module owns
//! the container⇄struct translation by hand. Writes go through typed containers;
//! reads hydrate via `get_deep_value()` + serde. Mutations of an existing
//! document reuse its containers (load → edit in place → snapshot) so document
//! lineage — and therefore future mergeability — is preserved.
//!
//! ## Why kv and sessions are flat maps of strings
//!
//! Concurrently creating the *same* nested-container key on two forests is
//! unsafe: each forest makes a distinct container and the parent map LWW-picks
//! one, silently dropping the other's contents. `checkouts` avoids this by
//! keying on forest id (no two forests write the same key), but `kv` namespaces
//! and `sessions` ids are naturally shared. So kv and sessions store *scalar
//! string* values in a single genesis-created map — kv keyed by a JSON
//! `["namespace","key"]`, sessions keyed by session id with a JSON-encoded
//! [`Session`] value. Independent entries then merge as ordinary LWW keys.

use loro::{Container, ExportMode, LoroDoc, LoroMap, ValueOrContainer};
use serde::Deserialize;

use crate::error::{Error, Result};
use crate::id::WorkstreamId;
use crate::workstream::{
    Checkout, CheckoutPrimitive, CheckoutState, Session, Status, Workstream, WorkstreamBody,
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
    root.insert("kind", body.kind.as_str()).map_err(loro_err)?;
    root.insert("created_at", body.created_at.as_str())
        .map_err(loro_err)?;

    let primitive = root
        .insert_container("primitive", LoroMap::new())
        .map_err(loro_err)?;
    primitive
        .insert("source", body.primitive.source.as_str())
        .map_err(loro_err)?;
    primitive
        .insert("mode", body.primitive.mode.as_str())
        .map_err(loro_err)?;

    // checkouts: nested map-of-maps, safe because keyed by forest id.
    let checkouts = root
        .insert_container("checkouts", LoroMap::new())
        .map_err(loro_err)?;
    for (forest_id, checkout) in &body.checkouts {
        write_checkout(&checkouts, forest_id, checkout)?;
    }

    // sessions + kv: flat maps of scalar strings (see module docs).
    let sessions = root
        .insert_container("sessions", LoroMap::new())
        .map_err(loro_err)?;
    for (session_id, session) in &body.sessions {
        sessions
            .insert(session_id.as_str(), session_json(session))
            .map_err(loro_err)?;
    }
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

/// Hydrate a [`Workstream`] from stored bytes.
pub(crate) fn hydrate(id: WorkstreamId, bytes: &[u8]) -> Result<Workstream> {
    let doc = LoroDoc::new();
    doc.import(bytes).map_err(loro_err)?;
    let value = doc.get_map(ROOT).get_deep_value();
    let json = serde_json::to_value(&value)
        .map_err(|e| Error::Corrupt(format!("workstream {id} not serializable: {e}")))?;
    let stored: StoredBody = serde_json::from_value(json)
        .map_err(|e| Error::Corrupt(format!("workstream {id}: {e}")))?;
    Ok(Workstream {
        id,
        body: stored.into_body(id)?,
    })
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
    let root = doc.get_map(ROOT);
    let checkouts = child_map(&root, "checkouts")?;
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

/// Attach a Claude session. Errors if `session_id` is already attached.
pub(crate) fn attach_session(
    doc: &LoroDoc,
    session_id: &str,
    name: &str,
    created_at: &str,
) -> Result<()> {
    let sessions = child_map(&doc.get_map(ROOT), "sessions")?;
    if sessions.get(session_id).is_some() {
        return Err(Error::SessionExists(session_id.to_string()));
    }
    let session = Session {
        name: name.to_string(),
        created_at: created_at.to_string(),
    };
    sessions
        .insert(session_id, session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Rename an attached session (preserving its `created_at`). Errors if absent.
pub(crate) fn rename_session(doc: &LoroDoc, session_id: &str, name: &str) -> Result<()> {
    let sessions = child_map(&doc.get_map(ROOT), "sessions")?;
    let existing = sessions
        .get(session_id)
        .and_then(value_as_string)
        .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?;
    let mut session: Session = serde_json::from_str(&existing)
        .map_err(|e| Error::Corrupt(format!("session {session_id}: {e}")))?;
    session.name = name.to_string();
    sessions
        .insert(session_id, session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Detach a session. A no-op if it is not attached.
pub(crate) fn detach_session(doc: &LoroDoc, session_id: &str) -> Result<()> {
    let sessions = child_map(&doc.get_map(ROOT), "sessions")?;
    if sessions.get(session_id).is_some() {
        sessions.delete(session_id).map_err(loro_err)?;
        doc.commit();
    }
    Ok(())
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

/// JSON-encode a session for storage as a scalar map value.
fn session_json(session: &Session) -> String {
    serde_json::to_string(session).expect("encoding a session is infallible")
}

/// The document's stored shape, before kv/sessions are un-flattened into the
/// nested [`WorkstreamBody`].
#[derive(Deserialize)]
struct StoredBody {
    name: String,
    status: Status,
    kind: String,
    created_at: String,
    primitive: CheckoutPrimitive,
    #[serde(default)]
    checkouts: std::collections::BTreeMap<String, Checkout>,
    /// session id → JSON-encoded `Session`.
    #[serde(default)]
    sessions: std::collections::BTreeMap<String, String>,
    /// JSON `["namespace","key"]` → value.
    #[serde(default)]
    kv: std::collections::BTreeMap<String, String>,
}

impl StoredBody {
    fn into_body(self, id: WorkstreamId) -> Result<WorkstreamBody> {
        let mut sessions = std::collections::BTreeMap::new();
        for (session_id, encoded) in self.sessions {
            let session: Session = serde_json::from_str(&encoded).map_err(|e| {
                Error::Corrupt(format!("workstream {id} session {session_id}: {e}"))
            })?;
            sessions.insert(session_id, session);
        }

        let mut kv: std::collections::BTreeMap<String, std::collections::BTreeMap<String, String>> =
            std::collections::BTreeMap::new();
        for (composite, value) in self.kv {
            let [namespace, key]: [String; 2] = serde_json::from_str(&composite).map_err(|e| {
                Error::Corrupt(format!("workstream {id} kv key {composite:?}: {e}"))
            })?;
            kv.entry(namespace).or_default().insert(key, value);
        }

        Ok(WorkstreamBody {
            name: self.name,
            status: self.status,
            kind: self.kind,
            created_at: self.created_at,
            primitive: self.primitive,
            checkouts: self.checkouts,
            sessions,
            kv,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use loro::ExportMode;

    use super::*;
    use crate::id::WorkstreamId;
    use crate::workstream::{CheckoutMode, CODE_CHECKOUT_KIND};

    fn sample_body() -> WorkstreamBody {
        WorkstreamBody {
            name: "sample".into(),
            status: Status::Active,
            kind: CODE_CHECKOUT_KIND.into(),
            created_at: "1970-01-01T00:00:00Z".into(),
            primitive: CheckoutPrimitive {
                source: "https://example.com/x.git".into(),
                mode: CheckoutMode::JjColocated,
            },
            checkouts: BTreeMap::new(),
            sessions: BTreeMap::new(),
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
        body.sessions.insert(
            "sid-1".into(),
            Session {
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
    /// converge to the union after exchanging updates.
    #[test]
    fn concurrent_edits_converge() {
        let base = snapshot(&build(1, &sample_body()).unwrap()).unwrap();

        // Two forests load the same base under distinct peer ids.
        let a = load(10, &base).unwrap();
        let b = load(20, &base).unwrap();

        // Concurrent edits — crucially, the SAME kv namespace on both sides.
        set_kv(&a, "fe", "left", "1").unwrap();
        attach_session(&a, "sess-A", "from A", "t0").unwrap();
        set_kv(&b, "fe", "right", "2").unwrap();
        attach_session(&b, "sess-B", "from B", "t0").unwrap();

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
        assert!(wa.body.sessions.contains_key("sess-A"));
        assert!(wa.body.sessions.contains_key("sess-B"));
    }
}
