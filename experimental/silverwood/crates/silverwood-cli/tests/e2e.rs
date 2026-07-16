//! End-to-end CLI tests against a real repo (`starptr/example`). These need the
//! network and `jj`/`git` on PATH, which the `nix flake check` sandbox lacks, so
//! every test is `#[ignore]`d. Run them in the dev shell:
//!
//! ```text
//! nix develop --command cargo test -p silverwood-cli -- --ignored
//! ```
//!
//! They assert only observable behavior: CLI `--json` output and the checkout
//! working copy on disk — never the forest's internal `.loro` files.

mod common;

use std::path::Path;

use common::{create, fails, forest, json, ok, EXAMPLE_SOURCE};

#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn new_creates_a_ready_colocated_checkout() {
    let dir = forest();
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "--name",
            "auth-refactor",
            "--source",
            EXAMPLE_SOURCE,
            "--mode",
            "jj-colocated",
        ],
    );

    // Reported workstream fields.
    assert_eq!(ws["name"], "auth-refactor");
    assert_eq!(ws["status"], "active");
    assert_eq!(ws["kind"], "basic");
    assert_eq!(ws["mode"]["checkout_mode"], "jj-colocated");
    assert_eq!(ws["mode"]["state"], "ready");
    assert!(ws["mode"]["initial_source"]
        .as_str()
        .unwrap()
        .contains("starptr/example"));
    let created = ws["created_at"].as_str().unwrap();
    assert!(
        created.contains('T') && (created.ends_with('Z') || created.contains('+')),
        "created_at not RFC3339-ish: {created}"
    );

    // The single checkout location, under this forest's working-copies.
    assert_eq!(ws["location"]["within"]["forest_kind"], "basic-forest");
    let location = ws["location"]["within"]["path"].as_str().unwrap();
    let loc = Path::new(location);
    assert!(
        loc.starts_with(dir.path()),
        "checkout not under forest: {location}"
    );

    // The checkout working copy on disk: cloned content + colocated markers.
    assert!(loc.join("README.md").is_file(), "cloned README.md missing");
    assert!(loc.join(".jj").is_dir(), ".jj missing (not colocated)");
    assert!(loc.join(".git").is_dir(), ".git missing (not colocated)");

    // `show <id>` matches the `ls` entry.
    let id = ws["id"].as_str().unwrap();
    let listed = json(&dir, &["--json", "ls"]);
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(json(&dir, &["--json", "show", id]), listed[0]);
}

#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn kv_and_session_lifecycle() {
    let dir = forest();
    let id = create(&dir, "work");
    let ns = "com.example.tui";

    // kv: set, get, overwrite (LWW), list, unset, namespace isolation.
    ok(&dir, &["kv", "set", &id, ns, "theme", "dark"]);
    ok(&dir, &["kv", "set", &id, ns, "pinned", "yes"]);
    assert_eq!(
        json(&dir, &["--json", "kv", "get", &id, ns, "theme"]),
        "dark"
    );

    ok(&dir, &["kv", "set", &id, ns, "theme", "light"]);
    assert_eq!(
        json(&dir, &["--json", "kv", "get", &id, ns, "theme"]),
        "light"
    );
    assert_eq!(
        json(&dir, &["--json", "kv", "ls", &id, ns])
            .as_object()
            .unwrap()
            .len(),
        2
    );

    ok(&dir, &["kv", "unset", &id, ns, "theme"]);
    assert_eq!(
        json(&dir, &["--json", "kv", "get", &id, ns, "theme"]),
        serde_json::Value::Null
    );
    assert_eq!(
        json(&dir, &["--json", "kv", "ls", &id, ns])
            .as_object()
            .unwrap()
            .len(),
        1
    );

    ok(&dir, &["kv", "set", &id, "other.ns", "pinned", "no"]);
    assert_eq!(
        json(&dir, &["--json", "kv", "ls", &id, ns])
            .as_object()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        json(&dir, &["--json", "kv", "ls", &id, "other.ns"])
            .as_object()
            .unwrap()
            .len(),
        1
    );

    // sessions: create (per-kind subcommand), duplicate errors, rename preserves
    // kind + created_at, absent rename errors, rm removes.
    ok(
        &dir,
        &[
            "session",
            "create",
            "claude-code",
            &id,
            "sess-1",
            "--name",
            "planning",
        ],
    );
    fails(
        &dir,
        &[
            "session",
            "create",
            "claude-code",
            &id,
            "sess-1",
            "--name",
            "dup",
        ],
    );

    let before = json(&dir, &["--json", "session", "ls", &id]);
    assert_eq!(before["sess-1"]["kind"], "claude-code");
    let created_at = before["sess-1"]["created_at"].as_str().unwrap().to_string();
    assert!(!created_at.is_empty());

    ok(&dir, &["session", "rename", &id, "sess-1", "planning v2"]);
    let after = json(&dir, &["--json", "session", "ls", &id]);
    assert_eq!(after["sess-1"]["name"], "planning v2");
    assert_eq!(
        after["sess-1"]["kind"], "claude-code",
        "rename must preserve kind"
    );
    assert_eq!(
        after["sess-1"]["created_at"],
        created_at.as_str(),
        "rename must preserve created_at"
    );

    fails(&dir, &["session", "rename", &id, "absent", "x"]);

    ok(&dir, &["session", "rm", &id, "sess-1"]);
    assert_eq!(
        json(&dir, &["--json", "session", "ls", &id]),
        serde_json::json!({})
    );

    // Sessions live in the reserved kv namespace, not a top-level `sessions` field;
    // and writing that namespace directly is rejected.
    ok(&dir, &["session", "create", "claude-code", &id, "sess-2"]);
    let ws = json(&dir, &["--json", "show", &id]);
    assert!(ws.get("sessions").is_none(), "no top-level sessions field");
    assert!(ws["kv"]["app.andref.silverwood.session"]["sess-2"].is_string());
    fails(
        &dir,
        &["kv", "set", &id, "app.andref.silverwood.session", "x", "{}"],
    );

    // workstream rename.
    ok(&dir, &["rename", &id, "renamed-work"]);
    assert_eq!(json(&dir, &["--json", "show", &id])["name"], "renamed-work");
}

#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn archive_tombstones_but_keeps_checkout_and_persists() {
    let dir = forest();
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "--name",
            "w",
            "--source",
            EXAMPLE_SOURCE,
            "--mode",
            "jj-colocated",
        ],
    );
    let id = ws["id"].as_str().unwrap().to_string();
    let location = ws["location"]["within"]["path"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(Path::new(&location).join("README.md").is_file());

    ok(&dir, &["archive", &id]);

    // Hidden from `ls`, present in `ls --all`, still shows as archived.
    assert_eq!(json(&dir, &["--json", "ls"]), serde_json::json!([]));
    let all = json(&dir, &["--json", "ls", "--all"]);
    assert_eq!(all.as_array().unwrap().len(), 1);
    assert_eq!(all[0]["status"], "archived");
    assert_eq!(json(&dir, &["--json", "show", &id])["status"], "archived");

    // Archive is a tombstone: the checkout working copy is NOT deleted.
    assert!(
        Path::new(&location).join("README.md").is_file(),
        "archive must not delete the checkout"
    );

    // Persistence across processes: re-read in yet another invocation.
    assert_eq!(json(&dir, &["--json", "show", &id])["id"], id);
}
