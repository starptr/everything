//! End-to-end authenticated write (`TODO.md` #18, `design/permissions.md`): `POST /api/channels/:id/items`
//! over the real router via `oneshot`. Proves the full gate with the real `basic` slice — a session is
//! required (401), the kind's `Permission` must allow `Post` (basic = members-only → 403 for a
//! non-member; deny-by-default → 403 for a kind with no `Permission`), and on success the item is created
//! with its author stamped server-side (a client-supplied author is overwritten).

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::response::Response;
use axum::Router;
use cp_core::{auth, Core, Registry};
use cp_frontend::{router, AppState};
use cp_model::{ChannelId, NewChannel, TypeId, UserId, WriteCtx};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

async fn json_body(res: Response) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

struct Harness {
    _dir: tempfile::TempDir,
    app: Router,
    core: Arc<Core>,
}

async fn harness() -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_basic::channel())
        .item(cp_basic::item())
        .channel(cp_space::channel()) // no Permission → deny-by-default
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());
    let app = router(AppState {
        core: core.clone(),
        registry,
        web_dir: dir.path().to_path_buf(),
    });
    Harness {
        _dir: dir,
        app,
        core,
    }
}

/// Provision a user with a password, returning their id (the login path is shell-provisioned).
async fn user(core: &Core, handle: &str) -> UserId {
    let pool = core.store();
    let id = auth::provision_user(pool.pool(), handle).await.unwrap();
    auth::set_password(pool.pool(), handle, "pw").await.unwrap();
    id
}

async fn channel(core: &Core, type_id: &str) -> ChannelId {
    core.store()
        .create_channel(NewChannel {
            type_id: TypeId::new(type_id),
            container: None,
            payload: json!({ "name": type_id }),
        })
        .await
        .unwrap()
}

/// Log in and return the `cp_session=…` cookie pair.
async fn login(app: &Router, handle: &str) -> String {
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "handle": handle, "password": "pw" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    res.headers()
        .get(header::SET_COOKIE)
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned()
}

fn post_item(
    channel: ChannelId,
    cookie: Option<&str>,
    type_id: &str,
    payload: Value,
) -> Request<Body> {
    let body = json!({ "type_id": type_id, "payload": payload });
    let mut b = Request::builder()
        .method("POST")
        .uri(format!("/api/channels/{channel}/items"))
        .header("content-type", "application/json");
    if let Some(c) = cookie {
        b = b.header(header::COOKIE, c);
    }
    b.body(Body::from(body.to_string())).unwrap()
}

#[tokio::test]
async fn member_posts_and_author_is_stamped() {
    let h = harness().await;
    let alice = user(&h.core, "alice").await;
    let room = channel(&h.core, "basic").await;
    h.core.store().add_member(room, alice).await.unwrap();
    let cookie = login(&h.app, "alice").await;

    // A client-supplied author is present but must be ignored — the server stamps the real principal.
    let res = h
        .app
        .clone()
        .oneshot(post_item(
            room,
            Some(&cookie),
            "basic",
            json!({ "body": "hello", "author": "spoofed" }),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let id = json_body(res).await["id"].as_str().unwrap().to_owned();

    // The stored item carries the body and the authenticated author, not the spoofed one.
    let res = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/items/{id}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let item = json_body(res).await;
    assert_eq!(item["payload"]["body"], "hello");
    assert_eq!(item["payload"]["author"], alice.to_string());
}

#[tokio::test]
async fn unauthenticated_and_unauthorized_are_rejected() {
    let h = harness().await;
    let _alice = user(&h.core, "alice").await;
    let _bob = user(&h.core, "bob").await;
    let room = channel(&h.core, "basic").await;
    let space = channel(&h.core, "space").await;

    // No session → 401 (the CurrentUser extractor rejects before any handler logic).
    let res = h
        .app
        .clone()
        .oneshot(post_item(room, None, "basic", json!({ "body": "hi" })))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Logged in but not a member of the basic room → 403.
    let bob_cookie = login(&h.app, "bob").await;
    let res = h
        .app
        .clone()
        .oneshot(post_item(
            room,
            Some(&bob_cookie),
            "basic",
            json!({ "body": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);

    // A kind with no Permission capability (space) is deny-by-default, even for a member-less action → 403.
    let res = h
        .app
        .oneshot(post_item(
            space,
            Some(&bob_cookie),
            "basic",
            json!({ "body": "hi" }),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
}
