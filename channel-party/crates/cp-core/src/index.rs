//! Index substrates. `index(payload) -> IndexEntry` (DESIGN §6) is a pure function applied
//! transactionally on write into core's built-in substrates: FTS5 (trigram tokenizer -> true
//! substring search) for name/body text, expression indexes for declared sort keys, and a 2D /
//! R-tree substrate for coordinates. The projection type lives in `cp-model`; wiring it into the
//! substrates is deferred slice work.

use cp_model::IndexEntry;

/// Write a kind's inline projection into the index substrates, transactionally with the envelope
/// write. §6. Stub: the substrates are not yet created.
pub fn write_entry(_entry: &IndexEntry) {
    // TODO(§6): FTS5 upsert (name/text), sort-key expression index, R-tree coord.
}
