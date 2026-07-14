//! Empirical probes of the two under-documented Loro behaviours the migration +
//! any-order-sync design relies on (both are intended-but-unverified per the
//! research). If either regresses, the deterministic-migration and
//! convergence-in-any-order assumptions must be revisited — better to fail here.

use loro::{ExportMode, LoroDoc};

fn deep(doc: &LoroDoc, name: &str) -> serde_json::Value {
    serde_json::to_value(doc.get_map(name).get_deep_value()).unwrap()
}

/// Re-importing the identical update bytes twice must be a no-op (idempotent) —
/// this is what makes applying updates in any order, with duplicates, safe.
#[test]
fn reimporting_identical_updates_is_idempotent() {
    let a = LoroDoc::new();
    a.set_peer_id(1).unwrap();
    a.get_map("m").insert("k", "v").unwrap();
    a.commit();
    let updates = a.export(ExportMode::all_updates()).unwrap();

    let b = LoroDoc::new();
    b.set_peer_id(2).unwrap();
    b.import(&updates).unwrap();
    let first = deep(&b, "m");
    b.import(&updates).unwrap();
    let second = deep(&b, "m");

    assert_eq!(first, second);
    assert_eq!(first, serde_json::json!({ "k": "v" }));
}

/// Two docs that independently author the *same* op under the same
/// `(PeerID, Counter)` (both peer 7's first op) must dedup on merge rather than
/// double-apply or diverge — the mechanism a deterministic migration exploits.
#[test]
fn identical_ops_under_same_peer_id_converge() {
    let make = || {
        let d = LoroDoc::new();
        d.set_peer_id(7).unwrap();
        d.get_map("m").insert("k", "v").unwrap();
        d.commit();
        d
    };
    let a = make();
    let b = make();
    let ua = a.export(ExportMode::all_updates()).unwrap();
    let ub = b.export(ExportMode::all_updates()).unwrap();
    a.import(&ub).unwrap();
    b.import(&ua).unwrap();

    let va = deep(&a, "m");
    let vb = deep(&b, "m");
    assert_eq!(va, vb, "same (peer,counter) ops must converge");
    assert_eq!(va, serde_json::json!({ "k": "v" }));
}
