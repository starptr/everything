-- channel-party core schema: three tables (two super-types) plus the fixed `users` substrate.
-- See DESIGN §3. Idempotent (CREATE ... IF NOT EXISTS): the scaffold re-runs this on every boot,
-- so there is no migration-tracking table yet.

CREATE TABLE IF NOT EXISTS users (
    id         TEXT PRIMARY KEY,                                        -- ULID
    handle     TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- The `linked-users` edge, bidirectional: a native user <-> a cached-user item.
CREATE TABLE IF NOT EXISTS user_external_links (
    user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,                                             -- references items(id)
    PRIMARY KEY (user_id, item_id)
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
