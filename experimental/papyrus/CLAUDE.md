# CLAUDE.md — papyrus

Papyrus is a canvas GUI for silverwood workstreams (Bun/Hono server + React/Vite/xterm
client), packaged with bun2nix. See `README.md` / `VENDOR.md` for background.

## Running a dev instance

The developer typically has a packaged `papyrus` running — it serves on port **6969** by
default (`bin/papyrus.ts`). A plain `bun run dev` puts Vite on 6969 too (and the backend on
6968), so it would collide. When you start a dev server to try a change, **always pass
non-default ports** so that instance keeps working — e.g. `PORT=7968 CLIENT_PORT=7969`
(open `http://localhost:7969`). `PORT` is the backend (`server/config.ts`, default 6968);
`CLIENT_PORT` is Vite's port (`client/vite.config.ts`, default 6969). Vite proxies only
`/api`; the terminal WebSocket connects straight to `PORT` (Vite's WS proxy does not relay
frames — see `client/src/components/terminalWs.ts`).

Get `bun` with **`nix shell nixpkgs#bun --impure`**, NOT `nix develop`. `nix develop`
overwrites `$SHELL` with the devshell's bash, so terminal panes would spawn `bash -l`
instead of your real login shell (silverwood's base shell is `$SHELL -l`). `nix shell`
leaves `$SHELL` alone, so panes spawn your actual login shell (e.g. fish). Full command
(run from `experimental/papyrus`; silverwood must be reachable — on `PATH` or via
`SILVERWOOD_BIN`):

    PORT=7968 CLIENT_PORT=7969 nix shell nixpkgs#bun --impure --command bun run dev

## Testing — ownership rule (read before touching tests)

Tests split by owner (full detail in `TESTING.md`):

- **Unit tests** — `client/src/**/*.test.ts(x)`, colocated. **Yours to write and
  maintain** when you implement code (pure logic, hooks, reducers, small units).
- **Behavioral tests** — `client/tests/behavior/**/*.test.tsx`. **Developer-owned.**
  Do **NOT** add, modify, or delete these without an explicit request from the
  developer. You MAY *suggest* a new behavioral test when implementing a feature —
  but the developer decides.

Runner is **`bun test`** (happy-dom + Testing Library); the suite is gated by
`nix flake check` (the `client-tests` derivation). The shippable build excludes
test files, so keep tests out of `tsconfig.json`'s compile set.
