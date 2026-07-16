//! The document corpus: round-trip + frozen-byte fixtures.
//!
//! Two layers:
//! - **Round-trip**: current code builds every structure in [`sample_bodies`],
//!   snapshots, and hydrates back to an equal body — plus version-stamp and
//!   already-latest checks.
//! - **Frozen bytes**: real `.loro` snapshots committed under `corpus/vN/` (see
//!   `corpus/README.md`). The current version's bytes guard model drift; older
//!   versions' bytes are genuine *old* bytes that guard the migration path — the
//!   `v1` snapshots stored sessions inside the kind (→ reserved kv namespace), and
//!   the `v2` snapshots had a `code_change` + a per-forest `checkouts` map (→ a
//!   single `mode` + `location`, collapsing to the first checkout).
//!
//! Regenerate the current version's fixtures — and refresh older versions' `.json`
//! projections from their frozen `.loro` — with
//! `SILVERWOOD_REGEN_CORPUS=1 cargo test -p silverwood-core corpus::regenerate`.

use std::path::{Path, PathBuf};

use loro::{ExportMode, LoroDoc};

use super::{any_id, sample_bodies};
use crate::doc;
use crate::error::Error;
use crate::migrate::DOC_SCHEMA_VERSION;

const PEER: u64 = 1;

fn corpus_dir(version: u32) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!("src/tests/corpus/v{version}"))
}

/// Read a `<name>.loro` + `<name>.json` fixture from a version's corpus dir.
fn read_fixture(dir: &Path, name: &str) -> (Vec<u8>, serde_json::Value) {
    let loro_path = dir.join(format!("{name}.loro"));
    let json_path = dir.join(format!("{name}.json"));
    let bytes = std::fs::read(&loro_path).unwrap_or_else(|e| {
        panic!(
            "missing frozen corpus {loro_path:?}: {e}\n(regenerate with SILVERWOOD_REGEN_CORPUS=1)"
        )
    });
    let expected: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&json_path).unwrap()).unwrap();
    (bytes, expected)
}

/// Every structure round-trips, is stamped at the latest version, and reports as
/// already-latest (no migration needed).
#[test]
fn round_trips_all_structures() {
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

/// Frozen current-version bytes hydrate to their committed projection, which must
/// also match today's model (drift guard).
#[test]
fn frozen_current_corpus_hydrates_to_projection() {
    let dir = corpus_dir(DOC_SCHEMA_VERSION);
    for (name, body) in sample_bodies() {
        let (bytes, expected) = read_fixture(&dir, name);
        let ws = doc::hydrate(any_id(), &bytes).unwrap();
        assert_eq!(
            serde_json::to_value(&ws.body).unwrap(),
            expected,
            "{name}: frozen bytes → projection"
        );
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            expected,
            "{name}: model drift — regenerate the corpus"
        );
    }
}

/// The migration guard: frozen **v1** bytes (sessions stored inside the kind) are
/// genuinely old. Reading them migrates v1→v2 — sessions relocate into the
/// reserved kv namespace — and must yield the committed current projection (and
/// today's model) on both the read-old-bytes and rewritten-bytes paths.
#[test]
fn frozen_v1_corpus_migrates_to_current_projection() {
    let dir = corpus_dir(1);
    for (name, body) in sample_bodies() {
        let (bytes, expected) = read_fixture(&dir, name);

        // The frozen bytes really are v1, and migrating rewrites them to latest.
        assert_eq!(
            doc::peek_version(any_id(), &bytes).unwrap(),
            1,
            "{name}: v1"
        );
        let rewritten = doc::migrate_bytes(any_id(), &bytes, PEER)
            .unwrap()
            .unwrap_or_else(|| panic!("{name}: v1 must migrate to a rewrite"));
        assert_eq!(
            doc::peek_version(any_id(), &rewritten).unwrap(),
            DOC_SCHEMA_VERSION,
            "{name}: rewrite is stamped latest"
        );

        // Old bytes and rewritten bytes both hydrate to the current projection.
        for (label, b) in [
            ("old", bytes.as_slice()),
            ("rewritten", rewritten.as_slice()),
        ] {
            let ws = doc::hydrate(any_id(), b).unwrap();
            assert_eq!(
                serde_json::to_value(&ws.body).unwrap(),
                expected,
                "{name} ({label}): migrated projection"
            );
        }
        // The migrated model equals today's model (via the committed json).
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            expected,
            "{name}: model drift — regenerate the corpus"
        );
    }
}

/// The migration guard for **v2** bytes (a `code_change` + a per-forest `checkouts`
/// map). Reading them migrates v2→v3 — the checkouts collapse to a single `mode` +
/// `location` (first checkout wins) — and must yield the committed current
/// projection (and today's model) on both the old-bytes and rewritten-bytes paths.
#[test]
fn frozen_v2_corpus_migrates_to_current_projection() {
    let dir = corpus_dir(2);
    for (name, body) in sample_bodies() {
        let (bytes, expected) = read_fixture(&dir, name);

        // The frozen bytes really are v2, and migrating rewrites them to latest.
        assert_eq!(
            doc::peek_version(any_id(), &bytes).unwrap(),
            2,
            "{name}: v2"
        );
        let rewritten = doc::migrate_bytes(any_id(), &bytes, PEER)
            .unwrap()
            .unwrap_or_else(|| panic!("{name}: v2 must migrate to a rewrite"));
        assert_eq!(
            doc::peek_version(any_id(), &rewritten).unwrap(),
            DOC_SCHEMA_VERSION,
            "{name}: rewrite is stamped latest"
        );

        // Old bytes and rewritten bytes both hydrate to the current projection.
        for (label, b) in [
            ("old", bytes.as_slice()),
            ("rewritten", rewritten.as_slice()),
        ] {
            let ws = doc::hydrate(any_id(), b).unwrap();
            assert_eq!(
                serde_json::to_value(&ws.body).unwrap(),
                expected,
                "{name} ({label}): migrated projection"
            );
        }
        // The migrated model equals today's model (via the committed json).
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            expected,
            "{name}: model drift — regenerate the corpus"
        );
    }
}

/// Regenerate the corpus. A no-op unless `SILVERWOOD_REGEN_CORPUS` is set, so
/// normal test runs never write. Writes the current version's `.loro` + `.json`
/// fixtures from the live model, and refreshes older versions' `.json` projection
/// sidecars from their **frozen** `.loro` bytes — never rewriting those bytes,
/// which would defeat the read-old-bytes guard. Review + commit the diff.
#[test]
fn regenerate() {
    if std::env::var("SILVERWOOD_REGEN_CORPUS").is_err() {
        return;
    }

    // Current version: (re)write both bytes and projection from the live model.
    let cur = corpus_dir(DOC_SCHEMA_VERSION);
    std::fs::create_dir_all(&cur).unwrap();
    for (name, body) in sample_bodies() {
        let doc = doc::build(PEER, &body).unwrap();
        std::fs::write(
            cur.join(format!("{name}.loro")),
            doc::snapshot(&doc).unwrap(),
        )
        .unwrap();
        std::fs::write(
            cur.join(format!("{name}.json")),
            serde_json::to_string_pretty(&body).unwrap(),
        )
        .unwrap();
    }

    // Older versions: refresh only the projection sidecars from their frozen bytes
    // (hydration migrates them up to the latest model).
    for version in 1..DOC_SCHEMA_VERSION {
        let dir = corpus_dir(version);
        for (name, _) in sample_bodies() {
            let Ok(bytes) = std::fs::read(dir.join(format!("{name}.loro"))) else {
                continue;
            };
            let ws = doc::hydrate(any_id(), &bytes).unwrap();
            std::fs::write(
                dir.join(format!("{name}.json")),
                serde_json::to_string_pretty(&ws.body).unwrap(),
            )
            .unwrap();
        }
    }
}
