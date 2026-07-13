//! Integration tests for a workstream's associated data: namespaced kv and
//! Claude session associations. Uses the fake provider (no network, no jj).

mod common;

use common::{new_ws, temp_forest, FakeOk};
use silverwood_core::Forest;

#[test]
fn kv_round_trip() {
    let dir = temp_forest("kv");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("kv-demo")).unwrap();
    let ns = "com.example.frontend";

    forest.set_kv(ws.id, ns, "theme", "\"dark\"").unwrap();
    forest.set_kv(ws.id, ns, "pinned", "true").unwrap();

    assert_eq!(
        forest.get_kv(ws.id, ns, "theme").unwrap(),
        Some("\"dark\"".to_string())
    );
    assert_eq!(forest.get_kv(ws.id, ns, "missing").unwrap(), None);
    assert_eq!(forest.list_kv(ws.id, ns).unwrap().len(), 2);

    // Overwrite is last-writer-wins.
    forest.set_kv(ws.id, ns, "theme", "\"light\"").unwrap();
    assert_eq!(
        forest.get_kv(ws.id, ns, "theme").unwrap(),
        Some("\"light\"".to_string())
    );

    // Remove one key.
    forest.unset_kv(ws.id, ns, "theme").unwrap();
    assert_eq!(forest.get_kv(ws.id, ns, "theme").unwrap(), None);
    assert_eq!(forest.list_kv(ws.id, ns).unwrap().len(), 1);

    // Distinct namespaces do not collide.
    forest.set_kv(ws.id, "other.ns", "pinned", "false").unwrap();
    assert_eq!(forest.list_kv(ws.id, ns).unwrap().len(), 1);
    assert_eq!(forest.list_kv(ws.id, "other.ns").unwrap().len(), 1);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn session_lifecycle() {
    let dir = temp_forest("sessions");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("sess-demo")).unwrap();

    forest.attach_session(ws.id, "abc-123", "planning").unwrap();
    assert!(
        forest.attach_session(ws.id, "abc-123", "dup").is_err(),
        "duplicate attach must error"
    );

    forest
        .rename_session(ws.id, "abc-123", "planning v2")
        .unwrap();
    let got = forest.get(ws.id).unwrap();
    assert_eq!(got.body.sessions["abc-123"].name, "planning v2");
    assert!(!got.body.sessions["abc-123"].created_at.is_empty());

    assert!(
        forest.rename_session(ws.id, "nope", "x").is_err(),
        "renaming an absent session must error"
    );

    forest.detach_session(ws.id, "abc-123").unwrap();
    assert!(forest.get(ws.id).unwrap().body.sessions.is_empty());

    // Detaching an absent session is a no-op.
    forest.detach_session(ws.id, "abc-123").unwrap();

    let _ = std::fs::remove_dir_all(&dir);
}
