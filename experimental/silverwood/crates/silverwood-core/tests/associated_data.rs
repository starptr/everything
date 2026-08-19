//! Integration tests for a workstream's associated data: namespaced kv and
//! agent session associations. Uses the fake provider (no network, no jj).

mod common;

use common::{new_ws, temp_forest, FakeOk};
use silverwood_core::{Forest, LocationWithinForest, SessionKind, SpawnSeed};

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
        .create_session(ws.id, "s1", SessionKind::ClaudeCode { lock: None }, "n")
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
            SessionKind::ClaudeCode { lock: None },
            "planning",
        )
        .unwrap();
    assert!(
        forest
            .create_session(
                ws.id,
                "abc-123",
                SessionKind::ClaudeCode { lock: None },
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
    assert_eq!(session.kind, SessionKind::ClaudeCode { lock: None });
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
            SessionKind::ClaudeCode { lock: None },
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
fn session_doctor_and_lock_cover_the_new_kinds() {
    let dir = temp_forest("new-kinds");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("new-kinds-demo")).unwrap();
    let claude = temp_forest("new-kinds-claude");

    // claude-code-noninteractive is a claude kind: doctor checks the transcript, and it locks.
    forest
        .create_session(
            ws.id,
            "ni",
            SessionKind::ClaudeCodeNoninteractive {
                lock: None,
                run_direnv_exec: true,
            },
            "ni",
        )
        .unwrap();
    let report = forest.doctor_session(ws.id, "ni", &claude).unwrap();
    assert_eq!(report.kind, "claude-code-noninteractive");
    assert_eq!(report.conversation_exists, Some(false));
    forest.lock_session(ws.id, "ni", "A", false).unwrap();
    assert_eq!(
        forest.get(ws.id).unwrap().body.sessions()["ni"]
            .lock()
            .unwrap()
            .holder,
        "A"
    );

    // disk-space is a shell kind: no conversation to check, and it is not lockable.
    forest
        .create_session(ws.id, "ds", SessionKind::DiskSpace {}, "ds")
        .unwrap();
    let report = forest.doctor_session(ws.id, "ds", &claude).unwrap();
    assert_eq!(report.kind, "disk-space");
    assert_eq!(report.conversation_exists, None);
    assert!(forest.lock_session(ws.id, "ds", "A", false).is_err());

    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&claude);
}

#[test]
fn spawn_plan_from_session_resolves_each_kind() {
    let dir = temp_forest("spawn-from-id");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    let ws = forest.create_workstream(new_ws("spawn-demo")).unwrap();
    let LocationWithinForest::BasicForest { path: cwd } =
        ws.body.location().unwrap().within.clone()
    else {
        unreachable!("a basic workstream has a basic-forest location");
    };
    let claude = temp_forest("spawn-claude"); // empty ⇒ no transcript ⇒ first-run

    let seed = SpawnSeed {
        home: "/home/x".into(),
        user: Some("x".into()),
        shell: "/bin/zsh".into(),
        term: None,
        ssh_auth_sock: None,
    };

    // claude-code (interactive): runs inside the login-interactive shell, first-run.
    forest
        .create_session(ws.id, "cc-1", SessionKind::ClaudeCode { lock: None }, "cc")
        .unwrap();
    let plan = forest
        .spawn_plan_from_session(ws.id, "cc-1", &seed, &claude)
        .unwrap();
    assert_eq!(plan.program, "/bin/zsh");
    assert_eq!(plan.args[0..3], ["-l", "-i", "-c"]);
    assert!(plan.args[3].contains("exec claude --session-id 'cc-1'"));
    assert_eq!(plan.cwd, cwd);

    // claude-code-noninteractive with direnv on: `direnv exec <cwd> claude --session-id`.
    forest
        .create_session(
            ws.id,
            "ni-1",
            SessionKind::ClaudeCodeNoninteractive {
                lock: None,
                run_direnv_exec: true,
            },
            "ni",
        )
        .unwrap();
    let plan = forest
        .spawn_plan_from_session(ws.id, "ni-1", &seed, &claude)
        .unwrap();
    assert_eq!(plan.program, "direnv");
    assert_eq!(
        plan.args,
        vec!["exec", &cwd, "claude", "--session-id", "ni-1"]
    );

    // plain-shell: a login shell in the checkout.
    forest
        .create_session(ws.id, "sh-1", SessionKind::PlainShell {}, "sh")
        .unwrap();
    let plan = forest
        .spawn_plan_from_session(ws.id, "sh-1", &seed, &claude)
        .unwrap();
    assert_eq!(plan.program, "/bin/zsh");
    assert_eq!(plan.args, vec!["-l"]);

    // disk-space: a `df` loop via the interactive shell.
    forest
        .create_session(ws.id, "ds-1", SessionKind::DiskSpace {}, "ds")
        .unwrap();
    let plan = forest
        .spawn_plan_from_session(ws.id, "ds-1", &seed, &claude)
        .unwrap();
    assert!(plan.args[3].contains("df -h"));

    // A transcript on disk flips the claude flag to --resume.
    let proj = claude.join("projects").join("-any");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("cc-2.jsonl"), "{}\n").unwrap();
    forest
        .create_session(ws.id, "cc-2", SessionKind::ClaudeCode { lock: None }, "cc2")
        .unwrap();
    let plan = forest
        .spawn_plan_from_session(ws.id, "cc-2", &seed, &claude)
        .unwrap();
    assert!(plan.args[3].contains("exec claude --resume 'cc-2'"));

    // An absent session errors.
    assert!(forest
        .spawn_plan_from_session(ws.id, "nope", &seed, &claude)
        .is_err());

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
            SessionKind::ClaudeCode { lock: None },
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
