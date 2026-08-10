#!/usr/bin/env bash
# run-owl-for-general-development.sh — browse THIS checkout's live working tree with a
# HERMETIC owl (pinned filter + renderer). For developing a feature OTHER than owl:
# you get a stable, correct owl over your current files, built once and served.
#
# Dynamic input, hermetic logic:
#   1. owl-filter (hermetic `nix run`) walks the live on-disk checkout and applies
#      owl.fileset.txt — so new/untracked files appear and deleted ones vanish (no
#      git needed), and secrets/ + build junk are pruned before anything reaches the
#      Nix store. A fresh tree each run => deletions propagate.
#   2. `nix build .#site` renders the pruned tree with the pinned toolchain.
# Re-run to refresh after edits. Takes no arguments; run it from anywhere.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
fileset="$repo_root/owl.fileset.txt"
[ -f "$fileset" ] || { echo "no owl.fileset.txt at repo root ($repo_root)" >&2; exit 1; }

# `pwd -P` resolves symlinked components (macOS /tmp -> /private/tmp): Nix's `path:`
# fetcher errors on a symlink in the path, so hand it the physical path.
tree=$(mktemp -d "${TMPDIR:-/tmp}/owl-tree.XXXXXX"); tree=$(cd "$tree" && pwd -P)
out_link="$here/result-dev-site"   # matches owl/.gitignore's `result-*`
trap 'rm -rf "$tree"' EXIT

echo "==> owl-filter: pruning live checkout -> $tree"
nix run "$here#owl-filter" -- --fileset "$fileset" "$repo_root" "$tree"

echo "==> nix build .#site: rendering (hermetic) -> $out_link"
nix build "$here#site" --override-input everything "path:$tree" -o "$out_link"
rm -rf "$tree"; trap - EXIT   # the store has its own copy now

site=$(readlink -f "$out_link")
pages=$(find -L "$site" -name '*.html' | wc -l | tr -d ' ')
echo
echo "owl site for your working tree: $out_link -> $site ($pages pages)"
echo "==> serving http://localhost:3000  (Ctrl-C to stop)"
exec nix shell nixpkgs#nodejs --command npx --yes serve "$site"
