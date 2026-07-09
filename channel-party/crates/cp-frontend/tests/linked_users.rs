//! `linked-users` HTTP reads (`TODO.md` #19, `design/linked-users.md`) over the real router via
//! `oneshot`: list a user's external links, and resolve an item up to its native user (authorship
//! resolution). Links are seeded through the core API (they are shell-provisioned — no HTTP write).

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::response::Response;
use cp_core::{auth, links, Core, Registry};
use cp_frontend::{router, AppState};
use cp_model::{NewChannel, NewItem, TypeId, WriteCtx};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

async fn json_body(res: Response) -> Value {
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn get(uri: String) -> Request<Body> {
    Request::builder().uri(uri).body(Body::empty()).unwrap()
}

#[tokio::test]
async fn list_links_and_resolve_authorship() {
    let dir = tempfile::tempdir().unwrap();
    let url = format!("sqlite:{}", dir.path().join("t.db").display());
    let registry = Registry::builder()
        .channel(cp_basic::channel())
        .item(cp_basic::item())
        .build();
    let core = Arc::new(Core::open(&url, registry.clone()).await.unwrap());

    // Seed: alice, a channel, a linked item (stands in for a cached-user) and an unlinked one.
    let alice = auth::provision_user(core.pool(), "alice").await.unwrap();
    let store = core.store();
    let cid = store
        .create_channel(NewChannel {
            type_id: TypeId::new("basic"),
            container: None,
            payload: serde_json::json!({ "name": "general" }),
        })
        .await
        .unwrap();
    let mk_item = |body: &str| NewItem {
        type_id: TypeId::new("basic"),
        container: Some(cid),
        external_key: None,
        payload: serde_json::json!({ "body": body }),
    };
    let linked = store.create_item(mk_item("i-am-alice")).await.unwrap();
    let unlinked = store.create_item(mk_item("nobody")).await.unwrap();
    links::link(core.pool(), alice, linked).await.unwrap();

    let app = router(AppState {
        core: core.clone(),
        registry,
        web_dir: dir.path().to_path_buf(),
    });

    // GET /api/users/:id/links -> the linked item envelope.
    let res = app
        .clone()
        .oneshot(get(format!("/api/users/{alice}/links")))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = json_body(res).await;
    let items = body["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], linked.to_string());

    // GET /api/items/:id/linked-user -> alice (authorship resolution).
    let res = app
        .clone()
        .oneshot(get(format!("/api/items/{linked}/linked-user")))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(json_body(res).await["handle"], "alice");

    // The unlinked item resolves to nobody -> 404.
    let res = app
        .oneshot(get(format!("/api/items/{unlinked}/linked-user")))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}
