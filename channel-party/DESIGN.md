# channel-party — Design

Status: core mechanisms implemented (write path · read primitives · index substrates · runtime
supervisor · event bus · migrator · debug shell · auth · authorization · linked-users) with the
`basic`/`space`/`canvas` slices real and `discord-compatible` ingestion + structure + contents landed
(#10 a+b+d); the rest of #10 (semantic index · webhook · outbound · membership) remains. See `TODO.md`.
Last updated: 2026-07-11

See `TODO.md` for the deferred implementation work, each item tagged with its design-readiness.

A Discord-inspired chat platform whose defining property is **extensibility**: the
number of channel kinds and message kinds is expected to grow without bound, while
the shared infrastructure (`channel-party-core`, `channel-party-frontend`) stays
fixed and simple.

channel-party is **agnostic to how a user experiences the app**. The core is
headless; a web frontend is merely the first consumer. Everything below is designed
so that adding a new kind of channel or message touches **zero lines of core or
frontend-shell code** — it adds a self-contained *vertical slice* instead.

> **Implementation status.** The §10 structure exists and `nix flake check` is green.
> Implemented: `cp-model`; the `cp-core` **write path** (`WriteCtx` — validate → persist →
> transactional index → change event; `external_key` upsert; the `channel_members` substrate),
> per `design/write-path.md` (`TODO.md` #1); **all four read primitives** (`StoreCtx` —
> `children`/`descendants`/`seek_time`/`search`), per `design/read-path.md` + `design/index-search.md`
> (#2/#3); the **FTS5 index substrate** feeding `search` (#3); the **runtime supervisor** —
> `spawn_runtime` supervises each `RuntimeComponent` (backfill-then-stream, restart/backoff, the real
> `RuntimeCtx` with `WriteScope` confinement + `version()` reset), per `design/runtime.md` (#4);
> **three vertical slices** — `basic`'s feed, `space`'s subtree search, and `canvas`'s viewport-bbox over
> its *own* R-tree (the reference §6 escape-hatch slice: an R-tree in `canvas_*` tables maintained by a
> `Derived` `SpatialIndex` component, #11) — on the generic HTTP API (`GET /api/channels|items/:id`,
> `POST .../contents` dispatch), end-to-end tested (#8/#9/#11/#12);
> **live updates** — `GET /api/events` streams the change bus over SSE, scope-filterable (#13); the
> **frontend** — `basic`'s live message list, `space`'s search box, and `canvas`'s pannable viewport,
> delegating rendering via the registry, on a fully-static, client-side-routed Astro shell (#15/#16); and
> the **gated debug shell** (`channel-party shell`) — read + envelope-CRUD + `reparent` + capability-gated
> membership + `set-password` through the mutation API (#6); and **native-user auth** — password login
> (argon2, provisioned accounts) + server-side sessions (`/api/auth/login|logout|me`, a `CurrentUser`
> extractor) with the shell's login state in the frontend, per `design/auth.md` (#17). Still stubbed:
> the `sort_key` index substrate (no consumer yet), the `discord` slice (#10), and per-channel
> permissions (#18). Deferred work and its design-readiness live in **`TODO.md`**.
>
> **Notable coupling** discovered building #4/#11: `cp-model` depends on `sqlx` — the price of the §6
> escape hatch (handing an escape-hatch kind a DB handle through `StoreCtx`/`RuntimeCtx`). Pure kinds
> never use it.
>
> Deltas from the illustrative code below: `StoreCtx` and `RuntimeCtx` are **traits**
> (passed as `&dyn`) implemented by `cp-core`, so kind crates depend only on `cp-model`;
> `ItemKind` is a plain (non-async) trait; `Migration`/`Migrations` live in `cp-model`;
> kinds register via constructor fns (`cp_basic::channel()`, `cp_discord::channels()`, …)
> and the crates are named `cp-basic`/`cp-space`/`cp-discord`/`cp-canvas`; the frontend is
> built with **npm/`buildNpmPackage`**, not pnpm (§11).

---

## 1. Guiding thesis: envelope + registry, types as vertical slices

The tension is: channels and messages are open-ended and infinitely flexible, but
the core and frontend must stay stable. The resolution is to make **core a
mechanism, not a policy**.

- **Storage is schemaless.** There is no base class and no required fields on a
  message, because core never looks inside one. Every channel and every item is an
  *envelope*: an id, a type discriminator, a containment edge, and an opaque JSON
  payload. Core stores envelopes; it does not interpret payloads.
- **Behavior is pluggable.** A *Kind* (channel-kind or item-kind) is a registry
  entry keyed by the type string. Core calls into it through a fixed set of
  capability traits; core never `match`es on a concrete type.

A "type" is therefore not a base class and not a separate service. It is a
**vertical slice** — a Rust crate (+ colocated frontend islands) that implements
only the capabilities it needs. The core and frontend are the *horizontal*
infrastructure; each type is a *vertical* plugin.

---

## 2. The two super-types

There are exactly **two super-types**, each an open-ended, plugin-extensible family:

- **`channel-type:*`** — containers.
- **`item-type:*`** — everything that lives in a container.

**Channels contain items *and* other channels, arbitrarily.**

Concrete kinds in the initial design:

| Super-type | Kinds |
| --- | --- |
| `channel-type:` | `basic` · `space` · `discord-compatible/{guild,section,channel,forum}` · `canvas` |
| `item-type:` | `basic` · `discord-compatible/{message,cached-message,cached-reaction,cached-user}` · `canvas-text-box` |

The word "message" is intentionally *not* a super-type. Reactions, cached external
users, and canvas text boxes are all **items** — "item" is the generic content
object; a chat message is just its most common kind.

### Users sit outside the taxonomy

There is exactly **one real principal: the native channel-party `User`.** It is not
a super-type because it is not extensible — there is one native user representation,
and it is the only thing that authenticates, owns, or holds permissions.

External identities are **not real users**. A Discord user is stored as an
`item-type:discord-compatible/cached-user` and is inert attribution data. A native
`User` carries `linked-users`: references to the cached-user items that represent it
on external platforms.

Invariant enforced by core: **only a native `User` can be a principal; items are
inert content.** Auth, sessions, ownership, and permission checks resolve
exclusively against `users`.

**Auth is implemented** (`design/auth.md`, `TODO.md` #17): password login (argon2id hash in
`users.password_hash`) with **provisioned accounts** — no public registration; a login is granted via
the debug shell's `set-password`. Sessions are server-side (opaque token in an HttpOnly cookie; the DB
stores only its SHA-256), exposed as `POST /api/auth/login|logout` + `GET /api/auth/me` and a
`CurrentUser` extractor. **Per-channel authorization is implemented** (§18, `design/permissions.md`): a
`Permission` capability on `ChannelKind` (deny-by-default), enforced at the authenticated write endpoint;
authorship is stamped server-side per kind (`with_author`) — no core author column, honoring the
polymorphic authorship below.

This makes authorship cleanly polymorphic (which is fine precisely *because* there
is no base class):

- `item-type:basic` → author is a native `UserId` (real FK).
- `item-type:discord-compatible/cached-message` → author is a reference to a
  `cached-user` item, optionally resolvable up to a native user via a link.
- `item-type:discord-compatible/message` (originates on channel-party, pushed to
  Discord via webhook) → author is a native `User`.

**The `linked-users` edge + authorship resolution are implemented** (§19, `design/linked-users.md`):
`cp-core::links` links a native user to the external `cached-user` items that represent it (a cached-user
maps to ≤1 native user) and resolves an item *up* the link to its native user; links are
**operator-provisioned** (debug shell), HTTP exposes only reads. Self-service linking awaits a *per-kind
proof-of-ownership* mechanism (each external kind verifies ownership its own way — Discord OAuth, etc.),
the future form of §14's OAuth-linking question.

---

## 3. Data model

Three tables — **two super-types, plus the fixed `users` substrate.**

```
users               (id, handle, auth…, created_at)          -- first-class, native principals only
user_external_links (user_id → users.id, item_id → items.id UNIQUE) -- `linked-users` edge; one native user per external item (§19)
channels            (id, type_id, container?, payload_json)  -- container = parent channel (null = root)
items               (id, type_id, container?, external_key?, payload_json)
```

- **Uniform containment edge.** Both channels and items carry
  `container: Option<ChannelId>`. A channel's children = *everything (channels or
  items) whose `container` is that channel*. Arbitrary mixing of sub-channels and
  items falls out for free. `container` is nullable: a root channel or a
  guild-scoped `cached-user` may have none.
- **Minimal required fields.** The only truly universal envelope fields are `id` and
  `type_id`. Even `container` is optional. Everything else lives in `payload_json`
  and is understood only by the owning kind.
- **`external_key`** on items is the dedup/upsert handle for mirrored external
  objects. There must be exactly **one** `cached-user` item per Discord user
  (`external_key = discord user id`, unique per namespace), referenced by thousands
  of cached-messages — never a copy per message, or `linked-users` becomes
  meaningless.
- **IDs are ULID / UUIDv7** (time-ordered). Consequences: a channel feed sorts by id
  with no mandated `timestamp` field; canvas boxes get a stable creation order for
  free; "jump to timestamp T" is just seeking to the ULID whose time prefix is T
  (see §5).

Writes go through core's mutation API — the `WriteCtx` trait (implemented, see
`design/write-path.md`): each mutation calls the kind's `validate`, then persists the
envelope + inline `index()` in one transaction, then emits a change event on commit. So no
path (including the debug shell) can persist an invalid envelope. `upsert_item` keyed on
`external_key` gives idempotent mirroring with a stable id; the key is an opaque string the
kind constructs to encode its own uniqueness grain (resolving §14's namespacing question).

---

## 4. The Kind abstraction and its capabilities

Two registries — one per super-type. Kinds are trait objects; capabilities are
**opt-in default methods**, so a trivial kind implements two lines and a rich one
implements many.

```rust
pub struct TypeId(String);   // "discord-compatible/channel"

pub struct Channel { id: ChannelId, type_id: TypeId, container: Option<ChannelId>, payload: Json }
pub struct Item    { id: ItemId, type_id: TypeId, container: Option<ChannelId>,
                     external_key: Option<String>, payload: Json }

#[async_trait]
pub trait ChannelKind: Send + Sync {
    fn type_id(&self) -> &TypeId;

    fn validate(&self, p: &Json) -> Result<()> { Ok(()) }             // §3

    /// Discover this channel's contents. `query` and the returned value are type-defined. §5
    async fn contents(&self, cx: &StoreCtx, ch: &Channel, query: Json) -> Result<Json>;

    fn index(&self, p: &Json) -> Option<IndexEntry> { None }          // inline projection, §6
    fn membership(&self) -> Option<&dyn Membership> { None }          // §8
    fn permission(&self) -> Option<&dyn Permission> { None }          // authorization; None = deny, §18
    fn routes(&self) -> Option<axum::Router> { None }                 // extra HTTP routes, mounted /ext/<type>
    fn debug_commands(&self) -> Vec<DebugCommand> { vec![] }          // §8
    fn debug_summary(&self, c: &Channel) -> Option<String> { None }   // §8
    // Frontend island is declared out-of-band via a web/ manifest, not in Rust. §9
}

#[async_trait]
pub trait ItemKind: Send + Sync {                                     // same shape, no `contents`/`membership`
    fn type_id(&self) -> &TypeId;
    fn validate(&self, p: &Json) -> Result<()> { Ok(()) }
    fn index(&self, p: &Json) -> Option<IndexEntry> { None }
    fn with_author(&self, p: Json, u: UserId) -> Json { p }          // stamp server-side authorship, §2/§18
    fn debug_summary(&self, i: &Item) -> Option<String> { None }
}
```

Kinds are grouped by **namespace, not by leaf**: `discord-compatible/` is one crate
holding guild + section + channel + forum + message + cached-message +
cached-reaction + cached-user + the shared Discord runtime, because they share a
great deal (one rate-limited client, one search index). This mirrors the
`namespace/leaf` id scheme.

### Capability coverage by example family

| Capability | `basic` | `space` | `discord-compatible` | `canvas` |
| --- | :-: | :-: | :-: | :-: |
| `validate` | – | – | ✓ | ✓ |
| `contents` (channel) | list+paginate | name search | fetch-all subtree | viewport bbox |
| `index` (inline) | name → FTS | – | (via RuntimeComponent) | coord → spatial |
| `membership` | ✓ | ✓ | reject / proxy to Discord | – |
| `permission` | members may post | – (deny) | Discord's model | – (deny) |
| `RuntimeComponent` | – | – | sync (Primary) + semantic index (Derived) | spatial index (Derived) |
| `routes` | – | – | webhook receiver | – |
| island (frontend) | message list | search UI | threaded view | pan/zoom canvas |

`basic` rides the generic path and implements almost nothing; `canvas` is
frontend- and index-heavy; `discord-compatible` is runtime-heavy. Same plugin
surface, radically different weights.

---

## 5. Contents discovery

**How a channel discovers its contents is itself a per-channel-type capability**,
not one fixed endpoint. Core provides one generic dispatch plus a small, *closed*
set of store primitives; each kind composes its own discovery strategy on top. Core
gains nothing per type.

One HTTP route → one trait method:

```
POST /api/channels/:id/contents   { query }   →   registry.channel(ch.type_id).contents(...)
```

`query` and the response are **opaque to core**; the island for that channel type
knows their shape. `StoreCtx` hands the kind these primitives (this set does not
grow as types are added):

```rust
cx.children(container, filter{super_type?, type_ids?}, page, order)  // one level, cursor-paginated
cx.descendants(root, filter, depth?)                                 // whole subtree (fetch-all)
cx.seek_time(container, timestamp) -> Cursor                         // ULID ⇒ time-jump is a cursor
cx.search(scope, text, filter, page)                                 // FTS over the index() projection, §6
```

The three worked examples all reduce to these:

| Channel kind | `contents(query)` |
| --- | --- |
| `basic` | `children(id, {Item, [basic]}, page, TimeDesc)`; `query.at` → `seek_time` first ⇒ jump-to-timestamp is free |
| `space` | `search(self, query.q, {Channel}, page)` → paginated name matches over the subtree (impl drops the design's `[basic]` restriction so `space` isn't coupled to a peer type) |
| `discord/guild` | `descendants(id, {Channel, [channel, section]})` → whole subtree at once; island builds the tree |
| `discord/section` | same, scoped to itself |

Discovery is **recursive**: a guild island renders channel *references*; opening one
mounts that child's island, which calls its *own* `contents`. Containers delegate to
children exactly as they delegate item rendering (§9).

All four primitives are **implemented** (see `design/read-path.md` + `design/index-search.md`):
`children` is a `UNION ALL` keyset query across the two super-type tables ordered by id
(`LIMIT n+1` derives the next cursor); `descendants` is a recursive CTE over the channel
containment edge (root = depth 0, optional depth cap); `seek_time` is a *pure* ULID
computation (the id just below time `T`'s floor), no query. A `Cursor` is an opaque string
wrapping a bare ULID keyset boundary — results resume strictly beyond it in the `Order`
direction, and because a ULID's base32 text sorts like its value the pagination is a plain
`id <cmp> ?`. **`search`** MATCHes the FTS5 projection (§6), joins back to channels/items, and
scopes to `scope`'s subtree via the *same* CTE as `descendants`; it ranks by bm25, so it pages by an
**offset** cursor — deliberately a different opaque encoding from the id-keyset one (which is why
`Cursor` is per-primitive, not globally structured).

---

## 6. Indexing

Substring name-search (`space`) can't run over opaque JSON efficiently — `name`
lives in `basic`'s payload. So the honest price of schemaless storage + type-specific
discovery is a **kind-declared projection** of searchable/sortable fields. Core still
hardcodes no field; it only calls a kind-supplied function. Two tiers:

### Tier 1 — inline projection (the 90% case)

`index(payload) -> IndexEntry` is a pure function applied **transactionally on
write** into core's built-in substrates:

- **FTS5** (trigram tokenizer → true substring search) for `name` / body text. **Implemented**
  (`search_index`, `design/index-search.md`): a standalone FTS5 table keyed by `envelope_id` +
  `super_type`, written delete-then-insert by `index::upsert`; `StoreCtx::search` MATCHes it and
  joins back to channels/items (orphaned rows from cascaded deletes are invisible to the join).
- Expression indexes for declared **sort keys** — *deferred* (no consumer yet; `TODO.md` #11).
- A **2D / R-tree** substrate for coordinates (`canvas-text-box`) — *deferred* to `canvas` (#11);
  RTREE is confirmed available in the build.

`IndexEntry { name?, text?, sort_key?, coord? }`. Cheap, deterministic, no I/O, no
task. A kind that needs no indexing returns `None` and costs nothing. `index::upsert` projects
`name`/`text` today and ignores `sort_key`/`coord` until #11 builds their substrates.

### Tier 2 — async indexing via `RuntimeComponent` (§7)

Anything expensive, async, cross-item, or externally-enriched — embeddings for
semantic search, a thread/reaction adjacency graph — is a supervised runtime
component, not an inline function. It may write core substrates or a table the type
owns.

**Type-owned index tables** are the escape hatch: a crate may ship namespaced
migrations (`discord_*`, `canvas_*`) registered with core's migrator, giving it a
fully self-contained search stack — *own table (schema) + RuntimeComponent (writer) +
`contents` (reader)* — that core never learns the shape of. **`canvas` is the reference
implementation** (`TODO.md` #11, `design/runtime.md`): `canvas_box` + `canvas_box_rtree`
(an R-tree), a `SpatialIndex` `Derived` component that maintains it off the change stream, and a
viewport-bbox `contents` reader — none of which core sees. The reader/writer reach their tables via
`type_owned_db()` on `StoreCtx`/`RuntimeCtx`, which is why `cp-model` depends on `sqlx`. Cost: those
schemas must be in each crate's `.sqlx` offline cache for compile-time query checking (§13).

---

## 7. `RuntimeComponent` — the one supervised-task abstraction

Ingesting workers and derived indexers are **the same machine**: a supervised,
long-lived task that does an initial batch pass, then reacts to a stream
("backfill-then-stream"). The Discord sync worker is *initial sync, then poll*; a
semantic indexer is *initial backfill, then react to change events*. One loop, one
trait — there is **no separate `Worker` and `Indexer`.**

```rust
#[async_trait]
pub trait RuntimeComponent: Send + Sync {
    fn name(&self) -> &str;
    fn interests(&self) -> Interests { Interests::none() } // a schedule, and/or the change stream (by type)
    fn version(&self) -> u32 { 0 }                         // bump ⇒ reset; component decides what reset means
    fn writes(&self) -> WriteScope { WriteScope::Derived } // Primary | Derived — see safety note
    async fn run(&self, cx: RuntimeCtx) -> Result<()>;     // backfill + steady-state, all in one loop
}
```

`RuntimeCtx` provides the store handle (restricted per `writes()`), the change-stream
subscription filtered by `interests`, the scheduler, and shutdown.

**Implemented** (`design/runtime.md`, `TODO.md` #4): the supervisor runs one task per component
(restart + capped backoff, `RuntimeHandle` shutdown); `RuntimeCtx` exposes `next_event` (the filtered
change stream merged with the scheduler; `None` on shutdown), point reads, `scan` (the backfill
enumerator), `writer() -> Option<&dyn WriteCtx>` (**`None` for `Derived`** — confinement is structural),
`type_owned_db` (the §6 escape hatch), and `reset_requested()` (a `version()` bump vs the
`runtime_component_state` table). The change-event types live in `cp-model`. First `Derived` consumer:
`canvas`'s `SpatialIndex` (§6, #11); first `Primary` consumer: `discord-compatible`'s `DiscordSync`
(#10 (a)+(b), `design/discord.md`) — it fetches Discord messages and upserts `cached-user`/`cached-message`
envelopes through `writer()` (which returns `Some` only for `Primary`). *Delta from the sketch above:*
`run` takes `cx: &dyn RuntimeCtx` (dyn-safe), and giving escape-hatch kinds a DB handle made `cp-model`
depend on `sqlx`.

Two facets that are **behavior, not interface**:

- **Reset semantics differ by input source.** A derived component resets by replaying
  *local* primary data — deterministic, cheap. An ingesting component resets by
  re-fetching from Discord — rate-limited, non-deterministic, unreconstructable
  locally. Same `version()` trigger, different `run` behavior; the interface doesn't
  care.
- **Write-scope safety.** `writes()` lets core hand back a restricted store handle:
  an ingestor writes `Primary` envelopes (source of truth); a derived indexer is
  confined to `Derived` tables, so a bug can't corrupt the source of truth.

Components are **crate-contributed singletons**, not one-per-channel-instance. A
*single* Discord component manages all bridged guilds behind one shared rate-limited
client and one token bucket — far better than N workers fighting the rate limit.
They compose via the event bus: the sync component writes cached-messages and emits
change events; the semantic-index component consumes them — independent tasks, so a
slow embedding pipeline never blocks ingestion.

---

## 8. Debug shell (`channel-party-core`)

A REPL that lets developers and LLMs grok the running application. It is a **thin
read wrapper over the database** by default, with an explicitly-gated write surface.

### Read side

Direct DB reads (fast, honest view of what is actually stored): show channels, show
a channel's items, show users, inspect an envelope. Payloads print as JSON; the
optional per-kind `debug_summary` adds a one-line human summary when present.

### Write-mode gate

- **Off by default, per-session, never persisted** — a fresh shell is always
  read-only, so exploration can't mutate anything by accident.
- `enable-write-mode` / `disable-write-mode` flip a session flag. Every mutating
  command refuses until it is on (`"read-only; run enable-write-mode first"`).
- The prompt reflects the mode: **`cp[ro]>`** vs **`cp[write]>`**.
- **Writes route through core's mutation API + the kind's `validate`, never raw
  SQL** — the one asymmetry with reads. A debug write cannot create an invalid
  envelope or bypass an invariant.

### Write commands are capability-gated

`add-user-to-channel <channel-id> <user-id>` is backed by an optional `Membership`
capability on `ChannelKind`:

```rust
pub trait Membership: Send + Sync {
    async fn add_user(&self, cx: &dyn WriteCtx, ch: &Channel, u: UserId) -> Result<()>;
    async fn remove_user(&self, cx: &dyn WriteCtx, ch: &Channel, u: UserId) -> Result<()>;
    async fn members(&self, cx: &dyn WriteCtx, ch: &Channel) -> Result<Vec<UserId>>;
}
```

Resolution of `add-user-to-channel`:

1. write-mode off → refuse;
2. `ch.kind().membership()` is `None` → **"channel-type `canvas` does not accept
   users"** (this *is* the "accepts users" check — capability presence);
3. `Some` → execute. What "add a user" means is the kind's choice: `basic` writes a
   membership edge (core offers a generic `channel_members` substrate); `space`
   likewise; `discord-compatible/channel` may reject (membership is owned by Discord)
   or proxy an outbound invite.

### The write surface scales with types

New types bring their own mutations (`move-box <item> <x> <y>`,
`resync-channel <id>`). The shell is a **generic command dispatcher**: kinds
contribute commands via `debug_commands()`, each flagged read/write so the mode gate
applies uniformly without the shell knowing what they do. Built-in
capability-backed commands (membership) + kind-registered commands, all behind the
one gate. The shell never grows per type.

**Implemented** (`TODO.md` #6, `cp_core::debug`, run via `channel-party shell`): the mode gate, the
direct-DB reads, and envelope-CRUD + membership through the mutation API. `create-user` bootstraps the
`users` substrate (raw insert) until auth (#17); `set-password` provisions logins (#17); `link-user` /
`unlink-user` / `show links` provision the `linked-users` edge (#19). *Executing* kind-registered
`debug_commands()` is deferred until the first kind ships one (needs a registry enumerator + a per-kind
execution hook).

---

## 9. Frontend (`channel-party-frontend`)

Astro serves a **static outline** (nav, channel tree, layout — entirely
type-agnostic). The dynamic, type-specific parts are **islands**.

- A channel page fetches `{ id, type_id }`, then **dynamically imports** the island
  bundle for that type from a client-side registry
  `Map<typeId, () => import(...)>` (dynamic import ⇒ code splitting). It mounts the
  island; the island owns its own data fetching (calls `POST .../contents` with its
  type-specific query), rendering, and interactions.
- **The registry map is generated at build time** by scanning `kinds/*/web/`, so
  adding a type does not edit any central switch. Convention over central
  registration — the frontend shell stays frozen.
- **Channel-kind islands render *containers* and delegate item rendering to
  item-kind islands** via the same registry. The canvas channel island owns
  pan/zoom/placement and delegates drawing each box to the `canvas-text-box` item
  island; a new item type that can appear on a canvas is one new item island and the
  canvas island never changes. The two axes (channel kinds, item kinds) scale
  independently.
- **Live updates**: the frontend server exposes SSE backed by the core event bus;
  islands subscribe to changes for their channel.

### Rust ↔ TS contract

To stop payloads from drifting, TS types are generated from the Rust payload structs
(`ts-rs`): each kind emits its payload/query/response types into its own `web/` dir,
which the island imports. The vertical slice stays coherent across the
language boundary.

### HTTP surface (all served by `channel-party-frontend`)

```
GET  /api/channels/:id                 -> { id, type_id, container }        (generic)
POST /api/channels/:id/contents  {q}   -> type-defined contents             (dispatch, §5)
POST /api/channels/:id/items  {type_id, payload} -> 201 { id }              (authenticated write, §18)
GET  /api/items/:id                    -> envelope                          (generic)
GET  /api/users/:id/links              -> { items: […] }                    (linked-users, §2/§19)
GET  /api/items/:id/linked-user        -> User | 404                        (authorship resolution, §2/§19)
GET  /api/events?scope=…               -> SSE change stream                 (generic)
POST /api/auth/login|logout · GET /api/auth/me                              (native-user auth, §2/§17)
/ext/<type>/…                          -> kind-contributed routes (webhooks, etc.)  (§4)
```

`POST …/items` is the first authenticated write (§18, `design/permissions.md`): it requires a session
(the `CurrentUser` extractor → 401), the channel kind's `Permission` to grant `Post` (→ 403,
deny-by-default), and a known item type (→ 400); the author is stamped server-side via the item kind's
`with_author` (§2), then `validate` + persist run in the write path. It stays type-agnostic — the client
names the `type_id` and the payload is opaque to core.

---

## 10. Component / crate layout

```
channel-party/
├── flake.nix · Cargo.toml            # nix + crane; one cargo workspace
├── crates/
│   ├── cp-model/     # envelope, ULID ids, Kind + capability traits, Membership,
│   │                 #   RuntimeComponent, serde, ts-rs exports          (the interface crate)
│   ├── cp-core/      # sqlx(sqlite) store · two Kind registries · contents dispatch ·
│   │                 #   index substrates + inline projection · RuntimeComponent supervisor ·
│   │                 #   event bus · migrator · gated debug shell
│   ├── cp-frontend/  # axum server: generic API + kind routes · serves Astro build · SSE
│   └── cp-bin/       # composition root: registers kinds + runtime components, boots core + frontend
├── kinds/                              # vertical-slice plugins (Rust src/ + colocated web/)
│   ├── basic/
│   ├── space/
│   ├── discord-compatible/  (src/ + web/ + migrations/)   # guild/section/channel/forum + items + runtime
│   └── canvas/              (src/ + web/ + migrations/)   # canvas + canvas-text-box + spatial index
├── web/              # Astro app shell (outline) + island registry generated from kinds/*/web
└── DESIGN.md
```

`cp-core` depends only on `cp-model` (the trait/interface crate). It has **no
dependency on any concrete kind crate.** Concrete kinds are wired in exactly one
place — the composition root:

```rust
let registry = Registry::builder()
    .item(cp_basic::item()).channel(cp_basic::channel())
    .channel(cp_space::channel())
    .channels(cp_discord::channels()).items(cp_discord::items())
    .runtime(cp_discord::sync())            // WriteScope::Primary  — ingests messages/users/reactions
    .runtime(cp_discord::semantic_index())  // WriteScope::Derived  — embeddings, off the change stream
    .channel(cp_canvas::channel()).item(cp_canvas::text_box())
    .runtime(cp_canvas::spatial_index())    // WriteScope::Derived
    .migrations(cp_discord::MIGRATIONS).migrations(cp_canvas::MIGRATIONS)
    .build();

let core = cp_core::Core::open(db, registry.clone()).await?;   // runs migrations (backfills stubbed)
core.spawn_runtime();                                          // supervises every RuntimeComponent (stubbed)
cp_frontend::serve(core, registry, addr).await?;
```

Explicit registration (over `inventory`-style auto-registration) is chosen for
clarity, testability, and control over ordering.

---

## 11. Build — Nix + crane

- **Rust workspace via crane.** Shared `cargoArtifacts` across the workspace for
  fast incremental caching; the whole workspace builds as one dependency graph.
- **sqlx in offline mode.** Compile-time query checking uses a committed `.sqlx`
  query cache (`SQLX_OFFLINE=1`), so builds are hermetic with no live DB — required
  under Nix. Type-owned migrations (§6) must be reflected in the offline cache.
- **Astro frontend** built as a separate derivation with **`buildNpmPackage`** (npm).
  pnpm was the first choice, but its `fetchPnpmDeps` fixed-output derivation is SIGKILLed
  on exit inside the Nix builder here, so npm is used; `sharp` (Astro's optional image
  dep) is excluded via the passthrough image service + `--ignore-scripts`. The island
  registry is generated from `kinds/*/web` at build time; `npmDepsHash` in `flake.nix`
  must be refreshed whenever `web/package-lock.json` changes. The final package wraps the
  server binary to serve the static Astro output via `CP_WEB_DIR`.
- **Devshell**: rust toolchain + node/pnpm + `sqlx-cli`.

---

## 12. Testing strategy

The whole point of splitting components is that each is independently
integration-testable.

- **`cp-model`** — unit tests for envelope serde and trait defaults.
- **`cp-core`** — integration tests against a tempfile/in-memory sqlite: store CRUD,
  the store primitives (`children`/`descendants`/`seek_time`/`search`), contents
  dispatch, index backfill + versioning, and RuntimeComponent supervision. Core's
  genericity is *proven* by testing it against a throwaway `test-support` kind — this
  also keeps the plugin API honest.
- **Each kind crate** — its own integration tests. `discord-compatible` tests
  rate-limit handling and cache/dedup logic against a **mock Discord API**
  (`wiremock`), never the real one.
- **`cp-frontend`** — tests hitting the axum server against a seeded DB; island tests
  via vitest/Playwright on the JS side.

---

## 13. Capability summary

Core is a fixed, small set of mechanisms:

> envelope store · two kind registries · `contents` dispatch · index substrates +
> inline projection · one `RuntimeComponent` supervisor · event bus · migrator ·
> gated debug shell

Every channel/item type is a vertical slice (Rust crate + colocated islands) that
opts into only the capabilities it needs:

| Capability | Surface | Where it runs |
| --- | --- | --- |
| `validate` | ChannelKind / ItemKind | core write path |
| `contents` | ChannelKind | core (HTTP dispatch) |
| `index` (inline) | ChannelKind / ItemKind | core write path (transactional) |
| `RuntimeComponent` | registry | core runtime (supervised) |
| `membership` | ChannelKind | core / debug shell |
| `permission` | ChannelKind | core write path (authz dispatch) |
| `with_author` | ItemKind | frontend write endpoint |
| `debug_commands` | ChannelKind | debug shell |
| `debug_summary` | ChannelKind / ItemKind | debug shell |
| `routes` | ChannelKind | frontend server |
| island | `web/` manifest | frontend (Astro) |

Adding a type touches none of these mechanisms — only the slice.

---

## 14. Open questions / deferred decisions

These are unresolved **design** questions, distinct from the implementation backlog in
`TODO.md` (which flags which items still need a design pass before coding):

- ~~**Permissions model.**~~ **Resolved (#18, `design/permissions.md`):** a `Permission` capability on
  `ChannelKind` (the "another capability" this predicted), deny-by-default, enforced at the authenticated
  write endpoint; the fixed `Action` vocabulary is `View`/`Post`/`Manage` (only `Post` gated so far —
  reads stay open). Authorship is stamped per-kind server-side (`ItemKind::with_author`), no core column.
- **Membership storage.** Partly resolved by #18: a `Permission` policy can ride the generic
  `channel_members` substrate (`basic` = "members may post"), so it is sufficient for the common case;
  membership-heavy kinds that outgrow it own their own edge tables via the §6 escape hatch (no core
  change). Still open only as "when to reach for a kind-owned table."
- **`external_key` namespacing.** Exact uniqueness scope for cached objects
  (per-guild vs global Discord user identity).
- ~~**Auth / session mechanism** for native users.~~ **Resolved (#17, `design/auth.md`):** password
  login + provisioned accounts + server-side sessions.
- ~~**`linked-users` linking.**~~ **Resolved (#19, `design/linked-users.md`):** `cp-core::links` +
  operator-provisioned links (shell) + read/resolution endpoints. Open self-signup and **self-service
  linking** remain future extensions — the latter gated by a **per-kind proof-of-ownership** capability
  (each external `cached-user` kind verifies ownership its own way, e.g. Discord OAuth), layered on the
  same edge without changing storage.
- **Registry ergonomics.** Whether to keep explicit registration or adopt
  `inventory`/`linkme` distributed registration as the type count grows.
```
