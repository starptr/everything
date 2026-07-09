//! The generic HTTP API (DESIGN §9). These endpoints are type-agnostic: the envelope reads return the
//! universal fields, and `contents` resolves the channel's kind and dispatches to it — core never
//! `match`es on a concrete type. `query` and the contents response are opaque to core (§5).

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use cp_model::{Action, ChannelId, Error, ItemId, NewItem, TypeId, UserId, WriteCtx};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::CurrentUser;
use crate::AppState;

/// Map a core `Error` to an HTTP status: missing → 404, bad payload → 400, else 500.
fn error_response(e: Error) -> (StatusCode, Json<Value>) {
    let status = match e {
        Error::NotFound => StatusCode::NOT_FOUND,
        Error::Validation(_) => StatusCode::BAD_REQUEST,
        Error::Other(_) => StatusCode::INTERNAL_SERVER_ERROR,
    };
    (status, Json(json!({ "error": e.to_string() })))
}

fn bad_request(msg: &str) -> (StatusCode, Json<Value>) {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": msg })))
}

fn not_found(resource: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::NOT_FOUND,
        Json(json!({ "error": "not found", "resource": resource })),
    )
}

fn forbidden() -> (StatusCode, Json<Value>) {
    (StatusCode::FORBIDDEN, Json(json!({ "error": "forbidden" })))
}

/// Serialize an envelope for a 200 response (serialization can't realistically fail, but is not
/// unwrapped so a bug surfaces as a 500 rather than a panic).
fn ok<T: serde::Serialize>(value: &T) -> (StatusCode, Json<Value>) {
    match serde_json::to_value(value) {
        Ok(v) => (StatusCode::OK, Json(v)),
        Err(e) => error_response(Error::Other(e.to_string())),
    }
}

/// `GET /api/channels/:id` -> the channel envelope (generic: `id`, `type_id`, `container`, `payload`).
/// §9. The `type_id` is what lets the type-agnostic shell mount the right island.
pub async fn get_channel(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> (StatusCode, Json<Value>) {
    let Ok(cid) = id.parse::<ChannelId>() else {
        return bad_request("invalid channel id");
    };
    match state.core.store().get_channel(cid).await {
        Ok(Some(ch)) => ok(&ch),
        Ok(None) => not_found("channel"),
        Err(e) => error_response(e),
    }
}

/// `POST /api/channels/:id/contents { query }` -> the channel kind's type-defined contents. §5/§9.
/// The request body is the (opaque) query; the channel's kind interprets it.
pub async fn channel_contents(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(query): Json<Value>,
) -> (StatusCode, Json<Value>) {
    let Ok(cid) = id.parse::<ChannelId>() else {
        return bad_request("invalid channel id");
    };
    let store = state.core.store();
    let ch = match store.get_channel(cid).await {
        Ok(Some(ch)) => ch,
        Ok(None) => return not_found("channel"),
        Err(e) => return error_response(e),
    };
    match cp_core::contents::dispatch(&state.registry, &*store, &ch, query).await {
        Ok(value) => (StatusCode::OK, Json(value)),
        Err(e) => error_response(e),
    }
}

/// The body of `POST /api/channels/:id/items`: the item's type and its opaque payload. Type-agnostic —
/// the client's island names the `type_id`; core validates it via that kind and never inspects `payload`.
#[derive(Deserialize)]
pub struct PostItemBody {
    type_id: String,
    #[serde(default)]
    payload: Value,
}

/// `POST /api/channels/:id/items { type_id, payload }` -> create an item in the channel as the current
/// user (§18, `design/permissions.md`). Requires a session (the `CurrentUser` extractor → 401), the
/// channel kind's `Permission` to allow `Post` (→ 403, deny-by-default), and a known item type (→ 400).
/// The author is stamped server-side via the item kind's `with_author` (§2); `validate` + persist happen
/// in the write path. On success: 201 with the new id.
pub async fn post_item(
    CurrentUser(user): CurrentUser,
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<PostItemBody>,
) -> (StatusCode, Json<Value>) {
    let Ok(cid) = id.parse::<ChannelId>() else {
        return bad_request("invalid channel id");
    };
    let store = state.core.store();
    let ch = match store.get_channel(cid).await {
        Ok(Some(ch)) => ch,
        Ok(None) => return not_found("channel"),
        Err(e) => return error_response(e),
    };
    match cp_core::authz::authorize(&state.registry, &*store, &ch, user.id, Action::Post).await {
        Ok(true) => {}
        Ok(false) => return forbidden(),
        Err(e) => return error_response(e),
    }
    let type_id = TypeId::new(&body.type_id);
    let Some(kind) = state.registry.item(&type_id) else {
        return bad_request("unknown item type");
    };
    let payload = kind.with_author(body.payload, user.id);
    match store
        .create_item(NewItem {
            type_id,
            container: Some(cid),
            external_key: None,
            payload,
        })
        .await
    {
        Ok(item_id) => (
            StatusCode::CREATED,
            Json(json!({ "id": item_id.to_string() })),
        ),
        Err(e) => error_response(e),
    }
}

/// `GET /api/items/:id` -> the item envelope (generic). §9.
pub async fn get_item(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> (StatusCode, Json<Value>) {
    let Ok(iid) = id.parse::<ItemId>() else {
        return bad_request("invalid item id");
    };
    match state.core.store().get_item(iid).await {
        Ok(Some(item)) => ok(&item),
        Ok(None) => not_found("item"),
        Err(e) => error_response(e),
    }
}

/// `GET /api/users/:id/links` -> the external cached-user items this native user is linked to (§2/§19,
/// `design/linked-users.md`). Read-only — links are shell-provisioned. Bad id -> 400.
pub async fn get_user_links(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> (StatusCode, Json<Value>) {
    let Ok(uid) = id.parse::<UserId>() else {
        return bad_request("invalid user id");
    };
    match cp_core::links::linked_items(state.core.pool(), uid).await {
        Ok(items) => match serde_json::to_value(&items) {
            Ok(v) => (StatusCode::OK, Json(json!({ "items": v }))),
            Err(e) => error_response(Error::Other(e.to_string())),
        },
        Err(e) => error_response(e),
    }
}

/// `GET /api/items/:id/linked-user` -> the native user an external cached-user item resolves up to, or
/// 404 if it is unlinked (authorship resolution, §2/§19). The `cached-message` island calls this to show
/// "this external author = native user Alice."
pub async fn get_item_linked_user(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> (StatusCode, Json<Value>) {
    let Ok(iid) = id.parse::<ItemId>() else {
        return bad_request("invalid item id");
    };
    match cp_core::links::user_for_item(state.core.pool(), iid).await {
        Ok(Some(user)) => ok(&user),
        Ok(None) => not_found("linked user"),
        Err(e) => error_response(e),
    }
}
