//! In-crate test harness for schema versioning, migration, and CRDT convergence.
//!
//! These live in `src/` (not `tests/`) because they exercise `pub(crate)`
//! internals (`doc::build`/`hydrate`/`migrate_bytes`, `migrate::*`) and drive the
//! Loro engine directly, which an integration test crate cannot reach.
//!
//! - [`loro_invariants`] — empirical probes of the two under-documented Loro
//!   behaviours the migration design assumes.
//! - [`corpus`] — round-trip over every document structure, plus a frozen byte
//!   corpus (real old bytes) that guards the migration path — see `corpus/README.md`.
//! - [`convergence`] — the real schema: K forests, random concurrent ops, all
//!   sync orderings converge to the union (no loss).
//! - [`synthetic`] — a self-contained two-version toy schema proving migration +
//!   convergence across a version bump under the barrier model.

mod convergence;
mod corpus;
mod loro_invariants;
mod synthetic;

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::id::ForestId;
use crate::workstream::{
    AgentSession, CheckoutMode, CheckoutState, Location, LocationWithinForest, SessionKind, Status,
    WorkstreamBody, WorkstreamKind, SESSION_NS,
};

/// A canonical set of bodies covering the structures a document can hold:
/// never-provisioned (pending, empty path), each ready/failed state, multiple
/// sessions, multi-namespace kv, archived, and unicode/edge strings. The
/// round-trip and frozen-corpus tests iterate this set.
///
/// Each body is authored to equal what the corresponding frozen **pre-v3** corpus
/// entry migrates to: those entries had multiple per-forest checkouts keyed by
/// non-UUID strings, so migration collapses them to the first checkout (by key
/// order) with a nil `forest_id`. Hence every body here is single-location with a
/// nil forest id — see [`basic`] and the migration in `migrate.rs`.
pub(super) fn sample_bodies() -> Vec<(&'static str, WorkstreamBody)> {
    vec![
        (
            "minimal",
            basic("minimal", "", CheckoutState::Pending, &[], &[]),
        ),
        (
            "one-checkout",
            basic("one-checkout", "/tmp/a", CheckoutState::Ready, &[], &[]),
        ),
        (
            // Migrates from three checkouts → the first (forest-a: /tmp/a, ready).
            "multi-checkout",
            basic("multi-checkout", "/tmp/a", CheckoutState::Ready, &[], &[]),
        ),
        (
            "sessions",
            basic(
                "sessions",
                "/tmp/a",
                CheckoutState::Ready,
                &[("sid-1", "planning"), ("sid-2", "impl")],
                &[],
            ),
        ),
        (
            "kv",
            basic(
                "kv",
                "",
                CheckoutState::Pending,
                &[],
                &[
                    ("com.example.a", "theme", "\"dark\""),
                    ("com.example.a", "pinned", "true"),
                    ("com.example.b", "x", "1"),
                ],
            ),
        ),
        ("archived", {
            let mut b = basic("archived", "/tmp/x", CheckoutState::Ready, &[], &[]);
            b.status = Status::Archived;
            b
        }),
        (
            "unicode",
            basic(
                "苺ましまろ 🍓",
                "",
                CheckoutState::Pending,
                &[("sid-α", "Frieren 葬送のフリーレン")],
                &[("ns", "k", "\"日本語\"")],
            ),
        ),
        (
            "full",
            basic(
                "full",
                "/tmp/a",
                CheckoutState::Ready,
                &[("sid-1", "one"), ("sid-2", "two")],
                &[("ns1", "a", "1"), ("ns2", "b", "\"two\"")],
            ),
        ),
    ]
}

/// Bodies for kinds introduced at the **current** schema version (v4): the
/// checkout-less `local-*` kinds. They have no older frozen bytes, so they are
/// round-tripped and included in the current frozen corpus, but excluded from the
/// cross-version (v1/v2/v3) migration tests. One carries a session + kv to prove
/// those stay kind-agnostic through a non-basic kind.
pub(super) fn current_kind_bodies() -> Vec<(&'static str, WorkstreamBody)> {
    vec![
        (
            "local-blank",
            local_kind(
                "local-blank",
                WorkstreamKind::LocalBlank {
                    location: nil_location("/tmp/blank"),
                },
                &[],
                &[],
            ),
        ),
        (
            "local-tmp",
            local_kind(
                "local-tmp",
                WorkstreamKind::LocalTmp {
                    location: nil_location("/tmp/uuidv7_0190-abc"),
                },
                &[("sid-1", "planning")],
                &[("ns", "k", "\"v\"")],
            ),
        ),
        (
            "local-unmanaged",
            local_kind(
                "local-unmanaged",
                WorkstreamKind::LocalUnmanagedExistingPath {
                    location: nil_location("/Users/x/existing"),
                },
                &[],
                &[],
            ),
        ),
    ]
}

/// A single-forest location at `path` with a nil `forest_id` (matching what the
/// frozen pre-v3 corpus migrates to, so bodies compare equal across the corpus).
fn nil_location(path: &str) -> Location {
    Location {
        forest_id: ForestId(Uuid::nil()),
        within: LocationWithinForest::BasicForest {
            path: path.to_string(),
        },
    }
}

/// The kv map for `sessions` + `kv`: sessions are all `claude-code` (the only agent
/// kind) stored as reserved-namespace entries (see [`SESSION_NS`]); kv entries are
/// verbatim namespace→key→value.
fn kv_and_sessions(
    sessions: &[(&str, &str)],
    kv: &[(&str, &str, &str)],
) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut kvmap: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for (ns, k, v) in kv {
        kvmap
            .entry(ns.to_string())
            .or_default()
            .insert(k.to_string(), v.to_string());
    }
    for (id, nm) in sessions {
        let session = AgentSession {
            kind: SessionKind::ClaudeCode { lock: None },
            name: nm.to_string(),
            created_at: "1970-01-01T00:00:00Z".to_string(),
        };
        kvmap
            .entry(SESSION_NS.to_string())
            .or_default()
            .insert(id.to_string(), serde_json::to_string(&session).unwrap());
    }
    kvmap
}

/// Build a single-location basic-kind body with a nil `forest_id` (matching what
/// the frozen pre-v3 corpus, whose checkout keys are not UUIDs, migrates to).
/// `path` is the checkout path (`""` for never-provisioned).
fn basic(
    name: &str,
    path: &str,
    state: CheckoutState,
    sessions: &[(&str, &str)],
    kv: &[(&str, &str, &str)],
) -> WorkstreamBody {
    WorkstreamBody {
        name: name.to_string(),
        status: Status::Active,
        created_at: "1970-01-01T00:00:00Z".to_string(),
        kind: WorkstreamKind::Basic {
            mode: CheckoutMode::JjColocated {
                initial_source: "https://example.com/x.git".to_string(),
                state,
            },
            location: nil_location(path),
        },
        kv: kv_and_sessions(sessions, kv),
    }
}

/// Build a checkout-less `local-*` kind body around `kind`.
fn local_kind(
    name: &str,
    kind: WorkstreamKind,
    sessions: &[(&str, &str)],
    kv: &[(&str, &str, &str)],
) -> WorkstreamBody {
    WorkstreamBody {
        name: name.to_string(),
        status: Status::Active,
        created_at: "1970-01-01T00:00:00Z".to_string(),
        kind,
        kv: kv_and_sessions(sessions, kv),
    }
}

/// A throwaway id for hydrating raw bytes (the id is not stored in the document).
fn any_id() -> crate::id::WorkstreamId {
    crate::id::WorkstreamId::generate()
}
