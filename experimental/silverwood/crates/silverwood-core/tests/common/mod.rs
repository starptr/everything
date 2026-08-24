//! Shared helpers for integration tests. Each test binary uses a subset, so
//! unused items here are expected.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use silverwood_core::{
    AbsolutePath, CheckoutExtent, CheckoutProvider, HttpsGitUrl, NewCheckoutMode, NewKind,
    NewWorkstream, Result,
};

/// A fresh, unique temp dir for an isolated forest.
pub fn temp_forest(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("silverwood-it-{}-{}", std::process::id(), tag));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// A provider that just creates the destination directory — no network, no jj.
pub struct FakeOk;

impl CheckoutProvider for FakeOk {
    fn provision(&self, _mode: &NewCheckoutMode, dest: &Path) -> Result<()> {
        std::fs::create_dir_all(dest).unwrap();
        Ok(())
    }
}

/// A `NewWorkstream` with a valid public HTTPS source, provisioned in full.
pub fn new_ws(name: &str) -> NewWorkstream {
    new_ws_extent(name, CheckoutExtent::Full)
}

/// A `NewWorkstream` with a valid public HTTPS source and the given checkout extent.
pub fn new_ws_extent(name: &str, checkout_extent: CheckoutExtent) -> NewWorkstream {
    NewWorkstream {
        name: name.into(),
        kind: NewKind::Basic {
            mode: NewCheckoutMode::JjColocated {
                initial_source: HttpsGitUrl::parse("https://github.com/octocat/Hello-World.git")
                    .unwrap(),
            },
            checkout_extent,
        },
    }
}

/// A `NewWorkstream` for the `local-blank` kind (fresh empty in-forest directory).
pub fn new_local_blank(name: &str) -> NewWorkstream {
    NewWorkstream {
        name: name.into(),
        kind: NewKind::LocalBlank,
    }
}

/// A `NewWorkstream` for the `local-tmp` kind (fresh `/tmp/<uuid>` directory).
pub fn new_local_tmp(name: &str) -> NewWorkstream {
    NewWorkstream {
        name: name.into(),
        kind: NewKind::LocalTmp,
    }
}

/// A `NewWorkstream` for the `local-unmanaged-existing-path` kind, adopting `path`.
pub fn new_local_unmanaged(name: &str, path: &str) -> NewWorkstream {
    NewWorkstream {
        name: name.into(),
        kind: NewKind::LocalUnmanagedExistingPath {
            path: AbsolutePath::parse(path).unwrap(),
        },
    }
}
