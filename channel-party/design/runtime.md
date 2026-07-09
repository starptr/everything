# Design note: the RuntimeComponent supervisor + `RuntimeCtx` (`TODO.md` #4) and the `canvas` slice (#11)

Status: **ratified & implemented (2026-07-10).** Built together on purpose: a `Derived` runtime
component's reason to exist is maintaining a kind's **type-owned index** off the change stream, so #4 is
only honestly validated by a real type-owned-table consumer — `canvas`'s `SpatialIndex` is that first
consumer. This note pins #4's `RuntimeCtx` surface, supervision, and confinement, plus how `canvas`
becomes a fully self-contained slice (own R-tree table + own writer + own reader). Folds into
`DESIGN.md` §6/§7.

## Why the two are one task

`canvas` (chosen over the "bbox as a 5th core primitive" alternative) is the smallest vehicle that
proves the design's single most load-bearing *unproven* claim: the §6 **type-owned table** escape hatch
— a kind with an index shape core knows nothing about (own migration + own `RuntimeComponent` writer +
own `contents` reader). That same slice is the first real `RuntimeComponent`, so it validates #4's
supervisor and `RuntimeCtx` end-to-end instead of against a contrived stub. One slice, three claims:
escape hatch, runtime supervisor, kind generality.

## The load-bearing finding: `cp-model` gains a `sqlx` dependency

An escape-hatch kind needs a DB handle in **both** directions:
- `SpatialIndex::run` (a `RuntimeComponent`) **writes** `canvas_box_coords`.
- `Canvas::contents` **reads** it for the viewport query (a bbox query is *not* expressible via the
  closed `StoreCtx` set — that is exactly why it's an escape-hatch table, not a core primitive).

Kinds only ever receive `&dyn StoreCtx` (in `contents`) and `&dyn RuntimeCtx` (in `run`), both defined
in `cp-model`. There is **no** way to hand a kind a DB handle through those without `cp-model` naming a
DB type. So `cp-model` now depends on `sqlx` and both traits expose:

```rust
fn type_owned_db(&self) -> &sqlx::SqlitePool;   // the §6 escape hatch, on StoreCtx AND RuntimeCtx
```

Cost, stated honestly: the interface crate is **no longer DB-agnostic** — it's committed to sqlite. The
project's store is sqlite throughout, so this trades a portability we never promised for the escape
hatch the thesis *does* promise. Pure primitive-consumers (`basic`/`space`) never call `type_owned_db`;
using it to touch core's own `channels`/`items` tables (rather than a kind's namespaced ones) is a
design violation — the closed primitives are the supported read path.

## `RuntimeCtx` surface

The handle `run(&self, cx: &dyn RuntimeCtx)` receives:

```rust
async fn next_event(&self) -> Option<RuntimeEvent>;   // filtered change | scheduler tick | None on shutdown
async fn get_item(&self, id: ItemId) -> Result<Option<Item>>;       // point reads: fetch a changed
async fn get_channel(&self, id: ChannelId) -> Result<Option<Channel>>; //   envelope's payload
fn writer(&self) -> Option<&dyn WriteCtx>;            // Some only for WriteScope::Primary — confinement
fn type_owned_db(&self) -> &sqlx::SqlitePool;         // the kind's namespaced tables
fn reset_requested(&self) -> bool;                    // version() bumped since last boot
```

- **`next_event`** merges the interests-filtered change stream and the `schedule_secs` interval into one
  awaitable, returning `None` when the supervisor cancels (clean loop exit). Change events arrive
  pre-filtered to `interests.types`; a `broadcast` *lag* is skipped (the component re-syncs on its own
  terms), not surfaced. The receiver sits behind a mutex so the method can take `&self` (the component
  holds `&dyn RuntimeCtx`, so `&mut` is impossible).
- **Point reads** because a `ChangeEvent` carries only `{op, target, type_id, container}` — not the
  payload. A `Derived` indexer sees "box X changed", then reads X's `x`/`y`. (This is why `ChangeOp` /
  `EnvelopeRef` / `ChangeEvent` **move to `cp-model`**: the runtime-facing consumer and the core emitter
  now share one type; `EventBus` stays in `cp-core` as mechanism, re-exporting the moved types.)

### WriteScope confinement — structural, where it counts

`writer()` returns `Option<&dyn WriteCtx>`: `Some` for `Primary`, **`None` for `Derived`**. A `Derived`
component *structurally cannot* obtain the envelope-mutation API, so a bug in an indexer can't corrupt
the `Primary` source of truth — the §7 guarantee. Residual: `Derived` still has `type_owned_db` (a raw
pool) and is *trusted* not to raw-SQL into core tables; enforcing that would need per-table ACLs sqlite
doesn't offer. The meaningful, enforced boundary is "no envelope writes for `Derived`."

## Supervision (`cp-core::runtime::spawn`)

One supervised `tokio` task per registered component, tracked in a `JoinSet`, cancellable via a
`CancellationToken` returned to the caller (so a server runs them forever; a test starts, drives, and
stops them):

- **Backfill-then-stream is the component's own shape** (§7): `run` does its batch pass, then loops on
  `next_event`. The supervisor just keeps `run` alive.
- **Restart with backoff**: if `run` returns `Err` or panics, log and retry after a capped exponential
  delay (reset to the floor on a clean/long-lived run). A clean `Ok`/`None`-driven exit (shutdown) is
  not restarted.
- **`version()` reset**: core keeps `runtime_component_state(name, version)`. At spawn, if the stored
  version differs from `component.version()` (or is absent), `reset_requested()` is `true` for this
  boot and core records the new version. The component decides what reset means (`SpatialIndex` rebuilds
  its table); doing it on every restart this boot is fine because reset is idempotent.

## The `canvas` slice (#11)

- **`canvas_box_coords`** becomes a real **R-tree** (`CREATE VIRTUAL TABLE … USING rtree(id, minX,
  maxX, minY, maxY)`) — RTREE confirmed available in the build (`design/index-search.md`). rtree's `id`
  is an integer, so a side `canvas_box(item_id TEXT PK, rowid INTEGER)` maps the ULID item id to the
  rtree rowid (rtree can't key on text). Both are `canvas_*`, core-invisible.
- **`SpatialIndex`** (`Derived`): on `reset_requested`, truncates + rebuilds; backfills all existing
  `canvas-text-box` items; then for each change fetches the item, and upserts (Created/Updated) or
  deletes (Deleted) its rect. `interests.types = [canvas-text-box]`.
- **`Canvas::contents`**: parses a `{x0,y0,x1,y1}` viewport, runs the rtree overlap query joined back to
  `items` (a *point* box has minX=maxX=x), returns a `NodePage` of the boxes in view. Reads via
  `cx.type_owned_db()`. Pagination: reuse the id-keyset cursor over the returned item ids (rtree gives a
  set, ordered by id for a stable page) — the viewport is the real filter, so deep paging is rare.
- **`CanvasTextBox`** drops its `index()` (it does *not* feed a core substrate — its projection lives in
  the kind's own table, written by the component). Payload: `{x, y, w, h, text}`.
- **Island**: a pan/zoom viewport that POSTs the visible rect to `contents` and draws each box via the
  item island (the §9 recursive-render path).

## Eventual consistency (flagged)

The R-tree lags a box write by the time the `SpatialIndex` processes the change — the honest cost of the
`Derived` (async) tier vs. inline indexing. Fine for a spatial canvas; tests poll for convergence. A
kind needing read-your-write spatial results would use inline indexing instead (a different §6 tier).

## What this touches

- **`cp-model`:** new `events` module (moved `ChangeOp`/`EnvelopeRef`/`ChangeEvent`); `sqlx` dep;
  `RuntimeCtx` fleshed out + `RuntimeEvent`; `type_owned_db` on `StoreCtx`. 
- **`cp-core`:** `runtime.rs` (real `CoreRuntimeCtx` + supervisor + backoff/reset); a
  `runtime_component_state` migration; `Store::type_owned_db`; `events.rs` re-exports the moved types;
  `Core::spawn_runtime` returns a `RuntimeHandle`.
- **`kinds/canvas`:** real R-tree migration, `SpatialIndex::run`, `Canvas::contents`, `CanvasTextBox`,
  island; `Cargo.toml` gains `sqlx`. New `crates/cp-core/tests/runtime.rs` (throwaway component,
  genericity) + `kinds/canvas` integration coverage via `cp-frontend`.
- **Not touched:** `basic`/`space` (still pure primitive-consumers — the escape hatch is opt-in).
