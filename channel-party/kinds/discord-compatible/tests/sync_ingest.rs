//! `DiscordSync` ingestion + structure + contents (`TODO.md` #10 (a)+(b)+(d), `design/discord.md`)
//! against a **mock** Discord (wiremock via twilight's proxy — never the live API, §12). Proves the
//! `Primary` write path end to end: the component builds the guild/channel envelope tree (deduped),
//! upserts `cached-message` + `cached-user` envelopes through `writer()`, and the channel kinds' own
//! `contents` reads them back (guild → subtree via `descendants`, channel → message feed via `children`).

use std::sync::Arc;
use std::time::Duration;

use cp_core::{Core, Registry, Store};
use cp_model::{Channel, Node, TypeId};
use wiremock::matchers::{method, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

const GUILD: &str = "discord-compatible/guild";
const CHANNEL: &str = "discord-compatible/channel";
const CACHED_MESSAGE: &str = "discord-compatible/cached-message";
const CACHED_USER: &str = "discord-compatible/cached-user";

/// A minimal-but-valid Discord message object (only the fields twilight requires present).
fn message(id: u64, author_id: u64, author: &str, content: &str) -> serde_json::Value {
    serde_json::json!({
        "id": id.to_string(),
        "channel_id": "1",
        "author": { "id": author_id.to_string(), "username": author, "discriminator": "0001" },
        "content": content,
        "timestamp": "2024-01-01T00:00:00.000000+00:00",
        "type": 0,
        "attachments": [],
        "embeds": [],
        "mention_everyone": false,
        "mention_roles": [],
        "mentions": [],
        "pinned": false,
        "tts": false
    })
}

async fn mock_channel(server: &MockServer, discord_channel: u64, messages: serde_json::Value) {
    Mock::given(method("GET"))
        .and(path_regex(format!(
            r"/channels/{discord_channel}/messages$"
        )))
        .respond_with(ResponseTemplate::new(200).set_body_json(messages))
        .mount(server)
        .await;
}

async fn channels_of_type(store: &Arc<Store>, ty: &str) -> Vec<Channel> {
    store
        .scan_by_types(&[TypeId::new(ty)])
        .await
        .unwrap()
        .into_iter()
        .filter_map(|n| match n {
            Node::Channel(c) => Some(c),
            Node::Item(_) => None,
        })
        .collect()
}

async fn count(store: &Arc<Store>, ty: &str) -> usize {
    store.scan_by_types(&[TypeId::new(ty)]).await.unwrap().len()
}

#[tokio::test]
async fn ingests_structure_messages_and_serves_contents() {
    // Mock Discord: guild 10 has two channels — 100 (two messages from alice) and 200 (one from bob).
    let server = MockServer::start().await;
    mock_channel(
        &server,
        100,
        serde_json::json!([
            message(1001, 555, "alice", "hello"),
            message(1002, 555, "alice", "again"),
        ]),
    )
    .await;
    mock_channel(
        &server,
        200,
        serde_json::json!([message(1003, 777, "bob", "hi")]),
    )
    .await;

    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let config = cp_discord::BridgeConfig {
        token: "Bot test.token".to_owned(),
        proxy: Some(server.address().to_string()),
        poll_secs: 1,
        guild: 10,
        channels: vec![100, 200],
    };
    let registry = Registry::builder()
        .channels(cp_discord::channels())
        .items(cp_discord::items())
        .migrations(cp_discord::MIGRATIONS)
        .runtime(cp_discord::bridge(config).sync())
        .build();
    let core = Core::open(&url, registry.clone()).await.unwrap();
    let store = core.store();
    let handle = core.spawn_runtime();

    // The initial sync builds the structure then ingests: wait until both channels + all 3 messages land.
    for _ in 0..200 {
        if channels_of_type(&store, CHANNEL).await.len() == 2
            && count(&store, CACHED_MESSAGE).await == 3
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(count(&store, GUILD).await, 1, "one guild envelope created");
    assert_eq!(
        count(&store, CHANNEL).await,
        2,
        "two channel envelopes created under it"
    );
    assert_eq!(
        count(&store, CACHED_MESSAGE).await,
        3,
        "all three messages ingested"
    );
    assert_eq!(
        count(&store, CACHED_USER).await,
        2,
        "two distinct authors deduped by external_key"
    );

    // Guild `contents` returns its channel subtree (descendants).
    let guild = channels_of_type(&store, GUILD).await.pop().unwrap();
    let out = cp_core::contents::dispatch(&registry, &*store, &guild, serde_json::json!({}))
        .await
        .unwrap();
    assert_eq!(
        out["nodes"].as_array().unwrap().len(),
        2,
        "guild contents = its two channels (descendants)"
    );

    // A channel's `contents` returns its message feed (children).
    let channels = channels_of_type(&store, CHANNEL).await;
    let ch100 = channels
        .iter()
        .find(|c| c.payload["discord_id"] == "100")
        .expect("channel 100 envelope");
    let out = cp_core::contents::dispatch(&registry, &*store, ch100, serde_json::json!({}))
        .await
        .unwrap();
    assert_eq!(
        out["nodes"].as_array().unwrap().len(),
        2,
        "channel 100 contents = its two messages (children)"
    );

    // A scheduled re-poll (poll_secs = 1) rebuilds structure + re-fetches: nothing duplicates.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(
        count(&store, GUILD).await,
        1,
        "re-poll does not duplicate the guild"
    );
    assert_eq!(
        count(&store, CHANNEL).await,
        2,
        "re-poll does not duplicate channels"
    );
    assert_eq!(
        count(&store, CACHED_MESSAGE).await,
        3,
        "re-poll upserts messages, no duplicates"
    );

    handle.shutdown().await;
}
