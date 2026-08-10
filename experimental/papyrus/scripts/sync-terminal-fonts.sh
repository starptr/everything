#!/usr/bin/env bash
# Populate client/public/fonts/ with the self-hosted terminal fonts for `bun run dev`.
#
# The fonts are bundled from nixpkgs by the flake's `terminalFonts` derivation (the same
# source the Nix build's preBuild uses), so dev and the packaged build serve identical files.
# The .ttf are gitignored (not committed); this script regenerates them. Idempotent.
set -euo pipefail

cd "$(dirname "$0")/.."
dest="client/public/fonts"

out=$(nix build --no-link --print-out-paths .#terminalFonts)
mkdir -p "$dest"
cp -f "$out"/*.ttf "$dest"/
chmod -R u+w "$dest"  # store files are read-only; make writable so re-runs can overwrite
echo "synced $(ls "$dest"/*.ttf | wc -l | tr -d ' ') font files -> $dest"
