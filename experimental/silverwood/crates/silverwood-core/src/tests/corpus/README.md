# Frozen document corpus

Real `.loro` snapshot bytes (+ their expected `<name>.json` logical projection),
one subdirectory per schema version: `v1/`, `v2/`, …

These are **frozen**: once a version ships, its bytes are never regenerated.
They are genuine old-version bytes produced by the code *at that version*, so the
migration tests read what an old silverwood actually wrote — not a re-encoding by
today's code (which would hide read-old-bytes bugs).

## Discipline

- **Never edit or regenerate an existing version's files.** They are the contract.
- When you add schema **vN**, generate and commit `vN/*` once, then leave it alone.
- The `corpus::regenerate` test writes the *current* version's fixtures when run
  with `SILVERWOOD_REGEN_CORPUS=1`; use it only for the version under development.
- `corpus::frozen_v1_corpus_hydrates_to_projection` reads these bytes, migrates to
  the latest, and asserts the projection — the read-old-bytes guard.

## Regenerating the current (in-development) version

```
SILVERWOOD_REGEN_CORPUS=1 cargo test -p silverwood-core corpus::regenerate
```

Then review and commit the changed fixtures. The Nix build keeps these files via
the `flake.nix` `src` filter (`/corpus/` is exempt from `cleanCargoSource`).
