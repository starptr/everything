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
//! and a root-level `kv` map. The `basic` container nests `mode` (the checkout
//! mode — `checkout_mode` tag + `initial_source` + `state`) and `location`
//! (`forest_id` + a `within` map: `forest_kind` tag + `path`). A basic workstream
//! is single-forest, so `location` is one value, not a per-forest map. Agent
//! sessions are **not** a kind container: they are ordinary `kv` entries under the
//! core-reserved [`SESSION_NS`].
//!
//! ## Merge-safety invariant
//!
//! Concurrently creating the *same* nested-container key on two forests is
//! unsafe: each forest makes a distinct container and the parent map LWW-picks
//! one, silently dropping the other's contents. We avoid this by only ever
//! creating containers **once, at genesis in [`build`]** — the `kind` is fixed
//! at creation and the `basic`/`mode`/`location`/`within`/`kv` containers are
//! never lazily re-created in a mutator (mutators fetch them with `child_map`,
//! which errors if absent). Two forests derive from the same base snapshot, so
//! they share those container ids.
//!
//! Within those genesis containers, `kv` stores *scalar string* values keyed by
//! JSON `["namespace","key"]` so independent entries merge as ordinary LWW keys
//! (sessions, living under [`SESSION_NS`], merge the same way). The basic kind's
//! `mode.state` and `location` are plain LWW registers: since a basic workstream
//! is materialized in a single forest, there is no concurrent-materialization case
//! to key apart (a future multi-forest kind would reintroduce per-forest keying).

use loro::{Container, ExportMode, LoroDoc, LoroMap, ValueOrContainer};

use crate::error::{Error, Result};
use crate::id::WorkstreamId;
use crate::migrate;
use crate::workstream::{
    AgentKind, AgentSession, CheckoutMode, CheckoutState, Location, LocationWithinForest,
    SessionLock, Status, Workstream, WorkstreamBody, WorkstreamKind, BASIC_KIND, SESSION_NS,
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
        WorkstreamKind::Basic { mode, location } => {
            let basic = root
                .insert_container(BASIC_KIND, LoroMap::new())
                .map_err(loro_err)?;
            write_mode(&basic, mode)?;
            write_location(&basic, location)?;
        }
    }

    // kv: flat map of scalar strings at the root — kind-agnostic frontend state.
    // Sessions ride along here too, under the reserved SESSION_NS (see module docs).
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

/// Overwrite the root `name` scalar (used to rename a workstream).
pub(crate) fn set_name(doc: &LoroDoc, name: &str) -> Result<()> {
    doc.get_map(ROOT).insert("name", name).map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Overwrite the checkout `state` scalar inside the basic container's `mode` map,
/// in place (the single per-workstream provisioning state).
pub(crate) fn set_state(doc: &LoroDoc, state: CheckoutState) -> Result<()> {
    let mode = child_map(&basic_map(doc)?, "mode")?;
    mode.insert("state", state.as_str()).map_err(loro_err)?;
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

/// Create an agent session — a scalar entry in the root `kv` map under the
/// reserved [`SESSION_NS`], keyed by session id. Errors if already present.
pub(crate) fn create_session(
    doc: &LoroDoc,
    session_id: &str,
    agent_kind: AgentKind,
    name: &str,
    created_at: &str,
) -> Result<()> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    let composite = kv_key(SESSION_NS, session_id);
    if kv.get(&composite).is_some() {
        return Err(Error::SessionExists(session_id.to_string()));
    }
    let session = AgentSession {
        kind: agent_kind,
        name: name.to_string(),
        created_at: created_at.to_string(),
    };
    kv.insert(composite.as_str(), agent_session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Rename a session (preserving its `kind` and `created_at`). Errors if absent.
pub(crate) fn rename_session(doc: &LoroDoc, session_id: &str, name: &str) -> Result<()> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    let composite = kv_key(SESSION_NS, session_id);
    let existing = kv
        .get(&composite)
        .and_then(value_as_string)
        .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?;
    let mut session: AgentSession = serde_json::from_str(&existing)
        .map_err(|e| Error::Corrupt(format!("session {session_id}: {e}")))?;
    session.name = name.to_string();
    kv.insert(composite.as_str(), agent_session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Remove a session. A no-op if it is not present.
pub(crate) fn remove_session(doc: &LoroDoc, session_id: &str) -> Result<()> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    let composite = kv_key(SESSION_NS, session_id);
    if kv.get(&composite).is_some() {
        kv.delete(&composite).map_err(loro_err)?;
        doc.commit();
    }
    Ok(())
}

/// Read a session's decoded record from the reserved [`SESSION_NS`], or `None`
/// if it is not present.
pub(crate) fn get_session(doc: &LoroDoc, session_id: &str) -> Result<Option<AgentSession>> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    let composite = kv_key(SESSION_NS, session_id);
    match kv.get(&composite).and_then(value_as_string) {
        None => Ok(None),
        Some(encoded) => serde_json::from_str(&encoded)
            .map(Some)
            .map_err(|e| Error::Corrupt(format!("session {session_id}: {e}"))),
    }
}

/// Set (or clear, with `None`) the advisory lock on a claude-code session,
/// preserving its other fields. Errors [`Error::SessionNotFound`] if absent.
pub(crate) fn set_session_lock(
    doc: &LoroDoc,
    session_id: &str,
    lock: Option<SessionLock>,
) -> Result<()> {
    let kv = child_map(&doc.get_map(ROOT), "kv")?;
    let composite = kv_key(SESSION_NS, session_id);
    let existing = kv
        .get(&composite)
        .and_then(value_as_string)
        .ok_or_else(|| Error::SessionNotFound(session_id.to_string()))?;
    let mut session: AgentSession = serde_json::from_str(&existing)
        .map_err(|e| Error::Corrupt(format!("session {session_id}: {e}")))?;
    match &mut session.kind {
        AgentKind::ClaudeCode { lock: slot } => *slot = lock,
        // A plain shell has no lock slot; refuse rather than silently drop the request.
        AgentKind::PlainShell {} => {
            return Err(Error::SessionNotLockable {
                session_id: session_id.to_string(),
                kind: session.kind.tag().to_string(),
            });
        }
    }
    kv.insert(composite.as_str(), agent_session_json(&session))
        .map_err(loro_err)?;
    doc.commit();
    Ok(())
}

/// Fetch the genesis-created `basic` kind container for in-place mutation. It is
/// created once in [`build`] and the kind is immutable, so it is always present
/// for a basic workstream (see the merge-safety invariant).
fn basic_map(doc: &LoroDoc) -> Result<LoroMap> {
    child_map(&doc.get_map(ROOT), BASIC_KIND)
}

/// Write the checkout `mode` as a fresh nested map under the basic container
/// (`checkout_mode` tag + the variant's fields).
fn write_mode(basic: &LoroMap, mode: &CheckoutMode) -> Result<()> {
    let map = basic
        .insert_container("mode", LoroMap::new())
        .map_err(loro_err)?;
    map.insert("checkout_mode", mode.tag()).map_err(loro_err)?;
    // Every mode carries the same two fields (`initial_source` + `state`); only the tag
    // (above) differs.
    match mode {
        CheckoutMode::JjColocated {
            initial_source,
            state,
        }
        | CheckoutMode::JjColocatedDirenvUnsafe {
            initial_source,
            state,
        }
        | CheckoutMode::ApfsCow {
            initial_source,
            state,
        }
        | CheckoutMode::ApfsCowDirenvUnsafe {
            initial_source,
            state,
        } => {
            map.insert("initial_source", initial_source.as_str())
                .map_err(loro_err)?;
            map.insert("state", state.as_str()).map_err(loro_err)?;
        }
    }
    Ok(())
}

/// Write the checkout `location` as a fresh nested map under the basic container
/// (`forest_id` + a `within` child map carrying the forest-kind-specific fields).
fn write_location(basic: &LoroMap, location: &Location) -> Result<()> {
    let map = basic
        .insert_container("location", LoroMap::new())
        .map_err(loro_err)?;
    let forest_id = location.forest_id.to_string();
    map.insert("forest_id", forest_id.as_str())
        .map_err(loro_err)?;
    let within = map
        .insert_container("within", LoroMap::new())
        .map_err(loro_err)?;
    within
        .insert("forest_kind", location.within.tag())
        .map_err(loro_err)?;
    match &location.within {
        LocationWithinForest::BasicForest { path } => {
            within.insert("path", path.as_str()).map_err(loro_err)?;
        }
    }
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
    use crate::id::{ForestId, WorkstreamId};
    use crate::workstream::{AgentKind, AgentSession, CheckoutMode, WorkstreamKind};

    fn sample_body() -> WorkstreamBody {
        WorkstreamBody {
            name: "sample".into(),
            status: Status::Active,
            created_at: "1970-01-01T00:00:00Z".into(),
            kind: WorkstreamKind::Basic {
                mode: CheckoutMode::JjColocated {
                    initial_source: "https://example.com/x.git".into(),
                    state: CheckoutState::Ready,
                },
                location: Location {
                    forest_id: ForestId::generate(),
                    within: LocationWithinForest::BasicForest {
                        path: "/tmp/x".into(),
                    },
                },
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
        // A session is just a reserved-namespace kv entry (see SESSION_NS).
        body.kv.entry(SESSION_NS.into()).or_default().insert(
            "sid-1".into(),
            agent_session_json(&AgentSession {
                kind: AgentKind::ClaudeCode { lock: None },
                name: "planning".into(),
                created_at: "t0".into(),
            }),
        );

        let doc = build(7, &body).unwrap();
        let ws = hydrate(WorkstreamId::generate(), &snapshot(&doc).unwrap()).unwrap();
        assert_eq!(ws.body, body);
        // The typed session view decodes the reserved namespace.
        assert_eq!(ws.body.sessions()["sid-1"].name, "planning");
    }

    /// The `jj-colocated-direnv-unsafe` mode round-trips through build → hydrate and
    /// projects the expected flat `checkout_mode` tag (it carries the same fields as
    /// `jj-colocated`, so `write_mode`/serde must distinguish it by tag alone).
    #[test]
    fn direnv_unsafe_mode_round_trips() {
        let mut body = sample_body();
        body.kind = WorkstreamKind::Basic {
            mode: CheckoutMode::JjColocatedDirenvUnsafe {
                initial_source: "https://example.com/x.git".into(),
                state: CheckoutState::Ready,
            },
            location: body.location().unwrap().clone(),
        };

        let doc = build(7, &body).unwrap();
        let ws = hydrate(WorkstreamId::generate(), &snapshot(&doc).unwrap()).unwrap();
        assert_eq!(ws.body, body);
        let json = serde_json::to_value(&ws).unwrap();
        assert_eq!(json["mode"]["checkout_mode"], "jj-colocated-direnv-unsafe");
        assert_eq!(json["mode"]["initial_source"], "https://example.com/x.git");
    }

    /// The `apfs-cow` mode round-trips through build → hydrate: its `initial_source`
    /// holds a local path (not a url) and it projects the `apfs-cow` tag.
    #[test]
    fn apfs_cow_mode_round_trips() {
        let mut body = sample_body();
        body.kind = WorkstreamKind::Basic {
            mode: CheckoutMode::ApfsCow {
                initial_source: "/Users/x/repo".into(),
                state: CheckoutState::Ready,
            },
            location: body.location().unwrap().clone(),
        };

        let doc = build(7, &body).unwrap();
        let ws = hydrate(WorkstreamId::generate(), &snapshot(&doc).unwrap()).unwrap();
        assert_eq!(ws.body, body);
        let json = serde_json::to_value(&ws).unwrap();
        assert_eq!(json["mode"]["checkout_mode"], "apfs-cow");
        assert_eq!(json["mode"]["initial_source"], "/Users/x/repo");
    }

    /// The `apfs-cow-direnv-unsafe` mode round-trips through build → hydrate: it carries
    /// the same fields as `apfs-cow` (a local-path `initial_source`), so `write_mode`/serde
    /// must distinguish it by tag alone.
    #[test]
    fn apfs_cow_direnv_unsafe_mode_round_trips() {
        let mut body = sample_body();
        body.kind = WorkstreamKind::Basic {
            mode: CheckoutMode::ApfsCowDirenvUnsafe {
                initial_source: "/Users/x/repo".into(),
                state: CheckoutState::Ready,
            },
            location: body.location().unwrap().clone(),
        };

        let doc = build(7, &body).unwrap();
        let ws = hydrate(WorkstreamId::generate(), &snapshot(&doc).unwrap()).unwrap();
        assert_eq!(ws.body, body);
        let json = serde_json::to_value(&ws).unwrap();
        assert_eq!(json["mode"]["checkout_mode"], "apfs-cow-direnv-unsafe");
        assert_eq!(json["mode"]["initial_source"], "/Users/x/repo");
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
        create_session(
            &a,
            "sess-A",
            AgentKind::ClaudeCode { lock: None },
            "from A",
            "t0",
        )
        .unwrap();
        set_kv(&b, "fe", "right", "2").unwrap();
        create_session(
            &b,
            "sess-B",
            AgentKind::ClaudeCode { lock: None },
            "from B",
            "t0",
        )
        .unwrap();

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
        let sessions = wa.body.sessions();
        assert!(sessions.contains_key("sess-A"));
        assert!(sessions.contains_key("sess-B"));
    }

    /// The public `--json` contract is flat: `kind` is a string discriminant and
    /// the basic kind's data (mode/location) plus kv sit at the top level alongside
    /// the id. Sessions are *not* a top-level field — they are kv entries under the
    /// reserved [`SESSION_NS`]. Frontends + the CLI e2e tests depend on it.
    #[test]
    fn public_json_shape_is_flat() {
        let mut body = sample_body();
        body.kv.entry(SESSION_NS.into()).or_default().insert(
            "sid-1".into(),
            agent_session_json(&AgentSession {
                kind: AgentKind::ClaudeCode { lock: None },
                name: "planning".into(),
                created_at: "t0".into(),
            }),
        );
        let ws = Workstream {
            id: WorkstreamId::generate(),
            body,
        };

        let json = serde_json::to_value(&ws).unwrap();
        assert!(json["id"].is_string());
        assert_eq!(json["kind"], "basic");
        assert_eq!(json["mode"]["checkout_mode"], "jj-colocated");
        assert_eq!(json["mode"]["state"], "ready");
        assert!(json["mode"]["initial_source"].is_string());
        assert_eq!(json["location"]["within"]["forest_kind"], "basic-forest");
        assert!(json["location"]["within"]["path"].is_string());
        assert!(json["kv"].is_object());
        // No top-level `sessions`; they live in the reserved kv namespace as
        // JSON-string values that decode back to an AgentSession.
        assert!(json.get("sessions").is_none());
        let encoded = json["kv"][SESSION_NS]["sid-1"].as_str().unwrap();
        let session: AgentSession = serde_json::from_str(encoded).unwrap();
        assert_eq!(session.kind, AgentKind::ClaudeCode { lock: None });
        assert_eq!(session.name, "planning");
    }

    /// A `plain-shell` session round-trips like any other: it serializes to the flat
    /// `{"kind":"plain-shell",…}` wire shape, carries no lock, rename preserves its
    /// kind, and locking it is refused (it has no lock slot).
    #[test]
    fn plain_shell_session_roundtrip() {
        let doc = build(1, &sample_body()).unwrap();
        create_session(&doc, "sh-1", AgentKind::PlainShell {}, "shell", "t0").unwrap();

        let session = get_session(&doc, "sh-1").unwrap().unwrap();
        assert_eq!(session.kind, AgentKind::PlainShell {});
        assert_eq!(session.kind.tag(), "plain-shell");
        assert_eq!(session.lock(), None);

        // Flat wire shape (no `lock` field), and it decodes back.
        let encoded = agent_session_json(&session);
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&encoded).unwrap(),
            serde_json::json!({"kind": "plain-shell", "name": "shell", "created_at": "t0"}),
        );

        // Rename preserves the kind + created_at.
        rename_session(&doc, "sh-1", "my shell").unwrap();
        let renamed = get_session(&doc, "sh-1").unwrap().unwrap();
        assert_eq!(renamed.name, "my shell");
        assert_eq!(renamed.kind, AgentKind::PlainShell {});
        assert_eq!(renamed.created_at, "t0");

        // A plain shell has no lock slot: locking is refused.
        let err = set_session_lock(
            &doc,
            "sh-1",
            Some(crate::workstream::SessionLock {
                holder: "A".into(),
                acquired_at: "t1".into(),
            }),
        )
        .unwrap_err();
        assert!(matches!(err, Error::SessionNotLockable { .. }));
    }
}
