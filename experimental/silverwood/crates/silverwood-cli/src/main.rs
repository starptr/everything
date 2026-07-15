//! `silverwood` — a thin CLI over `silverwood-core`.
//!
//! Every command takes explicit arguments (core supplies no defaults) and can
//! emit machine-readable JSON with `--json`, so any frontend can drive the same
//! backend by shelling out. The one frontend policy that lives here is the
//! default forest location, `$HOME/.silverwood`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;
use std::str::FromStr;

use clap::{Parser, Subcommand, ValueEnum};
use silverwood_core::{
    AgentKind, AgentSession, CheckoutMode, Forest, HttpsGitUrl, NewKind, NewWorkstream,
    UpgradeReport, Workstream, WorkstreamId, DOC_SCHEMA_VERSION,
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
        /// Human-friendly name.
        #[arg(long)]
        name: String,
        /// HTTPS git endpoint to clone from.
        #[arg(long, value_name = "HTTPS_URL")]
        source: String,
        /// How the checkout is materialized.
        #[arg(long, value_enum)]
        mode: ModeArg,
    },

    /// List workstreams.
    Ls {
        /// Include archived workstreams.
        #[arg(long)]
        all: bool,
    },

    /// Show a workstream by id.
    Show { id: String },

    /// Archive a workstream (tombstone).
    Archive { id: String },

    /// Rename a workstream.
    Rename { id: String, name: String },

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
}

#[derive(Subcommand)]
enum KvCommand {
    /// Set a value (value is an opaque JSON string).
    Set {
        id: String,
        namespace: String,
        key: String,
        value: String,
    },
    /// Get a value.
    Get {
        id: String,
        namespace: String,
        key: String,
    },
    /// List all entries in a namespace.
    Ls { id: String, namespace: String },
    /// Remove a value.
    Unset {
        id: String,
        namespace: String,
        key: String,
    },
}

#[derive(Subcommand)]
enum SessionCommand {
    /// Create (record) a session of a given agent kind.
    #[command(subcommand)]
    Create(SessionCreate),
    /// List sessions.
    Ls { id: String },
    /// Rename a session (preserving its kind + created_at).
    Rename {
        id: String,
        session_id: String,
        name: String,
    },
    /// Remove a session.
    Rm { id: String, session_id: String },
}

/// Per-kind session creation: each agent kind takes the parameters it needs, so
/// the argument shape is not forced to be identical across kinds (today: one).
#[derive(Subcommand)]
enum SessionCreate {
    /// A Claude Code session. `session_id` is the Claude session id; `name`
    /// defaults to the session id when omitted.
    ClaudeCode {
        id: String,
        session_id: String,
        #[arg(long)]
        name: Option<String>,
    },
}

/// CLI mirror of `CheckoutMode` (keeps `clap` out of `silverwood-core`).
#[derive(Clone, Copy, ValueEnum)]
enum ModeArg {
    #[value(name = "jj-colocated")]
    JjColocated,
}

impl ModeArg {
    fn to_core(self) -> CheckoutMode {
        match self {
            ModeArg::JjColocated => CheckoutMode::JjColocated,
        }
    }
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
    let forest = Forest::open(&root)?;

    match cli.command {
        Command::Info => info(&forest, json),

        Command::New { name, source, mode } => {
            let source = HttpsGitUrl::parse(&source)?;
            let ws = forest.create_workstream(NewWorkstream {
                name,
                kind: NewKind::Basic {
                    source,
                    mode: mode.to_core(),
                },
            })?;
            emit(json, &ws, || print_workstream(&ws));
            Ok(())
        }

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

        Command::UpgradeForest { dry_run } => {
            let reports = forest.upgrade_all(dry_run)?;
            emit(json, &reports, || print_upgrade(&reports, dry_run));
            Ok(())
        }
    }
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
        | SessionCommand::Rm { id, .. } => parse_id(id)?,
    };

    match cmd {
        SessionCommand::Create(SessionCreate::ClaudeCode {
            session_id, name, ..
        }) => {
            let name = name.unwrap_or_else(|| session_id.clone());
            forest.create_session(id, &session_id, AgentKind::ClaudeCode, &name)?;
        }
        SessionCommand::Rename {
            session_id, name, ..
        } => forest.rename_session(id, &session_id, &name)?,
        SessionCommand::Rm { session_id, .. } => forest.remove_session(id, &session_id)?,
        SessionCommand::Ls { .. } => {}
    }

    let sessions = forest.get(id)?.body.sessions();
    emit(json, &sessions, || print_sessions(&sessions));
    Ok(())
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
    if let Some(code_change) = ws.body.code_change() {
        println!(
            "  source:   {} ({})",
            code_change.source,
            enum_str(code_change.mode)
        );
    }
    println!("  created:  {}", ws.body.created_at);
    for (forest_id, checkout) in ws.body.checkouts().into_iter().flatten() {
        println!(
            "  checkout: [{}] {} (forest {forest_id})",
            enum_str(checkout.state),
            checkout.location
        );
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
        println!(
            "{session_id}  {}  [{}]  (since {})",
            session.name,
            enum_str(session.kind),
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
