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
            "--name",
            "x",
            "--source",
            "git@github.com:a/b.git",
            "--mode",
            "jj-colocated",
        ],
    );
    fails(
        &dir,
        &[
            "new",
            "--name",
            "x",
            "--source",
            "http://github.com/a/b.git",
            "--mode",
            "jj-colocated",
        ],
    );

    // Nothing was created.
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
