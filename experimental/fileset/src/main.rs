//! fileset — apply a gitignore-like fileset manifest to a directory, copying the
//! included files into an output dir. A general-purpose pre-filter: excluded paths
//! never reach whatever consumes the pruned tree.

use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;

use fileset::{filter_tree, Fileset};

/// Copy the files a fileset manifest includes from a directory into an output dir.
#[derive(Parser)]
#[command(name = "fileset", version, about)]
struct Args {
    /// Path to the fileset manifest.
    #[arg(long)]
    fileset: PathBuf,

    /// Source directory to filter.
    src: PathBuf,

    /// Output directory to populate with the included files.
    out: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let fileset = Fileset::load(&args.fileset)?;
    let copied = filter_tree(&args.src, &args.out, &fileset)?;
    eprintln!("fileset: copied {copied} files to {}", args.out.display());
    Ok(())
}
