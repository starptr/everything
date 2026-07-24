//! `silverwood` — a thin CLI over `silverwood-core`.
//!
//! Every command takes explicit arguments (core supplies no defaults) and can
//! emit machine-readable JSON with `--json`, so any frontend can drive the same
//! backend by shelling out. The one frontend policy that lives here is the
//! default forest location, `$HOME/.silverwood`.

use std::collections::BTreeMap;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::ExitCode;
use std::str::FromStr;

use clap::{Parser, Subcommand};
use silverwood_core::{
    agent_shell_plan, base_shell_plan, AgentKind, AgentSession, CheckoutState, Forest, HttpsGitUrl,
    LocationWithinForest, NewCheckoutMode, NewKind, NewWorkstream, SpawnSeed, UpgradeReport,
    Workstream, WorkstreamId, DOC_SCHEMA_VERSION,
};

/// Frontend-agnostic backend for the code you work on and the agent sessions
/// attached to it.
#[derive(Parser)]
#[command(name = "silverwood", version, about, long_about = None)]
struct Cli {
    /// Path to the forest (default: `$SILVERWOOD_FOREST_PATH`, else `$HOME/.silverwood`).
    #[arg(long, global = true, value_name = "DIR")]
    forest: Option<PathBuf>,

    /// Emit machine-readable JSON instead of human-readable text.
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Open the forest (creating it if absent) and print its identity.
    Info,

    /// Create a workstream, provisioning its checkout.
    New {
        /// Human-friendly name (accepted at any `new` subcommand level).
        #[arg(long, global = true)]
        name: Option<String>,
        #[command(subcommand)]
        variant: NewVariant,
    },

    /// List workstreams.
    Ls {
        /// Include archived workstreams.
        #[arg(long)]
        all: bool,
    },

    /// Show a workstream by id.
    Show {
        /// The workstream id (from `silverwood ls`).
        id: String,
    },

    /// Archive a workstream (tombstone).
    Archive {
        /// The workstream id (from `silverwood ls`).
        id: String,
    },

    /// Rename a workstream.
    Rename {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// The new display name.
        name: String,
    },

    /// Namespaced key-value state (frontend-owned).
    #[command(subcommand)]
    Kv(KvCommand),

    /// Agent sessions (a kind-aware wrapper over the reserved session kv).
    #[command(subcommand)]
    Session(SessionCommand),

    /// Upgrade every document in the forest to the latest schema version.
    UpgradeForest {
        /// Report what would change without writing.
        #[arg(long)]
        dry_run: bool,
    },

    /// List the available checkout modes for `new basic <MODE>`.
    Modes,

    /// Exec the interactive agent shell for a session in its checkout. The command
    /// is chosen from the checkout mode (env-scrubbed; `direnv exec` for the
    /// direnv-unsafe mode) — this replaces the process with the agent, so on
    /// success it never returns. Omit `session_id` for a bare login shell.
    Spawn {
        /// The workstream id whose checkout to spawn in (from `silverwood ls`).
        workstream_id: String,
        /// The Claude session id to run (`claude --session-id`/`--resume`); omit
        /// for a plain login shell in the checkout.
        session_id: Option<String>,
        /// Resume the session (`claude --resume`) instead of starting it fresh.
        #[arg(long)]
        resume: bool,
    },
}

/// Positional args are shared across kv subcommands: `<ID> <NAMESPACE> [KEY] [VALUE]`.
/// `id` is the workstream id; `namespace` is a reverse-DNS, frontend-owned prefix
/// (the `app.andref.silverwood.*` prefix is reserved).
#[derive(Subcommand)]
enum KvCommand {
    /// Set a value (value is an opaque JSON string).
    Set {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// The namespace (reverse-DNS; `app.andref.silverwood.*` is reserved).
        namespace: String,
        /// The key within the namespace.
        key: String,
        /// The value; stored verbatim as an opaque JSON string.
        value: String,
    },
    /// Get a value.
    Get {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// The namespace the key lives in.
        namespace: String,
        /// The key within the namespace.
        key: String,
    },
    /// List all entries in a namespace.
    Ls {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// The namespace to list.
        namespace: String,
    },
    /// Remove a value.
    Unset {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// The namespace the key lives in.
        namespace: String,
        /// The key to remove.
        key: String,
    },
}

#[derive(Subcommand)]
enum SessionCommand {
    /// Create (record) a session of a given agent kind.
    #[command(subcommand)]
    Create(SessionCreate),
    /// List the agent sessions recorded on a workstream.
    Ls {
        /// The workstream id whose sessions to list (from `silverwood ls`).
        id: String,
    },
    /// Rename a session (preserving its kind + created_at).
    Rename {
        /// The workstream id the session belongs to (from `silverwood ls`).
        id: String,
        /// The session id to rename.
        session_id: String,
        /// The new session name.
        name: String,
    },
    /// Remove a session.
    Rm {
        /// The workstream id the session belongs to (from `silverwood ls`).
        id: String,
        /// The session id to remove.
        session_id: String,
    },
    /// Acquire a session's best-effort advisory lock (cooperative; stops
    /// considerate clients from resuming the same session at once).
    Lock {
        /// The workstream id the session belongs to (from `silverwood ls`).
        id: String,
        /// The session id to lock.
        session_id: String,
        /// Opaque holder token identifying who is taking the lock.
        #[arg(long)]
        holder: String,
        /// Steal the lock even if another holder currently holds it.
        #[arg(long)]
        force: bool,
    },
    /// Release a session's advisory lock (no-op if unlocked).
    Unlock {
        /// The workstream id the session belongs to (from `silverwood ls`).
        id: String,
        /// The session id to unlock.
        session_id: String,
        /// Only release if held by this holder (omit with `--force` to clear any).
        #[arg(long)]
        holder: Option<String>,
        /// Release regardless of who holds it.
        #[arg(long)]
        force: bool,
    },
}

/// Per-kind session creation: each agent kind takes the parameters it needs, so
/// the argument shape is not forced to be identical across kinds (today: one).
#[derive(Subcommand)]
enum SessionCreate {
    /// A Claude Code session. `session_id` is the Claude session id; `name`
    /// defaults to the session id when omitted.
    ClaudeCode {
        /// The workstream id to attach the session to (from `silverwood ls`).
        id: String,
        /// The Claude Code session id to record.
        session_id: String,
        /// Display name for the session (defaults to the session id).
        #[arg(long)]
        name: Option<String>,
    },
}

/// The workstream variant (kind) to create — the first `new` subcommand level. Only
/// `basic` today (`WorkstreamKind` is `#[non_exhaustive]`); the kebab name matches the
/// stored `kind` tag.
#[derive(Subcommand)]
enum NewVariant {
    /// A basic workstream, materialized by a checkout mode.
    Basic {
        #[command(subcommand)]
        mode: NewModeArg,
    },
}

/// A `basic` workstream's checkout mode — the second `new` subcommand level. Each variant
/// carries that mode's creation seed as positionals; the kebab name matches the stored
/// `checkout_mode` tag.
#[derive(Subcommand)]
enum NewModeArg {
    /// jj/git colocated clone (`jj git clone --colocate`).
    JjColocated {
        /// HTTPS git endpoint to clone from.
        #[arg(value_name = "SOURCE_HTTPS_URL")]
        source: String,
    },
    /// jj-colocated clone, then `direnv allow` on the checkout (pre-approves .envrc; unsafe).
    JjColocatedDirenvUnsafe {
        /// HTTPS git endpoint to clone from.
        #[arg(value_name = "SOURCE_HTTPS_URL")]
        source: String,
    },
}

impl NewModeArg {
    /// Build the creation-side mode from the selector + its seed, validating the seed.
    /// Consumes `self` (the seed `String` moves into the returned mode).
    fn into_new_mode(self) -> Result<NewCheckoutMode, Box<dyn std::error::Error>> {
        Ok(match self {
            NewModeArg::JjColocated { source } => NewCheckoutMode::JjColocated {
                initial_source: HttpsGitUrl::parse(&source)?,
            },
            NewModeArg::JjColocatedDirenvUnsafe { source } => {
                NewCheckoutMode::JjColocatedDirenvUnsafe {
                    initial_source: HttpsGitUrl::parse(&source)?,
                }
            }
        })
    }
}

/// A checkout mode's metadata, for `silverwood modes` (drives a frontend picker).
#[derive(serde::Serialize)]
struct ModeInfo {
    /// The kebab tag naming the `new basic <MODE>` subcommand (matches the stored
    /// `checkout_mode`).
    mode: String,
    /// One-line human description.
    description: String,
    /// Whether this mode takes a source seed (has a `source` positional).
    requires_source: bool,
}

/// Metadata for every checkout mode, derived from the `new basic` subcommand tree so the
/// clap definitions stay the single source of truth (tag = subcommand name, description =
/// its help, `requires_source` = whether it has the `source` positional).
fn mode_infos() -> Vec<ModeInfo> {
    let basic = NewVariant::augment_subcommands(clap::Command::new("new"));
    basic
        .find_subcommand("basic")
        .expect("basic subcommand exists")
        .get_subcommands()
        .map(|sc| ModeInfo {
            mode: sc.get_name().to_string(),
            description: sc.get_about().map(|a| a.to_string()).unwrap_or_default(),
            requires_source: sc
                .get_positionals()
                .any(|a| a.get_id().as_str() == "source"),
        })
        .collect()
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("silverwood: {err}");
            ExitCode::FAILURE
        }
    }
}

type CliResult = Result<(), Box<dyn std::error::Error>>;

fn run(cli: Cli) -> CliResult {
    let root = match cli.forest {
        Some(path) => path,
        None => resolve_forest_dir()?,
    };
    let json = cli.json;

    // `modes` is pure metadata — handle it before opening (and thereby creating)
    // the forest, so listing modes never touches `$HOME/.silverwood`.
    if let Command::Modes = cli.command {
        let modes = mode_infos();
        emit(json, &modes, || {
            for m in &modes {
                println!("{:28}  {}", m.mode, m.description);
            }
        });
        return Ok(());
    }

    let forest = Forest::open(&root)?;

    match cli.command {
        Command::Info => info(&forest, json),

        Command::New { name, variant } => run_new(&forest, json, name, variant),

        Command::Ls { all } => {
            let list = forest.list(all)?;
            emit(json, &list, || {
                for ws in &list {
                    println!(
                        "{}  {:8}  {}",
                        ws.id,
                        enum_str(ws.body.status),
                        ws.body.name
                    );
                }
            });
            Ok(())
        }

        Command::Show { id } => {
            let ws = forest.get(parse_id(&id)?)?;
            emit(json, &ws, || print_workstream(&ws));
            Ok(())
        }

        Command::Archive { id } => {
            let id = parse_id(&id)?;
            forest.archive(id)?;
            let ws = forest.get(id)?;
            emit(json, &ws, || println!("archived {}", ws.id));
            Ok(())
        }

        Command::Rename { id, name } => {
            let id = parse_id(&id)?;
            forest.rename(id, &name)?;
            let ws = forest.get(id)?;
            emit(json, &ws, || print_workstream(&ws));
            Ok(())
        }

        Command::Kv(cmd) => run_kv(&forest, json, cmd),
        Command::Session(cmd) => run_session(&forest, json, cmd),

        Command::Spawn {
            workstream_id,
            session_id,
            resume,
        } => run_spawn(&forest, json, &workstream_id, session_id.as_deref(), resume),

        Command::UpgradeForest { dry_run } => {
            let reports = forest.upgrade_all(dry_run)?;
            emit(json, &reports, || print_upgrade(&reports, dry_run));
            Ok(())
        }

        // Handled above, before the forest is opened.
        Command::Modes => unreachable!("modes is handled before Forest::open"),
    }
}

fn run_new(forest: &Forest, json: bool, name: Option<String>, variant: NewVariant) -> CliResult {
    let name = name.ok_or("`--name <NAME>` is required")?;
    let NewVariant::Basic { mode } = variant;
    let ws = forest.create_workstream(NewWorkstream {
        name,
        kind: NewKind::Basic {
            mode: mode.into_new_mode()?,
        },
    })?;
    emit(json, &ws, || print_workstream(&ws));
    Ok(())
}

fn run_kv(forest: &Forest, json: bool, cmd: KvCommand) -> CliResult {
    match cmd {
        KvCommand::Set {
            id,
            namespace,
            key,
            value,
        } => {
            let id = parse_id(&id)?;
            forest.set_kv(id, &namespace, &key, &value)?;
            let entries = forest.list_kv(id, &namespace)?;
            emit(json, &entries, || print_kv(&entries));
        }
        KvCommand::Unset { id, namespace, key } => {
            let id = parse_id(&id)?;
            forest.unset_kv(id, &namespace, &key)?;
            let entries = forest.list_kv(id, &namespace)?;
            emit(json, &entries, || print_kv(&entries));
        }
        KvCommand::Get { id, namespace, key } => {
            let value = forest.get_kv(parse_id(&id)?, &namespace, &key)?;
            emit(json, &value, || {
                if let Some(v) = &value {
                    println!("{v}");
                }
            });
        }
        KvCommand::Ls { id, namespace } => {
            let entries = forest.list_kv(parse_id(&id)?, &namespace)?;
            emit(json, &entries, || print_kv(&entries));
        }
    }
    Ok(())
}

fn run_session(forest: &Forest, json: bool, cmd: SessionCommand) -> CliResult {
    let id = match &cmd {
        SessionCommand::Create(SessionCreate::ClaudeCode { id, .. })
        | SessionCommand::Ls { id }
        | SessionCommand::Rename { id, .. }
        | SessionCommand::Rm { id, .. }
        | SessionCommand::Lock { id, .. }
        | SessionCommand::Unlock { id, .. } => parse_id(id)?,
    };

    match cmd {
        SessionCommand::Create(SessionCreate::ClaudeCode {
            session_id, name, ..
        }) => {
            let name = name.unwrap_or_else(|| session_id.clone());
            forest.create_session(id, &session_id, AgentKind::ClaudeCode { lock: None }, &name)?;
        }
        SessionCommand::Rename {
            session_id, name, ..
        } => forest.rename_session(id, &session_id, &name)?,
        SessionCommand::Rm { session_id, .. } => forest.remove_session(id, &session_id)?,
        SessionCommand::Lock {
            session_id,
            holder,
            force,
            ..
        } => forest.lock_session(id, &session_id, &holder, force)?,
        SessionCommand::Unlock {
            session_id,
            holder,
            force,
            ..
        } => forest.unlock_session(id, &session_id, holder.as_deref(), force)?,
        SessionCommand::Ls { .. } => {}
    }

    let sessions = forest.get(id)?.body.sessions();
    emit(json, &sessions, || print_sessions(&sessions));
    Ok(())
}

/// Build the interactive-shell plan for a session (from the checkout mode) and
/// `exec` it, replacing this process with the agent — so the caller's PTY tracks
/// the agent's lifetime directly. `--json` prints the resolved plan instead of
/// exec'ing (for inspection/tests). The env/command construction lives in
/// `silverwood-core`; reading the seed vars from the environment is frontend
/// policy (like [`resolve_forest_dir`]), so it stays here.
fn run_spawn(
    forest: &Forest,
    json: bool,
    id: &str,
    session_id: Option<&str>,
    resume: bool,
) -> CliResult {
    let ws = forest.get(parse_id(id)?)?;
    let mode = ws
        .body
        .mode()
        .ok_or("workstream has no checkout to spawn in")?;
    if mode.state() != CheckoutState::Ready {
        return Err(format!("checkout is not ready (state: {})", enum_str(mode.state())).into());
    }
    let Some(LocationWithinForest::BasicForest { path: cwd }) =
        ws.body.location().map(|loc| &loc.within)
    else {
        return Err("workstream has no checkout location".into());
    };

    let seed = spawn_seed()?;
    let plan = match session_id {
        Some(session_id) => agent_shell_plan(mode, cwd, session_id, resume, &seed),
        None => base_shell_plan(cwd, &seed),
    };

    if json {
        println!("{}", serde_json::to_string_pretty(&plan)?);
        return Ok(());
    }

    let program = plan
        .resolve_program()
        .ok_or_else(|| format!("{:?} not found on the login PATH", plan.program))?;
    // Fully-qualified: the local `Command` is the clap subcommand enum.
    let err = std::process::Command::new(&program)
        .args(&plan.args)
        .current_dir(&plan.cwd)
        .env_clear()
        .envs(&plan.env)
        .exec();
    // `exec` replaces the process image, so it only returns on failure.
    Err(format!("exec {}: {err}", program.display()).into())
}

/// Gather the spawn's dynamic inputs from the environment — frontend policy, like
/// [`resolve_forest_dir`] (`silverwood-core` never reads env). `HOME` is required
/// to reconstruct a login environment; `SHELL` defaults if unset.
fn spawn_seed() -> Result<SpawnSeed, Box<dyn std::error::Error>> {
    let home =
        std::env::var("HOME").map_err(|_| "no HOME: cannot reconstruct a login environment")?;
    let user = std::env::var("USER")
        .ok()
        .or_else(|| std::env::var("LOGNAME").ok());
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
    let term = std::env::var("TERM").ok();
    let ssh_auth_sock = std::env::var("SSH_AUTH_SOCK").ok();
    Ok(SpawnSeed {
        home,
        user,
        shell,
        term,
        ssh_auth_sock,
    })
}

fn info(forest: &Forest, json: bool) -> CliResult {
    let pending = forest.pending_upgrades()?;
    if json {
        let value = serde_json::json!({
            "root": forest.root().display().to_string(),
            "forest_id": forest.id().to_string(),
            "peer_id": forest.peer_id(),
            "schema_version": DOC_SCHEMA_VERSION,
            "pending_upgrades": pending,
        });
        println!("{}", serde_json::to_string_pretty(&value)?);
    } else {
        println!("root           = {}", forest.root().display());
        println!("forest_id      = {}", forest.id());
        println!("peer_id        = {}", forest.peer_id());
        println!("schema_version = {DOC_SCHEMA_VERSION}");
        if pending > 0 {
            println!("pending        = {pending} document(s) need `upgrade-forest`");
        }
    }
    Ok(())
}

/// Print an `upgrade-forest` report: the upgraded documents plus a summary.
fn print_upgrade(reports: &[UpgradeReport], dry_run: bool) {
    let verb = if dry_run { "would upgrade" } else { "upgraded" };
    let upgraded: Vec<&UpgradeReport> = reports.iter().filter(|r| r.upgraded()).collect();
    for r in &upgraded {
        println!("{}  v{} → v{}  ({verb})", r.id, r.from, r.to);
    }
    if upgraded.is_empty() {
        println!(
            "forest up-to-date: {} document(s) at v{DOC_SCHEMA_VERSION}",
            reports.len()
        );
    } else {
        println!(
            "{verb} {} of {} document(s) to v{DOC_SCHEMA_VERSION}",
            upgraded.len(),
            reports.len()
        );
    }
}

/// Emit `value` as pretty JSON, or run `human` for text output.
fn emit<T: serde::Serialize>(json: bool, value: &T, human: impl FnOnce()) {
    if json {
        match serde_json::to_string_pretty(value) {
            Ok(text) => println!("{text}"),
            Err(err) => eprintln!("silverwood: serializing output: {err}"),
        }
    } else {
        human();
    }
}

fn print_workstream(ws: &Workstream) {
    println!(
        "{}  [{}]  {}",
        ws.id,
        enum_str(ws.body.status),
        ws.body.name
    );
    println!("  kind:     {}", ws.body.kind.tag());
    if let Some(mode) = ws.body.mode() {
        println!("  mode:     {} [{}]", mode.tag(), enum_str(mode.state()));
        println!("  source:   {}", mode.initial_source());
    }
    println!("  created:  {}", ws.body.created_at);
    if let Some(location) = ws.body.location() {
        if let LocationWithinForest::BasicForest { path } = &location.within {
            println!("  checkout: {path} (forest {})", location.forest_id);
        }
    }
    let session_count = ws.body.sessions().len();
    if session_count > 0 {
        println!("  sessions: {session_count}");
    }
    let kv_entries: usize = ws.body.kv.values().map(BTreeMap::len).sum();
    if kv_entries > 0 {
        println!(
            "  kv:       {kv_entries} entr{} in {} namespace(s)",
            if kv_entries == 1 { "y" } else { "ies" },
            ws.body.kv.len()
        );
    }
}

fn print_kv(entries: &BTreeMap<String, String>) {
    for (key, value) in entries {
        println!("{key} = {value}");
    }
}

fn print_sessions(sessions: &BTreeMap<String, AgentSession>) {
    for (session_id, session) in sessions {
        let lock = match session.lock() {
            Some(l) => format!("  🔒 {}", l.holder),
            None => String::new(),
        };
        println!(
            "{session_id}  {}  [{}]  (since {}){lock}",
            session.name,
            session.kind.tag(),
            session.created_at
        );
    }
}

/// Render a serde enum to its serialized string form (single source of truth
/// with the stored representation), e.g. `Status::Active` → `active`.
fn enum_str(value: impl serde::Serialize) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_default()
}

fn parse_id(input: &str) -> Result<WorkstreamId, Box<dyn std::error::Error>> {
    WorkstreamId::from_str(input)
        .map_err(|e| format!("invalid workstream id {input:?}: {e}").into())
}

/// Resolve the forest location when `--forest` is not given: the
/// `SILVERWOOD_FOREST_PATH` env var if set (and non-empty), else
/// `$HOME/.silverwood`.
///
/// Precedence overall is `--forest` flag > `SILVERWOOD_FOREST_PATH` > default —
/// all frontend policy that deliberately lives here, not in `silverwood-core`
/// (see `DESIGN.md` §2.4).
fn resolve_forest_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = std::env::var_os("SILVERWOOD_FOREST_PATH") {
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    let home = std::env::var_os("HOME").ok_or(
        "no forest location: pass --forest <DIR>, set SILVERWOOD_FOREST_PATH, or set HOME",
    )?;
    Ok(PathBuf::from(home).join(".silverwood"))
}
