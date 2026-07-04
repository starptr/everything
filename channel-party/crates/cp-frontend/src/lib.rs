//! `cp-frontend` — the axum server. It serves the generic HTTP API, mounts each channel kind's
//! `/ext/<type>` routes, exposes the SSE change stream, and serves the static Astro build. The
//! frontend shell is type-agnostic; type-specific rendering happens in client-side islands. See
//! DESIGN §9.
//!
//! Scaffold: the generic API handlers return `501 Not Implemented` (the server boots and serves
//! the static site); wiring them to the store/dispatch is §5/§9 slice work.

pub mod api;
pub mod sse;
pub mod static_files;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::routing::{get, post};
use axum::Router;
use cp_core::{Core, Registry};

/// Shared handler state. `Clone` is required by axum's `with_state`. §9.
#[derive(Clone)]
pub struct AppState {
    pub core: Arc<Core>,
    pub registry: Registry,
    pub web_dir: PathBuf,
}

/// Boot the server. The static Astro build is resolved from `CP_WEB_DIR` (the Nix package wraps the
/// binary to point at the bundled static output; defaults to `web/dist` for local dev). §9/§11.
pub async fn serve(core: Core, registry: Registry, addr: SocketAddr) -> anyhow::Result<()> {
    let web_dir = std::env::var("CP_WEB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("web/dist"));

    let state = AppState {
        core: Arc::new(core),
        registry,
        web_dir: web_dir.clone(),
    };

    let app = Router::new()
        .route("/api/channels/{id}", get(api::get_channel))
        .route("/api/channels/{id}/contents", post(api::channel_contents))
        .route("/api/items/{id}", get(api::get_item))
        .route("/api/events", get(sse::events))
        // Channel kinds may contribute extra routes (webhooks, etc.) under /ext/<type>. None do in
        // the scaffold; the mount point exists so the surface is stable. §4/§9.
        .nest("/ext", Router::<AppState>::new())
        .fallback_service(static_files::service(&web_dir))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, web_dir = %web_dir.display(), "channel-party frontend listening");
    axum::serve(listener, app).await?;
    Ok(())
}
