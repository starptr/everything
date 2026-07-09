//! Index substrates. `index(payload) -> IndexEntry` (DESIGN §6) is written transactionally with the
//! envelope by the write path. This implements the **FTS5** substrate (`search_index`, trigram) for
//! `name`/`text`, which `StoreCtx::search` queries. The other two `IndexEntry` fields have no consumer
//! yet: `sort_key` (expression index) and `coord` (R-tree) wait on `canvas` (`TODO.md` #11) and are
//! ignored here rather than built speculatively. See `design/index-search.md`.

use cp_model::{IndexEntry, Result};

use crate::events::EnvelopeRef;

/// The `(super_type, envelope_id)` a row is keyed by — both derived from the `EnvelopeRef`, so no
/// extra argument is needed on the write path.
fn key(target: EnvelopeRef) -> (&'static str, String) {
    match target {
        EnvelopeRef::Channel(id) => ("channel", id.to_string()),
        EnvelopeRef::Item(id) => ("item", id.to_string()),
    }
}

fn db(e: sqlx::Error) -> cp_model::Error {
    cp_model::Error::Other(e.to_string())
}

/// Write a kind's inline projection into `search_index`, in the caller's transaction. §6. FTS5 has no
/// unique constraint, so this is delete-then-insert keyed by envelope; an entry with neither `name` nor
/// `text` inserts no row (nothing to search). `sort_key`/`coord` are #11's substrates, ignored here.
pub async fn upsert(
    tx: &mut sqlx::SqliteConnection,
    target: EnvelopeRef,
    entry: &IndexEntry,
) -> Result<()> {
    delete(tx, target).await?;
    if entry.name.is_none() && entry.text.is_none() {
        return Ok(());
    }
    let (super_type, id) = key(target);
    sqlx::query(
        "INSERT INTO search_index (name, text, envelope_id, super_type) VALUES (?, ?, ?, ?)",
    )
    .bind(entry.name.as_deref())
    .bind(entry.text.as_deref())
    .bind(id)
    .bind(super_type)
    .execute(&mut *tx)
    .await
    .map_err(db)?;
    Ok(())
}

/// Remove an envelope's `search_index` row (on delete/before re-upsert), in the caller's transaction.
/// Only the directly-targeted envelope is purged; FK-cascaded children orphan their rows, which the
/// INNER JOIN in `search` renders invisible (see the design note). §6.
pub async fn delete(tx: &mut sqlx::SqliteConnection, target: EnvelopeRef) -> Result<()> {
    let (super_type, id) = key(target);
    sqlx::query("DELETE FROM search_index WHERE envelope_id = ? AND super_type = ?")
        .bind(id)
        .bind(super_type)
        .execute(&mut *tx)
        .await
        .map_err(db)?;
    Ok(())
}
