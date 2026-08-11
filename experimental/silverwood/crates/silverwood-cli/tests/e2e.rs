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

use tempfile::TempDir;

use common::{create, fails, forest, json, json_env, ok, EXAMPLE_SOURCE};

/// `new-schema` is pure metadata (no network, no forest), so it runs in the sandbox.
/// It reflects the `new` subcommand tree; assert its shape and per-leaf positionals.
#[test]
fn new_schema_reflects_the_new_command_tree() {
    let dir = forest();
    let schema = json(&dir, &["--json", "new-schema"]);
    assert_eq!(schema["name"], "new");

    // The one variant today is `basic`; find it under the root's subcommands.
    let variants = schema["subcommands"].as_array().expect("subcommands array");
    let basic = variants
        .iter()
        .find(|v| v["name"] == "basic")
        .expect("basic variant");

    // `basic`'s children are the checkout modes; collect their leaves by tag.
    let modes = basic["subcommands"].as_array().expect("mode subcommands");
    let mode = |tag: &str| {
        modes
            .iter()
            .find(|m| m["name"] == tag)
            .unwrap_or_else(|| panic!("missing mode {tag}: {modes:?}"))
    };
    let jj = mode("jj-colocated");
    mode("jj-colocated-direnv-unsafe");
    let apfs = mode("apfs-cow");

    // A leaf's single positional carries the value_name a frontend renders a field from.
    let sole_arg_value_name = |m: &serde_json::Value| -> String {
        let args = m["args"].as_array().expect("args array");
        assert_eq!(args.len(), 1, "expected one positional: {m:?}");
        assert!(args[0]["help"].as_str().is_some_and(|h| !h.is_empty()));
        assert!(args[0]["required"].as_bool().expect("required is a bool"));
        args[0]["value_name"]
            .as_str()
            .expect("value_name")
            .to_string()
    };
    assert_eq!(sole_arg_value_name(jj), "SOURCE_HTTPS_URL");
    assert_eq!(sole_arg_value_name(apfs), "ABSOLUTE_PATH");
}

#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn new_creates_a_ready_colocated_checkout() {
    let dir = forest();
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            EXAMPLE_SOURCE,
            "--name",
            "auth-refactor",
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

/// `--checkout-extent skip` registers without cloning; `workstream <id> basic checkout`
/// then provisions it, and a second checkout is rejected. The register step needs no
/// network, but the checkout step clones, so this is `#[ignore]`d like the rest.
#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn skip_then_checkout_provisions_and_rejects_recheckout() {
    let dir = forest();

    // Register with the checkout deferred: no clone yet.
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "skip",
            "jj-colocated",
            EXAMPLE_SOURCE,
            "--name",
            "deferred",
        ],
    );
    let id = ws["id"].as_str().unwrap().to_string();
    assert_eq!(
        ws["overall_state"],
        "active - basic.initialized-without-checkout"
    );
    let location = ws["location"]["within"]["path"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(
        !Path::new(&location).exists(),
        "skip must not clone: {location}"
    );

    // Checking out clones now and flips to ready.
    let checked_out = json(&dir, &["--json", "workstream", &id, "basic", "checkout"]);
    assert_eq!(checked_out["overall_state"], "active - basic.ready");
    assert!(
        Path::new(&location).join("README.md").is_file(),
        "checkout must be provisioned on disk"
    );

    // A second checkout is rejected — it is no longer awaiting one.
    let stderr = fails(&dir, &["workstream", &id, "basic", "checkout"]);
    assert!(stderr.contains("not awaiting checkout"), "got: {stderr}");
}

/// The apfs-cow mode copy-on-write clones a local directory into the checkout. No
/// network, but it needs a real APFS volume (macOS temp dirs are APFS) and shells out
/// to `/bin/cp -c`, so it is `#[ignore]`d like the rest and must run on macOS. The
/// source temp dir shares the forest's temp volume, so the same-volume precheck passes.
#[test]
#[ignore = "macOS + apfs (cp -c); run via `cargo test -- --ignored`"]
fn new_apfs_cow_creates_a_ready_checkout() {
    let dir = forest();

    // A source directory with a marker file.
    let src = TempDir::new().expect("create source dir");
    std::fs::write(src.path().join("marker.txt"), "hello").expect("write marker");
    let src_path = src.path().to_str().unwrap();

    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "apfs-cow",
            src_path,
            "--name",
            "cow-checkout",
        ],
    );

    assert_eq!(ws["name"], "cow-checkout");
    assert_eq!(ws["kind"], "basic");
    assert_eq!(ws["mode"]["checkout_mode"], "apfs-cow");
    assert_eq!(ws["mode"]["state"], "ready");
    assert_eq!(ws["mode"]["initial_source"], src_path);

    // The checkout is a copy-on-write clone: it lives under the forest and carries the
    // source's marker file.
    let location = ws["location"]["within"]["path"].as_str().unwrap();
    let loc = Path::new(location);
    assert!(
        loc.starts_with(dir.path()),
        "checkout not under forest: {location}"
    );
    assert_eq!(
        std::fs::read_to_string(loc.join("marker.txt")).expect("marker copied into checkout"),
        "hello"
    );
}

/// The apfs-cow-direnv-unsafe mode is apfs-cow plus `direnv allow`. The temp source has
/// no `.envrc`, so `direnv_allow` no-ops (no `direnv`/network needed) and provisioning
/// still succeeds; assert the mode tag, ready state, and the copied file — same shape as
/// the plain apfs-cow test. macOS + APFS only, so `#[ignore]`d like the rest.
#[test]
#[ignore = "macOS + apfs (cp -c); run via `cargo test -- --ignored`"]
fn new_apfs_cow_direnv_unsafe_creates_a_ready_checkout() {
    let dir = forest();

    let src = TempDir::new().expect("create source dir");
    std::fs::write(src.path().join("marker.txt"), "hello").expect("write marker");
    let src_path = src.path().to_str().unwrap();

    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "apfs-cow-direnv-unsafe",
            src_path,
            "--name",
            "cow-direnv",
        ],
    );

    assert_eq!(ws["name"], "cow-direnv");
    assert_eq!(ws["kind"], "basic");
    assert_eq!(ws["mode"]["checkout_mode"], "apfs-cow-direnv-unsafe");
    assert_eq!(ws["mode"]["state"], "ready");
    assert_eq!(ws["mode"]["initial_source"], src_path);

    let location = ws["location"]["within"]["path"].as_str().unwrap();
    let loc = Path::new(location);
    assert!(
        loc.starts_with(dir.path()),
        "checkout not under forest: {location}"
    );
    assert_eq!(
        std::fs::read_to_string(loc.join("marker.txt")).expect("marker copied into checkout"),
        "hello"
    );
}

/// The direnv-unsafe mode produces a ready checkout too. The example repo has no
/// `.envrc`, so `direnv allow` is a no-op and provisioning still succeeds; the
/// stored `checkout_mode` reflects the chosen mode. (A repo WITH an `.envrc` is
/// needed to observe the actual approval — see the manual E2E in the plan.)
#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn new_direnv_unsafe_mode_is_ready() {
    let dir = forest();
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated-direnv-unsafe",
            EXAMPLE_SOURCE,
            "--name",
            "with-direnv",
        ],
    );
    assert_eq!(ws["mode"]["checkout_mode"], "jj-colocated-direnv-unsafe");
    assert_eq!(ws["mode"]["state"], "ready");
    let loc = ws["location"]["within"]["path"].as_str().unwrap();
    assert!(Path::new(loc).join(".jj").is_dir(), ".jj missing");
}

/// `spawn --json` resolves the interactive-shell plan from the workstream's
/// stored checkout mode: plain `claude` for jj-colocated, `direnv exec <cwd>` for
/// the direnv-unsafe mode; `--resume` flips the claude flag; and omitting the
/// session id yields the base login shell. Needs a real (ready) checkout — hence
/// ignored. (The pure mode→argv logic is unit-tested in `silverwood-core`.)
#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn spawn_plan_reflects_checkout_mode() {
    let dir = forest();

    // Plain jj-colocated → `claude --session-id <sid>`, run in the checkout.
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            EXAMPLE_SOURCE,
            "--name",
            "plain",
        ],
    );
    let id = ws["id"].as_str().unwrap();
    let plan = json(&dir, &["--json", "spawn", id, "sess-1"]);
    assert_eq!(plan["program"], "claude");
    assert_eq!(plan["args"], serde_json::json!(["--session-id", "sess-1"]));
    assert_eq!(plan["cwd"], ws["location"]["within"]["path"]);

    // `--resume` flips the claude flag.
    let resumed = json(&dir, &["--json", "spawn", id, "sess-1", "--resume"]);
    assert_eq!(resumed["args"], serde_json::json!(["--resume", "sess-1"]));

    // The base-shell variant (no session id) runs a login shell in the checkout.
    let base = json(&dir, &["--json", "spawn", id]);
    assert!(base["program"].as_str().is_some_and(|p| !p.is_empty()));
    assert_eq!(base["args"], serde_json::json!(["-l"]));

    // Direnv-unsafe → claude wrapped in `direnv exec <cwd>` (cwd is its own argv).
    let ws2 = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated-direnv-unsafe",
            EXAMPLE_SOURCE,
            "--name",
            "with-direnv",
        ],
    );
    let id2 = ws2["id"].as_str().unwrap();
    let cwd2 = ws2["location"]["within"]["path"].as_str().unwrap();
    let plan2 = json(&dir, &["--json", "spawn", id2, "sess-2"]);
    assert_eq!(plan2["program"], "direnv");
    assert_eq!(
        plan2["args"],
        serde_json::json!(["exec", cwd2, "claude", "--session-id", "sess-2"])
    );
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

    // session doctor: read-only report of the variant + whether Claude's transcript
    // exists on disk. Point CLAUDE_CONFIG_DIR at a temp dir we control.
    let claude = forest(); // a fresh temp dir, reused as an isolated CLAUDE_CONFIG_DIR
    let claude_dir = claude.path().to_str().unwrap();
    let report = json_env(
        &dir,
        &[("CLAUDE_CONFIG_DIR", claude_dir)],
        &["--json", "session", "doctor", &id, "sess-2"],
    );
    assert_eq!(report["kind"], "claude-code");
    assert_eq!(report["conversation_exists"], false);
    // Read-only: the session is untouched by doctor.
    assert!(json(&dir, &["--json", "session", "ls", &id])["sess-2"].is_object());

    // With a transcript on disk (in any project dir), doctor reports it present.
    let proj = claude.path().join("projects").join("-any-escaped-cwd");
    std::fs::create_dir_all(&proj).unwrap();
    std::fs::write(proj.join("sess-2.jsonl"), "{}\n").unwrap();
    let report = json_env(
        &dir,
        &[("CLAUDE_CONFIG_DIR", claude_dir)],
        &["--json", "session", "doctor", &id, "sess-2"],
    );
    assert_eq!(report["conversation_exists"], true);

    // Advisory session lock: acquire surfaces in `session ls`, a second holder is
    // blocked, --force steals, unlock clears (best-effort cooperative flag).
    ok(&dir, &["session", "lock", &id, "sess-2", "--holder", "A"]);
    assert_eq!(
        json(&dir, &["--json", "session", "ls", &id])["sess-2"]["lock"]["holder"],
        "A"
    );
    fails(&dir, &["session", "lock", &id, "sess-2", "--holder", "B"]);
    ok(
        &dir,
        &["session", "lock", &id, "sess-2", "--holder", "B", "--force"],
    );
    assert_eq!(
        json(&dir, &["--json", "session", "ls", &id])["sess-2"]["lock"]["holder"],
        "B"
    );
    ok(&dir, &["session", "unlock", &id, "sess-2", "--holder", "B"]);
    assert!(
        json(&dir, &["--json", "session", "ls", &id])["sess-2"]
            .get("lock")
            .is_none(),
        "unlock must clear the lock"
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
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            EXAMPLE_SOURCE,
            "--name",
            "w",
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

/// `remove` is the delete-like tombstone: unlike archive it discards the checkout,
/// but (add-wins union) still keeps the document, marked `deleted`. Without `--force`
/// the stubbed safety check refuses.
#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn remove_deletes_checkout_but_keeps_deleted_tombstone() {
    let dir = forest();
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            EXAMPLE_SOURCE,
            "--name",
            "w",
        ],
    );
    let id = ws["id"].as_str().unwrap().to_string();
    let location = ws["location"]["within"]["path"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(Path::new(&location).join("README.md").is_file());

    // Without --force the safety check (stubbed false) refuses; nothing changes.
    fails(&dir, &["remove", &id]);
    assert_eq!(json(&dir, &["--json", "show", &id])["status"], "active");
    assert!(Path::new(&location).join("README.md").is_file());

    // --force soft-deletes: the checkout is gone, but the document survives as deleted.
    ok(&dir, &["remove", &id, "--force"]);
    assert_eq!(json(&dir, &["--json", "show", &id])["status"], "deleted");

    // Hidden from `ls`, present in `ls --all` as deleted.
    assert_eq!(json(&dir, &["--json", "ls"]), serde_json::json!([]));
    let all = json(&dir, &["--json", "ls", "--all"]);
    assert_eq!(all.as_array().unwrap().len(), 1);
    assert_eq!(all[0]["status"], "deleted");

    // The checked-out code on disk is deleted.
    assert!(
        !Path::new(&location).exists(),
        "remove must delete the checkout"
    );
}
