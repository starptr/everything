//! In-crate test harness for schema versioning, migration, and CRDT convergence.
//!
//! These live in `src/` (not `tests/`) because they exercise `pub(crate)`
//! internals (`doc::build`/`hydrate`/`migrate_bytes`, `migrate::*`) and drive the
//! Loro engine directly, which an integration test crate cannot reach.
//!
//! - [`loro_invariants`] — empirical probes of the two under-documented Loro
//!   behaviours the migration design assumes.
//! - [`corpus`] — v1 round-trip over every document structure, plus a frozen
//!   byte corpus (real old bytes) — see `corpus/README.md`.
//! - [`convergence`] — the real schema: K forests, random concurrent ops, all
//!   sync orderings converge to the union (no loss).
//! - [`synthetic`] — a self-contained two-version toy schema proving migration +
//!   convergence across a version bump under the barrier model.

mod convergence;
mod corpus;
mod loro_invariants;
mod synthetic;

use std::collections::BTreeMap;

use crate::workstream::{
    AgentKind, AgentSession, Checkout, CheckoutMode, CheckoutState, CodeChange, Status,
    WorkstreamBody, WorkstreamKind,
};

/// A canonical set of v1 bodies covering the structures a document can hold:
/// empty, multi-forest checkouts (each state), multiple sessions, multi-namespace
/// kv, archived, and unicode/edge strings. The round-trip and frozen-corpus
/// tests iterate this set.
pub(super) fn sample_bodies() -> Vec<(&'static str, WorkstreamBody)> {
    vec![
        ("minimal", basic("minimal", &[], &[], &[])),
        (
            "one-checkout",
            basic(
                "one-checkout",
                &[("forest-a", "/tmp/a", CheckoutState::Ready)],
                &[],
                &[],
            ),
        ),
        (
            "multi-checkout",
            basic(
                "multi-checkout",
                &[
                    ("forest-a", "/tmp/a", CheckoutState::Ready),
                    ("forest-b", "/tmp/b", CheckoutState::Pending),
                    ("forest-c", "/tmp/c", CheckoutState::Failed),
                ],
                &[],
                &[],
            ),
        ),
        (
            "sessions",
            basic(
                "sessions",
                &[("forest-a", "/tmp/a", CheckoutState::Ready)],
                &[("sid-1", "planning"), ("sid-2", "impl")],
                &[],
            ),
        ),
        (
            "kv",
            basic(
                "kv",
                &[],
                &[],
                &[
                    ("com.example.a", "theme", "\"dark\""),
                    ("com.example.a", "pinned", "true"),
                    ("com.example.b", "x", "1"),
                ],
            ),
        ),
        ("archived", {
            let mut b = basic(
                "archived",
                &[("f", "/tmp/x", CheckoutState::Ready)],
                &[],
                &[],
            );
            b.status = Status::Archived;
            b
        }),
        (
            "unicode",
            basic(
                "苺ましまろ 🍓",
                &[],
                &[("sid-α", "Frieren 葬送のフリーレン")],
                &[("ns", "k", "\"日本語\"")],
            ),
        ),
        (
            "full",
            basic(
                "full",
                &[
                    ("forest-a", "/tmp/a", CheckoutState::Ready),
                    ("forest-b", "/tmp/b", CheckoutState::Failed),
                ],
                &[("sid-1", "one"), ("sid-2", "two")],
                &[("ns1", "a", "1"), ("ns2", "b", "\"two\"")],
            ),
        ),
    ]
}

/// Build a basic-kind body. Sessions are all `claude-code` (the only agent kind).
fn basic(
    name: &str,
    checkouts: &[(&str, &str, CheckoutState)],
    sessions: &[(&str, &str)],
    kv: &[(&str, &str, &str)],
) -> WorkstreamBody {
    let checkouts = checkouts
        .iter()
        .map(|(forest, loc, state)| {
            (
                forest.to_string(),
                Checkout {
                    location: loc.to_string(),
                    state: *state,
                    mode: CheckoutMode::JjColocated,
                },
            )
        })
        .collect();
    let sessions = sessions
        .iter()
        .map(|(id, nm)| {
            (
                id.to_string(),
                AgentSession {
                    kind: AgentKind::ClaudeCode,
                    name: nm.to_string(),
                    created_at: "1970-01-01T00:00:00Z".to_string(),
                },
            )
        })
        .collect();
    let mut kvmap: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for (ns, k, v) in kv {
        kvmap
            .entry(ns.to_string())
            .or_default()
            .insert(k.to_string(), v.to_string());
    }
    WorkstreamBody {
        name: name.to_string(),
        status: Status::Active,
        created_at: "1970-01-01T00:00:00Z".to_string(),
        kind: WorkstreamKind::Basic {
            code_change: CodeChange {
                source: "https://example.com/x.git".to_string(),
                mode: CheckoutMode::JjColocated,
            },
            checkouts,
            sessions,
        },
        kv: kvmap,
    }
}

/// A throwaway id for hydrating raw bytes (the id is not stored in the document).
fn any_id() -> crate::id::WorkstreamId {
    crate::id::WorkstreamId::generate()
}
