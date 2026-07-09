# `discord-compatible` slice (`TODO.md` #10, DESIGN §4/§5/§7)

Status: in progress — **(a)+(b)** ratified 2026-07-11; **(d)** landed same day (structure + contents).
The rest stays stubbed/deferred.

**(d) as built** (a refinement of the plan below): the sync creates the `guild` + `channel` envelopes
itself, **deduped without a mapping table** — it `scan`s existing envelopes and matches the Discord id in
their payload, creating only the missing ones (idempotent; no crash window a separate map would add; no
escape-hatch table needed). Config became `guild` + channel ids (not the operator-provided container of
(b)). `contents` branches on the slice's own type: leaf `channel`/`forum` → `children` feed; structural
`guild`/`section` → `descendants` subtree (first real use of that primitive). Full section/forum
structure (the `GET /guilds/:id/channels` fetch, categories via `parent_id`, threads) is still deferred —
today's tree is guild → channels (flat).

The heaviest slice, split into sub-parts so each lands independently. This note plans the whole and
pins the decisions for the first chunk. **Client library: `twilight-http`** (chosen); tests mock Discord
via twilight's **proxy** support (`Client::builder().proxy(host, true)` → a local `wiremock` server) —
never the live API (§12).

## Sub-parts

- **(a) Shared client / bridge.** One `twilight-http` client, rate-limited, shared across the slice's
  runtime components. Exposed as a `DiscordBridge` the composition root builds once; `bridge.sync()`
  (and later `bridge.semantic_index()`) produce components holding the same `Arc<client>`. *This is the
  architecture point of (a): a namespace crate holds shared state across its runtime components.*
- **(b) Sync ingestion (`Primary`).** `DiscordSync` (`WriteScope::Primary`) backfills, then re-polls on a
  schedule: fetch a bridged channel's messages → **upsert** `cached-user` (`external_key =
  "discord:user:<id>"` — one per Discord user, §3) and `cached-message` (`external_key =
  "discord:message:<id>"`) envelopes through `writer()`. Reset = re-fetch. *The architecture point of
  (b): the `Primary` write path — `writer() → Some` and a component actually writing envelopes with
  `external_key` dedup — the last unproven §7 path (canvas only exercised `Derived`).*
- **(c) Semantic index (`Derived`).** `DiscordSemanticIndex` off the change stream into the type-owned
  `discord_message_embeddings` table. **Blocked on choosing an embedding provider/model + vector store**
  — deferred; the component stays a stub and is *not registered* (so it can't crashloop).
- **(d) Contents.** `channel`/`forum` list their cached-messages (`children`); `guild`/`section` fetch
  the subtree (`descendants`); the island builds the tree. Deferred.
- **(e) Webhook receiver.** `routes()` → `/ext/discord-compatible/…` (§4/§9) — the first real `/ext`
  mount. Deferred.
- **(f) Outbound.** `item-type:discord-compatible/message` originating here, pushed to Discord via
  webhook. Deferred.
- **(g) Membership.** `channel` rejects (membership is Discord's) vs proxies an outbound invite.
  Deferred.

## First chunk: (a) + (b)

**Decisions**

- **Config is passed from the composition root** (`BridgeConfig { token, proxy, poll_secs, channels }`),
  env-populated in `main.rs`. `channels` maps a Discord channel id → the channel-party `ChannelId`
  container that holds its messages. For this chunk the container is **operator-provided** (a
  `discord-compatible/channel` created via the shell) — creating/deduping the channel *envelope* is
  structural work that belongs to (d), and channels have no `external_key` to upsert on. Keeping it out
  focuses the proof on message/user ingestion.
- **Components register only when configured.** `main.rs` adds `bridge.sync()` only if a token is set;
  an unconfigured instance contributes no component. This also removes the `todo!()` crashloop the
  semantic-index stub caused (it is no longer registered until (c)).
- **Ingestion shape.** Per fetched message: upsert the author as `cached-user` (`container = None` — a
  guild-scoped cached-user may have none, §3) then the message as `cached-message` (`container =` the
  mapped channel). `cached-message` payload carries `{ discord_id, author_discord_id, author_name,
  content, timestamp }`; its author is the *reference* to the cached-user (by Discord id — the slice's
  convention, resolvable to a native user via #19's `linked-users` when a link exists). No reactions yet
  (defer to a later pass).
- **Reset = re-fetch** (an ingesting component's reset re-pulls from Discord, per §7). A `version()` bump
  requests it; because ingestion is idempotent upserts, a re-fetch converges without duplication.
- **Rate limiting** rides twilight's built-in limiter; a bespoke cross-guild token bucket is deferred.

**Test (`wiremock`, never live).** A mock Discord serves `GET /api/v10/channels/<id>/messages` with two
messages from one author + one from another. Build a `Core` with the discord kinds + `bridge.sync()`
pointed at the mock (proxy), create the container channel, `spawn_runtime`, and poll the store until the
cached-messages land: assert **3 cached-messages, 2 cached-users** (author dedup within a sync), and that
a second poll tick leaves the counts unchanged (upsert idempotency, via a short test `poll_secs`).

## Not in scope (this chunk)

Reactions; contents (d); the semantic index (c); webhook routes (e); outbound (f); membership (g);
channel-envelope creation/dedup; a bespoke rate limiter; live-gateway streaming (we poll, per §7).
