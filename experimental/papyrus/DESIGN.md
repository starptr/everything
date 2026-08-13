# papyrus — a GUI frontend for silverwood workstreams

papyrus is a local, canvas-based GUI for managing code/agent workstreams. Each running
coding agent appears as a draggable node on an infinite canvas, with live status and an
embedded terminal. It is intended to become a **frontend for [silverwood]** — the
frontend-agnostic backend for code/agent workstreams in this monorepo — presenting
silverwood's workstreams, code-changes, and agent sessions visually.

papyrus is **vendored and rebranded from [Fallomai/openui]**; see `./VENDOR.md` for
provenance and the list of local modifications. This document is the source of truth for
papyrus's own direction.

> Status: silverwood-backed and **stateless** — papyrus writes nothing to disk; all
> workstream state (including canvas coordinates) lives in silverwood.
> Companion task list: `./TODO.md`.

## Goals

- **Be silverwood's GUI.** Present silverwood workstreams (today the `basic` kind: a
  code-change and its checkouts, plus kv-backed agent sessions) on a visual canvas. The
  backend contract is `silverwood-core`, surfaced through the machine-readable
  `silverwood --json` CLI.
- **Local-first.** 100% local; no cloud backend of its own. papyrus drives external agent
  CLIs (Claude Code, etc.) and embeds their terminals.
- **Nix + reproducible.** Built with Nix (bun2nix) and distributed via `soup`, like
  silverwood.

## Non-goals (for now)

- **Arbitrary local-folder agents.** A node is a silverwood workstream, so it is created
  from an https git URL that silverwood clones — you cannot (yet) point an agent at an
  existing local repo. That needs a silverwood "adopt existing directory" checkout mode.
- **Deep UI rebrand.** Most in-app copy is now papyrus, but some upstream openui strings
  and visuals remain.
- **Non-darwin runtime.** Validated on aarch64-darwin; Linux support (patchelf for
  `bun-pty`'s `.so`) is later.

## Architecture (inherited from upstream, to evolve)

- **Server** (`server/`): Bun + Hono; a WebSocket endpoint bridges the browser to
  `bun-pty` PTYs. **Stateless** — no `.openui/`; all durable state is read/written through
  `server/services/silverwood.ts` (shells out to `silverwood --json`). Only live runtime
  state (PTYs, WebSocket clients, terminal scrollback) is in-memory. Port 6968.
- **Client** (`client/`): React + Vite + `@xyflow/react` (the node canvas) + xterm
  (terminals), built to `client/dist`.
- **Packaging** (`flake.nix`): bun2nix `writeBunApplication` packages the server while
  keeping a real `node_modules`, so `bun-pty`'s native FFI `.dylib` still `dlopen`s (a
  `bun build --compile` single binary would break it — Bun #30717). The client is built
  separately and placed at `client/dist`. See `./VENDOR.md`.

## The silverwood seam (how papyrus works)

A canvas **node is a silverwood workstream** (1:1). `silverwood --json ls` drives the
canvas; creating a node runs `silverwood new` (which clones the checkout); deleting it
`archive`s the workstream. Every per-node property lives in silverwood — papyrus keeps
no private state of its own:

- **Canvas coordinate / color / notes** → the workstream's KV under papyrus's namespace
  `app.andref.papyrus` (values are JSON strings). The coordinate is deliberately stored in
  silverwood too — that is the whole point.
- **Display name** → the workstream `name` (edited via `silverwood workstream <id> rename`).
- **Working directory** → silverwood's per-forest checkout location.
- **Session tabs** → silverwood sessions (themselves KV, under `app.andref.silverwood.session`).
  A tab is one session record: a `claude-code` agent session (papyrus mints its id and records
  it on spawn) or a `plain-shell` login shell (also durable, so its name persists and is
  workstream-scoped; it carries no lock and reopening spawns a fresh shell — there is no process
  to resume). Storing shell tabs here — not in papyrus-local client state — is what keeps a
  renamed shell from leaking across workstreams.

`server/services/silverwood.ts` is the single persistence boundary; it serializes writes
per workstream (silverwood does read-modify-overwrite with no locking). Dropped from the
openui era (no silverwood home, or a poor CRDT fit): canvas categories, terminal-scrollback
persistence, and the Linear/worktree/ticket flow.

[silverwood]: ../silverwood/DESIGN.md
[Fallomai/openui]: https://github.com/Fallomai/openui
