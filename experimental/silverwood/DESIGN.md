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
- **A kind, generalizable later.** A workstream has exactly one **kind**; today
  the only kind is **basic** (a materialized code-change: a checkout mode + a
  single-forest location). Agent sessions are
  kind-agnostic — stored as reserved-namespace KV (§5) — so any kind has them. The
  design leaves room for other kinds — e.g. a **feature** (potentially a nested,
  reparentable hierarchy) — without a rewrite. See §8.
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
| **Workstream** | The unit a developer works on. Has a human name, common properties, exactly one **kind**, and open namespaced KV. One Loro document per workstream. |
| **Kind** | What a workstream *is*. Today the only kind is **basic** (§3): a materialized code-change (a checkout mode carrying its seed + provisioning state, and a single-forest location). Future kinds may hold different data (§8). |
| **Code-change** | What a basic workstream is built around: a working copy provisioned by silverwood by cloning an HTTPS git endpoint in a specified **mode** (§3). |
| **Agent session** | An **agent kind** (today only `claude-code`) + a session id + a human-friendly name. Stored as a special case of namespaced KV under the core-reserved `app.andref.silverwood.session` namespace, so sessions are kind-agnostic (§5). |
| **Forest id / peer id** | The forest's stable identity, used as the Loro peer/actor id so edits are attributable. Local, never synced. |
| **DocStore** | The trait abstracting where workstream documents are persisted (files by default). |
| **CheckoutProvider** | The trait abstracting how a code-change is materialized on disk (jj-colocated clone today). |

---

## 2. Core model

### 2.1 The forest is a store of documents

A workstream *is* a document. Therefore a forest is not "a database with a
workstreams table" — it is a **collection of documents, one CRDT document per
workstream**. This is the `automerge-repo`-style mental model, applied with Loro.

Consequences that shape everything else:

- **Membership** of the forest = the set of workstream documents present. When
  forests eventually sync, this is an add-wins union.
- **Deletion is an in-document tombstone** (`status = archived` or `deleted`), never
  removal of the document. The tombstone rides along in the document's own merge, so a
  delete propagates correctly and there is no separate index/root document to keep
  consistent. (`deleted` additionally discards the on-disk checkout, but still keeps the
  document — a hard document removal cannot merge under the add-wins union above.)
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
├─ kind        : "basic"           # the workstream-kind discriminant
├─ created_at  : RFC3339 string    # minted by core
├─ basic       : LoroMap           # the "basic" kind's data — created once at genesis (§2.3)
│   ├─ mode       : LoroMap         # how it's materialized + its seed + state (see §3)
│   │   ├─ checkout_mode  : "jj-colocated"
│   │   ├─ initial_source : string  # https git url it was cloned from
│   │   └─ state          : "pending" | "ready" | "failed"
│   └─ location   : LoroMap         # where it lives — single-forest, so one value not a map
│       ├─ forest_id : <forest-id>
│       └─ within    : { forest_kind: "basic-forest", path }   # forest-kind-specific
└─ kv          : LoroMap (namespace → key → json-string)   # open frontend state (§5)
    └─ app.andref.silverwood.session → <session-id> : "{kind,name,created_at}"   # core-reserved: agent sessions
```

Agent sessions are stored as `kv` under the core-reserved
`app.andref.silverwood.session` namespace, **not** inside a kind, so they are
kind-agnostic: any kind gains sessions for free, and adding one never needs a
schema change (§5, §9.0). Core reserves the `app.andref.silverwood.*` prefix and
rejects frontend writes to it.

The **movable tree** (`get_tree`) container is intentionally unused in v1. It is
the reason Loro was chosen and is reserved for a future nested kind hierarchy (§8).

### 2.3 CRDT semantics

- **Engine: Loro** (`loro = "^1"`), Rust-native. Chosen over Automerge because the
  future feature kind may be a *reparentable hierarchy*, and Loro ships a
  movable-tree CRDT that resolves concurrent moves without cycles/duplication —
  which Automerge does not (§8). Cost accepted: Loro has no autosurgeon-style
  derive, so core hand-writes the container⇄struct mapping (§5).
- **Scalars** (name, status, and the basic kind's `mode`/`location` fields) are
  last-writer-wins registers.
- **The kind container** (`basic`) and its child maps (`mode`, `location`, `within`)
  are created once, at genesis, and the kind is immutable — so two forests never
  concurrently create the same container (which would LWW-drop one side's contents).
  See the merge-safety invariant in `doc.rs`.
- **Collections** (`kv`, which now includes sessions) are keyed maps: concurrent
  additions union. The basic kind's `mode.state` and `location` are plain LWW
  registers — a basic workstream is materialized in a **single forest**, so there is
  no concurrent-materialization case to key apart (a future multi-forest kind would
  reintroduce per-forest keying).
- **Peer id** is derived from / stored alongside the forest id (§4) so all local
  edits are attributable to this forest.

### 2.4 The no-defaults boundary

Core is **mechanism, not policy**. It accepts fully-specified inputs and invents
nothing user-facing.

- Core **does** mint what a caller cannot meaningfully supply: the workstream
  UUID, `created_at`, and the initial `active` status (a lifecycle invariant).
- Core **does not** invent policy: `name`, the checkout mode and its
  `initial_source`, and a session's **agent kind** are always caller-specified.
  There is no default
  mode, no default agent kind, no auto-created working branch, no ambient repo
  inference.
- Defaults, inference, and UX belong in a frontend (the CLI is itself a frontend
  and, for now, also requires explicit inputs).

---

## 3. The basic kind: a materialized code-change (+ agent sessions)

The **basic** kind is the only workstream kind today. It is a **code-change**
materialized in a single forest — a working copy silverwood provisions by cloning a
remote — plus zero or more agent sessions. It has two fields on two independent
axes: a **`mode`** (how it's materialized, owning the strategy-specific seed +
provisioning state) and a **`location`** (where it lives). The `silverwood-core`
constructor contract:

```rust
Forest::create_workstream(NewWorkstream {
    name: String,                        // explicit — no default name
    kind: NewKind::Basic {
        mode: NewCheckoutMode::JjColocated {   // creation-side mode + its seed
            initial_source: HttpsGitUrl,       // https:// clone URL; scheme validated
        },
    },
})
```

- **`WorkstreamKind` is an open, tagged enum**, `Basic` its only variant today;
  the enum is where new kinds (with their own data and session relationships) land.
- **`CheckoutMode` is a data-carrying, internally-tagged open enum** — the
  jj-colocated modes clone an HTTPS url; `apfs-cow` adopts a local directory via an
  APFS copy-on-write clone (`cp -c`), hard-failing at creation unless its source and
  the forest's checkout location share one APFS volume. `source` and `state` are
  **inside** each variant (`initial_source`, `state`) because they are meaningless
  without the strategy. The creation-side **`NewCheckoutMode`** omits `state`: core
  owns that lifecycle.
- **`Location` = `forest_id` + `LocationWithinForest`**, the latter an open enum over
  *forest kind* (today `BasicForest { path }`, an absolute path). This axis is
  independent of `CheckoutMode`. A basic workstream has exactly one location — it is
  single-forest (§2.3).
- **`JjColocated` means exactly:** run
  `jj git clone --colocate <initial_source> ~/.silverwood/working-copies/<uuid>` and
  nothing more. No auto-created branch/change (that is policy → a frontend's job),
  no base-ref parameter until explicitly wanted.
- **Auth is ambient.** Cloning a private HTTPS repo relies on the caller's git
  credential helper / PAT. Core manages no secrets.
- **Provisioning is fallible and slow**, so the mode carries a state machine:
  `create_workstream` writes the workstream document first with the mode's
  `state = "pending"`, runs the clone, then flips to `"ready"` or `"failed"`. A
  failed clone leaves a recoverable workstream, not a half-created mess.
- **`jj` and `git` are runtime dependencies** — the CLI shells out to them; the Nix
  package wraps the binary to put them on `PATH` (§6).

### Coherence: session discovery

Because core owns the checkout path, it knows the corresponding project directory
for a given agent kind — e.g. for `claude-code`, `~/.claude/projects/<escaped-checkout-path>/`
— and can *discover* sessions to offer for naming/attachment, rather than requiring
every session id to be entered by hand. (Discovery is a later part; the association
model, including the agent kind, exists now.)

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
- **Document schema version.** Every document stamps a `schema_version` root
  scalar (absent = v1, the pre-versioning shape). This is the migration source of
  truth — the *document* is the portable, synced unit, so the marker lives on it,
  not (only) in `config.toml`. Reads upgrade older documents in memory; the
  `upgrade-forest` command rewrites them; see §9. (Distinct from `config.toml`'s
  own `version`, which tracks the config-file format.)
- **`config.toml`** holds the forest id (a UUID), its derived stable Loro peer
  id, and the config-file `version`, plus local settings. Machine-local, never synced.
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
Forest::list(include_archived: bool) -> Result<Vec<Workstream>>
Forest::get(WorkstreamId) -> Result<Workstream>
Forest::archive(WorkstreamId) -> Result<()>          // tombstone
Forest::rename(WorkstreamId, name) -> Result<()>     // overwrite the name register
Forest::{set,unset,get,list}_kv(WorkstreamId, namespace, ..) // reserved namespaces rejected
Forest::{create,rename,remove}_session(WorkstreamId, session_id, ..)  // sessions = reserved-namespace kv
```

- **Namespaced KV** is how frontends store their own per-workstream state. A
  frontend picks a namespace (e.g. `com.example.myfrontend`) and writes arbitrary
  JSON-valued keys; core stores them opaquely and never interprets them. This is
  what keeps the backend genuinely frontend-agnostic: no frontend can force a core
  schema change.
- **Namespaces under the reserved `app.andref.silverwood.*` prefix are core-owned**
  and rejected by `set_kv`/`unset_kv`. **Agent sessions are exactly such a
  reserved-namespace KV convention** — `app.andref.silverwood.session`, keyed by
  session id → JSON `{kind,name,created_at}` — which the `Forest::*_session` API
  (and the `silverwood session` CLI) read and write with agent-kind awareness.
  Sessions being KV rather than a kind field is why any workstream kind gains them
  and why adding a session needs no schema change (§9.0).
- The domain types (`Workstream`, `WorkstreamKind`, `Checkout`, `AgentSession`) are
  plain idiomatic Rust structs. Because Loro has no derive layer, core owns the
  hand-written mapping between these structs and the Loro containers, keeping CRDT
  plumbing hidden.

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
- **Sync assumes a shared schema.** Peers running different silverwood versions
  need the migration story in §9 to converge rather than fork.

---

## 8. Future: more workstream kinds (e.g. feature)

New kinds are added as `WorkstreamKind` variants. A likely next kind is
**feature**: a unit of work not tied to a single checkout, which may **nest and be
reparented** (drag a sub-feature under a different parent). (Agent sessions are
kind-agnostic reserved-namespace KV (§5), so a new kind gets them for free.)
Concurrent reparenting across forests is the classic hard CRDT problem (a naive
merge yields cycles or duplicates). **Loro's movable-tree CRDT resolves it
deterministically** — which is precisely why Loro is the engine even though v1 uses
none of it. When such a kind lands, that workstream gains a tree container and the
flat forest membership is unchanged.

---

## 9. Schema evolution & migration

The document shape *will* change over silverwood's life (this doc's own history
already restructured sessions under a workstream kind). Silverwood carries a
**versioned migration framework** so forests upgrade safely and documents stay
bounded in size.

### 9.0 When to change the schema at all

Before adding a schema change, weigh it against the flexibility already in the
model — often both work, so pick the better design:

- **Use existing flexibility** when the data is frontend-owned, experimental, or
  sparse. The `kv` namespace (§5) is exactly this escape hatch: a frontend stores
  arbitrary JSON-valued state with no core change and no migration.
- **Change the schema** (add a field/container/kind) when the data is *core* —
  owned by silverwood, shared across frontends, merged or queried by core with
  first-class CRDT semantics, or simply not honestly expressible as opaque `kv`.

### 9.1 The mechanism

- **Marker.** Each document stamps a `schema_version` root scalar (absent = v1).
  `migrate::DOC_SCHEMA_VERSION` is what this build reads and writes.
- **Versioned decode → migrate → re-encode.** `migrate.rs` holds a **frozen decode
  struct per version** (`StoredBodyV1`, …) and a chain of pure-Rust
  `vN → vN+1` functions folding any older document up to the latest
  [`WorkstreamBody`]. Migrations are plain Rust over plain types — deterministic
  and unit-testable. Persisting re-encodes with `doc::build`, which stamps the
  latest version and, being a fresh op-graph, **shrinks** the document.
- **Read = upgrade-on-read** (in memory, no write); **write = lazy
  upgrade-on-write** (mutators rewrite the touched document first, since in-place
  mutation navigates the latest layout); **`silverwood upgrade-forest`** rewrites
  every document eagerly. A document newer than this build → `Error::SchemaTooNew`.
- **Seam:** `hydrate → migrate::to_latest_body` for reads; `Forest::upgrade_all`
  over the `DocStore` for whole-forest upgrades.

### 9.2 Never lose data — but stay bounded

Never losing data by *never moving/renaming/removing* is unsustainable: Loro
retains history, so an append-only shape bloats without limit. So destructive
restructuring (and history compaction) is **expected and supported**, not avoided —
it is how a document stays small over time. Two change classes:

- **Additive** (new field/container with a default): forward/backward compatible.
  Different-version peers interoperate with no coordination — the sync-safe default.
  (`serde(default)` on the decode structs already gives this.)
- **Destructive / compacting** (move/rename/remove, or trim history via
  `ExportMode::shallow_snapshot`): needed for bounded size, but it mints new Loro
  container ids / drops history, so it **cannot** merge with an un-migrated replica.
  This is the committed guarantee's cost.

### 9.3 The guarantee: barrier + additive-safe (and why)

Once forests sync (§7), a **destructive** migration collides with eventual
consistency: two replicas at different versions can't merge a restructured
container. The researched options are (a) additive+defaults with deterministic
migrations, (b) bidirectional lenses (Cambria — lets versions coexist, but heavy
and with fundamental soundness tradeoffs), or (c) a coordinated upgrade barrier.
Silverwood commits to **(a)+(c)**: additive changes need no coordination;
destructive/compacting changes require forests to reach a sync barrier, then a
migrated document is distributed (not independently recomputed — independent
rebuilds get different peer ids and can't merge). This dovetails with Loro's
shallow-snapshot GC, which itself only trims safely past a barrier. Concurrent
cross-version editing without a barrier (lenses) is deferred.

Grounding facts (Loro): ops dedup by `(PeerID, Counter)` — identical ops converge,
divergent ops at the same id silently corrupt (so deterministic migrations must be
distributed, not re-derived); containers cannot be renamed/moved; snapshot bytes
are not guaranteed deterministic (so tests compare *logical state*, not bytes).

### 9.4 Testing doctrine

Schema migration under eventual consistency has subtle bugs that review cannot
catch, so it is tested hard (`src/tests/`):

- **Frozen corpus** — real `.loro` bytes per version, generated by that version's
  code and committed under `src/tests/corpus/vN/`; **never regenerated** (that is
  what makes "read genuinely old bytes" a real test). Compare *logical projections*,
  not bytes.
- **Convergence property tests** (proptest) — K forests, random concurrent ops,
  **all sync orderings** → converge to the union, no loss. A two-version toy schema
  proves migrate + converge across a version bump under the barrier model.
- **Empirical Loro-invariant probes** — assert the dedup/idempotence behaviours the
  design rests on, so a Loro change that breaks them fails loudly.

---

## 10. Open questions

- **Explicit `base_ref` / working-branch** params on checkout creation — add when
  wanted (kept out now per §2.4).
- **SQLite-backed `DocStore`** — worth it for transactional multi-document writes,
  or do files suffice indefinitely?
- **Session auto-discovery** surface and its UX split between core and frontend.
- **Multi-kind workstreams** — the model says "exactly one kind"; revisit
  when new kinds arrive.
- **HTTPS-only vs SSH remotes** — start HTTPS-only (validated); reconsider later.
- **Peer-id derivation** — hash the forest UUID to a stable u64, or store an
  independent u64 in `config.toml`.
