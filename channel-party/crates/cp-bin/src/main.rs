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

    let mut builder = Registry::builder()
        .item(cp_basic::item())
        .channel(cp_basic::channel())
        .channel(cp_space::channel())
        .channels(cp_discord::channels())
        .items(cp_discord::items())
        .channel(cp_canvas::channel())
        .item(cp_canvas::text_box())
        .runtime(cp_canvas::spatial_index()) // WriteScope::Derived
        .migrations(cp_discord::MIGRATIONS)
        .migrations(cp_canvas::MIGRATIONS);

    // The Discord bridge (#10) registers its Primary ingestor only when configured (a token is set), so
    // a tokenless dev/CI boot runs no Discord component. The Derived semantic index (§7c) is deferred.
    if let Some(config) = cp_discord::BridgeConfig::from_env() {
        builder = builder.runtime(cp_discord::bridge(config).sync());
    }
    let registry = builder.build();

    // `sqlite:channel-party.db` (created if missing) or `sqlite::memory:`; override with CP_DB.
    let db_url = std::env::var("CP_DB").unwrap_or_else(|_| "sqlite:channel-party.db".to_owned());
    let core = Core::open(&db_url, registry.clone()).await?;

    // `channel-party shell` opens the gated debug REPL against the same DB, then exits (§8). Seed or
    // inspect here. A concurrent server on the same DB sees these writes on its next read (direct-read
    // `contents` like basic/space hits sqlite), but NOT live: the event bus is per-process, so SSE and
    // derived indexes (canvas's R-tree) only reflect writes from the server's own process — or, for a
    // shell-seeded DB, at the server's next boot via each component's backfill.
    if std::env::args().nth(1).as_deref() == Some("shell") {
        return cp_core::debug::run(&core).await;
    }

    // Hold the handle for the process lifetime: dropping it aborts the supervised components.
    let _runtime = core.spawn_runtime();

    let addr: SocketAddr = std::env::var("CP_BIND")
        .unwrap_or_else(|_| "127.0.0.1:8080".to_owned())
        .parse()?;
    cp_frontend::serve(core, registry, addr).await
}
