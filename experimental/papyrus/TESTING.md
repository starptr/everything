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
