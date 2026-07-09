//! Live updates over Server-Sent Events, backed by the core change bus (DESIGN §7/§9). The write path
//! emits a `ChangeEvent` after every committed mutation; this forwards each to subscribed clients as an
//! SSE `change` event, optionally filtered to one channel scope. The wire shape is a frontend concern,
//! so it is built here rather than by deriving serde onto core's event type.

use std::convert::Infallible;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::Json;
use cp_core::{ChangeEvent, ChangeOp, EnvelopeRef};
use cp_model::ChannelId;
use serde::Deserialize;
use serde_json::json;
use tokio_stream::wrappers::errors::BroadcastStreamRecvError;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;

use crate::AppState;

/// `?scope=<channel id>` restricts the stream to one channel; absent = the whole firehose.
#[derive(Debug, Deserialize)]
pub struct EventsQuery {
    scope: Option<String>,
}

/// `GET /api/events[?scope=…]` -> an SSE stream of change events. §9. A `scope` keeps events whose
/// container is that channel, plus changes to the channel envelope itself (so a channel view learns
/// both "my contents changed" and "I was renamed/deleted").
pub async fn events(State(state): State<AppState>, Query(q): Query<EventsQuery>) -> Response {
    let scope = match q.scope {
        Some(s) => match s.parse::<ChannelId>() {
            Ok(id) => Some(id),
            Err(_) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "invalid scope" })),
                )
                    .into_response()
            }
        },
        None => None,
    };

    // Subscribing here (before the handler returns) means any write committed after the client has the
    // response is guaranteed to reach this receiver via the broadcast buffer.
    let rx = state.core.events().subscribe();
    let stream = BroadcastStream::new(rx).filter_map(move |result| match result {
        Ok(event) => {
            if scope.is_some_and(|s| !in_scope(&event, s)) {
                None
            } else {
                Some(Ok::<Event, Infallible>(change_event(&event)))
            }
        }
        // A client too slow for the 1024-deep buffer misses events; tell it to resync rather than drop
        // silently. It stays subscribed and resumes with live events.
        Err(BroadcastStreamRecvError::Lagged(n)) => {
            Some(Ok(Event::default().event("lagged").data(n.to_string())))
        }
    });

    Sse::new(stream)
        .keep_alive(KeepAlive::default())
        .into_response()
}

/// Whether an event is visible to a scoped subscriber: a change within the channel, or to it.
fn in_scope(event: &ChangeEvent, scope: ChannelId) -> bool {
    event.container == Some(scope)
        || matches!(event.target, EnvelopeRef::Channel(id) if id == scope)
}

/// The SSE `change` frame for one event — the wire shape islands consume.
fn change_event(event: &ChangeEvent) -> Event {
    let (super_type, id) = match event.target {
        EnvelopeRef::Channel(id) => ("channel", id.to_string()),
        EnvelopeRef::Item(id) => ("item", id.to_string()),
    };
    let op = match event.op {
        ChangeOp::Created => "created",
        ChangeOp::Updated => "updated",
        ChangeOp::Deleted => "deleted",
    };
    let data = json!({
        "op": op,
        "super_type": super_type,
        "id": id,
        "type_id": event.type_id.as_str(),
        "container": event.container.map(|c| c.to_string()),
    });
    Event::default().event("change").data(data.to_string())
}
