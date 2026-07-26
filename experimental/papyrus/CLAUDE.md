# CLAUDE.md — papyrus

Papyrus is a canvas GUI for silverwood workstreams (Bun/Hono server + React/Vite/xterm
client), packaged with bun2nix. See `README.md` / `VENDOR.md` for background.

## Running a dev instance

The developer typically has a packaged `papyrus` running — it serves on port **6969** by
default (`bin/papyrus.ts`). A plain `bun run dev` puts Vite on 6969 too (and the backend on
6968), so it would collide. When you start a dev server to try a change, **always pass
non-default ports** so that instance keeps working — e.g.
`PORT=7968 CLIENT_PORT=7969 bun run dev` (open `http://localhost:7969`). `PORT` is the
backend (`server/config.ts`, default 6968); `CLIENT_PORT` is Vite's port
(`client/vite.config.ts`, default 6969), which proxies `/api` + `/ws` to `PORT`.

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
