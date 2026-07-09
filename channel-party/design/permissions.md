# Permissions model (`TODO.md` #18, DESIGN §14)

Status: ratified 2026-07-11. Folds into `DESIGN.md` §2/§4/§8/§9/§13/§14.

## Problem

Auth (#17) established the one principal — a native `User` with a session. What it did *not*
settle is **per-channel authorization**: who, among authenticated users, may act on a given
channel. §14 flagged the shape as unspecified ("likely another capability"). This note settles
it and wires the **first authenticated write endpoint** as its proof.

## Decisions

1. **Authorization is a capability, not core policy.** A new `Permission` trait on `ChannelKind`,
   opt-in exactly like `Membership`. Core holds *no* authorization policy — it resolves the
   capability and dispatches. This keeps §13's invariant ("adding a type touches none of these
   mechanisms — only the slice"): a kind's authorization model is part of its slice.

2. **Deny-by-default.** A channel whose kind returns `permission() -> None` is **not authorizable**
   over HTTP — the write endpoint refuses it. `None` is a structural "declines to authorize anyone,"
   the same way `membership() -> None` is "does not accept users." Secure-by-default: a kind is
   unwritable until it deliberately grants. (This is the one place we diverge from "trivial kind =
   two lines" — a writable kind must implement `Permission`. Accepted: authorization is exactly the
   thing that should be explicit.)

3. **Writes are enforced now; reads stay open.** The `Action` vocabulary includes `View` for
   completeness, but #18 only gates the write endpoint. Threading an optional session through every
   read path + `contents` dispatch is a larger change deferred to a later item; the `Action::View`
   variant means that later change needs no signature churn here.

4. **Authorship is stamped server-side, per kind.** Per §2, authorship is polymorphic — there is no
   core author column. The write endpoint calls a new `ItemKind::with_author(payload, user)` hook
   (default: unchanged) so the kind embeds provenance however it likes; `basic` sets
   `payload.author = <native UserId>`. The client's own `author` field, if any, is **overwritten** —
   provenance is never client-trusted.

## The vocabulary

```rust
/// A permission-checked action on a channel. A small, fixed, core-owned vocabulary (like `SuperType`),
/// distinct from the open-ended kind set.
pub enum Action { View, Post, Manage }
```

- `View`  — read a channel's contents. Defined, **not yet gated** (reads are open).
- `Post`  — create an item (send a message) in the channel. **The action #18 enforces.**
- `Manage` — administer the channel (membership, structure, config). Defined; HTTP does not expose a
  managing endpoint yet (structure is shell-only), so no kind need grant it now.

Adding a variant later is a core change — but `Action` is authorization *vocabulary*, a cross-cutting
core concern, not a per-type slice; a small stable enum like `SuperType`/`Order` is the right home.

## The capability

```rust
#[async_trait]
pub trait Permission: Send + Sync {
    async fn authorize(&self, cx: &dyn StoreCtx, ch: &Channel, user: UserId, action: Action)
        -> Result<bool>;
}

// on ChannelKind:
fn permission(&self) -> Option<&dyn Permission> { None }   // None = deny-by-default
```

`authorize` is a **read** — it takes `&dyn StoreCtx`, never `WriteCtx`; deciding never mutates. To let
a policy consult the generic membership substrate as a read, `StoreCtx` gains one primitive:

```rust
async fn is_member(&self, channel: ChannelId, user: UserId) -> Result<bool>;
```

the read companion to `WriteCtx`'s `add_member`/`remove_member`. This answers §14's *"is
`channel_members` sufficient?"* — **yes**: a `Permission` policy rides it; membership-heavy kinds that
outgrow it own their own tables (the same escape hatch `canvas` uses), no core change.

## `basic`'s policy — the reference

`basic` becomes the first real `Permission` implementor, riding `channel_members`:

| Action | `basic` policy |
| --- | --- |
| `View`   | allow (contents are public; not enforced yet anyway) |
| `Post`   | **members only** — `cx.is_member(ch.id, user)` |
| `Manage` | deny over HTTP (structure is shell-only for now) |

So the end-to-end proof is: provision + log in `alice` → `add-user-to-channel` → `POST …/items`
succeeds and the item records `author = alice`; a logged-in **non-member** gets `403`; **no session**
gets `401` (the extractor); a channel of a kind with no `Permission` gets `403` (deny-default).

## Core `authorize` helper

Mirrors `contents::dispatch` — one generic resolver, no per-type logic:

```rust
// cp-core::authz
pub async fn authorize(registry, store, channel, user, action) -> Result<bool> {
    match registry.channel(&channel.type_id).and_then(|k| k.permission()) {
        Some(policy) => policy.authorize(store, channel, user, action).await,
        None => Ok(false),   // deny-default (unknown kind or no capability)
    }
}
```

## The endpoint

```
POST /api/channels/:id/items   { type_id, payload }     (requires a session)
```

Flow: `CurrentUser` extractor (→ `401` if no session) → load channel (`404`) →
`authz::authorize(Post)` (→ `403` if false) → resolve the item kind (`400` if unknown) →
`kind.with_author(payload, user)` → `WriteCtx::create_item` → `201 { id }`. The endpoint stays
type-agnostic: it names no concrete kind and never inspects the payload; `type_id` + the opaque
payload come from the client's island, `validate` and authorship are the kind's.

Not in scope (documented, additive later): sub-channel creation over HTTP (`Manage`); a channel kind
vetoing *which* item types it accepts as children (a `validate`/child-policy concern, orthogonal to
who-may-act); read gating (`View`); resolving authorship up a `linked-users` edge (#19).

## Why not the alternatives

- **Core-generic grants table** (a `permissions(channel, user, role)` core enforces) — puts policy in
  core, against §1/§13. A Discord channel's authorization is Discord's, a canvas's is its own; a single
  core table can't model that without becoming a policy engine.
- **Membership = permission** (a member may do anything) — conflates joining with authorization and
  can't express `View` vs `Manage` tiers or public-read. `basic` *chooses* to equate them for `Post`,
  but that is `basic`'s policy, not a core law.
