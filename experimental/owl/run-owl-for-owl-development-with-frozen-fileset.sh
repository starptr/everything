#!/usr/bin/env bash
# run-owl-for-owl-development-with-frozen-fileset.sh — live dev server for hacking on
# owl ITSELF (the renderer). Filters the repo ONCE into a snapshot, then runs Astro's
# dev server: edits to owl's renderer (web/src/**) hot-reload instantly, while the
# rendered *content* stays frozen at this snapshot. This is the fast, stable inner
# loop (what the plain dev server does). Restart to re-snapshot.
#
# For content that tracks repo changes live, use the -with-dynamic-fileset script.
# Takes no arguments; run it from anywhere.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
fileset="$repo_root/owl.fileset.txt"
[ -f "$fileset" ] || { echo "no owl.fileset.txt at repo root ($repo_root)" >&2; exit 1; }

input=$(mktemp -d "${TMPDIR:-/tmp}/owl-input.XXXXXX")
trap 'rm -rf "$input"' EXIT

echo "==> fileset: one-time snapshot of the repo -> $input"
nix run "$here/../fileset" -- --fileset "$fileset" "$repo_root" "$input"

echo "==> npm run dev: http://localhost:4321  (renderer HMR; content frozen; Ctrl-C to stop)"
cd "$here/web"
export OWL_INPUT_DIR="$input"
export OWL_TITLE=everything   # site title (matches `nix build .#site`)
# Astro 7 auto-detaches `astro dev` into a background daemon when it detects an AI agent
# (or a non-interactive shell); force foreground so this script blocks — then Ctrl-C stops
# the server and fires the EXIT trap that cleans up the snapshot.
export ASTRO_DEV_BACKGROUND=0
# npm ci reinstalls node_modules from the lock, but only when package-lock.json has
# changed since the last install (recorded in the marker) — so the dev server stays
# faithful to the lock (e.g. after a dependency bump) without a clean install every start.
nix shell nixpkgs#nodejs --command bash -c '
  marker=node_modules/.last-hermetically-installed-package-lock.json
  cmp -s package-lock.json "$marker" 2>/dev/null || { npm ci && cp package-lock.json "$marker"; }
  npm run dev'
