# silverwood — implementation TODO

Design: ./DESIGN.md. Legend: [ ] pending · [~] in progress · [x] done.

This file is the persistent progress tracker across agent/LLM sessions. Keep it
current: mark `[~]` when starting, `[x]` when done + verified, and add a short
note when a decision or finding deviates from DESIGN.md.

## Part 0 — scaffold + forest skeleton  (this milestone)
- [ ] workspace `Cargo.toml` + `crates/silverwood-core` + `crates/silverwood-cli` (bin `silverwood`)
- [ ] `flake.nix` (crane): inputs nixpkgs-unstable + crane + flake-utils + advisory-db;
      `eachDefaultSystem`; single workspace `src`; `buildDepsOnly` artifacts reused everywhere
- [ ] flake `checks`: clippy (--deny warnings), cargoDoc (--deny warnings), fmt, taplo, audit, deny, nextest
- [ ] `packages.default` = CLI wrapped (`makeWrapper`) with `jujutsu` + `git` on PATH; `apps.default`; devShell (+ jujutsu, git)
- [ ] `rustfmt.toml` / `taplo.toml` / `deny.toml` as needed for the checks to pass
- [ ] `DocStore` trait + files-per-doc impl (load/save bytes by workstream id; enumerate ids)
- [ ] `Forest::open(root)` — locate/create the forest dir, mint forest id + derived peer id, write `config.toml`
- [ ] verify (structural): `nix flake check` green; `nix run . -- --help` prints usage
- [ ] verify (interactive, user): `nix develop` → `cargo run` opens a forest at a temp root; `config.toml` written once

## Part 1 — workstream model + code-checkout provisioning  (jj-colocated)
- [ ] `Workstream` / `Checkout` / `Session` structs ⇄ Loro container mapping (hand-written; no derive)
- [ ] one `LoroDoc` per workstream; snapshot export/import round-trip through `DocStore`
- [ ] `HttpsGitUrl` newtype + https-scheme validation (reject ssh/git@ → typed error)
- [ ] `CheckoutMode` open enum (`JjColocated` only); `NewWorkstream` / `NewPrimitive` types
- [ ] `CheckoutProvider` trait + `JjColocated` impl = `jj git clone --colocate <src> working-copies/<uuid>`
- [ ] `create_workstream`: mint id/created_at/active → write doc with checkout `state="pending"` → clone → flip `ready`/`failed`
- [ ] `list` (filter archived unless asked) / `get` / `archive` (in-doc tombstone, never delete the file)
- [ ] verify (structural): unit test round-trips a workstream doc; `create_workstream` against a real PUBLIC https repo clones + persists + reloads
- [ ] verify (interactive, user): create from a GitHub HTTPS URL → `working-copies/<uuid>` is a colocated repo (`.jj` AND `.git` present, `jj status` works); reopen forest → workstream still there

## Part 2 — associated data: kv + sessions
- [ ] `set_kv` / `get_kv` / `list_kv` — namespaced, value = opaque JSON string, core never interprets
- [ ] `attach_session` / `rename_session` / `detach_session` (tombstone); sessions keyed by claude session id
- [ ] verify (structural): kv + session round-trip; **merge test** — fork a doc, edit both, `import`/merge, assert convergence (proves the CRDT model holds)
- [ ] (later) session auto-discovery from the checkout path → `~/.claude/projects/<escaped>/`

## Part 3 — CLI surface  (`--json`)
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
