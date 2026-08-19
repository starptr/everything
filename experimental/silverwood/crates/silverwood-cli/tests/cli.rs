//! Sandbox-safe CLI tests: no network, no `jj` (nothing clones), so these run in
//! `nix flake check`. They cover forest-path resolution, source validation, and
//! id handling. The real-repo lifecycle lives in `e2e.rs` (`#[ignore]`d).

mod common;

use std::path::Path;

use common::{fails, forest, json, run};

#[test]
fn info_reports_forest_at_env_path() {
    let dir = forest();
    let value = json(&dir, &["--json", "info"]);

    assert_eq!(value["root"], dir.path().to_str().unwrap());
    assert!(value["forest_id"].as_str().is_some(), "got: {value}");
    assert!(value["peer_id"].is_number(), "got: {value}");
}

#[test]
fn forest_flag_overrides_env_var() {
    let env_dir = forest();
    let flag_dir = forest();

    // Env points at env_dir; --forest points at flag_dir → the flag wins.
    let out = run(
        &env_dir,
        &[
            "--forest",
            flag_dir.path().to_str().unwrap(),
            "--json",
            "info",
        ],
    );
    assert!(out.status.success());
    let value: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(value["root"], flag_dir.path().to_str().unwrap());
}

#[test]
fn env_var_actually_creates_the_forest_there() {
    let dir = forest();
    // A fresh forest lists nothing; the point is that the command targets `dir`
    // (via the env var) and succeeds rather than touching the real home forest.
    let listed = json(&dir, &["--json", "ls"]);
    assert_eq!(listed, serde_json::json!([]));
    // The env-resolved root is reflected back by `info`.
    assert_eq!(
        json(&dir, &["--json", "info"])["root"],
        dir.path().to_str().unwrap()
    );
}

#[test]
fn ls_empty_forest_is_json_array() {
    let dir = forest();
    assert_eq!(json(&dir, &["--json", "ls"]), serde_json::json!([]));
}

#[test]
fn new_with_non_https_source_is_rejected_without_cloning() {
    let dir = forest();

    // scp-like and http:// are both rejected by HttpsGitUrl before any clone.
    fails(
        &dir,
        &[
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            "git@github.com:a/b.git",
            "--name",
            "x",
        ],
    );
    fails(
        &dir,
        &[
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            "http://github.com/a/b.git",
            "--name",
            "x",
        ],
    );

    // Nothing was created.
    assert_eq!(json(&dir, &["--json", "ls"]), serde_json::json!([]));
}

#[test]
fn new_subcommand_structure_mirrors_the_data_model() {
    let dir = forest();

    // Each level demands its child: `new` needs a variant, `basic` needs a mode.
    // Both are clap parse errors (exit before the forest is touched).
    fails(&dir, &["new"]);
    fails(&dir, &["new", "basic"]);

    // `basic` demands its `--checkout-extent` (full|skip); omitting it is a clap error.
    let stderr = fails(&dir, &["new", "basic", "jj-colocated", "--name", "x"]);
    assert!(stderr.contains("checkout-extent"), "got: {stderr}");

    // A mode leaf demands its seed: the `<SOURCE_HTTPS_URL>` positional.
    let stderr = fails(
        &dir,
        &["new", "basic", "--checkout-extent", "full", "jj-colocated"],
    );
    assert!(stderr.contains("SOURCE_HTTPS_URL"), "got: {stderr}");

    // `--name` is required (enforced in the handler); omitting it fails before the
    // source is ever validated.
    let stderr = fails(
        &dir,
        &[
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            "http://github.com/a/b.git",
        ],
    );
    assert!(stderr.contains("--name"), "got: {stderr}");

    // `--name` is global: placing it at the `new` level (before the mode) parses,
    // and the command then reaches source validation (rejecting the non-https url).
    let stderr = fails(
        &dir,
        &[
            "new",
            "--name",
            "x",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            "http://github.com/a/b.git",
        ],
    );
    assert!(stderr.contains("scheme must be https"), "got: {stderr}");

    // The apfs-cow mode leaf demands its own seed: an `<ABSOLUTE_PATH>` positional...
    let stderr = fails(
        &dir,
        &["new", "basic", "--checkout-extent", "full", "apfs-cow"],
    );
    assert!(stderr.contains("ABSOLUTE_PATH"), "got: {stderr}");

    // ...and it must be absolute — a relative path is rejected before any forest work.
    let stderr = fails(
        &dir,
        &[
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "apfs-cow",
            "relative/path",
            "--name",
            "x",
        ],
    );
    assert!(stderr.contains("absolute"), "got: {stderr}");

    // The apfs-cow-direnv-unsafe leaf exists with the same seed: `<ABSOLUTE_PATH>`,
    // absolute-only (its extra `direnv allow` doesn't change the creation contract).
    let stderr = fails(
        &dir,
        &[
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "apfs-cow-direnv-unsafe",
        ],
    );
    assert!(stderr.contains("ABSOLUTE_PATH"), "got: {stderr}");
    let stderr = fails(
        &dir,
        &[
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "apfs-cow-direnv-unsafe",
            "relative/path",
            "--name",
            "x",
        ],
    );
    assert!(stderr.contains("absolute"), "got: {stderr}");

    // None of the above created anything.
    assert_eq!(json(&dir, &["--json", "ls"]), serde_json::json!([]));
}

#[test]
fn new_skip_registers_without_provisioning() {
    let dir = forest();

    // `--checkout-extent skip` registers the workstream but does not clone, so this runs
    // in the no-network sandbox: the checkout rests at `initialized-without-checkout` and
    // nothing is materialized on disk.
    let ws = json(
        &dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "skip",
            "jj-colocated",
            "https://github.com/octocat/Hello-World.git",
            "--name",
            "deferred",
        ],
    );
    assert_eq!(
        ws["overall_state"],
        "active - basic.initialized-without-checkout"
    );
    assert_eq!(ws["mode"]["state"], "initialized-without-checkout");

    // No working copy was provisioned.
    let location = ws["location"]["within"]["path"].as_str().unwrap();
    assert!(
        !Path::new(location).exists(),
        "skip must not materialize a checkout: {location}"
    );

    // `show` reflects the same deferred state.
    let id = ws["id"].as_str().unwrap();
    assert_eq!(
        json(&dir, &["--json", "workstream", id, "show"])["overall_state"],
        "active - basic.initialized-without-checkout"
    );
}

#[test]
fn show_rejects_bad_and_absent_ids() {
    let dir = forest();

    let stderr = fails(&dir, &["workstream", "not-a-uuid", "show"]);
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");

    // Well-formed but absent id → not-found failure.
    fails(
        &dir,
        &[
            "workstream",
            "uuidv7_01999999-0000-7000-8000-000000000000",
            "show",
        ],
    );
}

#[test]
fn bare_uuid_is_rejected_as_deprecated_implicit() {
    let dir = forest();

    // A well-formed UUID with no scheme prefix is the deprecated implicit form and
    // is rejected on input — the message must guide toward the explicit `uuidv7_`.
    let stderr = fails(
        &dir,
        &["workstream", "01999999-0000-7000-8000-000000000000", "show"],
    );
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");
    assert!(
        stderr.contains("uuidv7_"),
        "expected explicit-form guidance: {stderr}"
    );
}

#[test]
fn remove_rejects_bad_and_absent_ids() {
    let dir = forest();

    // Bad id → parse error, before any forest work.
    let stderr = fails(&dir, &["workstream", "not-a-uuid", "remove"]);
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");

    // Well-formed but absent id → not-found, both with and without `--force` (the
    // workstream is loaded before the safety check / force is consulted).
    fails(
        &dir,
        &[
            "workstream",
            "uuidv7_01999999-0000-7000-8000-000000000000",
            "remove",
        ],
    );
    fails(
        &dir,
        &[
            "workstream",
            "uuidv7_01999999-0000-7000-8000-000000000000",
            "remove",
            "--force",
        ],
    );
}

#[test]
fn spawn_from_id_rejects_bad_and_absent_ids() {
    let dir = forest();

    // Bad workstream id → parse error, before any forest work or exec.
    let stderr = fails(
        &dir,
        &["spawn", "from-id", "sess-1", "--workstream", "not-a-uuid"],
    );
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");

    // Well-formed but absent id → not-found (there is no workstream to spawn from).
    fails(
        &dir,
        &[
            "spawn",
            "from-id",
            "sess-1",
            "--workstream",
            "uuidv7_01999999-0000-7000-8000-000000000000",
        ],
    );
}

/// The direct spawn kinds build their plan from `--override-working-directory` (no
/// checkout needed), so their `--json` plan shape is testable in the sandbox. We assert on
/// shell-agnostic parts only — the interactive kinds' `program` is the login shell, which
/// varies by environment.
#[test]
fn spawn_direct_variants_reflect_the_kind() {
    let dir = forest();

    // plain-shell: an interactive login shell (`<shell> -l`).
    let plan = json(
        &dir,
        &[
            "--json",
            "spawn",
            "plain-shell",
            "--override-working-directory",
            "/tmp/x",
        ],
    );
    assert_eq!(plan["args"], serde_json::json!(["-l"]));
    assert_eq!(plan["cwd"], "/tmp/x");

    // claude-code (interactive): runs inside the login-interactive shell, chaining `exec claude`.
    let plan = json(
        &dir,
        &[
            "--json",
            "spawn",
            "claude-code",
            "first-run",
            "sess-1",
            "--override-working-directory",
            "/tmp/x",
        ],
    );
    let args = plan["args"].as_array().unwrap();
    assert_eq!(args[0], "-l");
    assert_eq!(args[1], "-i");
    assert_eq!(args[2], "-c");
    assert!(
        args[3]
            .as_str()
            .unwrap()
            .contains("exec claude --session-id 'sess-1'"),
        "script: {}",
        args[3]
    );

    // claude-code-noninteractive: claude directly when direnv off …
    let plan = json(
        &dir,
        &[
            "--json",
            "spawn",
            "claude-code-noninteractive",
            "--run-direnv-exec",
            "false",
            "resume",
            "sess-1",
            "--override-working-directory",
            "/tmp/x",
        ],
    );
    assert_eq!(plan["program"], "claude");
    assert_eq!(plan["args"], serde_json::json!(["--resume", "sess-1"]));

    // … and under `direnv exec <cwd>` when on.
    let plan = json(
        &dir,
        &[
            "--json",
            "spawn",
            "claude-code-noninteractive",
            "--run-direnv-exec",
            "true",
            "first-run",
            "sess-1",
            "--override-working-directory",
            "/tmp/x",
        ],
    );
    assert_eq!(plan["program"], "direnv");
    assert_eq!(
        plan["args"],
        serde_json::json!(["exec", "/tmp/x", "claude", "--session-id", "sess-1"])
    );

    // disk-space: a `df` loop via the interactive shell.
    let plan = json(
        &dir,
        &[
            "--json",
            "spawn",
            "disk-space",
            "--override-working-directory",
            "/tmp/x",
        ],
    );
    assert!(
        plan["args"][3].as_str().unwrap().contains("df -h"),
        "script: {}",
        plan["args"][3]
    );
}

#[test]
fn kv_set_rejects_reserved_namespace() {
    let dir = forest();

    // The reserved-namespace guard fires before the workstream is loaded, so a
    // well-formed (but absent) id still surfaces the reservation error — no clone.
    let stderr = fails(
        &dir,
        &[
            "kv",
            "set",
            "uuidv7_01999999-0000-7000-8000-000000000000",
            "app.andref.silverwood.session",
            "k",
            "v",
        ],
    );
    assert!(stderr.contains("reserved"), "got: {stderr}");
}
