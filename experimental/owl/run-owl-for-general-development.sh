#!/usr/bin/env bash
# run-owl-for-general-development.sh — browse THIS checkout's live working tree with a
# HERMETIC owl (pinned filter + renderer), rebuilt LIVE and INCREMENTALLY as you edit.
# For developing a feature OTHER than owl: a stable, correct owl over your current files
# that tracks the working tree without restarts.
#
#   1. fileset (hermetic `nix run`) prunes the live checkout with owl.fileset.txt into a
#      fresh staging tree — new/untracked files appear, excluded (secrets/) + build junk
#      never leave, and a fresh tree each pass means deletions propagate.
#   2. owl-render (built once, then reused) renders that tree to a static $dist. It reuses a
#      persistent cache ($work) across passes, so every pass after the first re-renders only
#      the pages whose source changed (`--incremental`).
#   3. A watchexec watcher re-runs steps 1–2 on any repo change.
#   4. `serve` publishes $dist. Ctrl-C stops everything. Takes no arguments; run anywhere.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
fileset="$repo_root/owl.fileset.txt"
[ -f "$fileset" ] || { echo "no owl.fileset.txt at repo root ($repo_root)" >&2; exit 1; }

# `pwd -P` resolves symlinked components (macOS /tmp -> /private/tmp): owl-render's Astro
# build mismatches paths when a symlink is in the tree (same reason Nix's path: fetcher
# does), so hand it physical paths.
dist=$(mktemp -d "${TMPDIR:-/tmp}/owl-dist.XXXXXX"); dist=$(cd "$dist" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/owl-work.XXXXXX"); work=$(cd "$work" && pwd -P)

# Build the pinned renderer once and reuse the binary each pass — avoids a per-rebuild Nix
# evaluation. (`result-*` is git-ignored.)
render_link="$here/result-owl-render"
echo "==> nix build owl-render"
nix build "$here#owl-render" -o "$render_link"
owl_render=$(readlink -f "$render_link")/bin/owl-render

# One pass: filter the live repo into a fresh staging tree, then render it incrementally
# into $dist reusing $work's cache. A fresh staging tree each pass makes deletions
# propagate (fileset only ever adds/overwrites). Baked into a temp script with concrete
# paths so the watcher can invoke it without quoting gymnastics.
refilter=$(mktemp "${TMPDIR:-/tmp}/owl-refilter.XXXXXX")
cat > "$refilter" <<EOF
set -e
staging=\$(mktemp -d "\${TMPDIR:-/tmp}/owl-stage.XXXXXX")
trap 'rm -rf "\$staging"' EXIT
nix run "$here/../fileset" -- --fileset "$fileset" "$repo_root" "\$staging"
"$owl_render" "\$staging" "$dist" --incremental --work-dir "$work" --title everything
EOF

pids=()
trap 'kill "${pids[@]:-}" 2>/dev/null; rm -rf "$dist" "$work" "$refilter" "$render_link"' EXIT

echo "==> initial render (full; later passes are incremental)"
bash "$refilter"

# Watch the repo; re-filter + re-render on change. owl writes only under $dist/$work
# (outside the repo), so nothing it does retriggers the loop; .jj/.owl-tree/manifest are
# ignored defensively (e.g. a concurrent owl dev server), .git/node_modules via .gitignore.
# --postpone: the initial render above already produced $dist.
echo "==> watchexec: re-filter + re-render on repo changes"
nix run nixpkgs#watchexec -- \
  --postpone --watch "$repo_root" --project-origin "$repo_root" --debounce 800ms \
  --ignore '**/.owl-tree/**' --ignore '**/generated/manifest.json' --ignore '**/.jj/**' \
  -- bash "$refilter" &
pids+=($!)

echo "==> serving (Ctrl-C to stop) — URL below"
# `serve` treats a path whose last segment has a dot (e.g. /rendered/.sops.yaml) as a
# file, so it shows a directory listing instead of the page. serve.json's renderSingle
# makes it serve each page directory's lone index.html. Real static hosts resolve these
# URLs natively — this only patches the local `serve` helper. Not `exec`'d, so the EXIT
# trap still runs on Ctrl-C to stop the watcher and remove the temp dirs.
nix shell nixpkgs#nodejs --command npx --yes serve "$dist" -c "$here/serve.json"
