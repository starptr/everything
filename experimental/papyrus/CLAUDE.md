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

Get `bun` with either **`nix shell nixpkgs#bun --impure`** or `nix develop` — both work for
terminal panes now. silverwood's base shell resolves your real login shell from the passwd
database (`getpwuid`), independent of `$SHELL`, so a devshell that overwrites `$SHELL` with
its bash no longer makes panes spawn `bash -l`; they spawn your actual login shell (e.g.
fish) regardless. (`nix develop` still drops you into a bash *interactive* shell, whereas
`nix shell --command` leaves your current shell alone — a preference, not a pane-correctness
issue.) Full command (run from `experimental/papyrus`; silverwood must be reachable — on
`PATH` or via `SILVERWOOD_BIN`):

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
