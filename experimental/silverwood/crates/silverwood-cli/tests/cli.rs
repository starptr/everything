//! CLI smoke tests that don't need the network or `jj` (no `new`). They drive
//! the built binary to check arg parsing, JSON output, and exit codes.

use std::path::PathBuf;
use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_silverwood"))
}

fn temp(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("silverwood-cli-{}-{}", std::process::id(), tag));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn info_json_reports_identity() {
    let dir = temp("info");
    let out = bin()
        .args(["--forest", dir.to_str().unwrap(), "--json", "info"])
        .output()
        .unwrap();

    assert!(out.status.success());
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(stdout.contains("\"forest_id\""), "got: {stdout}");
    assert!(stdout.contains("\"peer_id\""), "got: {stdout}");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn ls_empty_forest_is_json_array() {
    let dir = temp("ls");
    let out = bin()
        .args(["--forest", dir.to_str().unwrap(), "--json", "ls"])
        .output()
        .unwrap();

    assert!(out.status.success());
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert_eq!(stdout.trim(), "[]");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn show_with_bad_id_fails() {
    let dir = temp("badid");
    let out = bin()
        .args(["--forest", dir.to_str().unwrap(), "show", "not-a-uuid"])
        .output()
        .unwrap();

    assert!(!out.status.success());
    let stderr = String::from_utf8(out.stderr).unwrap();
    assert!(stderr.contains("invalid workstream id"), "got: {stderr}");

    let _ = std::fs::remove_dir_all(&dir);
}
