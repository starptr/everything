//! The HTTP surface: serves the upload page + assets, accepts the upload, and on success posts
//! the resulting link back to the originating Discord channel.

use axum::extract::{DefaultBodyLimit, Multipart, Path, State};
use axum::http::{header, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Serialize;
use serenity::all::ChannelId;

use crate::assets;
use crate::ipfs;
use crate::state::AppState;

/// Cap on a single upload. The endpoint is public (token-gated only) and the body is buffered in
/// memory, so this bound is what stops it being a memory-exhaustion DoS.
const MAX_UPLOAD_BYTES: usize = 100 * 1024 * 1024;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/u/{token}", get(serve_page))
        .route("/api/upload/{token}", post(upload))
        .route("/assets/app.css", get(serve_css))
        .route("/assets/app.js", get(serve_js))
        .layer(DefaultBodyLimit::max(MAX_UPLOAD_BYTES))
        .with_state(state)
}

async fn healthz() -> &'static str {
    "ok"
}

/// The upload page. The token is validated (but NOT consumed -- a GET must not burn it) so a
/// guessed, expired, or already-used link shows an error page instead of the form. The token is
/// only spent when the upload POSTs. JS reads the token back from the URL.
async fn serve_page(State(state): State<AppState>, Path(token): Path<String>) -> Response {
    if state.store.is_valid(&token) {
        Html(assets::INDEX_HTML).into_response()
    } else {
        (StatusCode::NOT_FOUND, Html(assets::INVALID_HTML)).into_response()
    }
}

async fn serve_css() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        assets::APP_CSS,
    )
}

async fn serve_js() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        assets::APP_JS,
    )
}

#[derive(Serialize)]
struct UploadResult {
    cid: String,
    url: String,
}

async fn upload(
    State(state): State<AppState>,
    Path(token): Path<String>,
    mut multipart: Multipart,
) -> Result<Json<UploadResult>, (StatusCode, String)> {
    // Consume the token BEFORE reading the body, so a replayed/expired link is rejected without
    // streaming the file. This burns the token even on a later failure -- fine, the member just
    // re-runs `/upload`.
    let pending = state
        .store
        .consume(&token)
        .ok_or((StatusCode::FORBIDDEN, "invalid or expired link".to_string()))?;

    let field = multipart
        .next_field()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?
        .ok_or((StatusCode::BAD_REQUEST, "no file field".to_string()))?;
    let filename = field.file_name().unwrap_or("upload").to_string();
    let bytes = field
        .bytes()
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;

    let cid = ipfs::add(&state, filename, bytes.to_vec())
        .await
        .map_err(|e| {
            tracing::error!("kubo add failed: {e}");
            (StatusCode::BAD_GATEWAY, "upload to IPFS failed".to_string())
        })?;
    let url = ipfs::gateway_url(&state, &cid);

    // Announce the result in the channel the command was run in. A bare URL lets Discord unfurl /
    // embed images, video, audio, etc. A failed post is logged but does not fail the upload -- the
    // member already has the link in the page.
    let content = format!("<@{}> uploaded: {url}", pending.user_id);
    if let Err(e) = ChannelId::new(pending.channel_id)
        .say(&state.discord, content)
        .await
    {
        tracing::warn!(
            "failed to post upload to channel {}: {e}",
            pending.channel_id
        );
    }

    Ok(Json(UploadResult { cid, url }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::tokens::TokenStore;
    use std::sync::Arc;

    fn test_state() -> AppState {
        AppState {
            cfg: Arc::new(Config {
                discord_bot_token: "x".into(),
                discord_guild_id: 0,
                kubo_rpc_base: "http://localhost:5001".into(),
                kubo_rpc_token: "x".into(),
                gateway_base_domain: "ipfs.example".into(),
                app_base_url: "https://example".into(),
                bind_addr: "0.0.0.0:8080".into(),
            }),
            kubo: reqwest::Client::new(),
            // Http::new does no I/O; it just holds the token for later requests.
            discord: Arc::new(serenity::http::Http::new("test-token")),
            store: Arc::new(TokenStore::new()),
        }
    }

    // A guessed link (token never issued) must not serve the upload form.
    #[tokio::test]
    async fn page_is_404_for_guessed_token() {
        let state = test_state();
        let resp = serve_page(State(state), Path("hello".to_string())).await;
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    // A live link serves the form once; after the upload spends it, the same link is rejected
    // (no reuse on refresh).
    #[tokio::test]
    async fn page_serves_live_token_then_404s_after_use() {
        let state = test_state();
        let token = state.store.issue(1, 2);

        let resp = serve_page(State(state.clone()), Path(token.clone())).await;
        assert_eq!(resp.status(), StatusCode::OK);

        // Simulate the upload consuming the token.
        assert!(state.store.consume(&token).is_some());

        let resp = serve_page(State(state), Path(token)).await;
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }
}
