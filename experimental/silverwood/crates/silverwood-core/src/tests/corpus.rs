//! The v1 document corpus.
//!
//! Two layers:
//! - **Round-trip**: current code builds every structure in [`sample_bodies`],
//!   snapshots, and hydrates back to an equal body — plus version-stamp and
//!   already-latest checks.
//! - **Frozen bytes**: real v1 `.loro` snapshots committed under `corpus/v1/`
//!   (see `corpus/README.md`) hydrate to their committed projection. This guards
//!   the day v2 lands and these become genuinely *old* bytes. Regenerate with
//!   `SILVERWOOD_REGEN_CORPUS=1 cargo test -p silverwood-core corpus::regenerate`.

use std::path::PathBuf;

use loro::{ExportMode, LoroDoc};

use super::{any_id, sample_bodies};
use crate::doc;
use crate::error::Error;
use crate::migrate::DOC_SCHEMA_VERSION;

const PEER: u64 = 1;

fn corpus_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/tests/corpus/v1")
}

/// Every structure round-trips, is stamped at the latest version, and reports as
/// already-latest (no migration needed).
#[test]
fn v1_round_trips_all_structures() {
    for (name, body) in sample_bodies() {
        let doc = doc::build(PEER, &body).unwrap();
        let bytes = doc::snapshot(&doc).unwrap();

        assert_eq!(
            doc::peek_version(any_id(), &bytes).unwrap(),
            DOC_SCHEMA_VERSION,
            "{name}: version stamp"
        );
        assert!(
            doc::migrate_bytes(any_id(), &bytes, PEER)
                .unwrap()
                .is_none(),
            "{name}: already latest, no rewrite"
        );

        let ws = doc::hydrate(any_id(), &bytes).unwrap();
        assert_eq!(ws.body, body, "{name}: round-trip");
    }
}

/// A document declaring a version newer than this build supports is rejected on
/// every read/upgrade path, and its version is still readable.
#[test]
fn future_version_is_rejected() {
    let doc = LoroDoc::new();
    doc.set_peer_id(PEER).unwrap();
    // A version-only root is enough: the version gate runs before decode.
    doc.get_map("workstream")
        .insert("schema_version", (DOC_SCHEMA_VERSION + 5) as i64)
        .unwrap();
    doc.commit();
    let bytes = doc.export(ExportMode::snapshot()).unwrap();

    assert_eq!(
        doc::peek_version(any_id(), &bytes).unwrap(),
        DOC_SCHEMA_VERSION + 5
    );
    assert!(matches!(
        doc::hydrate(any_id(), &bytes),
        Err(Error::SchemaTooNew { found, supported })
            if found == DOC_SCHEMA_VERSION + 5 && supported == DOC_SCHEMA_VERSION
    ));
    assert!(matches!(
        doc::migrate_bytes(any_id(), &bytes, PEER),
        Err(Error::SchemaTooNew { .. })
    ));
}

/// Frozen v1 bytes (produced by an earlier run and committed) hydrate to their
/// committed projection. When these are still v1==latest this also guards model
/// drift; once v2 lands it becomes the real read-old-bytes migration guard.
#[test]
fn frozen_v1_corpus_hydrates_to_projection() {
    let dir = corpus_dir();
    for (name, body) in sample_bodies() {
        let loro_path = dir.join(format!("{name}.loro"));
        let json_path = dir.join(format!("{name}.json"));
        let bytes = std::fs::read(&loro_path).unwrap_or_else(|e| {
            panic!("missing frozen corpus {loro_path:?}: {e}\n(regenerate with SILVERWOOD_REGEN_CORPUS=1)")
        });
        let expected: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&json_path).unwrap()).unwrap();

        let ws = doc::hydrate(any_id(), &bytes).unwrap();
        assert_eq!(
            serde_json::to_value(&ws.body).unwrap(),
            expected,
            "{name}: frozen bytes → projection"
        );
        // The committed projection must also match today's model (drift guard).
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            expected,
            "{name}: model drift — regenerate the corpus"
        );
    }
}

/// Regenerate the frozen corpus on disk. A no-op unless `SILVERWOOD_REGEN_CORPUS`
/// is set, so normal test runs never write. Run it after intentionally changing a
/// v1 sample, then commit the updated `corpus/v1/*` fixtures.
#[test]
fn regenerate() {
    if std::env::var("SILVERWOOD_REGEN_CORPUS").is_err() {
        return;
    }
    let dir = corpus_dir();
    std::fs::create_dir_all(&dir).unwrap();
    for (name, body) in sample_bodies() {
        let doc = doc::build(PEER, &body).unwrap();
        std::fs::write(
            dir.join(format!("{name}.loro")),
            doc::snapshot(&doc).unwrap(),
        )
        .unwrap();
        std::fs::write(
            dir.join(format!("{name}.json")),
            serde_json::to_string_pretty(&body).unwrap(),
        )
        .unwrap();
    }
}
