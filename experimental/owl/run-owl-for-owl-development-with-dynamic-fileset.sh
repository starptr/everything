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
nix run "$here/../fileset" -- --fileset "$fileset" "$repo_root" "$input"
cd "$here/web" && OWL_INPUT_DIR="$input" OWL_TITLE=everything nix shell nixpkgs#nodejs --command npm run gen:manifest
EOF

watcher=""
trap '[ -n "$watcher" ] && kill "$watcher" 2>/dev/null; rm -rf "$input" "$refilter"' EXIT

echo "==> fileset: initial snapshot -> $input"
nix run "$here/../fileset" -- --fileset "$fileset" "$repo_root" "$input"

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
export OWL_TITLE=everything   # site title (matches `nix build .#site`)
# Astro 7 auto-detaches `astro dev` into a background daemon when it detects an AI agent
# (or a non-interactive shell); force foreground so this script blocks — then Ctrl-C stops
# the server and fires the EXIT trap that kills the watcher and removes temp dirs.
export ASTRO_DEV_BACKGROUND=0
# npm ci reinstalls node_modules from the lock, but only when package-lock.json has
# changed since the last install (recorded in the marker) — so the dev server stays
# faithful to the lock (e.g. after a dependency bump) without a clean install every start.
nix shell nixpkgs#nodejs --command bash -c '
  marker=node_modules/.last-hermetically-installed-package-lock.json
  cmp -s package-lock.json "$marker" 2>/dev/null || { npm ci && cp package-lock.json "$marker"; }
  npm run dev'
