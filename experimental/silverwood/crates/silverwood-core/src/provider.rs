use std::path::Path;
use std::process::Command;

use crate::error::{Error, Result};
use crate::source::HttpsGitUrl;
use crate::workstream::CheckoutMode;

/// Materializes a code-checkout on disk for a chosen [`CheckoutMode`].
///
/// Provisioning is a local, fallible side effect: an implementation clones
/// `source` into `dest` (which must not already exist). Injected into
/// [`crate::Forest`] so tests can substitute a fake that skips the network.
pub trait CheckoutProvider {
    /// Clone `source` into `dest` using `mode`.
    fn provision(&self, mode: CheckoutMode, source: &HttpsGitUrl, dest: &Path) -> Result<()>;
}

/// The default provider: clones into a jj/git colocated repository via
/// `jj git clone --colocate`.
pub struct JjColocated;

impl CheckoutProvider for JjColocated {
    fn provision(&self, mode: CheckoutMode, source: &HttpsGitUrl, dest: &Path) -> Result<()> {
        // Exhaustive today; a new mode forces this provider to handle it.
        match mode {
            CheckoutMode::JjColocated => {}
        }

        let output = Command::new("jj")
            .arg("git")
            .arg("clone")
            .arg("--colocate")
            .arg(source.as_str())
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
