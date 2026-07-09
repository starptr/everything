-- channel-party core schema: three tables (two super-types) plus the fixed `users` substrate.
-- See DESIGN §3. Idempotent (CREATE ... IF NOT EXISTS): the scaffold re-runs this on every boot,
-- so there is no migration-tracking table yet.

CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,                                     -- ULID
    handle        TEXT NOT NULL UNIQUE,
    password_hash TEXT,                                                 -- argon2 PHC string; NULL = no password set (can't log in). §17
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS channels (
    id        TEXT PRIMARY KEY,                                        -- ULID (time-ordered)
    type_id   TEXT NOT NULL,
    container TEXT REFERENCES channels (id) ON DELETE CASCADE,         -- parent channel; null = root
    payload   TEXT NOT NULL                                            -- opaque JSON
);
CREATE INDEX IF NOT EXISTS channels_container ON channels (container);

CREATE TABLE IF NOT EXISTS items (
    id           TEXT PRIMARY KEY,                                     -- ULID (time-ordered)
    type_id      TEXT NOT NULL,
    container    TEXT REFERENCES channels (id) ON DELETE CASCADE,
    external_key TEXT,                                                 -- dedup/upsert handle
    payload      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS items_container ON items (container);

-- Exactly one item per external object (e.g. one cached-user per Discord user). §3.
CREATE UNIQUE INDEX IF NOT EXISTS items_external_key
ON items (external_key) WHERE external_key IS NOT NULL;

-- The `linked-users` edge, bidirectional: a native user <-> a cached-user item (§2/§19,
-- `design/linked-users.md`). Created after `items` for the FK. `item_id` is UNIQUE — one external
-- identity resolves up to at most one native user (a user still has many links, one per platform).
CREATE TABLE IF NOT EXISTS user_external_links (
    user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    item_id TEXT NOT NULL UNIQUE REFERENCES items (id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, item_id)
);

-- Generic membership substrate (§8), written by ChannelKind::membership() impls via WriteCtx.
-- Members are native principals only (§2): the user_id FK requires a real users row.
CREATE TABLE IF NOT EXISTS channel_members (
    channel_id TEXT NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    PRIMARY KEY (channel_id, user_id)
);

-- The FTS5 search substrate (DESIGN §6, `design/index-search.md`). A kind's `index(payload)` projects
-- its searchable fields here transactionally on write; `StoreCtx::search` MATCHes it then joins back to
-- channels/items. Standalone (not `content=`) because it spans both super-types. Trigram tokenizer ⇒
-- true substring ("search box") matching. UNINDEXED routing columns: `envelope_id` keys a row to its
-- envelope, `super_type` selects the join table. No FK, so cascaded deletes orphan rows — harmless, the
-- INNER JOIN in `search` drops orphans (see the design note).
CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
    name,
    text,
    envelope_id UNINDEXED,
    super_type UNINDEXED,
    tokenize = 'trigram'
);

-- Supervisor bookkeeping (DESIGN §7): the last `version()` core observed per runtime component. On
-- boot a differing version means the component should reset (rebuild its derived state).
CREATE TABLE IF NOT EXISTS runtime_component_state (
    name    TEXT PRIMARY KEY,
    version INTEGER NOT NULL
);

-- Server-side sessions (DESIGN §2, `design/auth.md`, #17). A login mints an opaque random token given
-- to the browser in an HttpOnly cookie; only its SHA-256 is stored here, so a DB leak exposes no live
-- token. Revocation = delete the row. Expiry is a plain string comparison (sqlite `datetime`).
CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,                                        -- SHA-256 hex of the cookie token
    user_id    TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions (user_id);
