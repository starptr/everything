//! The gated debug shell: a thin read wrapper over the database by default, with an
//! explicitly-gated write surface that is off by default, per-session, and never persisted. Writes
//! route through the mutation API + the kind's `validate`, never raw SQL. See DESIGN §8.
//!
//! The scaffold provides the mode gate and prompt; command evaluation (read commands over the
//! store, capability-backed + kind-registered write commands) is deferred.

use cp_model::DebugAccess;

use crate::registry::Registry;

/// The shell's per-session write mode. A fresh shell is always read-only. §8.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    ReadOnly,
    Write,
}

/// A read-only-by-default REPL over the store with a gated write surface. §8.
pub struct DebugShell {
    registry: Registry,
    mode: Mode,
}

impl DebugShell {
    pub fn new(registry: Registry) -> Self {
        Self {
            registry,
            mode: Mode::ReadOnly,
        }
    }

    /// The prompt reflecting the mode: `cp[ro]>` vs `cp[write]>`. §8.
    pub fn prompt(&self) -> &'static str {
        match self.mode {
            Mode::ReadOnly => "cp[ro]> ",
            Mode::Write => "cp[write]> ",
        }
    }

    pub fn enable_write_mode(&mut self) {
        self.mode = Mode::Write;
    }

    pub fn disable_write_mode(&mut self) {
        self.mode = Mode::ReadOnly;
    }

    /// Whether a command of the given access may run under the current mode. Every mutating command
    /// refuses until write mode is on. §8.
    pub fn permits(&self, access: DebugAccess) -> bool {
        matches!(
            (self.mode, access),
            (Mode::Write, _) | (Mode::ReadOnly, DebugAccess::Read)
        )
    }

    pub fn registry(&self) -> &Registry {
        &self.registry
    }
}
