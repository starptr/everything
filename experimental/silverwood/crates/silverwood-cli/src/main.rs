//! `silverwood` — a thin CLI over `silverwood-core`.
//!
//! Part 0 exposes only `info`, which opens (creating if needed) a forest and
//! prints its identity. Workstream commands arrive with Part 1.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use silverwood_core::Forest;

/// Frontend-agnostic backend for the code you work on and the agent sessions
/// attached to it.
#[derive(Parser)]
#[command(name = "silverwood", version, about, long_about = None)]
struct Cli {
    /// Path to the forest (defaults to `$HOME/.silverwood`).
    #[arg(long, global = true, value_name = "DIR")]
    forest: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Open the forest (creating it if absent) and print its identity.
    Info,
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

fn run(cli: Cli) -> Result<(), Box<dyn std::error::Error>> {
    let root = match cli.forest {
        Some(path) => path,
        None => default_forest_dir()?,
    };

    match cli.command {
        Command::Info => {
            let forest = Forest::open(&root)?;
            println!("root      = {}", forest.root().display());
            println!("forest_id = {}", forest.id());
            println!("peer_id   = {}", forest.peer_id());
        }
    }

    Ok(())
}

/// Resolve the default forest location, `$HOME/.silverwood`.
///
/// This default is frontend policy and deliberately lives here, not in
/// `silverwood-core` (see `DESIGN.md` §2.4).
fn default_forest_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let home = std::env::var_os("HOME")
        .ok_or("HOME is not set; pass --forest <DIR> to choose a forest location")?;
    Ok(PathBuf::from(home).join(".silverwood"))
}
