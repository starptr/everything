//! Shared helpers for integration tests. Each test binary uses a subset, so
//! unused items here are expected.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use silverwood_core::{
    CheckoutProvider, HttpsGitUrl, NewCheckoutMode, NewKind, NewWorkstream, Result,
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

/// A `NewWorkstream` with a valid public HTTPS source.
pub fn new_ws(name: &str) -> NewWorkstream {
    NewWorkstream {
        name: name.into(),
        kind: NewKind::Basic {
            mode: NewCheckoutMode::JjColocated {
                initial_source: HttpsGitUrl::parse("https://github.com/octocat/Hello-World.git")
                    .unwrap(),
            },
        },
    }
}
