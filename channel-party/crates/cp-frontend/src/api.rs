//! The generic HTTP API (DESIGN §9). These endpoints are type-agnostic: `contents` dispatches to
//! the channel's kind, and the envelope reads return the universal fields. Scaffold: all return
//! `501` so the server boots without a store implementation; the wiring points are marked below.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use crate::AppState;

fn not_implemented(endpoint: &str) -> (StatusCode, Json<serde_json::Value>) {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(serde_json::json!({ "error": "not implemented", "endpoint": endpoint })),
    )
}

/// `GET /api/channels/:id` -> `{ id, type_id, container }` (generic). §9.
pub async fn get_channel(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> (StatusCode, Json<serde_json::Value>) {
    // TODO(§9): read the channel envelope from the store; return { id, type_id, container }.
    not_implemented("GET /api/channels/{id}")
}

/// `POST /api/channels/:id/contents { query }` -> type-defined contents (dispatch). §5/§9.
pub async fn channel_contents(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> (StatusCode, Json<serde_json::Value>) {
    // TODO(§5): load the channel, then `cp_core::contents::dispatch(registry, store, &ch, query)`.
    not_implemented("POST /api/channels/{id}/contents")
}

/// `GET /api/items/:id` -> envelope (generic). §9.
pub async fn get_item(
    State(_state): State<AppState>,
    Path(_id): Path<String>,
) -> (StatusCode, Json<serde_json::Value>) {
    // TODO(§9): read the item envelope from the store.
    not_implemented("GET /api/items/{id}")
}
