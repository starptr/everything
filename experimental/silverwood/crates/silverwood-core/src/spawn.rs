//! Interactive-shell spawning — the hard-coded variants for creating an agent
//! shell in a checkout. silverwood owns *how* an interactive shell is created
//! (both the environment scrub and the per-checkout-mode command), so a frontend
//! (papyrus) just runs `silverwood spawn` instead of reconstructing any of it.
//!
//! Two variants, both fixed in code (never data — a data-driven command would be
//! an arbitrary-code-execution surface):
//!   1. a **base shell** — a clean login shell that does NOT inherit the parent
//!      process's environment, and
//!   2. an **agent** — `claude` run inside that clean env, wrapped in
//!      `direnv exec <cwd>` for the direnv-unsafe checkout mode so it loads the
//!      checkout's pre-approved `.envrc`.
//!
//! The env scrub mirrors what papyrus used to do inline: `process.env` in a
//! frontend launched from a nix devshell is polluted (`IN_NIX_SHELL`, `DEVENV_*`,
//! an augmented `PATH`), so a spawned agent must not inherit it. Instead the
//! user's real login environment is reconstructed by running the login shell from
//! an empty base in a dir with no `.envrc`, and the two dynamic vars a terminal
//! needs (`TERM`, the ssh-agent socket) are overlaid on top.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::workstream::CheckoutMode;

/// The dynamic, machine/session inputs a spawn needs, gathered by the frontend.
/// Reading these from the environment is frontend policy (like the forest dir),
/// so core takes them explicitly rather than touching `std::env`. `home`/`user`/
/// `shell` seed the login-env capture; `term`/`ssh_auth_sock` are overlaid onto
/// the captured env (a login capture can't have them).
#[derive(Debug, Clone)]
pub struct SpawnSeed {
    /// The user's home directory (`$HOME`).
    pub home: String,
    /// The login user (`$USER`/`$LOGNAME`), if known.
    pub user: Option<String>,
    /// Absolute path to the user's login shell (`$SHELL`).
    pub shell: String,
    /// The terminal type to advertise (`$TERM`), if any.
    pub term: Option<String>,
    /// The ssh-agent socket to forward (`$SSH_AUTH_SOCK`), if any.
    pub ssh_auth_sock: Option<String>,
}

/// A fully-resolved recipe for spawning an interactive shell: the program to run
/// (a bare name resolved against `env`'s PATH, or an absolute path as-is), its
/// arguments (after the program itself), the working directory, and the environment
/// — a clean login env, never the parent's. The CLI either `exec`s this
/// (replacing its process) or prints it (`--json`) for inspection.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ShellPlan {
    /// The program to exec (bare name → resolved via `env`'s PATH; else as-is).
    pub program: String,
    /// Arguments after the program name.
    pub args: Vec<String>,
    /// Working directory to run in (the checkout path).
    pub cwd: String,
    /// The complete, scrubbed environment for the spawned process.
    pub env: BTreeMap<String, String>,
}

impl ShellPlan {
    /// Resolve [`ShellPlan::program`] to an absolute path for exec: a name with a
    /// slash is used verbatim; a bare name is searched for on `env`'s PATH (so the
    /// login PATH — where `claude`/`direnv` live — decides, not the caller's).
    pub fn resolve_program(&self) -> Option<PathBuf> {
        if self.program.contains('/') {
            return Some(PathBuf::from(&self.program));
        }
        let path = self.env.get("PATH")?;
        path.split(':')
            .filter(|dir| !dir.is_empty())
            .map(|dir| Path::new(dir).join(&self.program))
            .find(|candidate| is_executable(candidate))
    }
}

/// The **base shell** variant: an interactive login shell (`<shell> -l`) in `cwd`
/// with a clean, non-inherited environment.
pub fn base_shell_plan(cwd: &str, seed: &SpawnSeed) -> ShellPlan {
    ShellPlan {
        program: seed.shell.clone(),
        args: vec!["-l".to_string()],
        cwd: cwd.to_string(),
        env: clean_env(seed),
    }
}

/// The **agent** variant: `claude` (fresh `--session-id`, or `--resume` to
/// reconnect), wrapped in `direnv exec <cwd>` for the direnv-unsafe checkout mode,
/// in a clean, non-inherited environment.
pub fn agent_shell_plan(
    mode: &CheckoutMode,
    cwd: &str,
    session_id: &str,
    resume: bool,
    seed: &SpawnSeed,
) -> ShellPlan {
    let mut argv = agent_argv(mode, cwd, session_id, resume);
    let program = argv.remove(0);
    ShellPlan {
        program,
        args: argv,
        cwd: cwd.to_string(),
        env: clean_env(seed),
    }
}

/// The agent command argv, selected from the checkout mode. Hard-coded per mode
/// (no data-driven templates): the direnv-unsafe mode runs claude under
/// `direnv exec <cwd>` (its `.envrc` was pre-approved at clone time); every other
/// mode runs claude directly. `cwd` is passed as its own argv element, so no shell
/// quoting is needed (the plan is exec'd directly, never through a shell).
fn agent_argv(mode: &CheckoutMode, cwd: &str, session_id: &str, resume: bool) -> Vec<String> {
    let flag = if resume { "--resume" } else { "--session-id" };
    let claude = ["claude", flag, session_id].map(String::from);
    match mode {
        CheckoutMode::JjColocatedDirenvUnsafe { .. } => {
            let mut argv = vec!["direnv".to_string(), "exec".to_string(), cwd.to_string()];
            argv.extend(claude);
            argv
        }
        _ => claude.to_vec(),
    }
}

/// The scrubbed environment for a spawned shell: the captured login env (or a
/// reconstructed fallback), with `TERM` and the ssh-agent socket overlaid.
fn clean_env(seed: &SpawnSeed) -> BTreeMap<String, String> {
    let mut env = capture_login_env(seed).unwrap_or_else(|| fallback_env(seed));
    if let Some(term) = &seed.term {
        env.insert("TERM".to_string(), term.clone());
    }
    if let Some(sock) = &seed.ssh_auth_sock {
        env.insert("SSH_AUTH_SOCK".to_string(), sock.clone());
    }
    env
}

/// Run the user's login shell from an empty base and read back its exported env:
/// `env -i HOME=… [USER/LOGNAME=…] <shell> -l -c '/usr/bin/env -0'` in `/` (a dir
/// with no `.envrc`, so no direnv pollutes the capture). Returns `None` on a
/// non-zero exit or a capture with no PATH, so the caller falls back.
fn capture_login_env(seed: &SpawnSeed) -> Option<BTreeMap<String, String>> {
    let mut cmd = Command::new("/usr/bin/env");
    cmd.env_clear()
        .current_dir("/")
        .arg("-i")
        .arg(format!("HOME={}", seed.home));
    if let Some(user) = &seed.user {
        cmd.arg(format!("USER={user}"))
            .arg(format!("LOGNAME={user}"));
    }
    cmd.arg(&seed.shell)
        .arg("-l")
        .arg("-c")
        .arg("/usr/bin/env -0");

    let output = cmd.output().ok()?;
    if !output.status.success() {
        return None;
    }

    let mut env = BTreeMap::new();
    for pair in output.stdout.split(|b| *b == 0) {
        if pair.is_empty() {
            continue;
        }
        let pair = String::from_utf8_lossy(pair);
        if let Some(eq) = pair.find('=') {
            if eq == 0 {
                continue;
            }
            env.insert(pair[..eq].to_string(), pair[eq + 1..].to_string());
        }
    }
    if !env.contains_key("PATH") {
        return None;
    }
    Some(env)
}

/// A minimal clean env if the login capture fails: identity from the seed plus a
/// deterministic nix-darwin PATH (where `claude`/`direnv`/`jj`/`git` live).
fn fallback_env(seed: &SpawnSeed) -> BTreeMap<String, String> {
    let user = seed.user.clone().unwrap_or_default();
    let path = [
        format!("{}/.nix-profile/bin", seed.home),
        format!("/etc/profiles/per-user/{user}/bin"),
        "/run/current-system/sw/bin".to_string(),
        "/nix/var/nix/profiles/default/bin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/bin".to_string(),
        "/bin".to_string(),
        "/usr/sbin".to_string(),
        "/sbin".to_string(),
    ]
    .join(":");

    let mut env = BTreeMap::new();
    env.insert("PATH".to_string(), path);
    env.insert("HOME".to_string(), seed.home.clone());
    env.insert("SHELL".to_string(), seed.shell.clone());
    if let Some(user) = &seed.user {
        env.insert("USER".to_string(), user.clone());
        env.insert("LOGNAME".to_string(), user.clone());
    }
    env
}

/// Whether `path` is a regular file with an owner/group/other execute bit set.
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workstream::CheckoutState;

    fn jj_colocated() -> CheckoutMode {
        CheckoutMode::JjColocated {
            initial_source: "https://example.com/x.git".into(),
            state: CheckoutState::Ready,
        }
    }

    fn direnv_unsafe() -> CheckoutMode {
        CheckoutMode::JjColocatedDirenvUnsafe {
            initial_source: "https://example.com/x.git".into(),
            state: CheckoutState::Ready,
        }
    }

    #[test]
    fn plain_mode_runs_claude_directly() {
        assert_eq!(
            agent_argv(&jj_colocated(), "/w/abc", "sess-1", false),
            vec!["claude", "--session-id", "sess-1"]
        );
    }

    #[test]
    fn resume_flips_the_claude_flag() {
        assert_eq!(
            agent_argv(&jj_colocated(), "/w/abc", "sess-1", true),
            vec!["claude", "--resume", "sess-1"]
        );
    }

    #[test]
    fn direnv_unsafe_mode_wraps_claude_in_direnv_exec() {
        // The checkout path is a distinct argv element (no shell quoting needed).
        assert_eq!(
            agent_argv(&direnv_unsafe(), "/w/a b/c", "sess-1", false),
            vec![
                "direnv",
                "exec",
                "/w/a b/c",
                "claude",
                "--session-id",
                "sess-1"
            ]
        );
        assert_eq!(
            agent_argv(&direnv_unsafe(), "/w/abc", "sess-1", true),
            vec!["direnv", "exec", "/w/abc", "claude", "--resume", "sess-1"]
        );
    }

    #[test]
    fn resolve_program_uses_the_env_path() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("claude");
        std::fs::write(&bin, "#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();

        let mut env = BTreeMap::new();
        env.insert(
            "PATH".to_string(),
            format!("/nonexistent:{}", dir.path().display()),
        );
        let plan = ShellPlan {
            program: "claude".to_string(),
            args: vec![],
            cwd: "/".to_string(),
            env,
        };
        assert_eq!(plan.resolve_program(), Some(bin));
    }

    #[test]
    fn resolve_program_passes_through_absolute_paths() {
        let plan = ShellPlan {
            program: "/bin/zsh".to_string(),
            args: vec!["-l".to_string()],
            cwd: "/".to_string(),
            env: BTreeMap::new(),
        };
        assert_eq!(plan.resolve_program(), Some(PathBuf::from("/bin/zsh")));
    }
}
