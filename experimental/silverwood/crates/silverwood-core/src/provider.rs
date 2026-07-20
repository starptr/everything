use std::path::Path;
use std::process::Command;

use crate::error::{Error, Result};
use crate::source::HttpsGitUrl;
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
        // The colocated clone is shared by both modes; the direnv-unsafe mode chains
        // `direnv allow` after a successful clone.
        match mode {
            NewCheckoutMode::JjColocated { initial_source } => jj_git_clone(initial_source, dest),
            NewCheckoutMode::JjColocatedDirenvUnsafe { initial_source } => {
                jj_git_clone(initial_source, dest)?;
                direnv_allow(dest)
            }
        }
    }
}

/// `jj git clone --colocate <initial_source> <dest>` (shared by both jj-colocated modes).
fn jj_git_clone(initial_source: &HttpsGitUrl, dest: &Path) -> Result<()> {
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

/// Pre-approve the checkout's `.envrc`: `direnv allow <dest>`. Marks approval only —
/// it does not evaluate the `.envrc`. A no-op when the cloned repo has no `.envrc`
/// (`direnv allow` errors on a missing file, and there is nothing to approve).
fn direnv_allow(dest: &Path) -> Result<()> {
    if !dest.join(".envrc").exists() {
        return Ok(());
    }

    let output = Command::new("direnv")
        .arg("allow")
        .arg(dest)
        .output()
        .map_err(|e| Error::Provision(format!("spawning direnv: {e}")))?;

    if !output.status.success() {
        return Err(Error::Provision(format!(
            "`direnv allow` exited {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(())
}
