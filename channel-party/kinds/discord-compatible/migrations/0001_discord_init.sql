-- Type-owned tables for the discord-compatible slice (namespaced `discord_*`). Core never learns
-- their shape: the slice's RuntimeComponent writes them and its `contents` reads them. See DESIGN §6.
--
-- Placeholder: a semantic-search table the DiscordSemanticIndex component (§7) will populate with
-- embeddings for cached-message items. A real deployment would use a vector-index extension.
CREATE TABLE IF NOT EXISTS discord_message_embeddings (
    item_id   TEXT PRIMARY KEY,   -- references items(id) (a discord-compatible/cached-message)
    embedding BLOB NOT NULL
);
