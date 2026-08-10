//! Parser and matcher for `owl.fileset.txt` — the gitignore-like manifest that
//! decides which files owl renders. Each line is one glob, compiled by `globset`
//! with `literal_separator(true)` and anchored gitignore-style: a pattern with a
//! `/` in it is anchored to the checkout root, a pattern without one matches at
//! any depth, and a trailing `/` matches a directory's whole subtree. A leading
//! `!` re-includes; `@import <path>` inlines another fileset/.gitignore-style
//! file (path relative to the importing file); `@title <text>` sets the site
//! title owl shows in its UI (last one wins). Paths are matched checkout-root-
//! relative, later rules win, and an unmatched path defaults to "included". See
//! the header of `owl.fileset.txt` for the source-of-truth format docs.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use globset::{GlobBuilder, GlobMatcher};

/// One rule: the glob(s) a single pattern expands to, plus whether matching them
/// re-includes (`!`) or excludes. The globs are OR'd (any match = the rule fires).
struct Rule {
    negated: bool,
    matchers: Vec<GlobMatcher>,
}

/// An ordered list of rules resolved from a fileset file (imports inlined in
/// place), plus the site title from the last `@title` directive (if any).
pub struct Fileset {
    rules: Vec<Rule>,
    title: Option<String>,
}

impl Fileset {
    /// Load a fileset file, recursively inlining `@import`ed files.
    pub fn load(path: &Path) -> Result<Fileset> {
        let mut rules = Vec::new();
        let mut title = None;
        parse_file(path, &mut rules, &mut title, &mut Vec::new())?;
        Ok(Fileset { rules, title })
    }

    /// The site title set by the last `@title` directive, if any.
    pub fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    /// Whether a checkout-root-relative path is included. Default include; scan
    /// rules in order and let the last match win (exclude drops, `!` re-includes).
    pub fn includes(&self, rel: &Path) -> bool {
        let mut included = true;
        for rule in &self.rules {
            if rule.matchers.iter().any(|m| m.is_match(rel)) {
                included = rule.negated;
            }
        }
        included
    }

    #[cfg(test)]
    fn from_str(content: &str) -> Result<Fileset> {
        let mut rules = Vec::new();
        let mut title = None;
        parse_lines(content, Path::new("."), &mut rules, &mut title, &mut Vec::new())?;
        Ok(Fileset { rules, title })
    }
}

/// Read a fileset file and parse its lines. `visited` holds canonicalized paths
/// already parsed, breaking `@import` cycles.
fn parse_file(
    path: &Path,
    rules: &mut Vec<Rule>,
    title: &mut Option<String>,
    visited: &mut Vec<PathBuf>,
) -> Result<()> {
    let canon = path
        .canonicalize()
        .with_context(|| format!("resolving fileset {}", path.display()))?;
    if visited.contains(&canon) {
        return Ok(());
    }
    visited.push(canon.clone());

    let content = std::fs::read_to_string(&canon)
        .with_context(|| format!("reading fileset {}", canon.display()))?;
    let dir = canon.parent().unwrap_or_else(|| Path::new("."));
    parse_lines(&content, dir, rules, title, visited)
}

/// Parse the lines of a fileset, resolving `@import` relative to `dir`.
fn parse_lines(
    content: &str,
    dir: &Path,
    rules: &mut Vec<Rule>,
    title: &mut Option<String>,
    visited: &mut Vec<PathBuf>,
) -> Result<()> {
    for (idx, raw) in content.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // `@title <text>`: set the UI title (last one wins). The whitespace/end
        // guard keeps `@titlefoo` from matching; a bare `@title` is a no-op.
        if let Some(rest) = line.strip_prefix("@title") {
            if rest.is_empty() || rest.starts_with(char::is_whitespace) {
                let name = rest.trim();
                if !name.is_empty() {
                    *title = Some(name.to_string());
                }
                continue;
            }
        }
        if let Some(rest) = line.strip_prefix("@import") {
            let target = rest.trim();
            if target.is_empty() {
                bail!("line {}: `@import` needs a path", idx + 1);
            }
            parse_file(&dir.join(target), rules, title, visited)?;
            continue;
        }
        let (negated, pat) = match line.strip_prefix('!') {
            Some(rest) => (true, rest.trim()),
            None => (false, line),
        };
        let matchers = compile_pattern(pat)
            .with_context(|| format!("line {}: invalid pattern {:?}", idx + 1, pat))?;
        rules.push(Rule { negated, matchers });
    }
    Ok(())
}

/// Expand one gitignore-style pattern into the globset globs it should match, then
/// compile them. Anchoring rules mirror gitignore: a `/` anywhere anchors to the
/// root, no `/` matches at any depth, a trailing `/` matches a directory subtree.
fn compile_pattern(raw: &str) -> Result<Vec<GlobMatcher>> {
    let (dir_only, pat) = match raw.strip_suffix('/') {
        Some(p) => (true, p),
        None => (false, raw),
    };
    let (leading_anchor, pat) = match pat.strip_prefix('/') {
        Some(p) => (true, p),
        None => (false, pat),
    };
    if pat.is_empty() {
        bail!("empty pattern");
    }
    let anchored = leading_anchor || pat.contains('/');

    let mut globs: Vec<String> = Vec::new();
    if anchored {
        if !dir_only {
            globs.push(pat.to_string());
        }
        globs.push(format!("{pat}/**"));
    } else {
        if !dir_only {
            globs.push(pat.to_string());
            globs.push(format!("**/{pat}"));
        }
        globs.push(format!("{pat}/**"));
        globs.push(format!("**/{pat}/**"));
    }

    globs
        .iter()
        .map(|g| {
            Ok(GlobBuilder::new(g)
                .literal_separator(true)
                .build()?
                .compile_matcher())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn included(fs: &Fileset, p: &str) -> bool {
        fs.includes(Path::new(p))
    }

    #[test]
    fn default_is_included() {
        let fs = Fileset::from_str("secrets/\n").unwrap();
        assert!(included(&fs, "venus/foo.nix"));
    }

    #[test]
    fn directory_exclude_covers_contents_at_any_depth() {
        let fs = Fileset::from_str("secrets/\n").unwrap();
        assert!(!included(&fs, "secrets/passwords.yaml"));
        assert!(!included(&fs, "secrets/personal/jupiter.env"));
        assert!(!included(&fs, "nested/secrets/x")); // slashless -> any depth
        assert!(included(&fs, "secretsX/thing")); // respects the name boundary
    }

    #[test]
    fn anchored_pattern_respects_literal_separator() {
        // A `/` anchors to root; `*` never crosses a path separator.
        let fs = Fileset::from_str("a/*.md\n").unwrap();
        assert!(!included(&fs, "a/x.md"));
        assert!(included(&fs, "a/b/x.md")); // `*` does not span a directory
        assert!(included(&fs, "x.md")); // anchored: only under a/
    }

    #[test]
    fn slashless_pattern_matches_any_depth() {
        let fs = Fileset::from_str("*.loro\n").unwrap();
        assert!(!included(&fs, "snap.loro"));
        assert!(!included(&fs, "deep/dir/snap.loro"));
    }

    #[test]
    fn negation_re_includes_and_last_match_wins() {
        let fs = Fileset::from_str("build/\n!build/keep/\n").unwrap();
        assert!(!included(&fs, "build/out.js"));
        assert!(included(&fs, "build/keep/y.js"));
    }

    #[test]
    fn lockfiles_excluded_but_flake_lock_kept() {
        let fs = Fileset::from_str("*.lock\n!flake.lock\n").unwrap();
        assert!(!included(&fs, "Cargo.lock"));
        assert!(!included(&fs, "a/b/pnpm-lock.lock"));
        assert!(included(&fs, "flake.lock"));
        assert!(included(&fs, "experimental/owl/flake.lock"));
    }

    #[test]
    fn import_directive_needs_a_path() {
        assert!(Fileset::from_str("@import\n").is_err());
    }

    #[test]
    fn title_directive_last_wins_and_defaults_none() {
        assert!(Fileset::from_str("*.lock\n").unwrap().title().is_none());
        let fs = Fileset::from_str("@title  Everything Repo \n@title final\n").unwrap();
        assert_eq!(fs.title(), Some("final"));
        // A bare `@title` sets nothing and is not parsed as a glob.
        let fs = Fileset::from_str("@title\n").unwrap();
        assert!(fs.title().is_none());
        assert!(included(&fs, "anything"));
    }
}
