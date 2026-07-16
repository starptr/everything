use std::path::Path;
use std::process::Command;

use crate::error::{Error, Result};
use crate::workstream::NewCheckoutMode;

/// Materializes a checkout on disk for a chosen [`NewCheckoutMode`].
///
/// Provisioning is a local, fallible side effect: an implementation clones the
/// mode's seed into `dest` (which must not already exist). It only *produces* the
/// provisioning state (ok/err) — it never sees the stored `state`. Injected into
/// [`crate::Forest`] so tests can substitute a fake that skips the network.
pub trait CheckoutProvider {
    /// Materialize `mode` (with its seed) into `dest`.
    fn provision(&self, mode: &NewCheckoutMode, dest: &Path) -> Result<()>;
}

/// The default provider: clones into a jj/git colocated repository via
/// `jj git clone --colocate`.
pub struct JjColocated;

impl CheckoutProvider for JjColocated {
    fn provision(&self, mode: &NewCheckoutMode, dest: &Path) -> Result<()> {
        // Exhaustive today; a new mode forces this provider to handle it.
        let NewCheckoutMode::JjColocated { initial_source } = mode;

        let output = Command::new("jj")
            .arg("git")
            .arg("clone")
            .arg("--colocate")
            .arg(initial_source.as_str())
            .arg(dest)
            .output()
            .map_err(|e| Error::Provision(format!("spawning jj: {e}")))?;

        if !output.status.success() {
            return Err(Error::Provision(format!(
                "`jj git clone --colocate` exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        Ok(())
    }
}
