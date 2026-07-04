//! Composition root: register kinds + runtime components, then boot core + frontend. This is the
//! one place concrete kinds are named — `cp-core` never depends on a kind crate. Explicit
//! registration (over `inventory`-style auto-registration) is chosen for clarity, testability, and
//! control over ordering. See DESIGN §10.

use std::net::SocketAddr;

use cp_core::{Core, Registry};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let registry = Registry::builder()
        .item(cp_basic::item())
        .channel(cp_basic::channel())
        .channel(cp_space::channel())
        .channels(cp_discord::channels())
        .items(cp_discord::items())
        .runtime(cp_discord::sync()) // WriteScope::Primary  — ingests messages/users/reactions
        .runtime(cp_discord::semantic_index()) // WriteScope::Derived — embeddings, off the stream
        .channel(cp_canvas::channel())
        .item(cp_canvas::text_box())
        .runtime(cp_canvas::spatial_index()) // WriteScope::Derived
        .migrations(cp_discord::MIGRATIONS)
        .migrations(cp_canvas::MIGRATIONS)
        .build();

    // `sqlite:channel-party.db` (created if missing) or `sqlite::memory:`; override with CP_DB.
    let db_url = std::env::var("CP_DB").unwrap_or_else(|_| "sqlite:channel-party.db".to_owned());
    let core = Core::open(&db_url, registry.clone()).await?;
    core.spawn_runtime();

    let addr: SocketAddr = std::env::var("CP_BIND")
        .unwrap_or_else(|_| "127.0.0.1:8080".to_owned())
        .parse()?;
    cp_frontend::serve(core, registry, addr).await
}
