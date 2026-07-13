# silverwood — a frontend-agnostic backend for code/agent workstreams

Silverwood is a Rust library (`silverwood-core`) and thin CLI (`silverwood-cli`)
that owns the **backend state** for managing the code you work on and the LLM
agent sessions attached to it. The premise: the underlying storage of code and
agent metadata does not change — only *how* it is presented to the developer
does. So silverwood makes the backend a stable, swappable-frontend contract.
Today there are many apps for managing LLM-agent workstreams; silverwood is the
layer underneath them that lets you swap the frontend without migrating data.

> Status: design / pre-implementation. This doc is the source of truth for the
> Part 0 build. Companion task list: ./TODO.md.

## Goals

- **Decouple frontend from backend.** Frontends (TUI, GUI, editor plugin, web)
  come and go; the checkout locations, agent-session associations, and workstream
  metadata are stable and outlive any one frontend.
- **A primitive, generalizable later.** The workstream primitive is a
  **code-checkout** for now. The design leaves room to generalize to a **feature**
  (potentially a nested, reparentable hierarchy) without a rewrite — see §8.
- **CRDT-friendly from day one.** State is stored as CRDT documents so that
  multiple *forests* (e.g. laptop and a remote dev shell) can eventually
  synchronize in an eventually-consistent way. Actual sync is deferred (§7); the
  data model is ready for it now.
- **Frontend-agnostic contract.** `silverwood-core` is the real API; the CLI is a
  thin, machine-readable (`--json`) surface over it. Frontends persist their own
  state in namespaced key-value pairs on each workstream (§5).
- **No policy in core.** Every user-facing parameter is explicit at the core
  boundary. Defaults, inference, and UX are a frontend concern (§2.4).
- **Nix + Rust, non-negotiable.** The project is a Nix flake, built with Nix, in
  Rust (§6). Eventually distributed via `soup`.

## Non-goals (for now)

- **Synchronization / networking.** Data is CRDT-ready, but no transport or merge
  scheduler is built yet (§7).
- **Provisioning defaults / UX.** No "if unspecified, use jj"; no ambient
  current-directory guessing. That lives in a frontend, if anywhere.
- **Secret / credential management.** HTTPS clone auth is ambient (the caller's
  git credential helper). Core never handles secrets.
- **Rows-as-CRDT (cr-sqlite) or SQLite-as-source-of-truth.** Superseded by a
  document-CRDT model (§2.1). SQLite may return only as one swappable `DocStore`
  backend (§4).

---

## 1. Concepts & vocabulary

| Term | Meaning |
| --- | --- |
| **Forest** | One local instance of silverwood state — by default the directory `~/.silverwood`. Two machines = two forests. A forest is *not necessarily* a directory in the future; storage is abstracted (§4). |
| **Workstream** | The unit a developer works on. Has a human name, common properties, exactly one **primitive**, and open namespaced KV. One Loro document per workstream. |
| **Primitive** | The kind of thing a workstream is built around. Today: **code-checkout**. Future: **feature** (§8). |
| **Code-checkout** | A working copy of a repository, provisioned by silverwood by cloning an HTTPS git endpoint in a specified **mode** (§3). |
| **Claude session** | A Claude Code session id + human-friendly name, associated with a workstream (zero or more). |
| **Forest id / peer id** | The forest's stable identity, used as the Loro peer/actor id so edits are attributable. Local, never synced. |
| **DocStore** | The trait abstracting where workstream documents are persisted (files by default). |
| **CheckoutProvider** | The trait abstracting how a code-checkout is materialized on disk (jj-colocated clone today). |

---

## 2. Core model

### 2.1 The forest is a store of documents

A workstream *is* a document. Therefore a forest is not "a database with a
workstreams table" — it is a **collection of documents, one CRDT document per
workstream**. This is the `automerge-repo`-style mental model, applied with Loro.

Consequences that shape everything else:

- **Membership** of the forest = the set of workstream documents present. When
  forests eventually sync, this is an add-wins union.
- **Deletion is an in-document tombstone** (`status = archived`), never removal of
  the document. The tombstone rides along in the document's own merge, so a delete
  propagates correctly and there is no separate index/root document to keep
  consistent.
- **`name` is owned by the workstream document** (no dual-home, no drift). Listing
  opens the documents (each is tiny — sub-millisecond). If listing ever becomes
  hot, a purely-local, rebuildable read-cache may be added — never the source of
  truth.
- **Fine-grained sync** falls out for free later: only changed workstream
  documents move.

### 2.2 Workstream document shape

Each workstream is one `LoroDoc`. Provisional container layout (Loro maps support
nested mergeable children; keyed maps give stable identity under merge):

```
root (LoroMap)
├─ name        : string            # LWW register — owned here
├─ status      : "active" | "archived"
├─ kind        : "code-checkout"
├─ created_at  : RFC3339 string    # minted by core
├─ primitive   : LoroMap           # code-checkout data (see §3)
│   ├─ source    : string          # https git url
│   └─ mode      : "jj-colocated"
├─ checkouts   : LoroMap keyed by <forest-id>   # per-forest materialization
│   └─ <forest-id> : { location, state, mode }  # keyed → concurrent creates never conflict
├─ sessions    : LoroMap keyed by <claude-session-id>   # OR-Set by construction
│   └─ <session-id> : { name, created_at }
└─ kv          : LoroMap (namespace → LoroMap(key → json-string))   # open frontend state (§5)
```

The **movable tree** (`get_tree`) container is intentionally unused in v1. It is
the reason Loro was chosen and is reserved for the future feature hierarchy (§8).

### 2.3 CRDT semantics

- **Engine: Loro** (`loro = "^1"`), Rust-native. Chosen over Automerge because the
  future feature primitive may be a *reparentable hierarchy*, and Loro ships a
  movable-tree CRDT that resolves concurrent moves without cycles/duplication —
  which Automerge does not (§8). Cost accepted: Loro has no autosurgeon-style
  derive, so core hand-writes the container⇄struct mapping (§5).
- **Scalars** (name, status, primitive fields) are last-writer-wins registers.
- **Collections** (sessions, kv, checkouts) are keyed maps — concurrent additions
  union; the per-forest keying of `checkouts` means two forests independently
  materializing the same workstream never conflict.
- **Peer id** is derived from / stored alongside the forest id (§4) so all local
  edits are attributable to this forest.

### 2.4 The no-defaults boundary

Core is **mechanism, not policy**. It accepts fully-specified inputs and invents
nothing user-facing.

- Core **does** mint what a caller cannot meaningfully supply: the workstream
  UUID, `created_at`, and the initial `active` status (a lifecycle invariant).
- Core **does not** invent policy: `name`, checkout `source`, and checkout `mode`
  are always caller-specified. There is no default mode, no auto-created working
  branch, no ambient repo inference.
- Defaults, inference, and UX belong in a frontend (the CLI is itself a frontend
  and, for now, also requires explicit inputs).

---

## 3. The primitive: code-checkout

A code-checkout is a working copy silverwood provisions by cloning a remote. The
`silverwood-core` constructor contract:

```rust
Forest::create_workstream(NewWorkstream {
    name: String,                        // explicit — no default name
    primitive: NewPrimitive::CodeCheckout {
        source: HttpsGitUrl,             // https:// clone URL; scheme validated → error otherwise
        mode:   CheckoutMode::JjColocated,  // open enum; one variant today
    },
})
```

- **`CheckoutMode` is an open enum**, `JjColocated` its only variant today. It is
  the sole checkout mode to begin with.
- **`JjColocated` means exactly:** run
  `jj git clone --colocate <source> ~/.silverwood/working-copies/<uuid>` and
  nothing more. No auto-created branch/change (that is policy → a frontend's job),
  no base-ref parameter until explicitly wanted.
- **Auth is ambient.** Cloning a private HTTPS repo relies on the caller's git
  credential helper / PAT. Core manages no secrets.
- **Provisioning is fallible and slow**, so the checkout carries a state machine:
  `create_workstream` writes the workstream document first with the checkout entry
  in `state = "pending"`, runs the clone, then flips to `"ready"` or `"failed"`. A
  failed clone leaves a recoverable workstream, not a half-created mess.
- **`jj` and `git` are runtime dependencies** — the CLI shells out to them; the Nix
  package wraps the binary to put them on `PATH` (§6).

### Coherence: session discovery

Because core owns the checkout path, it knows the corresponding Claude Code
project directory (`~/.claude/projects/<escaped-checkout-path>/`) and can *discover*
sessions to offer for naming/attachment, rather than requiring every session id to
be entered by hand. (Discovery is a later part; the association model exists now.)

---

## 4. Storage & layout

Default forest layout:

```
~/.silverwood/
├─ config.toml                    # forest id (+ derived peer id), settings — NEVER synced
├─ workstreams/<uuid>.loro        # ONE Loro document per workstream — the source of truth
└─ working-copies/<uuid>/         # the provisioned checkout (jj-colocated clone)
```

- **`DocStore` trait** abstracts persistence: load/save document bytes by
  workstream id, and enumerate ids. Default impl = one file per document (zero
  deps, human-inspectable, trivially backed up). SQLite-blob or remote-over-SSH
  backends are possible later without touching the domain layer — this is where
  "a forest need not be a directory / SQLite is not required" cashes out.
- **Loro persistence** follows the snapshot+updates pattern: export a snapshot
  (`ExportMode::snapshot()`) as the document bytes; optionally append updates
  (`ExportMode::updates`) and recompact if a document's history grows. v1 keeps it
  simple: rewrite the snapshot on each committed mutation.
- **`config.toml`** holds the forest id (a UUID) and its derived stable Loro peer
  id, plus local settings. It is machine-local state and is never synced.
- **Forest location resolution** is a CLI (frontend) concern — core always takes an
  explicit path (§2.4). The `silverwood` CLI resolves, in precedence order:
  `--forest <DIR>` flag → `SILVERWOOD_FOREST_PATH` env var → `$HOME/.silverwood`.

---

## 5. The frontend contract

`silverwood-core` is the real, stable API; `silverwood-cli` is a thin wrapper that
emits machine-readable `--json`. Any frontend — Rust (link core), or any language
(shell out to the CLI) — drives the same backend.

Provisional core surface (illustrative, not final):

```rust
Forest::open(root: &Path) -> Result<Forest>          // locate/create ~/.silverwood, mint forest id
Forest::create_workstream(NewWorkstream) -> Result<Workstream>
Forest::list(opts) -> Result<Vec<WorkstreamSummary>> // filters archived unless requested
Forest::get(WorkstreamId) -> Result<Workstream>
Forest::archive(WorkstreamId) -> Result<()>          // tombstone
Forest::set_kv(WorkstreamId, namespace, key, json) -> Result<()>
Forest::attach_session(WorkstreamId, session_id, name) -> Result<()>
```

- **Namespaced KV** is how frontends store their own per-workstream state. A
  frontend picks a namespace (e.g. `com.example.myfrontend`) and writes arbitrary
  JSON-valued keys; core stores them opaquely and never interprets them. This is
  what keeps the backend genuinely frontend-agnostic: no frontend can force a core
  schema change.
- The domain types (`Workstream`, `Checkout`, `Session`) are plain idiomatic Rust
  structs. Because Loro has no derive layer, core owns the hand-written mapping
  between these structs and the Loro containers, keeping CRDT plumbing hidden.

---

## 6. Nix + Rust (required implementation details)

**Hard requirements: the project is a Nix flake, built with Nix, written in Rust.**

- **Flake** follows the standard crane-workspace approach for Rust in this repo:
  inputs `nixpkgs` (unstable), `crane`, `flake-utils`, `advisory-db`;
  `flake-utils.lib.eachDefaultSystem`; `craneLib = crane.mkLib pkgs`; a single
  workspace `src`; `buildDepsOnly` artifacts reused by the package and all checks.
  Build inputs are added only as silverwood's own dependency graph requires them —
  no machinery is inherited from other projects in the repo.
- **`nix flake check`** gates: `clippy` (`--deny warnings`), `cargoDoc`
  (`--deny warnings`), `cargoFmt`, `taploFmt`, `cargoAudit` (advisory-db),
  `cargoDeny`, `cargoNextest`.
- **`packages.default`** = the CLI, wrapped with `makeWrapper` to prefix `PATH`
  with `pkgs.jujutsu` and `pkgs.git` (the `jj git clone --colocate` runtime deps).
- **`apps.default`** runs the CLI; **`devShells.default`** = `craneLib.devShell`
  plus `jujutsu` and `git`.
- **Rust crate layout** (crane workspace):

  ```
  experimental/silverwood/
  ├─ Cargo.toml                 # workspace
  ├─ flake.nix / flake.lock
  ├─ crates/
  │  ├─ silverwood-core/        # domain model, Loro mapping, DocStore, CheckoutProvider
  │  └─ silverwood-cli/         # thin `--json` binary named `silverwood`
  ├─ DESIGN.md
  └─ TODO.md
  ```

- **Distribution:** eventually packaged in `soup` (NUR). Until then it lives here
  and builds standalone via its own flake.

---

## 7. Sync (future — explicit non-goal now)

Deferred, but the model is built for it:

- Per-document merge: pull a remote workstream document's bytes over a `DocStore`
  backend, `LoroDoc::import` / merge into the local document, save. Only changed
  documents move (§2.1).
- Loro's `export(ExportMode::updates(..))` + version vectors give delta sync.
- **Naive `rsync` of the docs dir is not sync** — copying files clobbers concurrent
  edits. Sync must load and merge documents, not overwrite them.
- Membership union + in-document tombstones (§2.1) mean adds and deletes both
  converge without a central index.

---

## 8. Future: the feature primitive

The primitive generalizes from **code-checkout** to **feature**. A feature is a
unit of work not tied to a single checkout, and features may **nest and be
reparented** (drag a sub-feature under a different parent). Concurrent reparenting
across forests is the classic hard CRDT problem (a naive merge yields cycles or
duplicates). **Loro's movable-tree CRDT resolves it deterministically** — which is
precisely why Loro is the engine even though v1 uses none of it. When the feature
primitive lands, workstreams gain a tree container and the flat forest membership
is unchanged.

---

## 9. Open questions

- **Explicit `base_ref` / working-branch** params on checkout creation — add when
  wanted (kept out now per §2.4).
- **SQLite-backed `DocStore`** — worth it for transactional multi-document writes,
  or do files suffice indefinitely?
- **Session auto-discovery** surface and its UX split between core and frontend.
- **Multi-primitive workstreams** — the model says "exactly one primitive"; revisit
  when features arrive.
- **HTTPS-only vs SSH remotes** — start HTTPS-only (validated); reconsider later.
- **Peer-id derivation** — hash the forest UUID to a stable u64, or store an
  independent u64 in `config.toml`.
