//! Mapping between a [`Workstream`] and its Loro document.
//!
//! One `LoroDoc` per workstream. Loro has no derive layer, so this module owns
//! the container⇄struct translation by hand. Writes go through typed containers;
//! reads hydrate via `get_deep_value()` + serde. Mutations of an existing
//! document reuse its containers (load → edit in place → snapshot) so document
//! lineage — and therefore future mergeability — is preserved.

use loro::{Container, ExportMode, LoroDoc, LoroMap, ValueOrContainer};

use crate::error::{Error, Result};
use crate::id::WorkstreamId;
use crate::workstream::{Checkout, CheckoutState, Status, Workstream, WorkstreamBody};

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

    let checkouts = root
        .insert_container("checkouts", LoroMap::new())
        .map_err(loro_err)?;
    for (forest_id, checkout) in &body.checkouts {
        write_checkout(&checkouts, forest_id, checkout)?;
    }

    // Empty collection containers, created once so later edits mutate in place.
    root.insert_container("sessions", LoroMap::new())
        .map_err(loro_err)?;
    root.insert_container("kv", LoroMap::new())
        .map_err(loro_err)?;

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
    let body: WorkstreamBody = serde_json::from_value(json)
        .map_err(|e| Error::Corrupt(format!("workstream {id}: {e}")))?;
    Ok(Workstream { id, body })
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
