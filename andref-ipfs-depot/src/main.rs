//! andref-ipfs-depot: a Discord-gated file uploader for a pinned-only kubo (IPFS) node.
//!
//! One process runs both the serenity Discord bot (which mints upload links) and an axum HTTP
//! server (which serves the upload page and pins files to kubo), sharing an in-memory token store.

mod assets;
mod config;
mod discord;
mod ipfs;
mod state;
mod tokens;
mod web;

use std::sync::Arc;

use serenity::all::{Client, GatewayIntents};
use serenity::gateway::ShardManager;

use crate::config::Config;
use crate::discord::Handler;
use crate::state::{AppState, AppStateKey};
use crate::tokens::TokenStore;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[tokio::main]
async fn main() -> Result<(), BoxError> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::from_env().map_err(BoxError::from)?;
    let bind_addr = cfg.bind_addr.clone();

    // Slash-command interactions need no privileged (or any) gateway intents.
    let mut client = Client::builder(&cfg.discord_bot_token, GatewayIntents::empty())
        .event_handler(Handler)
        .await?;

    let state = AppState {
        cfg: Arc::new(cfg),
        kubo: reqwest::Client::new(),
        discord: client.http.clone(),
        store: Arc::new(TokenStore::new()),
    };
    client
        .data
        .write()
        .await
        .insert::<AppStateKey>(state.clone());

    let app = web::router(state);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!("listening on {bind_addr}");

    // Run the bot and the web server together; if either ends (error or shutdown) the process
    // exits and k8s restarts the pod. axum gets a graceful SIGTERM/Ctrl-C shutdown so in-flight
    // uploads finish, and the serenity shards are told to wind down on the same signal.
    let shard_manager = client.shard_manager.clone();
    let serenity_fut = async move { client.start().await.map_err(BoxError::from) };
    let web_fut = async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(shutdown_signal(shard_manager))
            .await
            .map_err(BoxError::from)
    };

    tokio::try_join!(serenity_fut, web_fut)?;
    Ok(())
}

/// Resolve on SIGTERM (k8s pod stop) or Ctrl-C, then ask serenity to wind down its shards so both
/// halves stop together.
async fn shutdown_signal(shard_manager: Arc<ShardManager>) {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.ok();
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
    tracing::info!("shutdown signal received");
    shard_manager.shutdown_all().await;
}
