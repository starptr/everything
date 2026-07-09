# Design note: the index substrate + `search` (`TODO.md` #3, `space`)

Status: **ratified & implemented (2026-07-10).** The FTS5 substrate (`crates/cp-core/src/index.rs`)
and `StoreCtx::search` (`store.rs`) are live, covered by `crates/cp-core/tests/search.rs`; `space`
composes them (`kinds/space`, integration test `crates/cp-frontend/tests/space_search.rs`). Folds into
`DESIGN.md` §5/§6 and supersedes the "planned shape" placeholder in `design/read-path.md`.

## The gap

`index(payload) -> IndexEntry` (§6) is called transactionally on write, but the substrate behind it was
a no-op, so `StoreCtx::search` (§5) returned a clear error and `space::contents` (whose whole job is
search) could not be built. This note pins the substrate schema, how `search` matches + joins + scopes,
and the search cursor — the pieces `design/read-path.md` deliberately deferred.

## Availability check (load-bearing, done first)

The Nix-built `sqlx` (0.8, `sqlite` feature ⇒ `libsqlite3-sys` **bundled** 0.30) compiles in **FTS5**
and **RTREE** — confirmed empirically before committing to the schema (a throwaway probe created an
`fts5(...)` + `rtree(...)` table and ran a `MATCH`). If a future build ever swaps to a system SQLite
without FTS5, this substrate is where it breaks, loudly, at migrate time.

## Scope of this pass

`IndexEntry { name?, text?, sort_key?, coord? }` has three substrates (§6). Only the one with a live
consumer is built now: **FTS5 for `name`/`text`**, which `space` searches. `sort_key` (expression
index) and `coord` (R-tree) have no consumer until `canvas` (`TODO.md` #11); `index::upsert` ignores
them today with a one-line note, rather than building speculative substrates. RTREE is proven available
(above) so #11 is derisked.

## The FTS substrate

One **standalone** (self-contentful) FTS5 table, not an `external content` one:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
    name, text,                 -- indexed: IndexEntry.name / IndexEntry.text
    envelope_id UNINDEXED,      -- ULID of the channel/item this row projects
    super_type  UNINDEXED,      -- 'channel' | 'item' — selects the join-back table
    tokenize = 'trigram'
);
```

- **Why standalone, not external-content.** FTS5 `content=` external tables bind to exactly *one* base
  table; we project *two* super-types (channels + items) into one search space. A standalone table
  stores its own copy of the projected text — a few bytes per envelope — and sidesteps that mismatch.
- **Trigram tokenizer** ⇒ true substring matching (a "search box", not word-prefix). Its floor is 3
  code points: a query shorter than that forms no trigram, so `search` short-circuits to an empty page
  before touching FTS (avoids relying on trigram's exact under-length behavior).
- **No `type_id` column.** The `{super_type, type_id}` filter is applied on the *joined* channels/items
  row (which carries `type_id`), not on the FTS row — so `index::upsert` needs no extra argument beyond
  what `EnvelopeRef` already carries.

### upsert / delete — keyed by `envelope_id`

FTS5 has no unique constraint or `ON CONFLICT`, so a write is **delete-then-insert** by `envelope_id`
(+ `super_type`, guarding the ~80-bit cross-table id-collision case `read-path.md` flags). `upsert`
skips the insert entirely when both `name` and `text` are absent — an envelope with nothing to index
leaves no row. Both run in the caller's transaction, so the FTS projection commits atomically with the
envelope (§6).

### Orphan rows are correctness-safe (the load-bearing invariant)

`search` **INNER JOINs** every FTS row back to `channels`/`items` to (a) rebuild the full `Node` and
(b) scope it. A stale FTS row whose envelope no longer exists simply fails the join and never appears.
This matters because `delete_channel` relies on FK `ON DELETE CASCADE` to remove child envelopes, and
that cascade does **not** touch the FTS table — so a subtree delete orphans its descendants' FTS rows.
Those orphans are invisible to results; the only cost is bounded dead storage. A future GC (a sweep
`WHERE envelope_id NOT IN (SELECT id FROM channels UNION SELECT id FROM items)`, or a `RuntimeComponent`
— nice §7 symmetry) can reclaim it. `index::delete` still runs for the *directly* deleted envelope, so
only cascaded children leak.

## `search(scope, text, filter, page)`

A `UNION ALL` of one arm per wanted super-type, each **matching FTS then joining back** and scoped to
the `scope` subtree via the *same* recursive CTE as `descendants` (so scoping semantics are identical):

```
WITH RECURSIVE subtree(id, depth) AS (              -- identical to descendants(scope)
    SELECT id, 0 FROM channels WHERE id = :scope
    UNION ALL SELECT c.id, s.depth+1 FROM channels c JOIN subtree s ON c.container = s.id
)
SELECT 'channel', c.*, f.rank AS score FROM search_index f JOIN channels c ON c.id = f.envelope_id
  WHERE f.super_type='channel' AND f MATCH :q AND c.id IN (SELECT id FROM subtree WHERE depth >= 1)
  [AND c.type_id IN (...)]
UNION ALL
SELECT 'item', i.*, f.rank AS score FROM search_index f JOIN items i ON i.id = f.envelope_id
  WHERE f.super_type='item' AND f MATCH :q AND i.container IN (SELECT id FROM subtree)
  [AND i.type_id IN (...)]
ORDER BY score ASC, id ASC LIMIT :n+1 OFFSET :off
```

- **Scope semantics mirror `descendants(scope)`**: channels at `depth >= 1` (scope itself excluded);
  items whose container is any subtree channel (scope included). A kind gets the same subtree whether it
  lists (`descendants`) or searches (`search`) — one mental model.
- **Query is a literal phrase**: the user string is wrapped `"…"` with embedded `"` doubled, so FTS5
  query operators (`AND`/`OR`/`NEAR`/`*`/column filters) in user input are matched verbatim, not
  executed. No FTS-syntax injection.
- **Ranking**: FTS5 `rank` (bm25; more negative = more relevant) → `ORDER BY score ASC`, `id` breaking
  ties into a total order for deterministic paging. Scores from the two arms share one table+tokenizer,
  so a global sort across super-types is meaningful enough for a search box.

### The search cursor is an **offset**, distinct from the id-keyset cursor

`read-path.md` kept `Cursor` opaque and per-primitive precisely so `search` could pick its own encoding.
It does: a plain decimal **offset** (`None` ⇒ 0; next page ⇒ `off + limit`), read via `LIMIT n+1 OFFSET`.
Not the `(rank, id)` keyset that note *sketched* — chosen deliberately:

- bm25 `rank` is a float; a keyset boundary on it means binding a float and exact-equality tiebreaks —
  fragile, and it composes awkwardly with the MATCH+JOIN. Offset needs none of that.
- Search result sets are small and shallow (nobody pages to result 900), and search is not a live feed,
  so keyset's two wins — O(seek) depth and concurrent-insert stability — barely apply. Offset's O(off)
  scan and possible drift across pages are acceptable here.

Keyset-on-rank stays available as a future optimization without disturbing the id-keyset cursor. A
malformed search cursor is a `Validation` error, not a silent reset.

## `space`

`space::contents` = `search(scope = self.id, query.q, {super_type: Channel}, page)` → serialize the
`NodePage`. **Deviation from `DESIGN.md` §5's `{Channel, [basic]}`**: it does *not* restrict to the
`basic` type. Hardcoding a peer kind's type string would couple `space` to `basic` and defeat the
"kinds gain nothing per type" invariant (§1); `super_type = Channel` already excludes messages, and a
space may legitimately contain any channel kind. The integration test relies on this — it uses a
throwaway channel kind (not `basic`) and still gets hits (DESIGN §12 genericity).

An empty/short `query.q` yields an empty page (the <3-char guard), so a freshly opened space search box
is `[]`, not an error.

## What this touches

- **`cp-core`:** `migrations/0001_init.sql` (+ `search_index`), `index.rs` (real upsert/delete),
  `store.rs` (real `search`). New `crates/cp-core/tests/search.rs`.
- **`kinds/space`:** real `contents` + a search-box island. New `crates/cp-frontend/tests/space_search.rs`.
- **Not touched:** `cp-model` (the `search`/`Filter`/`Cursor` surface already fit — another sign the
  read surface was right), the write path's `index::upsert`/`delete` call sites (already wired in #2).

## Assumptions that could still change (flagged, not blocking)

- **Cross-table id collision** (§read-path.md): guarded here by the `super_type` predicate on both the
  FTS row and its join, so a colliding channel/item id can't cross arms.
- **Orphan FTS rows** from cascaded subtree deletes accumulate until a future GC; results are unaffected.
- **Global bm25 across super-types** is treated as comparable; if a kind ever needs per-super-type
  ranking that becomes a new consideration, not a change to the primitive.
- **Offset drift** under concurrent writes to a searched subtree can skip/repeat a result across pages;
  acceptable for search, revisit with keyset-on-rank if it ever bites.
