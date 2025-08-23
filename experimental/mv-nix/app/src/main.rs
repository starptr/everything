use clap::Parser;
use rnix::{parser, tokenizer, SyntaxKind, SyntaxNode, NodeOrToken};
use std::fs;
use std::path::{Path, PathBuf, Component};
use pathdiff::diff_paths;
use std::ffi::OsStr;

/**
 * TODO: Support moving non-nix files
 * TODO: Support moving directories
 * TODO: When moving directories, create the target directory automatically
 */

/**
 * This tool lets you move a file or directory in a "subspace" (subtree of the filesystem),
 * and automatically updates all relative paths in all files that point to the moved file/directory.
 * Any text file that contains relative paths will be updated.
 * 
 * For example, relative paths such as `./foo/bar` or `../baz` will be updated.
 * 
 */

/// CLI args
#[derive(Parser)]
#[command(author, version, about)]
struct Args {
    /// Old file path
    #[arg(long)]
    old: PathBuf,

    /// New file path
    #[arg(long)]
    new: PathBuf,

    /// Dry run mode
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    dry_run: bool,

    /// Search root
    #[arg(short, long, default_value = ".")]
    search_space_subtree_root_dir: PathBuf,

    /// Git repository root
    #[arg(long, default_value = ".")]
    git_repo_root: PathBuf,
}

/// Get all files under `dir` recursively, treating symlinks as literal files (ie. not following them).
/// `subtree_root` must be a relative path wrt the cwd.
/// Returns a list of relative paths wrt the cwd.
fn collect_files(subtree_root: &Path, keep_dirs: bool, should_skip: &dyn Fn(&Path) -> bool) -> Vec<PathBuf> {
    use walkdir::WalkDir;

    WalkDir::new(subtree_root)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| {
            let ft = e.file_type();

            // Skip if the path matches the skip criteria
            if should_skip(e.path()) {
                return false;
            }

            // Keep directories
            if keep_dirs {
                return true;
            }
            // Don't keep directories
            !ft.is_dir()
        })
        .map(|e| e.into_path())
        .collect()
}

/// Logically remove `.` and `..` components from a relative path, except leading `..` components
fn normalize_rel_path(path: &Path) -> PathBuf {
    let components = path.components().peekable();
    let mut result = if path.is_absolute() {
        panic!("Absolute paths are not supported in this function");
    } else {
        let mut initial = PathBuf::new();
        initial
    };

    for comp in components {
        match comp {
            Component::CurDir => {
                // skip `.`
            }
            Component::ParentDir => {
                // pop last if possible, otherwise keep `..`
                if !result.pop() {
                    result.push("..");
                }
            }
            Component::RootDir | Component::Prefix(_) => {
                panic!("Unexpected root or prefix component in path normalization");
            }
            Component::Normal(c) => {
                result.push(c);
            }
        }
    }

    result
}

fn main() {
    use git2::Repository;

    let args = Args::parse();

    let is_gitignored = {
        let repo = Repository::discover(&args.git_repo_root).expect("Git repository not found");
        |path: &Path| {
            repo.is_path_ignored(path).expect("Unexpected error checking gitignore status")
        }
    };
    let dont_skip = |_| false;

    // List all files that may need to be updated
    let all_files = collect_files(&args.search_space_subtree_root_dir, false, &is_gitignored);

    // List all paths that are old
    let old_files = collect_files(&args.old, true, &dont_skip);

    for file in all_files {
        let mut content = fs::read_to_string(&file_path).expect("Failed to read file");

        // Parse the file
        let tokens = tokenizer::tokenize(&content);
        let parsed = parser::parse(tokens.into_iter());
        let root = SyntaxNode::new_root(parsed.0);

        // Collect updates
        let mut updates = Vec::new();
        collect_updates(&root, &args.old, &args.new, &file_path, &mut updates);

        if !updates.is_empty() {
            println!("File: {:?}", file_path);
            for (start, end, new_val) in &updates {
                println!("  Update: {} → {}", &content[*start..*end], new_val);
            }

            if !args.dry_run {
                // Apply updates in reverse order
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
