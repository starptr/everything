//! End-to-end tests for workstream creation + checkout provisioning.
//!
//! The automated tests use a fake provider (no network, no `jj`). The real
//! jj-colocated clone is behind `#[ignore]` — run it in the dev shell with
//! `cargo test -- --ignored`.

mod common;

use std::path::Path;

use common::{new_ws, new_ws_extent, temp_forest, FakeOk};
use silverwood_core::{
    CheckoutExtent, CheckoutProvider, CheckoutState, Error, Forest, LocationWithinForest,
    NewCheckoutMode, Result, Status,
};

/// A provider that always fails provisioning.
struct FakeFail;
impl CheckoutProvider for FakeFail {
    fn provision(&self, _mode: &NewCheckoutMode, _dest: &Path) -> Result<()> {
        Err(Error::Provision("boom".into()))
    }
}

#[test]
fn create_list_get_archive_round_trip() {
    let dir = temp_forest("crud");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    let ws = forest.create_workstream(new_ws("demo")).unwrap();
    assert_eq!(ws.body.status, Status::Active);
    assert_eq!(ws.body.kind.tag(), "basic");
    assert_eq!(ws.body.state(), Some(CheckoutState::Ready));

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
fn remove_soft_deletes_and_discards_checkout() {
    let dir = temp_forest("remove");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    let ws = forest.create_workstream(new_ws("doomed")).unwrap();
    let LocationWithinForest::BasicForest { path } = &ws.body.location().unwrap().within else {
        panic!("expected a basic-forest location");
    };
    let checkout = Path::new(path).to_path_buf();
    assert!(checkout.is_dir(), "FakeOk should have created the checkout");

    // Without --force the safety check refuses: FakeOk's checkout is a bare dir, not a
    // jj workspace root, so it fails condition 1 without shelling out to jj.
    assert!(matches!(
        forest.remove(ws.id, false).unwrap_err(),
        Error::UnsafeToRemove(_)
    ));
    assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Active);
    assert!(
        checkout.is_dir(),
        "refused remove must not touch the checkout"
    );
    assert_eq!(forest.list(false).unwrap().len(), 1);

    // --force: the document is KEPT but tombstoned `deleted`, and the checkout is gone.
    forest.remove(ws.id, true).unwrap();
    assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Deleted);
    assert!(
        forest.list(false).unwrap().is_empty(),
        "deleted is hidden from ls"
    );
    assert_eq!(forest.list(true).unwrap().len(), 1, "but shown by ls --all");
    assert!(!checkout.exists(), "the checked-out code must be deleted");

    // Idempotent: removing an already-deleted workstream is a no-op success.
    forest.remove(ws.id, true).unwrap();
    assert_eq!(forest.get(ws.id).unwrap().body.status, Status::Deleted);

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
    assert_eq!(all[0].body.state(), Some(CheckoutState::Failed));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn skip_defers_provisioning_then_checkout_readies() {
    let dir = temp_forest("skip-ready");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeOk)).unwrap();

    // A skip create registers the workstream without provisioning its checkout.
    let ws = forest
        .create_workstream(new_ws_extent("deferred", CheckoutExtent::Skip))
        .unwrap();
    assert_eq!(
        ws.body.state(),
        Some(CheckoutState::InitializedWithoutCheckout)
    );
    let LocationWithinForest::BasicForest { path } = &ws.body.location().unwrap().within else {
        panic!("expected a basic-forest location");
    };
    assert!(
        !Path::new(path).exists(),
        "skip must not provision the checkout (FakeOk would have created it)"
    );

    // Checking it out runs the provider and flips to Ready.
    let ready = forest.checkout_workstream(ws.id).unwrap();
    assert_eq!(ready.body.state(), Some(CheckoutState::Ready));
    assert!(
        Path::new(path).is_dir(),
        "checkout must now be provisioned on disk"
    );

    // A second checkout is rejected — it is no longer awaiting one.
    assert!(matches!(
        forest.checkout_workstream(ws.id).unwrap_err(),
        Error::NotAwaitingCheckout { .. }
    ));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn skip_then_failed_checkout_records_failed() {
    let dir = temp_forest("skip-fail");
    let forest = Forest::open_with_provider(&dir, Box::new(FakeFail)).unwrap();

    // The skip create SUCCEEDS despite the always-failing provider — proof it never
    // provisioned at creation time.
    let ws = forest
        .create_workstream(new_ws_extent("deferred", CheckoutExtent::Skip))
        .unwrap();
    assert_eq!(
        ws.body.state(),
        Some(CheckoutState::InitializedWithoutCheckout)
    );

    // Checking out runs the failing provider and records a recoverable Failed.
    let err = forest.checkout_workstream(ws.id).unwrap_err();
    assert!(matches!(err, Error::Provision(_)));
    assert_eq!(
        forest.get(ws.id).unwrap().body.state(),
        Some(CheckoutState::Failed)
    );

    // A Failed checkout is not re-checkout-able via this command.
    assert!(matches!(
        forest.checkout_workstream(ws.id).unwrap_err(),
        Error::NotAwaitingCheckout { .. }
    ));

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
    assert_eq!(ws.body.state(), Some(CheckoutState::Ready));

    let LocationWithinForest::BasicForest { path } = &ws.body.location().unwrap().within else {
        panic!("expected a basic-forest location");
    };
    let checkout_dir = Path::new(path);
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
