#!/usr/bin/env bash
# run-owl-for-owl-development-with-dynamic-fileset.sh — like the -with-frozen-fileset
# script (live dev server for hacking on owl's renderer), but the rendered CONTENT
# also tracks the repo: a watcher re-filters + regenerates the manifest whenever repo
# files change, so new / changed / deleted files show up without a restart. Astro
# HMRs the manifest and reads file bodies fresh per request; renderer edits (web/src)
# still hot-reload. Takes no arguments; run it from anywhere.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
fileset="$repo_root/owl.fileset.txt"
[ -f "$fileset" ] || { echo "no owl.fileset.txt at repo root ($repo_root)" >&2; exit 1; }

input=$(mktemp -d "${TMPDIR:-/tmp}/owl-input.XXXXXX")

# Re-filter the live repo into $input, then regenerate the manifest + .owl-tree
# (gen-manifest is node-builtins only, so no node_modules needed). Baked into a temp
# script with concrete paths so the watcher can invoke it with no quoting gymnastics.
refilter=$(mktemp "${TMPDIR:-/tmp}/owl-refilter.XXXXXX")
cat > "$refilter" <<EOF
set -e
nix run "$here#owl-filter" -- --fileset "$fileset" "$repo_root" "$input"
cd "$here/web" && OWL_INPUT_DIR="$input" nix shell nixpkgs#nodejs --command npm run gen:manifest
EOF

watcher=""
trap '[ -n "$watcher" ] && kill "$watcher" 2>/dev/null; rm -rf "$input" "$refilter"' EXIT

echo "==> owl-filter: initial snapshot -> $input"
nix run "$here#owl-filter" -- --fileset "$fileset" "$repo_root" "$input"

# Watch the repo; re-filter on change. owl's own outputs (.owl-tree/, the generated
# manifest, .jj/) are ignored so our writes can't retrigger the loop; .git and
# node_modules are skipped via .gitignore. watchexec supplies its own node via the
# refilter script, so it needs nothing on PATH here. --postpone: don't run on
# startup (the dev server's own gen:manifest populates .owl-tree first; a startup
# run would race its destructive rebuild).
echo "==> watchexec: re-filtering on repo changes"
nix run nixpkgs#watchexec -- \
  --postpone --watch "$repo_root" --project-origin "$repo_root" --debounce 800ms \
  --ignore '**/.owl-tree/**' --ignore '**/generated/manifest.json' --ignore '**/.jj/**' \
  -- bash "$refilter" &
watcher=$!

echo "==> npm run dev: http://localhost:4321  (content tracks the repo; Ctrl-C to stop)"
cd "$here/web"
export OWL_INPUT_DIR="$input"
nix shell nixpkgs#nodejs --command bash -c '[ -d node_modules ] || npm ci; npm run dev'
