//! Debug-shell command descriptors. The shell is a generic command dispatcher: kinds contribute
//! commands, each flagged read/write, so the write-mode gate applies uniformly without the shell
//! knowing what a command does. See DESIGN §8.

/// Whether a debug command reads or mutates. The shell's per-session write-mode gate keys off this.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DebugAccess {
    Read,
    Write,
}

/// A kind-contributed debug-shell command. §8.
#[derive(Clone, Debug)]
pub struct DebugCommand {
    pub name: String,
    pub access: DebugAccess,
    pub help: String,
}
