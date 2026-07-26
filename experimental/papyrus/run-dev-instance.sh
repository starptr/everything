#!/usr/bin/env bash
# Run a papyrus dev instance (backend + Vite) with silverwood on PATH from the sibling
# checkout. Non-default ports (7968/7969) so it doesn't collide with a packaged papyrus
# on 6969 — open http://localhost:7969.
set -euo pipefail

# Run from this script's dir so `path:../silverwood` and `bun run dev` resolve.
cd "$(dirname "$0")"

exec nix shell path:../silverwood nixpkgs#bun --impure \
  --command bash -c 'PORT=7968 CLIENT_PORT=7969 bun run dev'
