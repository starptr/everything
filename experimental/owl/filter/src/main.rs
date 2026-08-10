//! owl-filter — apply an `owl.fileset.txt` manifest to a checkout, copying the
//! included files into an output directory. This is owl's Nix-level pre-filter:
//! it runs before the Astro renderer, so excluded paths (notably `secrets/`)
//! never reach the render step. The renderer only ever sees the pruned tree.

mod fileset;

use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use walkdir::WalkDir;

use fileset::Fileset;

/// Copy the files an `owl.fileset.txt` includes from a checkout into an output dir.
#[derive(Parser)]
#[command(name = "owl-filter", version, about)]
struct Args {
    /// Path to the fileset manifest (e.g. the checkout's `owl.fileset.txt`).
    #[arg(long)]
    fileset: PathBuf,

    /// Source checkout root to filter.
    src: PathBuf,

    /// Output directory to populate with the included files.
    out: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let fileset = Fileset::load(&args.fileset)?;
    let src_root = args
        .src
        .canonicalize()
        .with_context(|| format!("resolving source dir {}", args.src.display()))?;

    // Prune VCS metadata dirs before walking them (they're huge and also excluded).
    let walker = WalkDir::new(&src_root).into_iter().filter_entry(|e| {
        !(e.file_type().is_dir() && matches!(e.file_name().to_str(), Some(".git" | ".jj")))
    });

    let mut copied = 0usize;
    for entry in walker {
        let entry = entry?;
        // Regular files only: symlinks and directories are skipped.
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry
            .path()
            .strip_prefix(&src_root)
            .expect("walked path is under src_root");
        if !fileset.includes(rel) {
            continue;
        }
        let dest = args.out.join(rel);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
        }
        fs::copy(entry.path(), &dest)
            .with_context(|| format!("copy {} -> {}", entry.path().display(), dest.display()))?;
        copied += 1;
    }

    eprintln!("owl-filter: copied {copied} files to {}", args.out.display());
    Ok(())
}
