# Testing papyrus

The client is tested with **`bun test`** (Bun's native runner) + **happy-dom** +
**@testing-library/react**. Chosen over Vitest because the Nix `checks` sandbox is
bun-only (bun2nix), so `bun test` is the only runner that actually runs — and
therefore is enforced — inside `nix flake check`.

## Division of responsibility (important)

There are two kinds of tests, with different owners:

| Kind | Location | Owner | Purpose |
|------|----------|-------|---------|
| **Unit** | `client/src/**/*.test.ts(x)` (colocated) | **the coding agent / LLM** | logic it wrote — pure functions, hooks, reducers, small units |
| **Behavioral** | `client/tests/behavior/**/*.test.tsx` | **the developer** | user-facing behavior invariants (render a component, drive it, assert) |

**Why the split:** the LLM writes the implementation, so unit tests are part of
that job — it adds/updates them freely. Behavioral tests encode *what the product
must do* — invariants the developer cares about (e.g. "the rename pane closes when
you switch tabs"). Those are specified by the developer. The LLM must **not** add
or modify behavioral tests on its own; it may **suggest** one when building a
feature, but the developer decides and owns them. The colocated-vs-`tests/behavior/`
location is the visible signal of who owns a file.

## Running

```sh
# from experimental/papyrus/client (needs bun — use `nix develop` at the repo root)
bun test                     # runs unit + behavioral tests
bun test tests/behavior      # just the behavioral suite
```

`nix flake check` runs the whole suite via the `client-tests` derivation, so a red
test fails the build. The shippable build (`tsc && vite build`) never sees test
files — `tsconfig.json` excludes `src/**/*.test.*` and `tests/` is outside its
`include`.

## Harness notes / gotchas

- **Setup** lives in `client/tests/setup.ts` (preloaded via `client/bunfig.toml`):
  registers happy-dom, extends `expect` with jest-dom matchers, `cleanup()` after
  each test, and mocks **framer-motion** to a synchronous passthrough so
  `AnimatePresence` exit animations don't defer DOM removal (present/absent
  assertions stay deterministic).
- **Render components in isolation, not `App`.** `App` runs the ~1s reconcile poll
  and mounts xterm + React Flow, which fight a headless DOM. Test `Sidebar` alone.
- **Mock the `Terminal` module** when importing `Sidebar` (`mock.module(".../Terminal", …)`
  *before* a dynamic `import` of Sidebar) so you don't pull `@xterm/xterm` and its
  CSS import. Using disconnected tabs also keeps `Terminal` from rendering.
- **Seed state via the store:** `useStore.setState({ sidebarOpen: true, selectedNodeId, sessions })`.
  The store is a singleton — re-seed at the start of each test.

See `client/tests/behavior/session-rename-pane.test.tsx` for a worked example.

## Server tests (`server-tests/`)

A separate **server-side e2e** suite lives in `server-tests/` at the package root. It drives
papyrus's real HTTP routes **in-process** (imports the exported `apiRoutes` and calls
`apiRoutes.request(...)`, Hono's test client — no port bound) against a **real `silverwood`
binary** and a per-test **temp forest**. Because papyrus is stateless and delegates all
durable state to silverwood, each test asserts ground truth by re-reading silverwood (via the
wrapper or a raw `cli()` helper), never server memory. This is the regression guard for the
server↔silverwood boundary: a silverwood CLI-contract change (e.g. moving a subcommand) turns
these red, where the client suite stays green.

- `server-tests/silverwood-contract.test.ts` — the wrapper (`services/silverwood.ts`) argv
  contract: create/get/list/rename/archive, kv, and the full session lifecycle. Native-free.
- `server-tests/api.e2e.test.ts` — the canvas CUJs through the routes: create / edit /
  delete a node, session-tab metadata, and error propagation.
- `server-tests/helpers/` — `forest.ts` (temp forest + `cli()` runner, the TS analog of
  silverwood's `tests/common/mod.rs`) and `app.ts` (stubs the native `bun-pty` — pulled in
  transitively via `sessionManager` — before loading the routes, the same trick the client
  behavioral test uses for `Terminal`; no CUJ here spawns a PTY).

**Running** (needs `bun` and a silverwood binary):

```sh
# from experimental/papyrus; SILVERWOOD_BIN points at a built silverwood
SILVERWOOD_BIN=../silverwood/target/debug/silverwood OPENUI_QUIET=1 bun test server-tests
# or: bun run test:server   (with SILVERWOOD_BIN set / silverwood on PATH)
```

`bun test server-tests` scopes to the `server-tests/` dir; do **not** run bare `bun test` at
the package root (the "tests" substring would also match `client/tests/`, whose happy-dom
preload only loads under `client/`).

**Scope / constraints.** Every journey uses silverwood `--checkout-extent skip`, so nothing
clones — the suite is network-free and runs in the `nix flake check` sandbox via the
`server-tests` derivation (`flake.nix`), which sets `SILVERWOOD_BIN` to the flake's wrapped
silverwood. The full create→checkout→live-terminal journey needs network + jj and is **out of
scope** here, matching silverwood's own `#[ignore]`d e2e split.

**Ownership.** These are developer-owned CUJ invariants (like behavioral tests): the coding
agent may add/update them when it changes the server↔silverwood contract, but the developer
owns the set and reviews changes.
