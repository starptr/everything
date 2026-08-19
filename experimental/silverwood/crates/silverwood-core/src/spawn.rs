//! Session spawning — how silverwood runs a session's shell in a checkout. silverwood
//! owns *how* a shell is created (the environment scrub and the per-kind command), so a
//! frontend (papyrus) just runs `silverwood spawn` instead of reconstructing any of it.
//!
//! Every kind runs in a clean, non-inherited login environment (see `clean_env`): a
//! frontend launched from a nix devshell has a polluted `process.env` (`IN_NIX_SHELL`,
//! `DEVENV_*`, an augmented `PATH`, an overwritten `$SHELL`), so a spawned shell must not
//! inherit it. The user's real login environment is reconstructed by running the login
//! shell from an empty base in a dir with no `.envrc`, and the vars a login capture can't
//! produce are overlaid on top (`TERM`, the ssh-agent socket, `SHELL`, a default `LANG`) —
//! see `overlay_session_env`. The login shell comes from the passwd database (via the
//! frontend's [`SpawnSeed`]), not the polluted `$SHELL`.
//!
//! silverwood is deliberately **direnv-blind** for the interactive kinds. Rather than
//! wrapping `claude` in `direnv exec`, the interactive kinds (`claude-code`, `disk-space`)
//! run the user's real login-interactive shell and *synchronously invoke its own prompt
//! hooks* — whatever the user installed (direnv, git-prompt, …) — before chaining the
//! command with `exec`. So a checkout's `.envrc` loads (or is ignored) exactly as it would
//! when the user types the command at their own prompt, and a user with no direnv hook
//! gets none. A non-interactive `<shell> -c 'cmd'` cannot do this (its interactive rc is
//! not sourced and no prompt is drawn), which is why these kinds use `<shell> -l -i -c` and
//! run the hooks by hand — see `interactive_shell_plan`/`prompt_hook_snippet`. The one
//! kind that still wraps `direnv exec` explicitly is `claude-code-noninteractive`, gated on
//! its own `run_direnv_exec` flag (the deterministic, rc-free counterpart).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The dynamic, machine/session inputs a spawn needs, gathered by the frontend.
/// Resolving these (identity from the passwd database, session context from the
/// environment) is frontend policy, so core takes them explicitly rather than touching
/// `std::env`/the passwd DB itself. `home`/`user`/`shell` seed the login-env capture;
/// `term`/`ssh_auth_sock` are overlaid onto the captured env (a login capture can't
/// have them).
#[derive(Debug, Clone)]
pub struct SpawnSeed {
    /// The user's home directory (`$HOME`).
    pub home: String,
    /// The login user (`$USER`/`$LOGNAME`), if known.
    pub user: Option<String>,
    /// Absolute path to the user's login shell (from the passwd database).
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

/// Whether a claude-code session is starting for the first time (`--session-id`, which
/// creates the conversation) or resuming an existing one (`--resume`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClaudeRun {
    /// First launch of this session id — `claude --session-id <id>`.
    FirstRun,
    /// Reconnect to an existing conversation — `claude --resume <id>`.
    Resume,
}

impl ClaudeRun {
    /// The `claude` flag that selects this run mode.
    fn flag(self) -> &'static str {
        match self {
            ClaudeRun::FirstRun => "--session-id",
            ClaudeRun::Resume => "--resume",
        }
    }
}

/// The **plain-shell** kind: an interactive login shell (`<shell> -l`) in `cwd` with a
/// clean, non-inherited environment. Attached to a tty it reaches a real prompt, so the
/// user's own prompt hooks (direnv, …) fire naturally — no synchronous hook run needed.
pub fn plain_shell_plan(cwd: &str, seed: &SpawnSeed) -> ShellPlan {
    ShellPlan {
        program: seed.shell.clone(),
        args: vec!["-l".to_string()],
        cwd: cwd.to_string(),
        env: clean_env(seed),
    }
}

/// The **claude-code** kind: `claude` run as a thin wrapper over the user's
/// login-interactive shell (so their own direnv/rc setup applies), started fresh
/// (`FirstRun`) or resumed (`Resume`). See `interactive_shell_plan`.
pub fn claude_code_plan(
    cwd: &str,
    session_id: &str,
    run: ClaudeRun,
    seed: &SpawnSeed,
) -> ShellPlan {
    // `session_id` is single-quoted: it is interpolated into the shell `-c` script (a
    // UUID in practice, but quote defensively). The flag is a fixed literal.
    interactive_shell_plan(
        cwd,
        &format!("exec claude {} '{session_id}'", run.flag()),
        seed,
    )
}

/// The **disk-space** kind: a `df` refresh loop, run through the same interactive-shell
/// mechanism as [`plain_shell_plan`] (so it is not special-cased). The loop is POSIX `sh`,
/// not the login shell — the login shell's syntax may differ (e.g. fish).
pub fn disk_space_plan(cwd: &str, seed: &SpawnSeed) -> ShellPlan {
    interactive_shell_plan(
        cwd,
        "exec sh -c 'while true; do clear; df -h; sleep 1; done'",
        seed,
    )
}

/// The **claude-code-noninteractive** kind: `claude` run directly in the clean login env
/// (no interactive shell), optionally wrapped in `direnv exec <cwd>` to load the checkout's
/// pre-approved `.envrc`. The explicit, deterministic counterpart to [`claude_code_plan`] —
/// `run_direnv_exec` selects the wrapping, not the checkout mode. `cwd` is a distinct argv
/// element, so no shell quoting is needed (the plan is exec'd directly, never via a shell).
pub fn claude_code_noninteractive_plan(
    cwd: &str,
    session_id: &str,
    run: ClaudeRun,
    run_direnv_exec: bool,
    seed: &SpawnSeed,
) -> ShellPlan {
    let claude = ["claude", run.flag(), session_id].map(String::from);
    let mut argv: Vec<String> = if run_direnv_exec {
        let mut v = vec!["direnv".to_string(), "exec".to_string(), cwd.to_string()];
        v.extend(claude);
        v
    } else {
        claude.to_vec()
    };
    let program = argv.remove(0);
    ShellPlan {
        program,
        args: argv,
        cwd: cwd.to_string(),
        env: clean_env(seed),
    }
}

/// Run `chained` inside the user's login-interactive shell (`<shell> -l -i -c`), after
/// synchronously invoking the shell's own prompt hooks so `chained` inherits their
/// environment (direnv, etc.). `chained` should `exec` its target so the shell is replaced
/// (the PTY then tracks the target directly). The hook-running snippet is chosen from the
/// login shell's basename; an unknown shell runs no hooks — the same environment a user
/// with none installed would get.
fn interactive_shell_plan(cwd: &str, chained: &str, seed: &SpawnSeed) -> ShellPlan {
    let prefix = prompt_hook_snippet(&seed.shell)
        .map(|s| format!("{s}\n"))
        .unwrap_or_default();
    ShellPlan {
        program: seed.shell.clone(),
        args: vec![
            "-l".to_string(),
            "-i".to_string(),
            "-c".to_string(),
            format!("{prefix}{chained}"),
        ],
        cwd: cwd.to_string(),
        env: clean_env(seed),
    }
}

/// The inline command that runs the login shell's own prompt hooks once — whatever the
/// user installed (direnv, git-prompt, …) — so a command chained after it inherits their
/// environment. Keyed on the login shell's basename, because the shells' syntaxes are
/// mutually unparseable (fish especially), so the branch is chosen before launch. `None`
/// for a shell we do not know how to drive: it degrades to running no hooks (the same
/// environment a user with none installed gets). silverwood names no specific hook (e.g.
/// direnv) here — it just runs whatever the shell registered.
fn prompt_hook_snippet(shell: &str) -> Option<String> {
    let name = Path::new(shell).file_name()?.to_str()?;
    let snippet = match name {
        // zsh keeps prompt hooks in the `precmd_functions` array (+ an optional `precmd`).
        "zsh" => "for f in $precmd_functions; do $f; done; (( $+functions[precmd] )) && precmd",
        // fish exposes a first-class \"run the prompt hooks\": emit the event.
        "fish" => "emit fish_prompt",
        // bash: a login shell reads ~/.bash_profile, never ~/.bashrc — see BASH_PROMPT_HOOK.
        "bash" => BASH_PROMPT_HOOK,
        _ => return None,
    };
    Some(snippet.to_string())
}

/// bash prompt-hook runner (see `prompt_hook_snippet`). A bash login shell sources
/// `~/.bash_profile`, never `~/.bashrc`, so if the profile did not source it the direnv
/// hook was never installed — the guard pulls `~/.bashrc` in *only* when no prompt hook is
/// registered (a no-op in the normal case, so no double-source). It then runs
/// `PROMPT_COMMAND` (a string pre-5.1, an array in 5.1+) and any `precmd_functions`
/// (bash-preexec). Works back to bash 3.2 (the array branch simply never matches there).
const BASH_PROMPT_HOOK: &str = r#"if [[ -z "$(declare -p PROMPT_COMMAND 2>/dev/null)" && ${#precmd_functions[@]} -eq 0 ]]; then [[ -r ~/.bashrc ]] && . ~/.bashrc; fi
if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then for c in "${PROMPT_COMMAND[@]}"; do eval "$c"; done; else [[ -n "${PROMPT_COMMAND:-}" ]] && eval "${PROMPT_COMMAND}"; fi
for f in "${precmd_functions[@]}"; do "$f"; done"#;

/// The scrubbed environment for a spawned shell: the captured login env (or a
/// reconstructed fallback), with the session/identity vars a login capture can't
/// produce overlaid on top (see `overlay_session_env`).
fn clean_env(seed: &SpawnSeed) -> BTreeMap<String, String> {
    let mut env = capture_login_env(seed).unwrap_or_else(|| fallback_env(seed));
    overlay_session_env(&mut env, seed);
    env
}

/// Overlay the vars a login-shell capture can't produce onto `env`: the dynamic terminal
/// context (`TERM`, the ssh-agent socket), `SHELL` (set by `login(1)`, never exported by
/// the shell itself), and a default `LANG` when the capture has none (macOS injects the
/// locale via Terminal.app, not the login shell). `SHELL` is authoritative (a hard
/// overlay); `LANG` is only a default, so a shell that sets its own locale wins.
fn overlay_session_env(env: &mut BTreeMap<String, String>, seed: &SpawnSeed) {
    if let Some(term) = &seed.term {
        env.insert("TERM".to_string(), term.clone());
    }
    if let Some(sock) = &seed.ssh_auth_sock {
        env.insert("SSH_AUTH_SOCK".to_string(), sock.clone());
    }
    env.insert("SHELL".to_string(), seed.shell.clone());
    if !env.contains_key("LANG") && !env.contains_key("LC_ALL") {
        env.insert("LANG".to_string(), "en_US.UTF-8".to_string());
    }
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

    fn seed_with_shell(shell: &str) -> SpawnSeed {
        SpawnSeed {
            home: "/home/x".to_string(),
            user: Some("x".to_string()),
            shell: shell.to_string(),
            term: Some("xterm-256color".to_string()),
            ssh_auth_sock: Some("/tmp/agent.sock".to_string()),
        }
    }

    #[test]
    fn plain_shell_is_a_login_shell() {
        let plan = plain_shell_plan("/w/abc", &seed_with_shell("/bin/zsh"));
        assert_eq!(plan.program, "/bin/zsh");
        assert_eq!(plan.args, vec!["-l"]);
        assert_eq!(plan.cwd, "/w/abc");
    }

    #[test]
    fn claude_code_runs_inside_the_login_interactive_shell() {
        let plan = claude_code_plan(
            "/w/abc",
            "sess-1",
            ClaudeRun::FirstRun,
            &seed_with_shell("/bin/zsh"),
        );
        assert_eq!(plan.program, "/bin/zsh");
        assert_eq!(plan.args[0..3], ["-l", "-i", "-c"]);
        let script = &plan.args[3];
        assert!(
            script.contains("exec claude --session-id 'sess-1'"),
            "script: {script}"
        );
        // Runs the shell's own prompt hooks (zsh: precmd_functions) — never `direnv exec`.
        assert!(script.contains("precmd_functions"), "script: {script}");
        assert!(!script.contains("direnv exec"), "script: {script}");
    }

    #[test]
    fn claude_code_resume_uses_the_resume_flag() {
        let plan = claude_code_plan(
            "/w/abc",
            "sess-1",
            ClaudeRun::Resume,
            &seed_with_shell("/bin/bash"),
        );
        assert!(
            plan.args[3].contains("exec claude --resume 'sess-1'"),
            "script: {}",
            plan.args[3]
        );
    }

    #[test]
    fn disk_space_runs_a_df_loop_via_the_interactive_shell() {
        let plan = disk_space_plan("/w/abc", &seed_with_shell("/usr/bin/fish"));
        assert_eq!(plan.program, "/usr/bin/fish");
        assert_eq!(plan.args[0..3], ["-l", "-i", "-c"]);
        let script = &plan.args[3];
        assert!(script.contains("emit fish_prompt"), "script: {script}"); // fish's hook runner
        assert!(script.contains("df -h"), "script: {script}");
    }

    #[test]
    fn noninteractive_runs_claude_directly_when_direnv_off() {
        let plan = claude_code_noninteractive_plan(
            "/w/abc",
            "sess-1",
            ClaudeRun::FirstRun,
            false,
            &seed_with_shell("/bin/zsh"),
        );
        assert_eq!(plan.program, "claude");
        assert_eq!(plan.args, vec!["--session-id", "sess-1"]);
    }

    #[test]
    fn noninteractive_wraps_claude_in_direnv_exec_when_on() {
        // The checkout path is a distinct argv element (no shell quoting needed).
        let plan = claude_code_noninteractive_plan(
            "/w/a b/c",
            "sess-1",
            ClaudeRun::Resume,
            true,
            &seed_with_shell("/bin/zsh"),
        );
        assert_eq!(plan.program, "direnv");
        assert_eq!(
            plan.args,
            vec!["exec", "/w/a b/c", "claude", "--resume", "sess-1"]
        );
    }

    #[test]
    fn prompt_hook_snippet_is_chosen_by_shell_basename() {
        assert!(prompt_hook_snippet("/bin/zsh")
            .unwrap()
            .contains("precmd_functions"));
        assert_eq!(
            prompt_hook_snippet("/opt/homebrew/bin/fish").unwrap(),
            "emit fish_prompt"
        );
        // bash guards that ~/.bashrc loads even if the login profile didn't source it.
        let bash = prompt_hook_snippet("/bin/bash").unwrap();
        assert!(bash.contains(".bashrc"), "bash: {bash}");
        assert!(bash.contains("PROMPT_COMMAND"), "bash: {bash}");
        // An unknown shell degrades to no hooks.
        assert!(prompt_hook_snippet("/usr/bin/nu").is_none());
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

    #[test]
    fn overlay_sets_shell_authoritatively() {
        // A stale SHELL in the captured env must lose to the resolved login shell.
        let mut env = BTreeMap::new();
        env.insert("SHELL".to_string(), "/bin/bash".to_string());
        overlay_session_env(&mut env, &seed_with_shell("/usr/bin/fish"));
        assert_eq!(env.get("SHELL"), Some(&"/usr/bin/fish".to_string()));
    }

    #[test]
    fn overlay_applies_term_and_ssh_auth_sock() {
        let mut env = BTreeMap::new();
        overlay_session_env(&mut env, &seed_with_shell("/usr/bin/fish"));
        assert_eq!(env.get("TERM"), Some(&"xterm-256color".to_string()));
        assert_eq!(
            env.get("SSH_AUTH_SOCK"),
            Some(&"/tmp/agent.sock".to_string())
        );
    }

    #[test]
    fn overlay_defaults_lang_when_absent() {
        let mut env = BTreeMap::new();
        overlay_session_env(&mut env, &seed_with_shell("/usr/bin/fish"));
        assert_eq!(env.get("LANG"), Some(&"en_US.UTF-8".to_string()));
    }

    #[test]
    fn overlay_keeps_an_existing_lang() {
        let mut env = BTreeMap::new();
        env.insert("LANG".to_string(), "de_DE.UTF-8".to_string());
        overlay_session_env(&mut env, &seed_with_shell("/usr/bin/fish"));
        assert_eq!(env.get("LANG"), Some(&"de_DE.UTF-8".to_string()));
    }

    #[test]
    fn overlay_skips_lang_default_when_lc_all_is_set() {
        let mut env = BTreeMap::new();
        env.insert("LC_ALL".to_string(), "C".to_string());
        overlay_session_env(&mut env, &seed_with_shell("/usr/bin/fish"));
        assert!(!env.contains_key("LANG"));
    }
}
