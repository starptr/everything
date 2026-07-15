# Vendor provenance — papyrus

papyrus is **vendored** (upstream source copied in-tree) and **rebranded** from an
upstream project. This file records where it came from and what was changed.

## Upstream
- Project: **openui** — "AI command center for AI coding agents"
- Repository: https://github.com/Fallomai/openui
- Commit: `2963e596d2e0f3ff46151e734252e766c6fc7f2b` (branch `main`, 2026-01-22)
- License: **MIT** — declared in the upstream `package.json`, but upstream ships **no
  LICENSE file** (GitHub detects no license). We preserve the declared MIT and carry a
  `./LICENSE` here with upstream attribution.
- Vendored: **2026-07-14**

## Why vendored (not a flake input)
papyrus is intended to become silverwood's GUI frontend and will be modified heavily over
time (see `DESIGN.md`). Copying the source in-tree — rather than pinning upstream as a
`flake = false` input — is deliberate, so the code is directly editable. This is the first
in-tree source vendor in this monorepo.

## Local modifications vs upstream @ 2963e59
- **Rebrand.** `package.json`: `name` `@fallom/openui` → `papyrus`; `bin`
  `openui`/`bin/openui.ts` → `papyrus`/`bin/papyrus.ts`; dropped the stale upstream
  `repository`/`bugs`/`homepage` URLs (provenance lives here instead).
- **Removed stale prebuilt duplicates** `bin/openui.js` and `server/index.js` — the Nix
  build and the dev workflow both run the TypeScript directly via Bun.
- **Nix packaging (new).** Added `flake.nix` (bun2nix `writeBunApplication`), generated +
  committed `bun.nix` and `client/bun.nix`, plus `.gitignore`, `DESIGN.md`, `TODO.md`,
  `LICENSE`.
- **No server source patches.** `bin/papyrus.ts` (the upstream launcher: ASCII art,
  browser open, runtime Claude-plugin download, npm-update check) is kept as-is but is
  **not** the Nix entrypoint — the Nix package runs `server/index.ts` directly (via
  bun2nix), so the launcher's network side-effects don't run in the packaged binary.

## Runtime notes (Nix package)
- Entry: `bun run server/index.ts`, wrapped by bun2nix `writeBunApplication`, which
  `--chdir`s into the store app dir at runtime. `serveStatic({ root: "./client/dist" })`
  therefore resolves against that dir (the client build is placed there at build time), so
  no source patch is needed.
- Runtime state (`.openui/`) is written under `LAUNCH_CWD` (see
  `server/services/persistence.ts`). The Nix wrapper sets `LAUNCH_CWD="${LAUNCH_CWD:-$PWD}"`
  **before** the chdir so state lands in the user's invocation directory, not the
  read-only Nix store.

## Regenerating the bun2nix lockfiles
`bun.lock` is the source of truth (no npm lockfile). After changing dependencies, in the
papyrus devShell:
- root:   `bun install && bun2nix -o bun.nix`
- client: `cd client && bun install && bun2nix -o bun.nix`

Commit the updated `bun.lock` + `bun.nix` together.
