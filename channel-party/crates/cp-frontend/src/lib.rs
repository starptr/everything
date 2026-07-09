//! `cp-frontend` — the axum server. It serves the generic HTTP API, mounts each channel kind's
//! `/ext/<type>` routes, exposes the SSE change stream, and serves the static Astro build. The
//! frontend shell is type-agnostic; type-specific rendering happens in client-side islands. See
//! DESIGN §9.
//!
//! The generic API handlers read envelopes and dispatch `contents` to the channel's kind, and
//! `/api/events` streams the change bus over SSE (§5/§9). The only remaining `501`-free-but-empty
//! surface is the `/ext` per-kind mount (no kind contributes routes yet).

pub mod api;
pub mod auth;
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

/// Build the router for a given state. Split out from [`serve`] so integration tests can drive the
/// real routes via `tower::ServiceExt::oneshot` without binding a socket. §9.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/api/channels/{id}", get(api::get_channel))
        .route("/api/channels/{id}/contents", post(api::channel_contents))
        // Authenticated write: post an item into a channel, gated by the kind's Permission. §18.
        .route("/api/channels/{id}/items", post(api::post_item))
        .route("/api/items/{id}", get(api::get_item))
        // linked-users reads: a user's external links, and an item's authorship resolution. §2/§19.
        .route("/api/users/{id}/links", get(api::get_user_links))
        .route(
            "/api/items/{id}/linked-user",
            get(api::get_item_linked_user),
        )
        .route("/api/events", get(sse::events))
        // Native-user auth (provisioned accounts; §2/§17). No registration route.
        .route("/api/auth/login", post(auth::login))
        .route("/api/auth/logout", post(auth::logout))
        .route("/api/auth/me", get(auth::me))
        // Channel kinds may contribute extra routes (webhooks, etc.) under /ext/<type>. None do yet;
        // the mount point exists so the surface is stable. §4/§9.
        .nest("/ext", Router::<AppState>::new())
        .fallback_service(static_files::service(&state.web_dir))
        .with_state(state)
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
    let app = router(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, web_dir = %web_dir.display(), "channel-party frontend listening");
    axum::serve(listener, app).await?;
    Ok(())
}
