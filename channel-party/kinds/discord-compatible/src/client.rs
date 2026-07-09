//! A thin wrapper over `twilight-http` for the ingestion this slice needs: fetch a channel's recent
//! messages, normalized to the few fields the envelopes carry. The base URL is configurable via
//! twilight's proxy support, so tests point it at a local mock server — never live Discord (§12). See
//! `design/discord.md`.

use twilight_http::Client;
use twilight_model::id::marker::ChannelMarker;
use twilight_model::id::Id;

/// One fetched Discord message, normalized to what ingestion stores.
pub struct FetchedMessage {
    pub id: u64,
    pub author_id: u64,
    pub author_name: String,
    pub content: String,
    pub timestamp_ms: i64,
}

/// The shared Discord REST client — one per [`crate::DiscordBridge`], shared across the slice's runtime
/// components (a single rate-limited client for all bridged guilds, §7).
pub struct DiscordClient {
    http: Client,
}

impl DiscordClient {
    /// Build the client. `proxy` (a `host:port`) routes REST calls over plain http to a local server for
    /// tests; `None` targets Discord directly. `token` is the bot authorization value.
    pub fn new(token: String, proxy: Option<String>) -> Self {
        let mut builder = Client::builder().token(token);
        if let Some(proxy) = proxy {
            builder = builder.proxy(proxy, true);
        }
        Self {
            http: builder.build(),
        }
    }

    /// Fetch up to `limit` recent messages of a channel (Discord returns newest-first).
    pub async fn channel_messages(
        &self,
        channel_id: u64,
        limit: u16,
    ) -> Result<Vec<FetchedMessage>, String> {
        let id = Id::<ChannelMarker>::new(channel_id);
        let response = self
            .http
            .channel_messages(id)
            .limit(limit)
            .await
            .map_err(|e| e.to_string())?;
        let messages = response.model().await.map_err(|e| e.to_string())?;
        Ok(messages
            .into_iter()
            .map(|m| FetchedMessage {
                id: m.id.get(),
                author_id: m.author.id.get(),
                author_name: m.author.name,
                content: m.content,
                timestamp_ms: m.timestamp.as_micros() / 1000,
            })
            .collect())
    }
}
