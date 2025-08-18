use clap::Parser;
use rnix::{parse, SyntaxNode};
use std::fs;
use std::path::{Path, PathBuf};

/// Simple tool to move a .nix file and update all relative references in a flake
#[derive(Parser)]
#[command(author, version, about)]
struct Args {
    /// Old file path
    #[arg(long)]
    old: PathBuf,

    /// New file path
    #[arg(long)]
    new: PathBuf,

    /// Dry run mode: print changes without modifying files
    #[arg(long, default_value_t = false)]
    dry_run: bool,

    /// Project root (defaults to current directory)
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

/// Recursively collects all `.nix` files in a directory
fn collect_nix_files(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir).expect("Cannot read directory") {
        let entry = entry.expect("Cannot read entry");
        let path = entry.path();
        if path.is_dir() {
            files.extend(collect_nix_files(&path));
        } else if path.extension().map(|ext| ext == "nix").unwrap_or(false) {
            files.push(path);
        }
    }
    files
}

/// Compute relative path from `from` to `to`
fn relative_path(from: &Path, to: &Path) -> String {
    let from_dir = from.parent().unwrap_or_else(|| Path::new("."));
    pathdiff::diff_paths(to, from_dir)
        .unwrap_or_else(|| to.to_path_buf())
        .to_str()
        .unwrap()
        .replace('\\', "/") // normalize Windows paths
}

/// Recursively traverse the AST and collect updates
fn collect_updates(
    node: &SyntaxNode,
    old_file: &Path,
    new_file: &Path,
    current_file: &Path,
    updates: &mut Vec<(usize, usize, String)>,
) {
    for child in node.children() {
        if child.kind().is_leaf() {
            let text = child.text();
            if text.starts_with("./") || text.starts_with("../") {
                let target_path = current_file.parent().unwrap_or_else(|| Path::new(".")).join(text);
                if target_path == *old_file {
                    let new_rel = relative_path(current_file, new_file);
                    let range = child.text_range();
                    updates.push((range.start(), range.end(), new_rel));
                }
            }
        }
        collect_updates(&child, old_file, new_file, current_file, updates);
    }
}

fn main() {
    let args = Args::parse();

    let nix_files = collect_nix_files(&args.root);

    for file_path in nix_files {
        let mut content = fs::read_to_string(&file_path).expect("Failed to read file");
        let parsed = parse(&content);

        let mut updates = Vec::new();
        collect_updates(&parsed.node(), &args.old, &args.new, &file_path, &mut updates);

        if !updates.is_empty() {
            println!("File: {:?}", file_path);
            for (start, end, new_val) in &updates {
                println!("  Update: {} → {}", &content[*start..*end], new_val);
            }

            if !args.dry_run {
                // Apply updates in reverse order to not mess up byte offsets
                for (start, end, new_val) in updates.iter().rev() {
                    content.replace_range(*start..*end, new_val);
                }
                fs::write(&file_path, content).expect("Failed to write file");
            }
        }
    }

    if !args.dry_run {
        fs::create_dir_all(args.new.parent().unwrap()).expect("Failed to create directories");
        fs::rename(&args.old, &args.new).expect("Failed to move file");
        println!("Moved file from {:?} to {:?}", args.old, args.new);
    } else {
        println!("Dry run complete. No files were modified or moved.");
    }
}
