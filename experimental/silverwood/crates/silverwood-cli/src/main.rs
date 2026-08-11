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

use clap::{Parser, Subcommand, ValueEnum};
use silverwood_core::{
    agent_shell_plan, base_shell_plan, AbsolutePath, AgentKind, AgentSession, CheckoutExtent,
    CheckoutState, DoctorReport, Forest, HttpsGitUrl, LocationWithinForest, NewCheckoutMode,
    NewKind, NewWorkstream, SpawnSeed, UpgradeReport, Workstream, WorkstreamId, DOC_SCHEMA_VERSION,
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

    /// Create a workstream. Whether its checkout is provisioned now or deferred is
    /// chosen per kind (basic: `--checkout-extent full|skip`).
    New {
        /// Human-friendly name (accepted at any `new` subcommand level).
        #[arg(long, global = true)]
        name: Option<String>,
        #[command(subcommand)]
        variant: NewVariant,
    },

    /// List workstreams.
    Ls {
        /// Include archived and deleted workstreams.
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

    /// Remove a workstream: mark it deleted and delete its checked-out code. Refuses
    /// unless the workstream is safe to remove (currently: never) — pass `--force`.
    Remove {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// Remove even if the workstream is not deemed safe to remove.
        #[arg(long)]
        force: bool,
    },

    /// Rename a workstream.
    Rename {
        /// The workstream id (from `silverwood ls`).
        id: String,
        /// The new display name.
        name: String,
    },

    /// Per-kind workstream management operations. The `<KIND>` subcommand (e.g.
    /// `basic`) is validated against the workstream's actual kind.
    Workstream {
        /// The workstream id (from `silverwood ls`).
        id: String,
        #[command(subcommand)]
        kind: WorkstreamCommand,
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

    /// Print the `new` subcommand tree (every variant/mode and its positional
    /// arguments) as JSON, so a frontend can drive creation without assuming a
    /// fixed shape. Human output enumerates each leaf invocation.
    NewSchema,

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
    /// Report a session's health (read-only): its agent variant, and — for a
    /// claude-code session — whether Claude's conversation transcript still exists
    /// on disk (a session created but never prompted has none, so `claude --resume`
    /// fails). Never mutates; use `session rm` to remove an orphaned session.
    Doctor {
        /// The workstream id the session belongs to (from `silverwood ls`).
        id: String,
        /// The session id to examine.
        session_id: String,
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
        /// Whether to provision the checkout now (`full`) or register the workstream and
        /// defer provisioning to `silverwood workstream <ID> basic checkout` (`skip`).
        #[arg(long, value_enum)]
        checkout_extent: CheckoutExtentArg,
        #[command(subcommand)]
        mode: NewModeArg,
    },
}

/// CLI spelling of [`CheckoutExtent`] for `new basic --checkout-extent`.
#[derive(Clone, Copy, ValueEnum)]
enum CheckoutExtentArg {
    /// Provision the checkout now, before the command returns.
    Full,
    /// Register only; provision later via `workstream <ID> basic checkout`.
    Skip,
}

impl From<CheckoutExtentArg> for CheckoutExtent {
    fn from(arg: CheckoutExtentArg) -> Self {
        match arg {
            CheckoutExtentArg::Full => CheckoutExtent::Full,
            CheckoutExtentArg::Skip => CheckoutExtent::Skip,
        }
    }
}

/// Per-kind management operations for `silverwood workstream <ID> <KIND> …`. The kind
/// subcommand is validated against the workstream's actual kind at dispatch. Only
/// `basic` today (`WorkstreamKind` is `#[non_exhaustive]`); the kebab name matches the
/// stored `kind` tag.
#[derive(Subcommand)]
enum WorkstreamCommand {
    /// Operations on a basic workstream.
    Basic {
        #[command(subcommand)]
        op: BasicOp,
    },
}

/// Operations on a basic workstream (`silverwood workstream <ID> basic <OP>`).
#[derive(Subcommand)]
enum BasicOp {
    /// Provision the checkout of a workstream created with `--checkout-extent skip`.
    /// Fails if the workstream has already been checked out (or is mid-provision).
    Checkout,
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
    /// APFS copy-on-write clone of a local dir (source + forest must share an APFS volume).
    ApfsCow {
        /// Absolute path to the local directory to copy-on-write clone.
        #[arg(value_name = "ABSOLUTE_PATH")]
        path: String,
    },
    /// APFS copy-on-write clone of a local dir, then `direnv allow` (pre-approves .envrc; unsafe).
    ApfsCowDirenvUnsafe {
        /// Absolute path to the local directory to copy-on-write clone.
        #[arg(value_name = "ABSOLUTE_PATH")]
        path: String,
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
            NewModeArg::ApfsCow { path } => NewCheckoutMode::ApfsCow {
                source_path: AbsolutePath::parse(&path)?,
            },
            NewModeArg::ApfsCowDirenvUnsafe { path } => NewCheckoutMode::ApfsCowDirenvUnsafe {
                source_path: AbsolutePath::parse(&path)?,
            },
        })
    }
}

/// A positional argument of a `new` command node (drives a frontend input field).
#[derive(serde::Serialize)]
struct ArgInfo {
    /// The clap `value_name`, e.g. "SOURCE_HTTPS_URL" or "ABSOLUTE_PATH".
    value_name: String,
    /// One-line help for the positional.
    help: String,
    /// Whether the positional must be supplied.
    required: bool,
}

/// A node in the `new` subcommand tree: its own positionals plus its child subcommands.
/// A leaf (no `subcommands`) is a complete invocation — the path names the variant/mode/…
/// and `args` are what the user must supply. Nothing here assumes a fixed depth or a
/// single "seed": a node may have children, positionals, or both.
#[derive(serde::Serialize)]
struct CommandNode {
    /// The subcommand name (kebab), or "new" at the root.
    name: String,
    /// One-line description (the subcommand's clap `about`).
    description: String,
    /// This node's own positional arguments, in declaration order.
    args: Vec<ArgInfo>,
    /// Child subcommands (empty at a leaf).
    subcommands: Vec<CommandNode>,
}

/// Reflect the whole `new` subcommand tree so the clap definitions stay the single source
/// of truth for how a workstream is created — a frontend renders inputs from this without
/// hardcoding any variant/mode/seed shape.
fn new_schema() -> CommandNode {
    reflect_command(&NewVariant::augment_subcommands(clap::Command::new("new")))
}

/// Recursively reflect one clap command into a [`CommandNode`] (positionals → `args`,
/// nested subcommands → `subcommands`). Globals/options like `--name` are not positionals,
/// so they are excluded.
fn reflect_command(cmd: &clap::Command) -> CommandNode {
    CommandNode {
        name: cmd.get_name().to_string(),
        description: cmd.get_about().map(|a| a.to_string()).unwrap_or_default(),
        args: cmd
            .get_positionals()
            .map(|arg| ArgInfo {
                value_name: arg
                    .get_value_names()
                    .and_then(|names| names.first())
                    .map(|n| n.to_string())
                    .unwrap_or_default(),
                help: arg.get_help().map(|h| h.to_string()).unwrap_or_default(),
                required: arg.is_required_set(),
            })
            .collect(),
        subcommands: cmd.get_subcommands().map(reflect_command).collect(),
    }
}

/// Human output for `new-schema`: enumerate each leaf invocation with its positionals,
/// accumulating any positionals declared along the path (`out` gets one line per leaf).
fn print_new_leaves(
    node: &CommandNode,
    path: &mut Vec<String>,
    args: &mut Vec<String>,
    out: &mut Vec<String>,
) {
    path.push(node.name.clone());
    for a in &node.args {
        args.push(format!("<{}>", a.value_name));
    }
    if node.subcommands.is_empty() {
        let mut line = path.join(" ");
        if !args.is_empty() {
            line.push(' ');
            line.push_str(&args.join(" "));
        }
        out.push(line);
    } else {
        for sc in &node.subcommands {
            print_new_leaves(sc, path, args, out);
        }
    }
    args.truncate(args.len() - node.args.len());
    path.pop();
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

    // `new-schema` is pure metadata — handle it before opening (and thereby
    // creating) the forest, so it never touches `$HOME/.silverwood`.
    if let Command::NewSchema = cli.command {
        let schema = new_schema();
        emit(json, &schema, || {
            let mut lines = Vec::new();
            print_new_leaves(&schema, &mut Vec::new(), &mut Vec::new(), &mut lines);
            for line in &lines {
                println!("{line}");
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
            let items: Vec<_> = list.iter().map(workstream_json).collect();
            emit(json, &items, || {
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
            emit(json, &workstream_json(&ws), || print_workstream(&ws));
            Ok(())
        }

        Command::Archive { id } => {
            let id = parse_id(&id)?;
            forest.archive(id)?;
            let ws = forest.get(id)?;
            emit(json, &workstream_json(&ws), || {
                println!("archived {}", ws.id)
            });
            Ok(())
        }

        Command::Remove { id, force } => {
            let id = parse_id(&id)?;
            forest.remove(id, force)?;
            let ws = forest.get(id)?;
            emit(json, &workstream_json(&ws), || {
                println!("deleted {}", ws.id)
            });
            Ok(())
        }

        Command::Rename { id, name } => {
            let id = parse_id(&id)?;
            forest.rename(id, &name)?;
            let ws = forest.get(id)?;
            emit(json, &workstream_json(&ws), || print_workstream(&ws));
            Ok(())
        }

        Command::Workstream { id, kind } => run_workstream(&forest, json, &id, kind),

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
        Command::NewSchema => unreachable!("new-schema is handled before Forest::open"),
    }
}

fn run_new(forest: &Forest, json: bool, name: Option<String>, variant: NewVariant) -> CliResult {
    let name = name.ok_or("`--name <NAME>` is required")?;
    let NewVariant::Basic {
        mode,
        checkout_extent,
    } = variant;
    let ws = forest.create_workstream(NewWorkstream {
        name,
        kind: NewKind::Basic {
            mode: mode.into_new_mode()?,
            checkout_extent: checkout_extent.into(),
        },
    })?;
    emit(json, &workstream_json(&ws), || print_workstream(&ws));
    Ok(())
}

fn run_workstream(forest: &Forest, json: bool, id: &str, kind: WorkstreamCommand) -> CliResult {
    let id = parse_id(id)?;
    let WorkstreamCommand::Basic { op } = kind;

    // The `basic` subcommand asserts the workstream's kind; reject a mismatch so the
    // per-kind operation only runs on the kind it was written for.
    let actual = forest.get(id)?.body.kind.tag();
    if actual != "basic" {
        return Err(format!("workstream {id} is not a basic workstream (it is {actual})").into());
    }

    match op {
        BasicOp::Checkout => {
            let ws = forest.checkout_workstream(id)?;
            emit(json, &workstream_json(&ws), || print_workstream(&ws));
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
        | SessionCommand::Rm { id, .. }
        | SessionCommand::Lock { id, .. }
        | SessionCommand::Unlock { id, .. }
        | SessionCommand::Doctor { id, .. } => parse_id(id)?,
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
        SessionCommand::Doctor { session_id, .. } => {
            // Read-only: report on this one session and return, rather than falling
            // through to the shared `session ls` emit below.
            let config_dir = resolve_claude_config_dir()?;
            let report = forest.doctor_session(id, &session_id, &config_dir)?;
            emit(json, &report, || print_doctor(&report));
            return Ok(());
        }
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

/// The user's real login identity, read from the passwd database.
struct LoginIdentity {
    name: String,
    home: String,
    shell: String,
}

/// Read the user's real login identity from the passwd database (`getpwuid(getuid())`)
/// — authoritative and independent of the process env, which a nix devshell pollutes
/// (it overwrites `$SHELL`). On macOS this consults Directory Services; on Linux,
/// `/etc/passwd`/nsswitch. Returns `None` if the entry is missing or a field is
/// empty/non-UTF8, so the caller falls back to env vars.
fn login_identity() -> Option<LoginIdentity> {
    // SAFETY: getpwuid returns a pointer to a static buffer valid until the next getpw*
    // call; we copy every field out immediately and never retain the pointer. spawn_seed
    // is called once at startup on the main thread, so the shared buffer is not raced.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() {
            return None;
        }
        let pw = &*pw;
        let field = |p: *const libc::c_char| -> Option<String> {
            if p.is_null() {
                return None;
            }
            std::ffi::CStr::from_ptr(p)
                .to_str()
                .ok()
                .filter(|s| !s.is_empty())
                .map(String::from)
        };
        Some(LoginIdentity {
            name: field(pw.pw_name)?,
            home: field(pw.pw_dir)?,
            shell: field(pw.pw_shell)?,
        })
    }
}

/// Gather the spawn's dynamic inputs — frontend policy, like [`resolve_forest_dir`]
/// (`silverwood-core` never touches env/the passwd DB). Identity (`home`/`user`/`shell`)
/// comes from the passwd database via [`login_identity`] so it is independent of the
/// process env (a nix devshell overwrites `$SHELL`); env vars are only a fallback. `HOME`
/// is required to reconstruct a login environment. `term`/`ssh_auth_sock` are session
/// context, so they stay env-sourced.
fn spawn_seed() -> Result<SpawnSeed, Box<dyn std::error::Error>> {
    let login = login_identity();
    let home = login
        .as_ref()
        .map(|l| l.home.clone())
        .or_else(|| std::env::var("HOME").ok())
        .ok_or("no HOME: cannot reconstruct a login environment")?;
    let user = login
        .as_ref()
        .map(|l| l.name.clone())
        .or_else(|| std::env::var("USER").ok())
        .or_else(|| std::env::var("LOGNAME").ok());
    let shell = login
        .as_ref()
        .map(|l| l.shell.clone())
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/zsh".to_string());
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

/// Serialize a workstream to JSON with the derived `overall_state` injected — the same
/// single-source-of-truth string the human output surfaces as its `state:` line, exposed
/// to `--json` consumers (e.g. papyrus).
fn workstream_json(ws: &Workstream) -> serde_json::Value {
    let mut value = serde_json::to_value(ws).unwrap_or_default();
    if let serde_json::Value::Object(map) = &mut value {
        map.insert("overall_state".into(), ws.body.overall_state().into());
    }
    value
}

fn print_workstream(ws: &Workstream) {
    println!(
        "{}  [{}]  {}",
        ws.id,
        enum_str(ws.body.status),
        ws.body.name
    );
    println!("  state:    {}", ws.body.overall_state());
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

fn print_doctor(report: &DoctorReport) {
    let convo = match report.conversation_exists {
        Some(true) => "present",
        Some(false) => "missing",
        None => "n/a (variant not checkable)",
    };
    println!(
        "{}  [{}]  conversation: {convo}",
        report.session_id, report.kind
    );
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

/// Resolve Claude Code's config dir (its per-session transcripts live under
/// `projects/`): `$CLAUDE_CONFIG_DIR` if set and non-empty, else `$HOME/.claude`.
/// Frontend policy, like [`resolve_forest_dir`] — `silverwood-core` never reads env.
fn resolve_claude_config_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    let home = std::env::var_os("HOME")
        .ok_or("cannot locate Claude's config dir: set CLAUDE_CONFIG_DIR or HOME")?;
    Ok(PathBuf::from(home).join(".claude"))
}
