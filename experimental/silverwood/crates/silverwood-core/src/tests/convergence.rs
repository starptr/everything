//! Real-schema convergence: K forests fork a shared workstream, each applies a
//! set of disjoint concurrent ops, and every pairwise update is merged in a
//! proptest-chosen order. All forests must converge to the same body, and that
//! body must hold the union of every forest's ops (no data lost in any order).
//!
//! This generalises the hand-written `doc::tests::concurrent_edits_converge`
//! (2 peers, fixed order) to K peers and all orderings.

use std::collections::BTreeSet;

use loro::{ExportMode, LoroDoc};
use proptest::prelude::*;

use super::{any_id, sample_bodies};
use crate::doc;
use crate::workstream::AgentKind;

/// Per-forest ops: kv entries `(key index, value index)` and session indices.
/// Namespacing by forest index (below) keeps every forest's writes disjoint, so
/// the merged union is well-defined regardless of order.
type ForestOps = (Vec<(u8, u8)>, Vec<u8>);

fn forest_ops() -> impl Strategy<Value = ForestOps> {
    (
        prop::collection::vec((0u8..6, 0u8..6), 0..5),
        prop::collection::vec(0u8..5, 0..5),
    )
}

fn scenario() -> impl Strategy<Value = (usize, Vec<ForestOps>, Vec<u64>)> {
    (2usize..=4).prop_flat_map(|k| {
        (
            Just(k),
            prop::collection::vec(forest_ops(), k),
            prop::collection::vec(any::<u64>(), 24),
        )
    })
}

/// Merge every ordered (src → tgt) update once, in the order dictated by `order`.
/// Loro holds updates with missing deps as pending, so any order must converge.
fn gossip(forests: &[LoroDoc], order: &[u64]) {
    let blobs: Vec<Vec<u8>> = forests
        .iter()
        .map(|d| d.export(ExportMode::all_updates()).unwrap())
        .collect();
    let mut steps: Vec<(usize, usize)> = Vec::new();
    for src in 0..forests.len() {
        for tgt in 0..forests.len() {
            if src != tgt {
                steps.push((tgt, src));
            }
        }
    }
    let mut keyed: Vec<(u64, (usize, usize))> = steps
        .iter()
        .enumerate()
        .map(|(idx, s)| (order[idx % order.len()], *s))
        .collect();
    keyed.sort_by_key(|(key, _)| *key);
    for (_, (tgt, src)) in keyed {
        forests[tgt].import(&blobs[src]).unwrap();
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn k_forests_converge_in_any_order((k, ops, order) in scenario()) {
        let base_body = sample_bodies().into_iter().next().unwrap().1; // "minimal" (basic kind)
        let base = doc::snapshot(&doc::build(1000, &base_body).unwrap()).unwrap();

        let mut forests: Vec<LoroDoc> = Vec::with_capacity(k);
        for (i, (kv_ops, sess_ops)) in ops.iter().enumerate() {
            let d = doc::load(10 * (i as u64 + 1), &base).unwrap();
            for (ki, vi) in kv_ops {
                doc::set_kv(&d, &format!("f{i}"), &format!("k{ki}"), &format!("v{vi}")).unwrap();
            }
            for si in sess_ops.iter().copied().collect::<BTreeSet<u8>>() {
                doc::create_session(&d, &format!("f{i}-s{si}"), AgentKind::ClaudeCode, "n", "t0")
                    .unwrap();
            }
            forests.push(d);
        }

        gossip(&forests, &order);

        // Convergence: all forests hydrate to the same body.
        let bodies: Vec<_> = forests
            .iter()
            .map(|d| doc::hydrate(any_id(), &doc::snapshot(d).unwrap()).unwrap().body)
            .collect();
        for b in &bodies[1..] {
            prop_assert_eq!(&bodies[0], b);
        }

        // No loss: the merged body contains every forest's ops.
        let merged = &bodies[0];
        for (i, (kv_ops, sess_ops)) in ops.iter().enumerate() {
            for (ki, _) in kv_ops {
                let present = merged
                    .kv
                    .get(&format!("f{i}"))
                    .and_then(|m| m.get(&format!("k{ki}")))
                    .is_some();
                prop_assert!(present, "lost kv f{}/k{}", i, ki);
            }
            let sessions = merged.sessions();
            for si in sess_ops.iter().copied().collect::<BTreeSet<u8>>() {
                prop_assert!(
                    sessions.contains_key(&format!("f{i}-s{si}")),
                    "lost session f{}-s{}",
                    i,
                    si
                );
            }
        }
    }
}
