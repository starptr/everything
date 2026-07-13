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

## Part 2 — associated data: kv + sessions
- [ ] `set_kv` / `get_kv` / `list_kv` — namespaced, value = opaque JSON string, core never interprets
- [ ] `attach_session` / `rename_session` / `detach_session` (tombstone); sessions keyed by claude session id
- [ ] verify (structural): kv + session round-trip; **merge test** — fork a doc, edit both, `import`/merge, assert convergence (proves the CRDT model holds)
- [ ] (later) session auto-discovery from the checkout path → `~/.claude/projects/<escaped>/`

## Part 3 — CLI surface  (`--json`)
- [ ] **wrap `packages.default` with `makeWrapper` (jujutsu + git on PATH)** — deferred from Part 0/1; due now that the CLI's `new` shells out to `jj`
- [ ] subcommands: `new`, `ls`, `show`, `archive`, `kv (get/set/ls)`, `session (attach/ls/rename/detach)`
- [ ] all inputs explicit (no defaults): `new --name <n> --source <https-url> --mode jj-colocated`
- [ ] dual output: human-readable default + `--json` for frontends
- [ ] verify (structural): end-to-end CLI drives a forest start-to-finish; `--json` parses; exit codes sane
- [ ] verify (interactive, user): drive a full create → ls → show → attach-session → archive cycle by hand

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
