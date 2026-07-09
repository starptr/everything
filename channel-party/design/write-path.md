# Design note: the core write path (`TODO.md` #1)

Status: **ratified & implemented (2026-07-09).** `WriteCtx`, the extended `ChangeEvent`, the
`Store` write impl, and `channel_members` are live in `cp-model`/`cp-core`, covered by
`crates/cp-core/tests/write_path.rs`; the key points are folded into `DESIGN.md` (§3, §8). The
open decisions below were resolved as recommended, with one deviation decided during
implementation:

- **`RuntimeCtx` was left as-is (an empty marker trait).** Its real shape — `reads()`/`writer()`/
  `derived()`/`events()` and the `WriteScope`-gated write handle sketched below — is `TODO.md` #4,
  not #1; defining it now would pre-commit #4's assumptions (exactly what we're avoiding). So
  `WriteScope` **confinement lands with #4** too. For #1, `cp-core::Store` is the trusted Primary
  writer, used directly by the debug shell and the generic API.

## The gap

`DESIGN.md` leans on "core's mutation API" (§3, §8) as the single write path, but never
gives it a shape. It is the linchpin: `TODO.md` #5 (events), #6 (debug writes), #8/#12
(reads that need data to exist), and all ingestion (#10) sit on top of it. This note
specifies it.

## Invariants the write path must hold

1. **One path.** Debug shell, generic API, `Membership` impls, and ingesting runtime
   components all mutate through the same API. No caller writes envelope tables via raw SQL
   (§8). Type-owned derived tables are the one exception (see §WriteScope).
2. **Validated.** Every write calls the owning kind's `validate(payload)` first; an
   unregistered `type_id` is rejected (you cannot persist an envelope core can't validate).
3. **Transactional index.** The inline `index()` projection (§6) is written in the *same*
   transaction as the envelope, or not at all.
4. **Event after commit.** A `ChangeEvent` is published only after the transaction commits,
   so subscribers (SSE, indexers) never observe uncommitted state.
5. **Idempotent mirror.** `external_key` upsert keeps one item per external object with a
   *stable* id across updates (§3 — one cached-user per Discord user, referenced by
   thousands of cached-messages).
6. **Principals are inert-safe.** The write path never creates a `User`; users come from
   auth (#17). Items stay inert content (§2).

## Context taxonomy (what each caller gets)

Today `StoreCtx` (read-only: `children`/`descendants`/`seek_time`/`search`) is the only
context. Add a **write** context that extends it, and make the runtime context real:

```rust
// cp-model — read stays as-is; writes are a superset so a mutation can read first (upsert).
#[async_trait]
pub trait WriteCtx: StoreCtx {
    async fn create_channel(&self, spec: NewChannel) -> Result<ChannelId>;
    async fn create_item(&self, spec: NewItem) -> Result<ItemId>;

    /// Insert-or-update keyed on `external_key`; the id is stable across updates. §3.
    async fn upsert_item(&self, spec: NewItem) -> Result<Upsert<ItemId>>;

    async fn set_channel_payload(&self, id: ChannelId, payload: Json) -> Result<()>;
    async fn set_item_payload(&self, id: ItemId, payload: Json) -> Result<()>;

    async fn reparent_channel(&self, id: ChannelId, container: Option<ChannelId>) -> Result<()>;
    async fn reparent_item(&self, id: ItemId, container: Option<ChannelId>) -> Result<()>;

    async fn delete_channel(&self, id: ChannelId) -> Result<()>; // cascades via FK
    async fn delete_item(&self, id: ItemId) -> Result<()>;

    // Generic `channel_members` substrate (§8), used by `ChannelKind::membership()` impls.
    async fn add_member(&self, channel: ChannelId, user: UserId) -> Result<()>;
    async fn remove_member(&self, channel: ChannelId, user: UserId) -> Result<()>;
    async fn members(&self, channel: ChannelId) -> Result<Vec<UserId>>;
}

pub struct NewChannel {
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
    pub payload: Json,
}
pub struct NewItem {
    pub type_id: TypeId,
    pub container: Option<ChannelId>,
    pub external_key: Option<String>,
    pub payload: Json,
}
pub enum Upsert<Id> {
    Inserted(Id),
    Updated(Id),
}
```

- **`ChannelKind::contents`** keeps `&dyn StoreCtx` (read-only — a reader can't mutate).
- **`Membership`** changes from `&dyn StoreCtx` to **`&dyn WriteCtx`** (it writes edges;
  small interface change — Open decision 1). What "add a user" means stays the kind's
  choice: `basic`/`space` call `cx.add_member(...)`; `discord` may reject or proxy an invite.
- `cp-core::Store` implements both `StoreCtx` and `WriteCtx`. The debug shell and generic
  API hold the concrete `Store` and thus have the full write surface.

Runtime components get scope-gated access — this sketches the shape `TODO.md` #4 will build.
It is **not** implemented by #1 (see the status note): `RuntimeCtx` is still a marker trait,
and `Store` (the Primary writer) is used directly by the shell + generic API for now.

```rust
// cp-model — RuntimeCtx becomes real (today it is an empty marker trait).
#[async_trait]
pub trait RuntimeCtx: Send + Sync {
    fn reads(&self) -> &dyn StoreCtx;              // always
    fn writer(&self) -> Option<&dyn WriteCtx>;     // Some iff writes() == Primary
    fn derived(&self) -> &dyn DerivedStore;        // this crate's type-owned tables
    fn events(&self) -> broadcast::Receiver<ChangeEvent>; // filtered by interests (§7)
    // + a schedule tick and a shutdown token — detailed in #4.
}
```

## Write algorithm (per mutation)

```
create_item(spec):
    kind = registry.item(&spec.type_id).ok_or(NotFound)?     # invariant 2
    kind.validate(&spec.payload)?                            # pure, no I/O (§6)
    id = ItemId::generate()                                  # ULID, time-ordered
    tx = pool.begin()
    INSERT INTO items(id, type_id, container, external_key, payload) VALUES (...)
        # container FK enforces "parent exists"; failure -> abort (invariant: cheap ref integrity)
    if let Some(entry) = kind.index(&spec.payload):          # invariant 3
        upsert_index(tx, Item, id, entry)                    # FTS / sort-key / R-tree
    tx.commit()
    events.publish(ChangeEvent { op: Created, super_type: Item, id, type_id, container })  # invariant 4
    Ok(id)
```

`upsert_item` is one atomic statement, not a read-then-write race:

```sql
INSERT INTO items (id, type_id, container, external_key, payload)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(external_key) DO UPDATE SET payload = excluded.payload, container = excluded.container
RETURNING id, (id = excluded.id) AS inserted;
```

On conflict the *existing* id is returned (stable — invariant 5); `inserted` distinguishes
`Inserted` vs `Updated` for the return value and the emitted `ChangeOp`. Channels have no
`external_key`, so there is no `upsert_channel`.

`delete_channel` relies on the schema's `ON DELETE CASCADE` for the subtree; index rows are
removed in the same tx. Deletes emit `ChangeOp::Deleted`.

## `external_key` uniqueness (resolves DESIGN §14)

The scaffold schema has one global `UNIQUE(external_key) WHERE external_key IS NOT NULL`.
**Proposal:** keep it global and push namespacing *into the key string* — the kind builds
an opaque key that encodes the scope it wants (`"discord:user:456"` for a global Discord
identity, or `"discord:guild:123:user:456"` if per-guild). Core never parses it; the kind
owns the uniqueness grain. This keeps the schema trivial and answers §14's open question
without a composite index (Open decision 2).

## WriteScope enforcement (§7)

`writes()` returns `Primary` or `Derived`. Enforcement is by *which context the component
holds*, not a per-row check:

- **Primary** (e.g. Discord sync): `writer()` is `Some` — full `WriteCtx`.
- **Derived** (semantic/spatial index): `writer()` is `None`; it gets only `reads()`
  (to backfill) + `derived()` (its own `discord_*` / `canvas_*` tables).

Two honesty levels for "a Derived bug can't corrupt the source of truth":

- **Option A (single DB, convention).** `derived()` is a scoped SQL executor over the one
  database. A Derived component is handed *no* envelope-mutation API, but raw SQL *could*
  technically reach `channels`/`items`. Confinement is API-level + code review. Simple.
- **Option B (separate DB, airtight).** Type-owned derived tables live in a second SQLite
  file `ATTACH`ed for reads; `derived()` writes only that file, so a bug physically cannot
  touch envelopes. `contents` cross-DB-joins index ⇄ envelopes. Honors §7 literally, at the
  cost of attach/join plumbing.

Recommend **A** now, **B** as an upgrade if the guarantee needs teeth (Open decision 3).

## `ChangeEvent` extension (§7/§9)

Today `ChangeEvent { type_id, scope }` carries too little for SSE/indexers to react
precisely. Extend:

```rust
pub enum ChangeOp { Created, Updated, Deleted }
pub enum EnvelopeRef { Channel(ChannelId), Item(ItemId) }

pub struct ChangeEvent {
    pub op: ChangeOp,
    pub target: EnvelopeRef,
    pub type_id: TypeId,
    pub container: Option<ChannelId>, // the scope SSE clients / interests filter on
}
```

## Referential integrity (a deliberate boundary)

- **Container existence** is enforced free by the `container REFERENCES channels(id)` FK.
- **`validate` stays pure** (§6: no I/O), so it *cannot* check that a payload's author
  `UserId` or any cross-envelope reference exists. Authorship lives in the payload (core is
  schemaless); DESIGN §2's "real FK" for a `basic` author is therefore enforced by *kind
  convention*, not a DB constraint or `validate`. Accept this for now (Open decision 5); a
  later optional async `validate_with(&self, cx, payload)` hook could add referential checks
  where a kind wants them, without making the common path do I/O.

## What this touches

- **`cp-model`:** add `WriteCtx`, `NewChannel`/`NewItem`/`Upsert`; make `RuntimeCtx` real;
  extend `ChangeEvent`/add `ChangeOp`/`EnvelopeRef`; change `Membership` to `&dyn WriteCtx`.
- **`cp-core`:** `Store` implements `WriteCtx`; new `index::upsert_index`/`delete_index`
  (still stubbed substrates — real FTS/R-tree is #3); `events` gains the richer event;
  `channel_members` migration (add to `0001_init.sql` or a new core migration).
- **Not touched:** kind crates (they gain behavior only when their `contents`/`membership`
  land), the frontend shell.

## Open decisions (confirm before I code)

1. **Interface change:** `Membership` takes `&dyn WriteCtx` (was `&dyn StoreCtx`). OK?
2. **`external_key`:** global unique + namespacing-in-the-key (vs a composite
   `(namespace, external_key)` index). OK to resolve §14 this way?
3. **WriteScope confinement:** ship **Option A** (convention) now, note B as the upgrade?
4. **`ChangeEvent`** extended to `{ op, target, type_id, container }`. OK?
5. **`validate` stays pure**; cross-envelope reference integrity (author exists) is *not*
   enforced at write. Accept, with an optional async hook deferred?
6. **Scope of #1:** land `WriteCtx` + `ChangeEvent` + the `Store` impl + `channel_members`
   now; leave the full `RuntimeCtx`/supervisor wiring to #4 (I'll define the trait but stub
   its provider). Agree?
7. **Frontend writes:** how the web app *triggers* a write (generic REST `POST` endpoints
   vs per-kind `/ext` routes) is unspecified in §9 — **defer** to #12/#15, or decide here?
   (Recommend defer; #1 is the internal mechanism, exercised first via the debug shell.)
```
