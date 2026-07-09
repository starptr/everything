# `linked-users` API + authorship resolution (`TODO.md` #19, DESIGN §2/§3)

Status: ratified 2026-07-11. Folds into `DESIGN.md` §2/§3/§8/§9/§14.

## Problem

A native `User` carries **`linked-users`**: references to the `cached-user` items that represent it on
external platforms (§2). The edge table `user_external_links (user_id, item_id)` and the
`UserExternalLink` struct exist, but nothing reads or writes them. #19 supplies:

1. **Linking** a native user to an external `cached-user` item (and unlinking).
2. **Authorship resolution**: given a `cached-user` item (the author a `cached-message` payload points
   at), resolve *up the link* to the native `User`, if any (§2's polymorphic authorship).

## Decisions

1. **Links are operator-provisioned (shell only).** Linking asserts an identity ("this Discord user is
   Alice"); pre-OAuth there is no proof of ownership, so a self-service link would be an unverified
   claim — a logged-in user could claim someone else's `cached-user` and inherit its authorship. This is
   the same trust posture as #17 (provisioned accounts, no self-signup). So the write path is the debug
   shell (`link-user` / `unlink-user`, write-gated); **HTTP exposes only reads**.

   *Future (noted, not built):* self-service linking gated by a **per-kind proof-of-ownership**
   mechanism — each external `cached-user` kind verifies ownership its own way (Discord OAuth, etc.).
   That is where §14's "Discord-OAuth linking" lands: **another kind capability**, consistent with the
   rest of the model, layered on this same edge — the storage does not change, only who may write it.

2. **Core stays type-agnostic.** `link` joins a native user to *an item* — core never checks the item is
   a "cached-user" (that would hardcode a kind string, against §13). The cached-user semantics are the
   caller's; the mechanism is "user ↔ item." (The tests link to a throwaway item, proving this.)

3. **A cached-user maps to ≤1 native user.** §2: a user has *many* linked items (one per platform), but
   an external identity resolves up to *a* (single) native user. So `item_id` is **`UNIQUE`** — a second
   user claiming the same item is a conflict, not a silent second row; `user_for_item` returns `Option`
   (0 or 1), never a list.

4. **Referential integrity.** `item_id` gets a real FK `REFERENCES items(id) ON DELETE CASCADE` (deleting
   a cached-user drops its links); `user_id` already cascades from `users`. This requires the table to be
   created *after* `items` — the block moves below `items` in the migration.

## Core module (`cp-core::links`, sibling to `auth`)

Pool-based (no `Store` dependency), mirroring `auth`:

```rust
pub async fn link(pool, user: UserId, item: ItemId) -> Result<()>;       // validate item exists;
                                                                          // idempotent; conflict if the
                                                                          // item is already linked elsewhere
pub async fn unlink(pool, user: UserId, item: ItemId) -> Result<()>;
pub async fn linked_items(pool, user: UserId) -> Result<Vec<Item>>;       // forward: a user's cached-users
pub async fn user_for_item(pool, item: ItemId) -> Result<Option<User>>;   // reverse: authorship resolution
```

`link` semantics: item missing → `NotFound`; already linked to *this* user → `Ok` (idempotent); already
linked to a *different* user → `Validation` conflict (never silently ignored, unlike a plain
`INSERT OR IGNORE`).

## Shell (`link-user` / `unlink-user` / `show links`)

Operator provisioning, write-gated like the other mutations (§8). A handle is resolved to its user id
(operator-friendly, like `set-password`):

```
link-user   <handle> <item-id>     link a native user to an external cached-user item   (write)
unlink-user <handle> <item-id>     remove the link                                      (write)
show links  <handle>               list the cached-user items a user is linked to       (read)
```

## HTTP surface (reads only)

```
GET /api/users/:id/links        -> { items: [ <item envelope>, … ] }   the user's linked cached-users
GET /api/items/:id/linked-user  -> <User> | 404                        resolve a cached-user up to its native user
```

Open like all other reads (a trusted self-hosted instance; attribution is not secret). The second
endpoint is what an island rendering a `cached-message` calls to show "this external author = native
user Alice." No write endpoints — links are shell-provisioned (decision 1).

## Not in scope (additive later)

Self-service linking + per-kind proof-of-ownership (the OAuth path above); resolving a *message's* author
field to a user in one hop (the message kind knows where its author id lives — this gives it the
`item → user` primitive to compose with); listing links being access-controlled (reads are open).
