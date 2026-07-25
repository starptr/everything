//! Sandbox-safe CLI tests: no network, no `jj` (nothing clones), so these run in
//! `nix flake check`. They cover forest-path resolution, source validation, and
//! id handling. The real-repo lifecycle lives in `e2e.rs` (`#[ignore]`d).

mod common;

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

    // A mode leaf demands its seed: the `<SOURCE_HTTPS_URL>` positional.
    let stderr = fails(&dir, &["new", "basic", "jj-colocated"]);
    assert!(stderr.contains("SOURCE_HTTPS_URL"), "got: {stderr}");

    // `--name` is required (enforced in the handler); omitting it fails before the
    // source is ever validated.
    let stderr = fails(
        &dir,
        &["new", "basic", "jj-colocated", "http://github.com/a/b.git"],
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
            "jj-colocated",
            "http://github.com/a/b.git",
        ],
    );
    assert!(stderr.contains("scheme must be https"), "got: {stderr}");

    // The apfs-cow mode leaf demands its own seed: an `<ABSOLUTE_PATH>` positional...
    let stderr = fails(&dir, &["new", "basic", "apfs-cow"]);
    assert!(stderr.contains("ABSOLUTE_PATH"), "got: {stderr}");

    // ...and it must be absolute — a relative path is rejected before any forest work.
    let stderr = fails(
        &dir,
        &["new", "basic", "apfs-cow", "relative/path", "--name", "x"],
    );
    assert!(stderr.contains("absolute"), "got: {stderr}");

    // The apfs-cow-direnv-unsafe leaf exists with the same seed: `<ABSOLUTE_PATH>`,
    // absolute-only (its extra `direnv allow` doesn't change the creation contract).
    let stderr = fails(&dir, &["new", "basic", "apfs-cow-direnv-unsafe"]);
    assert!(stderr.contains("ABSOLUTE_PATH"), "got: {stderr}");
    let stderr = fails(
        &dir,
        &[
            "new",
            "basic",
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
fn show_rejects_bad_and_absent_ids() {
    let dir = forest();

    let stderr = fails(&dir, &["show", "not-a-uuid"]);
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");

    // Well-formed but absent id → not-found failure.
    fails(&dir, &["show", "01999999-0000-7000-8000-000000000000"]);
}

#[test]
fn spawn_rejects_bad_and_absent_ids() {
    let dir = forest();

    // Bad id → parse error, before any forest work or exec.
    let stderr = fails(&dir, &["spawn", "not-a-uuid", "sess-1"]);
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");

    // Well-formed but absent id → not-found (there is no checkout to spawn in).
    fails(
        &dir,
        &["spawn", "01999999-0000-7000-8000-000000000000", "sess-1"],
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
            "01999999-0000-7000-8000-000000000000",
            "app.andref.silverwood.session",
            "k",
            "v",
        ],
    );
    assert!(stderr.contains("reserved"), "got: {stderr}");
}
