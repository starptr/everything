//! Integration tests for a workstream's associated data: namespaced kv and
//! agent session associations. Uses the fake provider (no network, no jj).

mod common;

use common::{new_ws, temp_forest, FakeOk};
use silverwood_core::{AgentKind, Forest};

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
fn reserved_namespace_is_rejected() {
    let dir = temp_forest("reserved");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("reserved-demo")).unwrap();

    // The core-reserved prefix cannot be written through raw kv...
    assert!(forest
        .set_kv(ws.id, "app.andref.silverwood.session", "sid", "{}")
        .is_err());
    assert!(forest
        .set_kv(ws.id, "app.andref.silverwood.anything", "k", "v")
        .is_err());
    assert!(forest
        .unset_kv(ws.id, "app.andref.silverwood.session", "sid")
        .is_err());
    // ...but a frontend's own namespace is fine.
    forest
        .set_kv(ws.id, "app.andref.papyrus", "position", "{}")
        .unwrap();

    // Sessions go through the typed API and land in the reserved namespace.
    forest
        .create_session(ws.id, "s1", AgentKind::ClaudeCode { lock: None }, "n")
        .unwrap();
    assert_eq!(forest.get(ws.id).unwrap().body.sessions().len(), 1);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn session_lifecycle() {
    let dir = temp_forest("sessions");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("sess-demo")).unwrap();

    forest
        .create_session(
            ws.id,
            "abc-123",
            AgentKind::ClaudeCode { lock: None },
            "planning",
        )
        .unwrap();
    assert!(
        forest
            .create_session(
                ws.id,
                "abc-123",
                AgentKind::ClaudeCode { lock: None },
                "dup"
            )
            .is_err(),
        "duplicate create must error"
    );

    forest
        .rename_session(ws.id, "abc-123", "planning v2")
        .unwrap();
    let got = forest.get(ws.id).unwrap();
    let sessions = got.body.sessions();
    let session = &sessions["abc-123"];
    assert_eq!(session.name, "planning v2");
    assert_eq!(session.kind, AgentKind::ClaudeCode { lock: None });
    assert!(!session.created_at.is_empty());

    assert!(
        forest.rename_session(ws.id, "nope", "x").is_err(),
        "renaming an absent session must error"
    );

    forest.remove_session(ws.id, "abc-123").unwrap();
    assert!(forest.get(ws.id).unwrap().body.sessions().is_empty());

    // Removing an absent session is a no-op.
    forest.remove_session(ws.id, "abc-123").unwrap();

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn session_doctor_reports_variant_and_conversation_presence() {
    let dir = temp_forest("doctor");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("doctor-demo")).unwrap();
    forest
        .create_session(
            ws.id,
            "sess-1",
            AgentKind::ClaudeCode { lock: None },
            "planning",
        )
        .unwrap();

    // An isolated Claude config dir with no transcripts on disk.
    let claude = temp_forest("doctor-claude");

    // Nothing persisted → conversation_exists: Some(false); the report names the variant
    // and echoes the ids.
    let report = forest.doctor_session(ws.id, "sess-1", &claude).unwrap();
    assert_eq!(report.kind, "claude-code");
    assert_eq!(report.conversation_exists, Some(false));
    assert_eq!(report.session_id, "sess-1");
    assert_eq!(report.workstream_id, ws.id.to_string());

    // Doctor is read-only: the session is untouched.
    assert_eq!(forest.get(ws.id).unwrap().body.sessions().len(), 1);

    // A transcript under any project dir (glob-by-id) → conversation_exists: Some(true).
    let proj = claude.join("projects").join("-any-escaped-cwd");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("sess-1.jsonl"), "{}\n").unwrap();
    let report = forest.doctor_session(ws.id, "sess-1", &claude).unwrap();
    assert_eq!(report.conversation_exists, Some(true));

    // Doctoring an absent session errors.
    assert!(forest.doctor_session(ws.id, "nope", &claude).is_err());

    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&claude);
}

#[test]
fn session_lock_lifecycle() {
    let dir = temp_forest("session-lock");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("lock-demo")).unwrap();
    forest
        .create_session(
            ws.id,
            "s1",
            AgentKind::ClaudeCode { lock: None },
            "planning",
        )
        .unwrap();

    // A fresh session is unlocked.
    assert!(forest.get(ws.id).unwrap().body.sessions()["s1"]
        .lock()
        .is_none());

    // Acquire for holder A (core mints acquired_at).
    forest.lock_session(ws.id, "s1", "A", false).unwrap();
    let lock = forest.get(ws.id).unwrap().body.sessions()["s1"]
        .lock()
        .cloned()
        .unwrap();
    assert_eq!(lock.holder, "A");
    assert!(!lock.acquired_at.is_empty());

    // Re-acquire by the same holder is idempotent.
    forest.lock_session(ws.id, "s1", "A", false).unwrap();

    // A different holder is blocked without --force, and so is a wrong-holder unlock.
    assert!(
        forest.lock_session(ws.id, "s1", "B", false).is_err(),
        "a second holder must be blocked"
    );
    assert!(forest
        .unlock_session(ws.id, "s1", Some("B"), false)
        .is_err());

    // --force steals the lock.
    forest.lock_session(ws.id, "s1", "B", true).unwrap();
    assert_eq!(
        forest.get(ws.id).unwrap().body.sessions()["s1"]
            .lock()
            .unwrap()
            .holder,
        "B"
    );

    // Release; the session is unlocked again, and re-unlock is a no-op.
    forest
        .unlock_session(ws.id, "s1", Some("B"), false)
        .unwrap();
    assert!(forest.get(ws.id).unwrap().body.sessions()["s1"]
        .lock()
        .is_none());
    forest
        .unlock_session(ws.id, "s1", Some("B"), false)
        .unwrap();

    // Locking an absent session errors.
    assert!(forest.lock_session(ws.id, "nope", "A", false).is_err());

    let _ = std::fs::remove_dir_all(&dir);
}
