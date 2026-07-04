//! `discord-compatible` — one crate holding the whole namespace: guild / section / channel / forum
//! channels, message / cached-message / cached-reaction / cached-user items, and the shared Discord
//! runtime. Grouped by namespace (not leaf) because they share a great deal: one rate-limited
//! client, one search index. This mirrors the `namespace/leaf` id scheme. See DESIGN §4/§7.
//!
//! It is runtime-heavy: a single `DiscordSync` component (WriteScope::Primary) ingests all bridged
//! guilds behind one shared rate-limited client, and a `DiscordSemanticIndex` (Derived) builds
//! embeddings off the change stream. Everything here is a scaffold stub.

use async_trait::async_trait;
use cp_model::{
    Channel, ChannelKind, Interests, ItemKind, Json, Migration, Migrations, Result,
    RuntimeComponent, RuntimeCtx, StoreCtx, TypeId, WriteScope,
};

/// A channel kind in this namespace (guild / section / channel / forum). §4.
struct DiscordChannel {
    type_id: TypeId,
}

#[async_trait]
impl ChannelKind for DiscordChannel {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }

    // §4 capability table: discord-compatible validates its payloads.
    fn validate(&self, _payload: &Json) -> Result<()> {
        Ok(())
    }

    async fn contents(&self, _cx: &dyn StoreCtx, _ch: &Channel, _query: Json) -> Result<Json> {
        // DESIGN §5: descendants(id, {Channel, [channel, section]}) -> the whole subtree at once;
        // the guild island builds the tree. Recursive: opening a child mounts its own island.
        todo!("discord channel contents (DESIGN §5)")
    }
}

/// An item kind in this namespace (message / cached-message / cached-reaction / cached-user). §4.
struct DiscordItem {
    type_id: TypeId,
}

impl ItemKind for DiscordItem {
    fn type_id(&self) -> &TypeId {
        &self.type_id
    }
}

/// The channel kinds this namespace contributes. §10.
pub fn channels() -> Vec<Box<dyn ChannelKind>> {
    [
        "discord-compatible/guild",
        "discord-compatible/section",
        "discord-compatible/channel",
        "discord-compatible/forum",
    ]
    .into_iter()
    .map(|type_id| {
        Box::new(DiscordChannel {
            type_id: TypeId::new(type_id),
        }) as Box<dyn ChannelKind>
    })
    .collect()
}

/// The item kinds this namespace contributes. §10.
pub fn items() -> Vec<Box<dyn ItemKind>> {
    [
        "discord-compatible/message",
        "discord-compatible/cached-message",
        "discord-compatible/cached-reaction",
        "discord-compatible/cached-user",
    ]
    .into_iter()
    .map(|type_id| {
        Box::new(DiscordItem {
            type_id: TypeId::new(type_id),
        }) as Box<dyn ItemKind>
    })
    .collect()
}

/// Initial sync then poll: ingests messages / users / reactions behind one shared rate-limited
/// client. Writes `Primary` envelopes (the source of truth). Resets by re-fetching from Discord. §7.
struct DiscordSync;

#[async_trait]
impl RuntimeComponent for DiscordSync {
    fn name(&self) -> &str {
        "discord-sync"
    }

    fn writes(&self) -> WriteScope {
        WriteScope::Primary
    }

    fn interests(&self) -> Interests {
        Interests {
            schedule_secs: Some(60),
            types: Vec::new(),
        }
    }

    async fn run(&self, _cx: &dyn RuntimeCtx) -> Result<()> {
        todo!("discord sync: initial sync, then poll (DESIGN §7)")
    }
}

/// Initial backfill then react to change events: embeddings for semantic search. Confined to
/// `Derived` tables, so a bug can't corrupt the source of truth. Resets by replaying local data. §7.
struct DiscordSemanticIndex;

#[async_trait]
impl RuntimeComponent for DiscordSemanticIndex {
    fn name(&self) -> &str {
        "discord-semantic-index"
    }

    fn writes(&self) -> WriteScope {
        WriteScope::Derived
    }

    fn interests(&self) -> Interests {
        Interests {
            schedule_secs: None,
            types: vec![TypeId::new("discord-compatible/cached-message")],
        }
    }

    async fn run(&self, _cx: &dyn RuntimeCtx) -> Result<()> {
        todo!("discord semantic index: backfill, then react to change events (DESIGN §7)")
    }
}

/// The Primary ingestor, for the composition root. §10.
pub fn sync() -> impl RuntimeComponent {
    DiscordSync
}

/// The Derived semantic indexer, for the composition root. §10.
pub fn semantic_index() -> impl RuntimeComponent {
    DiscordSemanticIndex
}

/// Type-owned migrations (namespaced `discord_*`). Core never learns their shape. §6.
pub static MIGRATIONS: Migrations = Migrations(&[Migration {
    name: "0001_discord_init",
    sql: include_str!("../migrations/0001_discord_init.sql"),
}]);
