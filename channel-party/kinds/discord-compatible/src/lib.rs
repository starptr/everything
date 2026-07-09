//! `discord-compatible` — one crate holding the whole namespace: guild / section / channel / forum
//! channels, message / cached-message / cached-reaction / cached-user items, and the shared Discord
//! runtime. Grouped by namespace (not leaf) because they share a great deal: one rate-limited
//! client, one search index. This mirrors the `namespace/leaf` id scheme. See DESIGN §4/§7.
//!
//! It is runtime-heavy: a single `DiscordSync` component (`WriteScope::Primary`) ingests all bridged
//! guilds behind one shared rate-limited client (the [`DiscordBridge`]). Implemented so far (#10
//! (a)+(b)+(d), `design/discord.md`): the shared client, message/user ingestion, guild/channel envelope
//! creation + dedup, and channel `contents`. Deferred: the `Derived` semantic index (c), webhook
//! `routes` (e), outbound (f), membership (g), reactions, and full section/forum structure.

mod client;

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use cp_model::{
    Channel, ChannelId, ChannelKind, Cursor, Error, Filter, Interests, ItemKind, Json, Migration,
    Migrations, NewChannel, NewItem, Node, NodePage, Order, Page, Result, RuntimeComponent,
    RuntimeCtx, RuntimeEvent, StoreCtx, SuperType, TypeId, WriteCtx, WriteScope,
};
use serde::Deserialize;

use crate::client::{DiscordClient, FetchedMessage};

const GUILD: &str = "discord-compatible/guild";
const CHANNEL: &str = "discord-compatible/channel";
const FORUM: &str = "discord-compatible/forum";
const CACHED_USER: &str = "discord-compatible/cached-user";
const CACHED_MESSAGE: &str = "discord-compatible/cached-message";

/// Page size when a `contents` query omits `limit`.
const DEFAULT_LIMIT: u32 = 50;

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

    async fn contents(&self, cx: &dyn StoreCtx, ch: &Channel, query: Json) -> Result<Json> {
        // Two strategies by kind (§5). This is the slice matching on *its own* types — never core.
        let page = match self.type_id.as_str() {
            // Leaf channels hold messages: a newest-first feed of cached-messages (like `basic`).
            CHANNEL | FORUM => {
                let q = DiscordQuery::parse(query)?;
                cx.children(
                    ch.id,
                    Filter {
                        super_type: Some(SuperType::Item),
                        type_ids: Some(vec![TypeId::new(CACHED_MESSAGE)]),
                    },
                    Page {
                        cursor: Cursor(q.cursor),
                        limit: q.limit.unwrap_or(DEFAULT_LIMIT),
                    },
                    Order::TimeDesc,
                )
                .await?
            }
            // Structural channels (guild / section) return their whole channel subtree in one call, so
            // the island builds the tree from each node's `container`.
            _ => {
                let nodes = cx
                    .descendants(
                        ch.id,
                        Filter {
                            super_type: Some(SuperType::Channel),
                            type_ids: None,
                        },
                        None,
                    )
                    .await?;
                NodePage {
                    nodes,
                    next: Cursor(None),
                }
            }
        };
        serde_json::to_value(page).map_err(|e| Error::Other(e.to_string()))
    }
}

/// The `contents` query shared by discord channel kinds — all optional. Leaf channels page their
/// message feed with `cursor`/`limit`; structural channels ignore it (they return the whole subtree).
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct DiscordQuery {
    cursor: Option<String>,
    limit: Option<u32>,
}

impl DiscordQuery {
    fn parse(query: Json) -> Result<Self> {
        if query.is_null() {
            Ok(Self::default())
        } else {
            serde_json::from_value(query).map_err(|e| Error::Validation(e.to_string()))
        }
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

/// How the composition root configures the bridge. The bridge creates the channel-party `guild` +
/// `channel` envelopes itself (deduped), so the operator supplies only Discord ids: `guild` and the
/// `channels` under it to ingest. `proxy` (a `host:port`) routes the client at a test mock; `None`
/// targets Discord. §10.
pub struct BridgeConfig {
    pub token: String,
    pub proxy: Option<String>,
    pub poll_secs: u64,
    pub guild: u64,
    pub channels: Vec<u64>,
}

impl BridgeConfig {
    /// Read the bridge config from the environment, or `None` when unconfigured (no `CP_DISCORD_TOKEN`
    /// or `CP_DISCORD_GUILD`) — in which case the composition root registers no Discord component.
    /// `CP_DISCORD_CHANNELS` is comma-separated Discord channel ids; `CP_DISCORD_BASE_URL` is the test
    /// proxy; `CP_DISCORD_POLL_SECS` defaults to 60.
    pub fn from_env() -> Option<Self> {
        let token = std::env::var("CP_DISCORD_TOKEN").ok()?;
        let guild = std::env::var("CP_DISCORD_GUILD")
            .ok()?
            .trim()
            .parse()
            .ok()?;
        let channels = std::env::var("CP_DISCORD_CHANNELS")
            .ok()
            .map(|s| parse_ids(&s))
            .unwrap_or_default();
        Some(Self {
            token,
            proxy: std::env::var("CP_DISCORD_BASE_URL").ok(),
            poll_secs: std::env::var("CP_DISCORD_POLL_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(60),
            guild,
            channels,
        })
    }
}

fn parse_ids(spec: &str) -> Vec<u64> {
    spec.split(',')
        .filter_map(|s| s.trim().parse().ok())
        .collect()
}

/// The shared Discord bridge (sub-part (a), `design/discord.md`): one rate-limited client, from which
/// every runtime component in this slice is spun so they share it. Build it once at the composition root.
pub struct DiscordBridge {
    client: Arc<DiscordClient>,
    guild: u64,
    channels: Arc<Vec<u64>>,
    poll_secs: u64,
}

impl DiscordBridge {
    /// The Primary ingestor, sharing this bridge's client. (A future `semantic_index()` would share it
    /// too — the point of a bridge.) §7/§10.
    pub fn sync(&self) -> DiscordSync {
        DiscordSync {
            client: self.client.clone(),
            guild: self.guild,
            channels: self.channels.clone(),
            poll_secs: self.poll_secs,
        }
    }
}

/// Build the shared bridge from config. §10.
pub fn bridge(config: BridgeConfig) -> DiscordBridge {
    DiscordBridge {
        client: Arc::new(DiscordClient::new(config.token, config.proxy)),
        guild: config.guild,
        channels: Arc::new(config.channels),
        poll_secs: config.poll_secs,
    }
}

/// Initial sync then poll: ensures the guild/channel envelope structure, then ingests each channel's
/// messages + authors behind the shared rate-limited client. Writes `Primary` envelopes (the source of
/// truth), deduped by `external_key` (items) / carried Discord id (channels). Resets by re-fetching from
/// Discord (idempotent upserts converge). §7. (Reactions are a later pass.)
pub struct DiscordSync {
    client: Arc<DiscordClient>,
    guild: u64,
    channels: Arc<Vec<u64>>,
    poll_secs: u64,
}

#[async_trait]
impl RuntimeComponent for DiscordSync {
    fn name(&self) -> &str {
        "discord-sync"
    }

    fn writes(&self) -> WriteScope {
        WriteScope::Primary
    }

    fn interests(&self) -> Interests {
        // A schedule (re-poll); no change-stream interest — this component is a source, not a projector.
        Interests {
            schedule_secs: Some(self.poll_secs),
            types: Vec::new(),
        }
    }

    async fn run(&self, cx: &dyn RuntimeCtx) -> Result<()> {
        let writer = cx
            .writer()
            .ok_or_else(|| Error::Other("discord-sync is Primary but got no writer".to_owned()))?;
        // Initial sync == reset: both re-fetch from Discord (§7). Idempotent, so it converges.
        self.sync_all(cx, writer).await?;
        while let Some(event) = cx.next_event().await {
            if let RuntimeEvent::Tick = event {
                self.sync_all(cx, writer).await?;
            }
        }
        Ok(())
    }
}

impl DiscordSync {
    async fn sync_all(&self, cx: &dyn RuntimeCtx, writer: &dyn WriteCtx) -> Result<()> {
        let containers = self.ensure_structure(cx, writer).await?;
        for discord_channel in self.channels.iter() {
            let Some(&container) = containers.get(discord_channel) else {
                continue;
            };
            let messages = self
                .client
                .channel_messages(*discord_channel, 100)
                .await
                .map_err(Error::Other)?;
            for message in messages {
                self.ingest(writer, container, &message).await?;
            }
        }
        Ok(())
    }

    /// Ensure the `guild` envelope and a `channel` envelope per configured Discord channel exist,
    /// deduped by the Discord id each envelope carries in its payload. Channels have no `external_key`,
    /// so dedup is *derived from the source of truth* — `scan` the existing envelopes and create only the
    /// missing ones. Idempotent across re-syncs with no separate mapping table (and no crash window a
    /// mapping table would introduce). Returns Discord channel id -> its channel-party container id.
    async fn ensure_structure(
        &self,
        cx: &dyn RuntimeCtx,
        writer: &dyn WriteCtx,
    ) -> Result<HashMap<u64, ChannelId>> {
        let existing = cx.scan(&[TypeId::new(GUILD), TypeId::new(CHANNEL)]).await?;
        let mut by_discord: HashMap<u64, ChannelId> = existing
            .iter()
            .filter_map(|node| {
                let Node::Channel(ch) = node else {
                    return None;
                };
                let discord_id = ch
                    .payload
                    .get("discord_id")?
                    .as_str()?
                    .parse::<u64>()
                    .ok()?;
                Some((discord_id, ch.id))
            })
            .collect();

        let guild = match by_discord.get(&self.guild).copied() {
            Some(id) => id,
            None => {
                let id = writer
                    .create_channel(NewChannel {
                        type_id: TypeId::new(GUILD),
                        container: None,
                        payload: serde_json::json!({ "discord_id": self.guild.to_string() }),
                    })
                    .await?;
                by_discord.insert(self.guild, id);
                id
            }
        };

        for discord_channel in self.channels.iter() {
            if !by_discord.contains_key(discord_channel) {
                let id = writer
                    .create_channel(NewChannel {
                        type_id: TypeId::new(CHANNEL),
                        container: Some(guild),
                        payload: serde_json::json!({ "discord_id": discord_channel.to_string() }),
                    })
                    .await?;
                by_discord.insert(*discord_channel, id);
            }
        }
        Ok(by_discord)
    }

    /// Upsert one message and its author: a `cached-user` (one per Discord user, `external_key` dedup,
    /// §3) then a `cached-message` under the mapped channel. Its author is a reference to the cached-user
    /// by Discord id (resolvable to a native user via a `linked-users` link, §2/#19).
    async fn ingest(
        &self,
        writer: &dyn WriteCtx,
        container: ChannelId,
        m: &FetchedMessage,
    ) -> Result<()> {
        writer
            .upsert_item(NewItem {
                type_id: TypeId::new(CACHED_USER),
                container: None,
                external_key: Some(format!("discord:user:{}", m.author_id)),
                payload: serde_json::json!({
                    "discord_id": m.author_id.to_string(),
                    "name": m.author_name,
                }),
            })
            .await?;
        writer
            .upsert_item(NewItem {
                type_id: TypeId::new(CACHED_MESSAGE),
                container: Some(container),
                external_key: Some(format!("discord:message:{}", m.id)),
                payload: serde_json::json!({
                    "discord_id": m.id.to_string(),
                    "author_discord_id": m.author_id.to_string(),
                    "author_name": m.author_name,
                    "content": m.content,
                    "timestamp_ms": m.timestamp_ms,
                }),
            })
            .await?;
        Ok(())
    }
}

/// Type-owned migrations (namespaced `discord_*`). Core never learns their shape. §6.
pub static MIGRATIONS: Migrations = Migrations(&[Migration {
    name: "0001_discord_init",
    sql: include_str!("../migrations/0001_discord_init.sql"),
}]);
