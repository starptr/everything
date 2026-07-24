//! macOS APFS probes for the `apfs-cow` checkout mode: whether a path lives on an
//! APFS volume, and whether two paths share one volume. Native copy-on-write
//! (`clonefile(2)`, via `cp -c`) requires both endpoints on a single APFS volume,
//! so the mode's creation precheck consults these before anything is persisted.
//!
//! APFS detection is macOS-only (`statfs(2)`'s `f_fstypename` string is a BSD/macOS
//! field; Linux's `statfs` has a numeric `f_type`), so [`is_apfs`] has a non-macOS
//! stub returning `false` — the mode is unsupported off macOS, and its precheck
//! rejects there. [`same_volume`] is portable std and needs no such split.

use std::path::Path;

use crate::error::{Error, Result};

/// Whether `path` resides on an APFS volume (always `false` off macOS).
#[cfg(target_os = "macos")]
pub(crate) fn is_apfs(path: &Path) -> Result<bool> {
    use std::os::unix::ffi::OsStrExt;

    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|e| Error::InvalidSource(format!("{path:?}: path has interior nul: {e}")))?;

    // SAFETY: `c_path` is a valid NUL-terminated C string; `buf` is a zeroed
    // repr(C) `statfs` we only read after the call reports success (rc == 0).
    let mut buf: libc::statfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statfs(c_path.as_ptr(), &mut buf) };
    if rc != 0 {
        return Err(Error::io(path, std::io::Error::last_os_error()));
    }

    // SAFETY: on success `f_fstypename` is a NUL-terminated fs-type name, e.g. "apfs".
    let fstype = unsafe { std::ffi::CStr::from_ptr(buf.f_fstypename.as_ptr()) };
    Ok(fstype.to_bytes() == b"apfs")
}

/// Off macOS there is no APFS: the `apfs-cow` mode is unsupported, so report `false`
/// and let the precheck reject it.
#[cfg(not(target_os = "macos"))]
pub(crate) fn is_apfs(_path: &Path) -> Result<bool> {
    Ok(false)
}

/// Whether `a` and `b` live on the same volume (same device id) — a precondition
/// for an APFS copy-on-write clone, which cannot cross volumes.
pub(crate) fn same_volume(a: &Path, b: &Path) -> Result<bool> {
    use std::os::unix::fs::MetadataExt;
    let dev = |p: &Path| {
        std::fs::metadata(p)
            .map(|m| m.dev())
            .map_err(|e| Error::io(p, e))
    };
    Ok(dev(a)? == dev(b)?)
}
