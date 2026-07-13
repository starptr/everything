# silverwood — implementation TODO

Design: ./DESIGN.md. Legend: [ ] pending · [~] in progress · [x] done.

This file is the persistent progress tracker across agent/LLM sessions. Keep it
current: mark `[~]` when starting, `[x]` when done + verified, and add a short
note when a decision or finding deviates from DESIGN.md.

## Part 0 — scaffold + forest skeleton  (this milestone) — DONE
- [x] workspace `Cargo.toml` + `crates/silverwood-core` + `crates/silverwood-cli` (bin `silverwood`)
- [x] `flake.nix` (crane): inputs nixpkgs-unstable + crane + flake-utils + advisory-db;
      `eachDefaultSystem`; single workspace `src`; `buildDepsOnly` artifacts reused everywhere
- [x] flake `checks`: clippy (--deny warnings), cargoDoc (--deny warnings), fmt, taplo, audit, deny, nextest
- [~] `packages.default` = CLI (`meta.mainProgram`); `apps.default`; devShell (+ jujutsu, git, taplo).
      makeWrapper (jj/git on PATH) DEFERRED to Part 1 — nothing shells out yet, so wrapping now would
      only pull jujutsu into the closure for no runtime use.
- [x] `deny.toml` (permissive license allowlist; multiple-versions=allow). No `rustfmt.toml`/`taplo.toml`
      needed — defaults satisfy the fmt/toml-fmt checks.
- [x] `DocStore` trait + files-per-doc impl (`*.loro`; load/save bytes by workstream id; enumerate ids) + unit tests
- [x] `Forest::open(root)` — locate/create the forest dir, mint forest id + derived peer id, write `config.toml` + tests
- [x] verify (structural): `nix flake check` green (rustc 1.96.1); `nix run . -- --help` prints usage
- [x] verify (behavioral): `nix run . -- --forest <tmp> info` creates `config.toml`+`workstreams/`+`working-copies/`,
      prints forest/peer id; second run returns the identical identity (idempotent)

Part 0 notes:
- **TOML/u64 gotcha**: TOML integers are i64; a raw u64 peer id > i64::MAX fails to serialize
  (`ConfigSer(OutOfRange)`). `derive_peer_id` masks to `[1, i64::MAX]` (63 bits — ample for Loro
  peer uniqueness). Caught by the `open_creates_layout`/`peer_id_is_nonzero` tests, not the build.
- **crane warning** (cosmetic): virtual-workspace root has no `[package]`, so crane logs a
  placeholder-name warning for the fmt/audit/deny check derivations. Harmless; checks pass.
- Files are `git add`-staged (flake eval needs it) but NOT committed.

## Part 1 — workstream model + code-checkout provisioning  (jj-colocated) — DONE
- [x] `Workstream`/`Checkout`/`Session`/`WorkstreamBody` structs ⇄ Loro container mapping (`doc.rs`, hand-written; no derive)
- [x] one `LoroDoc` per workstream; snapshot export/import round-trip through `DocStore`
- [x] `HttpsGitUrl` newtype + https-scheme validation (reject ssh/git@/http → typed `InvalidSource`) + unit tests
- [x] `CheckoutMode` open enum (`#[non_exhaustive]`, `JjColocated` only); `NewWorkstream`/`NewPrimitive`/`CheckoutState` types
- [x] `CheckoutProvider` trait + `JjColocated` impl = `jj git clone --colocate <src> working-copies/<uuid>` (captures stderr on failure)
- [x] `create_workstream`: mint id/created_at/active → write doc (checkout `pending`) → provision → flip `ready`/`failed` in place → persist
- [x] `list` (filter archived unless asked, sorted by id) / `get` / `archive` (in-doc `status=archived` tombstone, file retained)
- [x] provider injected via `Forest::open_with_provider` so tests avoid network; `FakeOk`/`FakeFail` integration tests in nextest
- [x] verify (structural): `nix flake check` green — doc round-trip, CRUD, failed-provision-recoverable, persist-across-reopen (FakeProvider)
- [x] verify (behavioral): `#[ignore]` `real_jj_colocated_clone` (devshell, `cargo test -- --ignored`) — real clone → `.jj` AND `.git` present, state `Ready`, persists across reopen. PASSED.

Part 1 notes:
- **Loro 1.13.6**. Confirmed API: `doc.get_map(name)` (root by name), `map.insert(k, scalar)`, `map.insert_container(k, LoroMap::new())`,
  `doc.export(ExportMode::snapshot())` / `doc.import(&bytes)`, `doc.set_peer_id` (rejects only `PeerID::MAX`). Reads hydrate via
  `serde_json::to_value(&map.get_deep_value())` → `serde_json::from_value` (LoroValue: Serialize; `get_deep_value` resolves nested
  containers so no `🦜:` container refs). Nav for in-place edits: `map.get(k)` → `Some(ValueOrContainer::Container(Container::Map(m)))`.
- **Lineage preserved**: build the doc once (all containers created once); the pending→ready/failed flip and archive mutate EXISTING
  containers in place (never rebuild), so future cross-forest merge stays valid.
- **deny**: added `BSL-1.0` (Boost) — a permissive license used by a crate in Loro's dependency tree.
- **created_at**: `time::OffsetDateTime::now_utc()` formatted RFC3339.
- **jj/git wrapper still deferred** — moved to Part 3: `create_workstream` shells out to `jj`, but the shipped `silverwood` binary
  doesn't expose create until the Part 3 CLI, so the package only needs the jj/git PATH wrapper once `new` lands. (Dev shell has both.)

## Part 2 — associated data: kv + sessions — DONE
- [x] `set_kv` / `get_kv` / `list_kv` / `unset_kv` — namespaced, value = opaque JSON string, core never interprets
- [x] `attach_session` (errors if dup) / `rename_session` (errors if absent, preserves created_at) / `detach_session` (no-op if absent)
- [x] verify (structural): `nix flake check` green — kv round-trip (LWW overwrite, namespace isolation, unset), session lifecycle,
      build↔hydrate round-trip with populated kv/sessions
- [x] verify (**CRDT merge**): `doc::tests::concurrent_edits_converge` — two peers load one base, edit the SAME kv namespace
      (different keys) + attach different sessions, exchange updates both ways → converge to the union. PASSED. Proves the model merges.
- [ ] (later) session auto-discovery from the checkout path → `~/.claude/projects/<escaped>/`

Part 2 notes:
- **CRDT-safety fix (important)**: the first merge test FAILED — concurrently creating the SAME nested-container key drops one
  side (parent map LWW-picks one container). Fix: `kv` and `sessions` are now FLAT maps of scalar strings in the single
  genesis-created container — kv keyed by JSON `["namespace","key"]`, sessions keyed by session id with a JSON-encoded `Session`
  value. `checkouts` stays nested (safe: keyed by forest id, never concurrently same-key). Rule for future nested state:
  never create the same container key on two forests concurrently. Public `WorkstreamBody` stays nested; `doc::StoredBody`
  is the flat on-disk shape, un-flattened during hydrate.
- Integration test helpers moved to `tests/common/mod.rs` (shared by `provisioning.rs` + `associated_data.rs`).

## Part 3 — CLI surface  (`--json`) — DONE
- [x] **wrapped `packages.default` with `makeWrapper` (jujutsu + git on PATH)** — `packages.unwrapped` is the bare crane build; checks use unwrapped
- [x] subcommands: `new`, `ls [--all]`, `show <id>`, `archive <id>`, `kv (set/get/ls/unset)`, `session (attach/ls/rename/detach)`
- [x] all inputs explicit (no defaults): `new --name <n> --source <https-url> --mode jj-colocated`; `--mode` is a clap ValueEnum (`ModeArg`, keeps clap out of core)
- [x] dual output: human-readable default + `--json` (global flag); mutating cmds print the affected object after the change
- [x] verify (structural): `nix flake check` green + `cli.rs` smoke tests (info json, ls empty=`[]`, bad-id exits non-zero) — no network needed
- [x] verify (behavioral): drove the WRAPPED binary (`nix build .#default`) new→ls→kv→session→show→archive with a real clone of
      octocat/Hello-World → checkout `ready`, working copy has `.jj`+`.git`+`README`, `--json` emits the full frontend contract,
      archive hides from `ls` / shows in `ls --all`. Proves jj/git resolve via the wrapper OUTSIDE the dev shell. PASSED.

Part 3 notes:
- CLI has no automated `new`/clone test (needs network + jj, unavailable in the nextest sandbox); `cli.rs` covers the non-network
  plumbing, and the real create path is verified by hand (above) + the core `#[ignore]` `real_jj_colocated_clone`.
- Enum display in the CLI uses `enum_str` (serialize→string) so it shares the single source of truth with the stored form.

## Part 3.1 — env-configurable forest + CLI e2e tests — DONE
- [x] `SILVERWOOD_FOREST_PATH` env var (CLI-only, frontend policy). Precedence: `--forest` flag > env var > `$HOME/.silverwood`.
      `resolve_forest_dir` in main.rs treats an empty env value as unset. Documented in DESIGN §4.
- [x] `tempfile`/`serde_json` added to `silverwood-cli` `[dev-dependencies]` (`tempfile = "3"`, matching channel-party's convention).
- [x] `tests/common/mod.rs` (CLI): `forest()` (tempfile TempDir), `run/ok/json/fails/create` driving `CARGO_BIN_EXE_silverwood` with the env var.
- [x] Sandbox-safe CLI tests (`cli.rs`, run in `nix flake check`): env-var resolves `root`, `--forest` overrides env, empty `ls`=`[]`,
      non-https source rejected without cloning, bad/absent id fails.
- [x] verify (network e2e, `tests/e2e.rs`, `#[ignore]`, devshell): full lifecycle vs `https://github.com/starptr/example.git` —
      new→ready colocated checkout (`README.md`+`.jj`+`.git` on disk), kv set/get/ls/unset + namespace isolation,
      session attach/dup-error/rename-preserves-created_at/absent-error/detach, archive tombstone keeps checkout + persists. PASSED (3/3).

Part 3.1 notes:
- e2e tests need network + jj → `#[ignore]`d (sandbox has neither); run with `nix develop --command cargo test -p silverwood-cli -- --ignored`.
- Assertions are observable-only (CLI `--json` + checkout working copy); they do NOT touch forest internals (`config.toml`, `.loro` files).

## Part 3.2 — generalize sessions → agent sessions under a workstream kind
- [x] `Session` → `AgentSession { kind: AgentKind, name, created_at }`; `AgentKind` open enum (`#[non_exhaustive]`, `claude-code` only)
- [x] introduce `WorkstreamKind` (tagged, `#[non_exhaustive]`, one variant `Basic { code_change, checkouts, sessions }`); `CheckoutPrimitive` → `CodeChange`; `NewPrimitive` → `NewKind`
- [x] `WorkstreamBody` = `{ name, status, created_at, kind: WorkstreamKind, kv }` — sessions/checkouts/code-change move INSIDE the kind; `kv` stays top-level (kind-agnostic)
- [x] Loro layout: nest kind data under a genesis-created `basic` container (`code_change`/`checkouts`/`sessions`); `kv` stays at root
- [x] `attach_session` gains an explicit `agent_kind` (no defaults, DESIGN §2.4); CLI `session attach --agent claude-code` (clap `AgentArg`, mirrors `--mode`)
- [x] verify (structural): `nix flake check` green — round-trip, CRUD, `concurrent_edits_converge` (now through the nested `basic` path)
- [ ] verify (network e2e, devshell): `session attach --agent claude-code` → `ls` shows `kind":"claude-code"`, rename preserves kind+created_at

Part 3.2 notes:
- **Clean break**: the on-disk doc shape changed (no backward-compat reader); pre-release, so existing forests are just recreated.
- **Serialize-only body types**: nothing deserializes `Workstream`/`WorkstreamBody`/`WorkstreamKind` (reads go via the private `StoredBody`; CLI tests parse untyped `Value`). Dropping their `Deserialize` derive lets us use the reliable Serialize side of `#[serde(flatten)]` + an internally-tagged (`tag="kind"`) enum → flat `--json` (`kind:"basic"` + `code_change`/`checkouts`/`sessions` at top level), keeping `ws["checkouts"]` test access working.
- **Merge-safety invariant** (in `doc.rs`): the `basic` container + its children are created ONCE in `build`; kind is immutable; mutators only `child_map` (fetch, never `insert_container`). This is what keeps the nested layout free of the concurrent-same-key-container drop bug.
- `AgentKind` needs no hand-written `as_str` (sessions are serde-encoded, never written as a bare Loro scalar), unlike `CheckoutMode`.
- Ergonomic accessors `WorkstreamBody::{code_change,checkouts,sessions}()` return `Option<&_>` to keep enum destructuring out of the CLI/tests (forward-compat for kinds without those).

## Part 4 — sync  (deferred; DESIGN §7)
- [ ] per-document merge over a `DocStore` backend (`LoroDoc::import` + merge, not overwrite)
- [ ] Loro `export(updates)` + version vectors for delta sync; remote (SSH) `DocStore` backend
- [ ] membership union + tombstone convergence across two real forests
- Note: naive `rsync` of the docs dir is NOT sync — it clobbers concurrent edits.

## Part 5 — feature primitive + soup packaging  (deferred; DESIGN §8)
- [ ] generalize the primitive to `feature`; introduce the Loro movable-tree container for nesting/reparenting
- [ ] package in `soup` (NUR); wire distribution

Notes:
- Files must be `git add`-staged for flake evaluation (jj/git), even before commit.
- Standalone flake for now; not wired into any system profile.
- `jj` + `git` are runtime deps of the CLI (checkout provisioning shells out) — the wrapped package must guarantee them on PATH.
