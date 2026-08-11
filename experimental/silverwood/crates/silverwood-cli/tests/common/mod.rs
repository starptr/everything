//! Shared helpers for CLI integration tests. Each test binary uses a subset, so
//! unused items here are expected.
#![allow(dead_code)]

use std::process::{Command, Output};

use tempfile::TempDir;

/// The env var the CLI reads to locate the forest.
pub const FOREST_ENV: &str = "SILVERWOOD_FOREST_PATH";

/// The small example repo used by the network e2e tests (1 commit, only
/// `README.md`, default branch `main`).
pub const EXAMPLE_SOURCE: &str = "https://github.com/starptr/example.git";

/// A fresh temp directory to hold a forest, auto-removed on drop.
pub fn forest() -> TempDir {
    TempDir::new().expect("create temp dir")
}

/// Run the CLI with `SILVERWOOD_FOREST_PATH` pointed at `dir`.
pub fn run(dir: &TempDir, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_silverwood"))
        .env(FOREST_ENV, dir.path())
        .args(args)
        .output()
        .expect("spawn silverwood")
}

/// Run, require success, return stdout.
pub fn ok(dir: &TempDir, args: &[&str]) -> String {
    let out = run(dir, args);
    assert!(
        out.status.success(),
        "command {args:?} failed ({}):\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf8 stdout")
}

/// Run, require success, parse stdout as JSON.
pub fn json(dir: &TempDir, args: &[&str]) -> serde_json::Value {
    let stdout = ok(dir, args);
    serde_json::from_str(&stdout)
        .unwrap_or_else(|e| panic!("command {args:?} bad json: {e}\n{stdout}"))
}

/// Like [`run`], with extra environment variables set (e.g. `CLAUDE_CONFIG_DIR`).
pub fn run_env(dir: &TempDir, env: &[(&str, &str)], args: &[&str]) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_silverwood"));
    cmd.env(FOREST_ENV, dir.path());
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.args(args).output().expect("spawn silverwood")
}

/// Like [`json`], with extra environment variables set.
pub fn json_env(dir: &TempDir, env: &[(&str, &str)], args: &[&str]) -> serde_json::Value {
    let out = run_env(dir, env, args);
    assert!(
        out.status.success(),
        "command {args:?} failed ({}):\n{}",
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    serde_json::from_str(&stdout)
        .unwrap_or_else(|e| panic!("command {args:?} bad json: {e}\n{stdout}"))
}

/// Run, require failure (non-zero exit), return stderr.
pub fn fails(dir: &TempDir, args: &[&str]) -> String {
    let out = run(dir, args);
    assert!(
        !out.status.success(),
        "command {args:?} unexpectedly succeeded:\n{}",
        String::from_utf8_lossy(&out.stdout)
    );
    String::from_utf8(out.stderr).expect("utf8 stderr")
}

/// Create a workstream from the example repo (needs network + jj), returning its
/// id. Used only by the `#[ignore]`d e2e tests.
pub fn create(dir: &TempDir, name: &str) -> String {
    let value = json(
        dir,
        &[
            "--json",
            "new",
            "basic",
            "--checkout-extent",
            "full",
            "jj-colocated",
            EXAMPLE_SOURCE,
            "--name",
            name,
        ],
    );
    value["id"].as_str().expect("id field").to_string()
}
