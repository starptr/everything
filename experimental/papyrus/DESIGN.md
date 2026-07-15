# papyrus — a GUI frontend for silverwood workstreams

papyrus is a local, canvas-based GUI for managing code/agent workstreams. Each running
coding agent appears as a draggable node on an infinite canvas, with live status and an
embedded terminal. It is intended to become a **frontend for [silverwood]** — the
frontend-agnostic backend for code/agent workstreams in this monorepo — presenting
silverwood's workstreams, code-changes, and agent sessions visually.

papyrus is **vendored and rebranded from [Fallomai/openui]**; see `./VENDOR.md` for
provenance and the list of local modifications. This document is the source of truth for
papyrus's own direction.

> Status: vendored + packaged (Nix, via bun2nix). Not yet wired to silverwood.
> Companion task list: `./TODO.md`.

## Goals

- **Be silverwood's GUI.** Present silverwood workstreams (today the `basic` kind: a
  code-change, its checkouts, and zero or more agent sessions) on a visual canvas. The
  backend contract is `silverwood-core`, surfaced through the machine-readable
  `silverwood --json` CLI.
- **Local-first.** 100% local; no cloud backend of its own. papyrus drives external agent
  CLIs (Claude Code, etc.) and embeds their terminals.
- **Nix + reproducible.** Built with Nix (bun2nix) and distributed via `soup`, like
  silverwood.

## Non-goals (for now)

- **silverwood integration.** The canvas currently runs on openui's own session model
  (in-memory + `.openui/state.json`); reading/writing silverwood workstreams is the next
  milestone, not yet built (see `TODO.md` Part 2).
- **Deep UI rebrand.** In-app "OpenUI" branding and copy are inherited from upstream and
  not yet reskinned.
- **Non-darwin runtime.** Validated on aarch64-darwin; Linux support (patchelf for
  `bun-pty`'s `.so`) is later.

## Architecture (inherited from upstream, to evolve)

- **Server** (`server/`): Bun + Hono; a WebSocket endpoint bridges the browser to
  `bun-pty` PTYs; on-disk persistence under `LAUNCH_CWD/.openui/`. Default port 6968.
- **Client** (`client/`): React + Vite + `@xyflow/react` (the node canvas) + xterm
  (terminals), built to `client/dist`.
- **Packaging** (`flake.nix`): bun2nix `writeBunApplication` packages the server while
  keeping a real `node_modules`, so `bun-pty`'s native FFI `.dylib` still `dlopen`s (a
  `bun build --compile` single binary would break it — Bun #30717). The client is built
  separately and placed at `client/dist`. See `./VENDOR.md`.

## The silverwood seam (future — the point of papyrus)

silverwood owns workstream state as CRDT documents and exposes it via `silverwood --json`.
papyrus will map its canvas nodes onto silverwood workstreams and agent sessions,
replacing openui's ad-hoc `.openui/state.json` model. This is the reason papyrus exists;
it is the next milestone (`TODO.md` Part 2).

[silverwood]: ../silverwood/DESIGN.md
[Fallomai/openui]: https://github.com/Fallomai/openui
