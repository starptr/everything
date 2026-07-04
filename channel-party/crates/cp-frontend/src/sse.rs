//! Live updates: SSE backed by the core event bus. Islands subscribe to changes for their channel.
//! See DESIGN §9. Scaffold: the bus exists (`core.events()`); forwarding it as an SSE stream
//! (`tokio_stream::wrappers::BroadcastStream` -> `axum::response::sse`) is deferred.

use axum::extract::State;
use axum::http::StatusCode;

use crate::AppState;

/// `GET /api/events?scope=…` -> SSE change stream (generic). §9.
pub async fn events(State(_state): State<AppState>) -> StatusCode {
    StatusCode::NOT_IMPLEMENTED
}
