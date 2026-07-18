# CLAUDE.md — papyrus

Papyrus is a canvas GUI for silverwood workstreams (Bun/Hono server + React/Vite/xterm
client), packaged with bun2nix. See `README.md` / `VENDOR.md` for background.

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
