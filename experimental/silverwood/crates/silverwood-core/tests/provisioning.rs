//! End-to-end tests for workstream creation + code-checkout provisioning.
//!
//! The automated tests use a fake provider (no network, no `jj`). The real
//! jj-colocated clone is behind `#[ignore]` — run it in the dev shell with
//! `cargo test -- --ignored`.

mod common;

use std::path::Path;

use common::{new_ws, temp_forest, FakeOk};
use silverwood_core::{
    CheckoutMode, CheckoutProvider, CheckoutState, Error, Forest, HttpsGitUrl, Result, Status,
};

/// A provider that always fails provisioning.
struct FakeFail;
impl CheckoutProvider for FakeFail {
    fn provision(&self, _mode: CheckoutMode, _source: &HttpsGitUrl, _dest: &Path) -> Result<()> {
        Err(Error::Provision("boom".into()))
    }
}

#[test]
fn create_list_get_archive_round_trip() {
    let dir = temp_forest("crud");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    let ws = forest.create_workstream(new_ws("demo")).unwrap();
    assert_eq!(ws.body.status, Status::Active);
    assert_eq!(ws.body.kind, "code-checkout");
    let checkout = ws.body.checkouts.values().next().expect("one checkout");
    assert_eq!(checkout.state, CheckoutState::Ready);

    // get reloads to an equal value.
    assert_eq!(forest.get(ws.id).unwrap(), ws);

    // list shows the active workstream.
    let listed = forest.list(false).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, ws.id);

    // archive tombstones it.
    forest.archive(ws.id).unwrap();
    assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Archived);
    assert!(forest.list(false).unwrap().is_empty());
    assert_eq!(forest.list(true).unwrap().len(), 1);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn failed_provision_is_recoverable() {
    let dir = temp_forest("fail");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeFail)).unwrap();

    let err = forest.create_workstream(new_ws("doomed")).unwrap_err();
    assert!(matches!(err, Error::Provision(_)));

    // The workstream persists with its checkout marked Failed — recoverable.
    let all = forest.list(false).unwrap();
    assert_eq!(all.len(), 1);
    let checkout = all[0].body.checkouts.values().next().unwrap();
    assert_eq!(checkout.state, CheckoutState::Failed);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn persists_across_reopen() {
    let dir = temp_forest("reopen");
    let id = {
        let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
        forest.create_workstream(new_ws("persist")).unwrap().id
    };
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();
    assert_eq!(forest.get(id).unwrap().body.name, "persist");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
#[ignore = "network + jj; run via `cargo test -- --ignored`"]
fn real_jj_colocated_clone() {
    let dir = temp_forest("real-clone");
    let forest = Forest::open(&dir).unwrap(); // real JjColocated provider

    let ws = forest.create_workstream(new_ws("hello")).unwrap();
    let checkout = ws.body.checkouts.values().next().unwrap();
    assert_eq!(checkout.state, CheckoutState::Ready);

    let checkout_dir = Path::new(&checkout.location);
    assert!(checkout_dir.join(".jj").exists(), ".jj must exist");
    assert!(
        checkout_dir.join(".git").exists(),
        ".git must exist (colocated)"
    );

    // Workstream persists across reopen.
    let reopened = Forest::open(&dir).unwrap();
    assert_eq!(reopened.get(ws.id).unwrap().id, ws.id);

    let _ = std::fs::remove_dir_all(&dir);
}
