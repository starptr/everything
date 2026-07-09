# Design note: the store read primitives (`TODO.md` #2)

Status: **ratified & implemented (2026-07-09).** `children`, `descendants`, and `seek_time` are live
in `cp-core::Store`'s `StoreCtx` impl, covered by `crates/cp-core/tests/read_path.rs`. `search` landed
in #3 (`design/index-search.md`, `crates/cp-core/tests/search.rs`) — see its section below. The key
points are folded into `DESIGN.md` §5.

## The gap

`DESIGN.md` §5 names the closed primitive set a kind composes `contents` from —
`children`/`descendants`/`seek_time`/`search` — and gives their *intent*, but leaves the *encodings*
open (called out in `TODO.md` #2): the cursor format, how `descendants` traverses, how filters become
SQL, and how the two super-type tables combine into one ordered result. This note pins those down.

## Invariants

1. **Closed set, unchanged per type.** Implementing these adds no per-type surface to core (DESIGN
   §1/§5). A kind that wants a novel traversal composes it from these four; it never asks core for a
   new primitive.
2. **Time order is id order.** IDs are ULIDs (§3), so "sort a feed by time" is "sort by id" and needs
   no mandated `timestamp` payload field. The Crockford-base32 *text* encoding of a ULID sorts
   identically to its 128-bit value, so a plain `ORDER BY id` / `id <cmp> ?` over the `TEXT` id column
   is correct — no numeric decode.
3. **Uniform containment.** Children = every envelope (channel *or* item) whose `container` is this
   channel (§3). A discovery result is therefore a heterogeneous `Vec<Node>` unioned across the two
   tables, not one table's rows.
4. **Reads never mutate.** These take `&self` on the read context; `contents` gets `&dyn StoreCtx`, so
   a discovery strategy structurally cannot write (the write surface is `WriteCtx`, a separate trait).

## Cursor encoding (the load-bearing decision)

**A `Cursor` is an opaque string wrapping a bare ULID — a keyset boundary.** Results resume *strictly
beyond* it in the query's `Order` direction:

- `TimeDesc` → `WHERE id < :cursor ORDER BY id DESC` (walk toward older ids)
- `TimeAsc`  → `WHERE id > :cursor ORDER BY id ASC`  (walk toward newer ids)

Keyset (not `OFFSET`) because it is O(index-seek) regardless of depth and is stable under concurrent
inserts. `children` returns `next = Cursor(Some(<id of the last row on the page>))`; the next call
resumes strictly after it. To decide whether a *further* page exists in a single round-trip, the query
fetches `LIMIT n + 1`: if `n + 1` rows come back, the extra one is dropped and `next` is set; otherwise
`next = Cursor(None)` (end of feed). `limit == 0` short-circuits to an empty page.

The cursor is deliberately a bare id string, not a struct: it is direction-agnostic (the `Order` is
supplied per call, not baked into the cursor) and works uniformly across both super-type tables. It is
opaque to callers — only `cp-core` mints and interprets it. If a future primitive needs a richer cursor
(e.g. FTS relevance-rank pagination, which is *not* id-ordered — see `search`), that primitive can
adopt a versioned/tagged encoding without disturbing this one.

### `seek_time` is a pure computation

A ULID is a 48-bit millisecond time prefix followed by 80 random bits, so the earliest id that can
exist at time `T` is `from_parts(T, 0)`. `seek_time(container, T)` returns the id *one below* that
floor: `Ulid(from_parts(T, 0).0 - 1)`, as a cursor. Feeding it to `children(.., TimeAsc)` then yields
exactly the rows created **at/after T** (exclusive-beyond `> boundary` includes the whole `T` floor);
`TimeDesc` yields those strictly before `T`. This needs **no query** — hence the `container` argument
is currently unused (kept for the trait contract and for a future substrate-backed implementation that
might scope differently). This is the concrete form of §3's "jump to timestamp T is a seek to the ULID
whose time prefix is T" and makes `basic`'s `query.at → seek_time` free.

## `children` — one level, cursor-paginated

A `UNION ALL` of one arm per *wanted* super-type (selected by `filter.super_type`; `None` ⇒ both),
each tagged with a literal `super_type` column so a row round-trips back into the right `Node` variant.
Both arms filter `container = ?` and, when `filter.type_ids` is a non-empty list, `type_id IN (...)`
(empty/`None` ⇒ unfiltered). A trailing `ORDER BY id <dir> LIMIT n+1` applies to the whole compound.

## `descendants` — whole subtree, via a recursive CTE

Traversal is a single **recursive CTE over the channel containment edge**, not application-side N+1:

```
WITH RECURSIVE subtree(id, depth) AS (
    SELECT id, 0 FROM channels WHERE id = :root
    UNION ALL
    SELECT c.id, s.depth + 1 FROM channels c JOIN subtree s ON c.container = s.id
    [WHERE s.depth + 1 <= :max]     -- only when depth-limited
)
```

Only channels can contain, so the recursion walks channels; items are then attached by container.
**Depth semantics:** root is depth 0, its direct children depth 1, etc. A node's depth = its
container's depth + 1. So descendant *channels* are the subtree minus root (`depth >= 1`), and an
*item* qualifies when its container is within `max - 1` hops (uncapped ⇒ any subtree channel; `depth 0`
⇒ empty). `descendants` is fetch-all by contract (no pagination) and returns nodes in ascending id
order; a missing `root` yields an empty vec, not an error (existence checks are the caller's to do via
a point read).

## `search` — implemented in #3 (see `design/index-search.md`)

`search` is substring/relevance search over the projection `index()` (§6) populates into an FTS5
(trigram) table. It is now **live** — the full substrate schema, the MATCH-then-join-back query, the
subtree scoping (reusing this note's `descendants` CTE), and the cursor decision are in
`design/index-search.md`.

One decision there **revises the sketch left here:** search pages by a plain **offset** cursor, *not*
the `(rank, id)` keyset this note originally guessed — bm25 rank is a float (fragile as a keyset
boundary) and search sets are shallow, so offset's simplicity wins. The point that mattered holds: the
search cursor is a *different opaque encoding* from the id-keyset one, which is exactly why `Cursor` is
kept opaque and per-primitive rather than globally structured.

## Safety valve

`children` clamps `limit` to `MAX_LIMIT` (1000) so an unbounded value arriving from an HTTP query
(#12) can't ask sqlite to materialize an entire table at once; callers keep paging via the cursor.
`descendants` has no such clamp — "whole subtree" is its contract; a kind bounds cost with `depth`.

## What this touches

- **`cp-core`:** `store.rs` — the real `StoreCtx` impl + row/query helpers; `Cargo.toml` gains `ulid`
  (for the `seek_time` time-floor computation). New `crates/cp-core/tests/read_path.rs`.
- **Not touched:** `cp-model` (the `StoreCtx` trait and `Cursor`/`Filter`/`Order`/`Node` types were
  already defined in the scaffold and needed no change — a good sign the read surface was right),
  kind crates, the frontend.

## Assumptions that could still change (flagged, not blocking)

- **Cross-table id collisions.** Channel and item ids are minted independently; a shared ULID across
  the two tables (needed to confuse keyset pagination) is an ~80-bit-per-ms coincidence. Not guarded.
- **`descendants` unordered-by-depth.** It returns id (time) order, not a pre-order tree walk; the
  island reconstructs hierarchy from each node's `container`. If a kind ever needs server-side tree
  order, that is a new consideration, not a change to this primitive.
- **`seek_time` ignores `container`.** Correct while ordering is globally by ULID; a per-container time
  index (if ever added) would make the argument meaningful.
